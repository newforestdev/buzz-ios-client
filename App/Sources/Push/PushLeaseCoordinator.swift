import CryptoKit
import Foundation
import NostrCore
import BuzzKit
import Security

/// Joins APNs, the gateway's installation authority, and the active relay's lease.
/// Installation metadata contains no APNs token or delivery capability; only the relay sees
/// the NIP-44 encrypted lease payload.
@MainActor
final class PushLeaseCoordinator {
    static let shared = PushLeaseCoordinator()
    private let defaults: UserDefaults
    private let attester: any PushAttesting
    private let transport = URLSessionHTTPTransport()
    private let recovery: PushEnrollmentRecovery
    private var activationInFlight = false
    private var revocationInFlight = false
    private var operationRevision = 0
    private let renewalWindow: Int64 = 7 * 24 * 60 * 60
    private let maximumTimestampLead: Int64 = 30

    init(defaults: UserDefaults = .standard, attester: any PushAttesting = ApplePushAttester(),
         installationStore: any PushInstallationStore = KeychainPushInstallationStore.shared) {
        self.defaults = defaults
        self.attester = attester
        recovery = PushEnrollmentRecovery(store: installationStore)
    }

    func activate(
        token: Data,
        relayURLString: String,
        signer: any EventSigner,
        engine: SyncEngine,
        directMessageChannelIDs: [String] = []
    ) async throws -> PushPreviewLease {
        let revision = operationRevision
        while activationInFlight || revocationInFlight {
            try check(revision)
            try await Task.sleep(for: .milliseconds(50))
        }
        try check(revision)
        activationInFlight = true
        defer { activationInFlight = false }
        guard let infoClient = RelayInfoClient(relayURLString: relayURLString, transport: transport),
              let descriptor = try await infoClient.fetch().push,
              let deliveryString = descriptor.endpoint ?? Bundle.main.object(forInfoDictionaryKey: "HivePushGatewayURL") as? String,
              let deliveryURL = URL(string: deliveryString),
              let gateway = PushGatewayClient(deliveryURL: deliveryURL, transport: transport)
        else { throw PushRegistrationError.unsupportedRelay }
        try check(revision)

        let pubkey = try await signer.publicKey().hex
        guard let relayPubkey = descriptor.currentKey?.pubkey else { throw PushRegistrationError.invalidDescriptor }
        let tokenHash = Data(SHA256.hash(data: token)).hexString
        let stateKey = leaseKey(origin: Self.normalizedRelayOrigin(descriptor.origin), pubkey: pubkey)
        let fingerprint = Self.leaseFingerprint(
            origin: descriptor.origin,
            deliveryURL: deliveryURL,
            ownerPubkey: pubkey,
            relayKeyID: descriptor.currentKey?.id ?? "",
            relayPubkey: relayPubkey,
            tokenHash: tokenHash,
            pushKinds: descriptor.pushEligibleKinds,
            dmChannelIDs: directMessageChannelIDs
        )
        let now = Int64(Date().timeIntervalSince1970)
        if let saved = loadLease(for: stateKey),
           saved.isActive == true,
           saved.activeLeaseFingerprint == fingerprint,
           let activeLeaseExpiresAt = saved.activeLeaseExpiresAt,
           activeLeaseExpiresAt > now + renewalWindow,
           let previewLease = saved.previewLease, previewLease.isActive(at: now) {
            return previewLease
        }
        var installation = try await prepareInstallation(
            token: token, deliveryURL: deliveryURL, gateway: gateway, revision: revision
        )

        var leaseState = try prepareLeaseState(
            descriptor: descriptor, deliveryURL: deliveryURL, pubkey: pubkey,
            stateKey: stateKey, installation: installation
        )

        let expiry = Int64(Date().timeIntervalSince1970) + 30 * 24 * 60 * 60
        // A replacement delegation may fence off the previous lease. Hide its
        // snapshot before this await; only the successfully queued lease restores it.
        PushPreviewCustody.clear()
        let grant = try await gateway.delegate(
            installation: installation,
            relayPubkey: relayPubkey,
            generation: leaseState.generation,
            expiresAt: expiry,
            attester: attester
        )
        do {
            try check(revision)
        } catch {
            try? await gateway.revokeDelegation(
                installation: installation,
                relayPubkey: relayPubkey,
                generation: leaseState.generation,
                attester: attester
            )
            throw error
        }
        installation = PushInstallation(
            keyID: installation.keyID,
            handle: installation.handle,
            endpointEpoch: installation.endpointEpoch,
            expiresAt: expiry,
            profile: installation.profile
        )
        leaseState.installation = installation
        leaseState.isActive = false
        leaseState.activeLeaseFingerprint = nil
        leaseState.activeLeaseExpiresAt = nil
        try recovery.remember(installation, gateway: gateway, tokenHash: tokenHash)
        saveInstallation(installation, tokenHash: tokenHash, deliveryURL: deliveryURL)
        saveLease(leaseState, for: stateKey)
        gateway.completeEnrollmentJournal()
        return try await queueLease(
            descriptor: descriptor,
            publication: LeasePublication(stateKey: stateKey, state: leaseState,
                                          fingerprint: fingerprint, revision: revision, grant: grant),
            signer: signer, engine: engine, directMessageChannelIDs: directMessageChannelIDs
        )
    }

