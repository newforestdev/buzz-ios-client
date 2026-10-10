import Foundation
import BuzzKit
import NostrCore
import Security

/// Constructs the content-free reconnect lease the iOS app authorizes.
enum PushLeaseBuilder {
    struct Lease: Equatable, Sendable {
        let content: String
        let tags: [[String]]
        let d: String
        let expiresAt: Int64
        let generation: Int64
        let previewLease: PushPreviewLease
    }

    static func build(
        descriptor: RelayPushDescriptor,
        endpointGrant: String,
        selfPubkey: String,
        generation: Int64,
        expiresAt: Int64,
        signer: any EventSigner,
        directMessageChannelIDs: [String] = [],
        d: String? = nil
    ) async throws -> Lease {
        guard let key = descriptor.currentKey,
              let keyBytes = Data(hexString: key.pubkey),
              let executorKey = try? PublicKey(rawRepresentation: keyBytes),
              endpointGrant.utf8.count <= 4096,
              selfPubkey.count == 64,
              selfPubkey.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              generation > 0,
              let installationID = d ?? randomInstallationID()
        else { throw PushLeaseError.invalidInput }

        let supportedKinds = descriptor.pushEligibleKinds.sorted()
        guard !supportedKinds.isEmpty, supportedKinds.count <= 16 else { throw PushLeaseError.invalidInput }
        let kinds = supportedKinds.map { EventKind(rawValue: $0) }
        let ignoreSelf = [Filter(authors: [selfPubkey], kinds: kinds)]
        guard directMessageChannelIDs.allSatisfy(Self.isCanonicalUUIDv4) else {
            throw PushLeaseError.invalidDirectMessageChannel
        }
        var subscriptions = [
            PushLeaseSubscription(
                filter: Filter(kinds: kinds, tagQueries: ["p": [selfPubkey]]),
                ignore: ignoreSelf
            ),
        ]
        let dmKinds = [9, 40_002].filter(supportedKinds.contains)
        let dmChannels = Array(Set(directMessageChannelIDs)).sorted()
        if !dmChannels.isEmpty, !dmKinds.isEmpty {
            let maxH = descriptor.maxChannelIDs
            let maxSubscriptions = descriptor.maxSubscriptions
            guard maxH > 0,
                  maxSubscriptions > 1,
                  (dmChannels.count + maxH - 1) / maxH <= maxSubscriptions - 1
            else { throw PushLeaseError.tooManyDirectMessageChannels }
            for start in stride(from: 0, to: dmChannels.count, by: maxH) {
                let end = min(start + maxH, dmChannels.count)
                subscriptions.append(
                    PushLeaseSubscription(
                        filter: Filter(kinds: dmKinds.map { EventKind(rawValue: $0) },
                                       tagQueries: ["h": Array(dmChannels[start..<end])]),
                        ignore: ignoreSelf
                    )
                )
            }
        }
        guard subscriptions.count <= descriptor.maxSubscriptions else {
            throw PushLeaseError.tooManyDirectMessageChannels
        }

        let payload = LeasePayload(
            v: 1,
            origin: descriptor.origin,
            appProfile: PushGatewayClient.appProfile,
            transport: "apns",
            endpoint: endpointGrant,
            generation: generation,
            active: true,
            subscriptions: subscriptions
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let plaintext = try encoder.encode(payload)
        guard plaintext.count <= 32_768,
              let plaintextString = String(data: plaintext, encoding: .utf8)
        else { throw PushLeaseError.invalidInput }
        let ciphertext = try await signer.encrypt(plaintextString, to: executorKey)
        let tags = [
            ["d", installationID],
            ["expiration", String(expiresAt)],
            ["exec", key.id],
            ["alt", "Push lease"],
        ]
        return Lease(
            content: ciphertext,
            tags: tags,
            d: installationID,
            expiresAt: expiresAt,
            generation: generation,
            previewLease: PushPreviewLease(active: true, expiresAt: expiresAt, subscriptions: subscriptions)
        )
    }

    private static func randomInstallationID() -> String? {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func isCanonicalUUIDv4(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        let canonical = uuid.uuidString.lowercased()
        guard value == canonical else { return false }
        let chars = Array(value)
        return chars.count == 36 && chars[14] == "4" && ["8", "9", "a", "b"].contains(chars[19])
    }
}

enum PushLeaseError: Error, Equatable { case invalidInput, invalidDirectMessageChannel, tooManyDirectMessageChannels }

private struct LeasePayload: Encodable {
    let v: Int
    let origin: String
    let appProfile: String
    let transport: String
    let endpoint: String
    let generation: Int64
    let active: Bool
    let subscriptions: [PushLeaseSubscription]
    enum CodingKeys: String, CodingKey {
        case v, origin, transport, endpoint, generation, active, subscriptions
        case appProfile = "app_profile"
    }
}