    private func prepareInstallation(
        token: Data, deliveryURL: URL, gateway: PushGatewayClient, revision: Int
    ) async throws -> PushInstallation {
        let tokenHash = Data(SHA256.hash(data: token)).hexString
        PushPreviewCustody.clear()
        var savedInstallation = loadInstallation()
        // Migrate the existing defaults record before it can be replaced. The
        // Keychain archive survives loss of app defaults and keeps old issuers.
        if let savedInstallation,
           let issuerURL = URL(string: savedInstallation.deliveryURL),
           let issuer = PushGatewayClient(deliveryURL: issuerURL, transport: transport) {
            try recovery.remember(savedInstallation.installation, gateway: issuer,
                                  tokenHash: savedInstallation.tokenHash)
        }
        if let saved = savedInstallation,
           let issuerURL = URL(string: saved.deliveryURL),
           let issuer = PushGatewayClient(deliveryURL: issuerURL, transport: transport),
           let archived = try recovery.restoredRecord(for: saved.installation, gateway: issuer) {
            // Recover a crash between the Keychain write and the defaults write,
            // including the endpoint epoch/token hash after token rotation.
            savedInstallation = SavedInstallation(
                installation: archived.installation, tokenHash: archived.tokenHash,
                deliveryURL: saved.deliveryURL, profile: archived.installation.profile
            )
        }
        var installation: PushInstallation
        if let savedInstallation,
           savedInstallation.profile == PushGatewayClient.appProfile,
           savedInstallation.deliveryURL == deliveryURL.absoluteString,
           savedInstallation.installation.expiresAt > Int64(Date().timeIntervalSince1970) {
            if savedInstallation.tokenHash == tokenHash {
                installation = savedInstallation.installation
            } else {
                installation = try await gateway.rotateEndpoint(
                    token: token,
                    installation: savedInstallation.installation,
                    attester: attester
                )
                try recovery.remember(installation, gateway: gateway, tokenHash: tokenHash)
                saveInstallation(installation, tokenHash: tokenHash, deliveryURL: deliveryURL)
                try check(revision)
            }
        } else {
            let expiry = Int64(Date().timeIntervalSince1970) + 30 * 24 * 60 * 60
            installation = try await recovery.enroll(
                gateway: gateway,
                token: token,
                expiresAt: expiry,
                attester: attester
            )
            try check(revision)
            saveInstallation(installation, tokenHash: tokenHash, deliveryURL: deliveryURL)
        }

        return installation
    }

    private func prepareLeaseState(
        descriptor: RelayPushDescriptor, deliveryURL: URL, pubkey: String,
        stateKey: String, installation: PushInstallation
    ) throws -> SavedLeaseState {
        guard let relayPubkey = descriptor.currentKey?.pubkey else { throw PushRegistrationError.invalidDescriptor }
        var leaseState = loadLease(for: stateKey) ?? SavedLeaseState(
            origin: descriptor.origin,
            ownerPubkey: pubkey,
            relayPubkey: relayPubkey,
            deliveryURL: deliveryURL.absoluteString,
            installation: installation,
            d: Self.randomID(),
            generation: 0,
            executorKeyID: descriptor.currentKey?.id ?? "",
            executorPubkey: descriptor.currentKey?.pubkey ?? ""
        )
        guard !leaseState.d.isEmpty,
              let executorKeyID = descriptor.currentKey?.id,
              let executorPubkey = descriptor.currentKey?.pubkey
        else { throw PushRegistrationError.invalidDescriptor }
        leaseState.installation = installation
        leaseState.relayPubkey = relayPubkey
        leaseState.deliveryURL = deliveryURL.absoluteString
        leaseState.executorKeyID = executorKeyID
        leaseState.executorPubkey = executorPubkey
        guard let nextGeneration = PushLeaseGeneration.next(after: leaseState.generation) else {
            throw PushRegistrationError.invalidDescriptor
        }
        leaseState.generation = nextGeneration
        // Persist the next generation before the gateway accepts it. If the process is killed
        // after server admission, the next attempt advances again instead of replaying a
        // consumed generation.
        saveLease(leaseState, for: stateKey)

        return leaseState
    }
}

extension PushLeaseCoordinator {
    private func queueLease(
        descriptor: RelayPushDescriptor, publication: LeasePublication,
        signer: any EventSigner, engine: SyncEngine, directMessageChannelIDs: [String]
    ) async throws -> PushPreviewLease {
        let stateKey = publication.stateKey
        let leaseState = publication.state
        let installation = leaseState.installation
        let gatewayURL = try Self.deliveryURL(from: leaseState.deliveryURL)
        guard let gateway = PushGatewayClient(deliveryURL: gatewayURL, transport: transport) else {
            throw PushRegistrationError.invalidDescriptor
        }
        let revision = publication.revision
        let fingerprint = publication.fingerprint
        let pubkey = leaseState.ownerPubkey
        let relayPubkey = leaseState.relayPubkey
        let expiry = installation.expiresAt
        let lease = try await PushLeaseBuilder.build(
            descriptor: descriptor,
            endpointGrant: publication.grant,
            selfPubkey: pubkey,
            generation: leaseState.generation,
            expiresAt: expiry,
            signer: signer,
            directMessageChannelIDs: directMessageChannelIDs,
            d: leaseState.d
        )
        do {
            try check(revision)
        } catch {
            try? await gateway.revokeDelegation(
                installation: installation,
                relayPubkey: relayPubkey,
                generation: leaseState.generation,
                attester: attester
            )
            throw error
        }
        let publicationTimestamp = try await reservePublicationTimestamp(for: stateKey, revision: revision)
        try check(revision)
        _ = try await engine.enqueueProtocolEvent(
            kind: .pushLease,
            content: lease.content,
            tags: lease.tags,
            createdAt: Date(timeIntervalSince1970: TimeInterval(publicationTimestamp))
        )
        try check(revision)
        var publishedState = loadLease(for: stateKey) ?? leaseState
        publishedState.isActive = true
        publishedState.activeLeaseFingerprint = fingerprint
        publishedState.activeLeaseExpiresAt = expiry
        publishedState.previewLease = lease.previewLease
        saveLease(publishedState, for: stateKey)
        return lease.previewLease
    }

    private static func deliveryURL(from raw: String) throws -> URL {
        guard let url = URL(string: raw) else { throw PushRegistrationError.invalidDescriptor }
        return url
    }

    func cancelPendingActivation() { operationRevision &+= 1 }

    func revoke(relayURLString: String, signer: any EventSigner, engine: SyncEngine) async {
        revocationInFlight = true
        defer { revocationInFlight = false }
        cancelPendingActivation()
        while activationInFlight { try? await Task.sleep(for: .milliseconds(50)) }
        guard let pubkey = try? await signer.publicKey().hex,
              let stateKey = findLeaseKey(relayURLString: relayURLString, pubkey: pubkey),
              var state = loadLease(for: stateKey),
              let deliveryURL = URL(string: state.deliveryURL),
              let gateway = PushGatewayClient(deliveryURL: deliveryURL, transport: transport)
        else { return }

        // Turn off gateway authority first; an APNs wake cannot pass the delegation fence
        // even if the relay publish is offline. The addressable tombstone then removes the
        // relay-side matcher state as soon as its ordinary connection can accept the event.
        try? await gateway.revokeDelegation(
            installation: state.installation,
            relayPubkey: state.relayPubkey,
            generation: state.generation,
            attester: attester
        )
        guard let nextGeneration = PushLeaseGeneration.next(after: state.generation),
              let executorBytes = Data(hexString: state.executorPubkey),
              let executorKey = try? PublicKey(rawRepresentation: executorBytes)
        else { return }
        let plaintext = "{\"v\":1,\"origin\":\"\(state.origin)\",\"generation\":\(nextGeneration),\"active\":false}"
        guard let ciphertext = try? await signer.encrypt(plaintext, to: executorKey) else { return }
        let expiration = Int64(Date().timeIntervalSince1970) + 30 * 24 * 60 * 60
        let tags = [
            ["d", state.d], ["expiration", String(expiration)],
            ["exec", state.executorKeyID], ["alt", "Push lease"],
        ]
        state.generation = nextGeneration
        state.isActive = false
        state.activeLeaseFingerprint = nil
        state.activeLeaseExpiresAt = nil
        saveLease(state, for: stateKey)
        guard let publicationTimestamp = try? await reservePublicationTimestamp(for: stateKey, revision: nil) else { return }
        _ = try? await engine.enqueueProtocolEvent(
            kind: .pushLease,
            content: ciphertext,
            tags: tags,
            createdAt: Date(timeIntervalSince1970: TimeInterval(publicationTimestamp))
        )
        // Keep the address and watermark locally after revocation. The gateway also retains
        // its generation fence, so a later opt-in must replace this lease at a higher value.
    }

    func revokeGateway(relayURLString: String, pubkey: String) async {
        guard let stateKey = findLeaseKey(relayURLString: relayURLString, pubkey: pubkey),
              let state = loadLease(for: stateKey),
              let deliveryURL = URL(string: state.deliveryURL),
              let gateway = PushGatewayClient(deliveryURL: deliveryURL, transport: transport)
        else { return }
        do {
            try await gateway.revokeDelegation(
                installation: state.installation,
                relayPubkey: state.relayPubkey,
                generation: state.generation,
                attester: attester
            )
            // Retain lease identity/generation for a future opt-in. Revocation is a state
            // transition, not deletion of the installation's local generation watermark.
        } catch {
            // Keep the record so a later sign-out or settings change can retry revocation.
        }
    }

    private func loadInstallation() -> SavedInstallation? {
        guard let data = defaults.data(forKey: "push.installation.v1") else { return nil }
        return try? JSONDecoder().decode(SavedInstallation.self, from: data)
    }

    private func saveInstallation(_ installation: PushInstallation, tokenHash: String, deliveryURL: URL) {
        let value = SavedInstallation(
            installation: installation,
            tokenHash: tokenHash,
            deliveryURL: deliveryURL.absoluteString,
            profile: installation.profile
        )
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: "push.installation.v1") }
    }

    private func loadLease(for key: String) -> SavedLeaseState? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SavedLeaseState.self, from: data)
    }

    private func saveLease(_ state: SavedLeaseState, for key: String) {
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: key) }
    }

    private func check(_ revision: Int) throws {
        guard operationRevision == revision else { throw CancellationError() }
    }

    private func reservePublicationTimestamp(for stateKey: String, revision: Int?) async throws -> Int64 {
        while true {
            if let revision { try check(revision) }
            guard var state = loadLease(for: stateKey) else { throw PushRegistrationError.invalidDescriptor }
            let now = Int64(Date().timeIntervalSince1970)
            if state.lastPublishTimestamp == nil {
                // Migration from earlier builds: the prior event was signed from the
                // wall clock, so seed the watermark at this second and wait for the next
                // one. This also makes the first active lease and first tombstone use the
                // same single-writer ordering path.
                state.lastPublishTimestamp = now
                saveLease(state, for: stateKey)
                continue
            }
            if let last = state.lastPublishTimestamp, last >= now {
                let lead = last - now
                guard lead <= maximumTimestampLead else { throw PushRegistrationError.clockTooFarAhead }
                try await Task.sleep(for: .milliseconds(100))
                continue
            }
            guard let timestamp = PushLeaseTimestamp.next(now: now, last: state.lastPublishTimestamp) else {
                throw PushRegistrationError.invalidDescriptor
            }
            state.lastPublishTimestamp = timestamp
            saveLease(state, for: stateKey)
            return timestamp
        }
    }

    private func findLeaseKey(relayURLString: String, pubkey: String) -> String? {
        // The protocol origin is the relay's canonical websocket URL. The existing client
        // normalizes ws/wss spellings before constructing its connection.
        let candidate = Self.normalizedRelayOrigin(relayURLString)
        let key = leaseKey(origin: candidate, pubkey: pubkey)
        return defaults.data(forKey: key) == nil ? nil : key
    }

    private func leaseKey(origin: String, pubkey: String) -> String {
        let material = Data("\(origin)\n\(pubkey)".utf8)
        return "push.lease.v1.\(Data(SHA256.hash(data: material)).hexString)"
    }

    private static func leaseFingerprint(
        origin: String,
        deliveryURL: URL,
        ownerPubkey: String,
        relayKeyID: String,
        relayPubkey: String,
        tokenHash: String,
        pushKinds: [Int],
        dmChannelIDs: [String]
    ) -> String {
        let components = [
            "hive-push-lease-schema-v2", PushGatewayClient.appProfile,
            origin, deliveryURL.absoluteString, ownerPubkey,
            relayKeyID, relayPubkey, tokenHash,
            pushKinds.sorted().map(String.init).joined(separator: ","),
            Array(Set(dmChannelIDs)).sorted().joined(separator: ","),
        ]
        return Data(SHA256.hash(data: Data(components.joined(separator: "\n").utf8))).hexString
    }

    private static func normalizedRelayOrigin(_ raw: String) -> String {
        RelayEndpoint.websocketURLString(fromAnyRelay: raw) ?? raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func randomID() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return "" }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

private struct SavedInstallation: Codable {
    let installation: PushInstallation
    let tokenHash: String
    let deliveryURL: String
    let profile: String
}

private struct SavedLeaseState: Codable {
    let origin: String
    let ownerPubkey: String
    var relayPubkey: String
    var deliveryURL: String
    var installation: PushInstallation
    let d: String
    var generation: Int64
    var executorKeyID: String
    var executorPubkey: String
    var lastPublishTimestamp: Int64? = nil
    var isActive: Bool? = nil
    var activeLeaseFingerprint: String? = nil
    var activeLeaseExpiresAt: Int64? = nil
    var previewLease: PushPreviewLease? = nil
}

enum PushRegistrationError: Error { case unsupportedRelay, invalidDescriptor, busy, clockTooFarAhead }

enum PushLeaseGeneration {
    static func next(after current: Int64) -> Int64? {
        let (value, overflow) = current.addingReportingOverflow(1)
        return overflow || value <= 0 ? nil : value
    }
}

enum PushLeaseTimestamp {
    static func next(now: Int64, last: Int64?) -> Int64? {
        guard let last else { return now }
        guard let afterLast = PushLeaseGeneration.next(after: last) else { return nil }
        return max(now, afterLast)
    }
}

private struct LeasePublication {
    let stateKey: String
    let state: SavedLeaseState
    let fingerprint: String
    let revision: Int
    let grant: String
}
