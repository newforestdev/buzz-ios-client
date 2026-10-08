import CryptoKit
import Foundation
import NostrCore
import Security

/// The client side of Buzz's App Attest backed endpoint custody protocol.
///
/// The gateway deliberately never learns a Nostr private key and the relay never sees the
/// APNs token. This object only enrolls the installation and asks the gateway to mint a
/// relay-scoped opaque delivery capability.
struct PushGatewayClient: Sendable {
    static let appProfile = "buzz-ios-dogfood"
    let baseURL: URL
    let transport: any HTTPTransport
    let enrollmentJournal: any PushEnrollmentJournal

    /// Builds a client from the delivery endpoint carried by the relay's NIP-11 push
    /// descriptor (for example `https://push.steelbeach.net/v1/deliveries/apns`). The
    /// gateway control routes share that origin and the `/v1` API prefix.
    init?(deliveryURL: URL, transport: any HTTPTransport = URLSessionHTTPTransport(), enrollmentJournal: any PushEnrollmentJournal = KeychainPushEnrollmentJournal.shared) {
        guard deliveryURL.scheme?.lowercased() == "https",
              deliveryURL.path.hasSuffix("/v1/deliveries/apns"),
              let host = deliveryURL.host
        else { return nil }
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = host
        parts.port = deliveryURL.port
        guard let origin = parts.url else { return nil }
        self.init(baseURL: origin, transport: transport, enrollmentJournal: enrollmentJournal)
    }

    init?(baseURL: URL, transport: any HTTPTransport = URLSessionHTTPTransport(), enrollmentJournal: any PushEnrollmentJournal = KeychainPushEnrollmentJournal.shared) {
        guard baseURL.scheme?.lowercased() == "https",
              baseURL.host != nil,
              baseURL.user == nil,
              baseURL.password == nil
        else { return nil }
        self.baseURL = baseURL
        self.transport = transport
        self.enrollmentJournal = enrollmentJournal
    }

    func enroll(
        token: Data,
        profile: String,
        expiresAt: Int64,
        attester: any PushAttesting
    ) async throws -> PushInstallation {
        guard !token.isEmpty, token.count <= 512 else { throw PushGatewayError.invalidToken }
        let endpoint = token.map { String(format: "%02x", $0) }.joined()
        guard profile == Self.appProfile else { throw PushGatewayError.invalidRequest }
        let tokenHash = Data(SHA256.hash(data: token)).hexString
        if let pending = enrollmentJournal.load() {
            guard pending.gatewayOrigin == gatewayOrigin,
                  pending.tokenHash == tokenHash,
                  pending.profile == profile else {
                throw PushGatewayError.pendingEnrollment
            }
            return try await replayEnrollment(pending)
        }

        let keyID = try await attester.generateKey()
        let challenge = try await self.challenge()
        let transcript = PushAttestationTranscript.enrollment(
            audience: "https://push.buzz.xyz/v1/installations",
            challenge: challenge,
            keyID: keyID,
            profile: profile,
            endpoint: endpoint,
            expiresAt: expiresAt
        )
        let attestation = try await attester.attest(keyID: keyID, clientData: Data(transcript.utf8))
        let request = EnrollmentRequest(
            challengeID: challenge.id,
            challenge: challenge.value,
            keyID: keyID,
            attestation: attestation.base64EncodedString(),
            profile: profile,
            endpoint: endpoint,
            expiresAt: expiresAt
        )
        let requestData = try JSONEncoder().encode(request)
        guard requestData.count <= 23_896 else { throw PushGatewayError.invalidRequest }
        let journal = PendingEnrollment(gatewayOrigin: gatewayOrigin, tokenHash: tokenHash, profile: profile, body: requestData)
        try enrollmentJournal.save(journal)
        let response = try await sendEnrollment(requestData)
        return PushInstallation(
            keyID: keyID,
            handle: response.installationHandle,
            endpointEpoch: response.endpointEpoch,
            expiresAt: response.expiresAt,
            profile: profile
        )
    }

    /// Keep the exact App Attest request in Keychain until the relay delegation state has
    /// been durably saved. The gateway's enrollment replay rule recovers a lost 201 response.
    func completeEnrollmentJournal() { enrollmentJournal.clear() }

    private func replayEnrollment(_ pending: PendingEnrollment) async throws -> PushInstallation {
        let response = try await sendEnrollment(pending.body)
        let request = try JSONDecoder().decode(EnrollmentRequest.self, from: pending.body)
        return PushInstallation(
            keyID: request.keyID,
            handle: response.installationHandle,
            endpointEpoch: response.endpointEpoch,
            expiresAt: response.expiresAt,
            profile: request.profile
        )
    }

    private func sendEnrollment(_ body: Data) async throws -> EnrollmentResponse {
        let (data, status) = try await transport.post(
            body: body,
            to: url("/v1/installations"),
            headers: ["Content-Type": "application/json", "Accept": "application/json"]
        )
        guard status == 201 else {
            if [400, 401, 404].contains(status) { enrollmentJournal.clear() }
            throw PushGatewayError.httpStatus(status)
        }
        guard let response = try? JSONDecoder().decode(EnrollmentResponse.self, from: data) else {
            throw PushGatewayError.invalidResponse
        }
        return response
    }

    func delegate(
        installation: PushInstallation,
        relayPubkey: String,
        generation: Int64,
        expiresAt: Int64,
        attester: any PushAttesting
    ) async throws -> String {
        guard relayPubkey.count == 64,
              relayPubkey.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              generation > 0
        else { throw PushGatewayError.invalidRequest }
        let challenge = try await self.challenge()
        let notBefore = Int64(Date().timeIntervalSince1970)
        let transcript = PushAttestationTranscript.delegation(
            audience: "https://push.buzz.xyz/v1/delegations",
            challenge: challenge,
            installation: installation,
            generation: generation,
            relayPubkey: relayPubkey,
            notBefore: notBefore,
            expiresAt: expiresAt
        )
        let assertion = try await attester.assertion(
            keyID: installation.keyID,
            clientDataHash: Data(SHA256.hash(data: Data(transcript.utf8)))
        )
        let body = DelegationRequest(
            challengeID: challenge.id,
            challenge: challenge.value,
            installationHandle: installation.handle,
            endpointEpoch: installation.endpointEpoch,
            generation: generation,
            relayPubkey: relayPubkey,
            notBefore: notBefore,
            expiresAt: expiresAt,
            assertion: assertion.base64EncodedString()
        )
        let response: DelegationResponse = try await post(body, path: "/v1/delegations", success: 201)
        return response.endpointGrant
    }

    func revoke(
        installation: PushInstallation,
        attester: any PushAttesting
    ) async throws {
        let challenge = try await self.challenge()
        let nextEpoch = installation.endpointEpoch + 1
        guard nextEpoch > installation.endpointEpoch else { throw PushGatewayError.invalidRequest }
        let transcript = PushAttestationTranscript.revokeInstallation(
            audience: "https://push.buzz.xyz/v1/installations/revoke",
            challenge: challenge,
            installation: installation,
            newEpoch: nextEpoch
        )
        let assertion = try await attester.assertion(
            keyID: installation.keyID,
            clientDataHash: Data(SHA256.hash(data: Data(transcript.utf8)))
        )
        let body = RevokeRequest(
            challengeID: challenge.id,
            challenge: challenge.value,
            installationHandle: installation.handle,
            endpointEpoch: installation.endpointEpoch,
            newEndpointEpoch: nextEpoch,
            assertion: assertion.base64EncodedString()
        )
        let _: StatusResponse = try await post(body, path: "/v1/installations/revoke", success: 200)
    }

    func rotateEndpoint(
        token: Data,
        installation: PushInstallation,
        attester: any PushAttesting
    ) async throws -> PushInstallation {
        guard !token.isEmpty, token.count <= 512 else { throw PushGatewayError.invalidToken }
        let challenge = try await self.challenge()
        let endpoint = token.map { String(format: "%02x", $0) }.joined()
        let nextEpoch = installation.endpointEpoch + 1
        guard nextEpoch > installation.endpointEpoch else { throw PushGatewayError.invalidRequest }
        let transcript = PushAttestationTranscript.rotateEndpoint(
            audience: "https://push.buzz.xyz/v1/installations/endpoint",
            challenge: challenge,
            installation: installation,
            newEpoch: nextEpoch,
            endpoint: endpoint
        )
        let assertion = try await attester.assertion(
            keyID: installation.keyID,
            clientDataHash: Data(SHA256.hash(data: Data(transcript.utf8)))
        )
        let request = RotateEndpointRequest(
            challengeID: challenge.id,
            challenge: challenge.value,
            installationHandle: installation.handle,
            endpointEpoch: installation.endpointEpoch,
            newEndpointEpoch: nextEpoch,
            endpoint: endpoint,
            assertion: assertion.base64EncodedString()
        )
        let _: StatusResponse = try await post(request, path: "/v1/installations/endpoint", success: 200)
        return PushInstallation(
            keyID: installation.keyID,
            handle: installation.handle,
            endpointEpoch: nextEpoch,
            expiresAt: installation.expiresAt,
            profile: installation.profile
        )
    }

    func revokeDelegation(
        installation: PushInstallation,
        relayPubkey: String,
        generation: Int64,
        attester: any PushAttesting
    ) async throws {
        let challenge = try await self.challenge()
        let transcript = PushAttestationTranscript.revokeDelegation(
            audience: "https://push.buzz.xyz/v1/delegations/revoke",
            challenge: challenge,
            installation: installation,
            relayPubkey: relayPubkey,
            generation: generation
        )
        let assertion = try await attester.assertion(
            keyID: installation.keyID,
            clientDataHash: Data(SHA256.hash(data: Data(transcript.utf8)))
        )
        let body = RevokeDelegationRequest(
            challengeID: challenge.id,
            challenge: challenge.value,
            installationHandle: installation.handle,
            relayPubkey: relayPubkey,
            generation: generation,
            assertion: assertion.base64EncodedString()
        )
        let _: StatusResponse = try await post(body, path: "/v1/delegations/revoke", success: 200)
    }

    private func challenge() async throws -> PushChallenge {
        let response: ChallengeResponse = try await post(VersionRequest(), path: "/v1/installations/challenges", success: 200)
        guard UUID(uuidString: response.challengeID) != nil,
              Data(base64URLEncoded: response.challenge)?.count == 32
        else { throw PushGatewayError.invalidResponse }
        return PushChallenge(id: response.challengeID, value: response.challenge)
    }

    private func post<Request: Encodable, Response: Decodable>(
        _ request: Request,
        path: String,
        success: Int,
        maximumBodyBytes: Int = 8192
    ) async throws -> Response {
        var destination = url(path)
        var body = try JSONEncoder().encode(request)
        // All protocol JSON is ASCII. JSONEncoder's key order is deliberately irrelevant on
        // the wire; App Attest signs the separately constructed ordered transcript.
        guard body.count <= maximumBodyBytes else { throw PushGatewayError.invalidRequest }
        let (data, status) = try await transport.post(
            body: body,
            to: destination,
            headers: ["Content-Type": "application/json", "Accept": "application/json"]
        )
        body.resetBytes(in: 0..<body.count)
        destination = url(path)
        guard status == success else { throw PushGatewayError.httpStatus(status) }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw PushGatewayError.invalidResponse
        }
        return decoded
    }

    private func url(_ path: String) -> URL {
        URL(string: path, relativeTo: baseURL)!.absoluteURL
    }

    private var gatewayOrigin: String {
        var components = URLComponents()
        components.scheme = baseURL.scheme
        components.host = baseURL.host
        components.port = baseURL.port
        return components.string ?? baseURL.absoluteString
    }
}

struct PushInstallation: Codable, Equatable, Sendable {
    let keyID: String
    let handle: String
    let endpointEpoch: Int64
    let expiresAt: Int64
    let profile: String
}

struct PushChallenge: Equatable, Sendable {
    let id: String
    let value: String
}

enum PushGatewayError: Error, Equatable {
    case invalidToken
    case invalidRequest
    case invalidResponse
    case pendingEnrollment
    case journalFailure
    case httpStatus(Int)
}

enum PushAttestationTranscript {
    static func enrollment(
        audience: String,
        challenge: PushChallenge,
        keyID: String,
        profile: String,
        endpoint: String,
        expiresAt: Int64
    ) -> String {
        "buzz.push.enroll.v1\n{\"v\":1,\"audience\":\(quoted(audience)),\"challenge_id\":\(quoted(challenge.id)),\"challenge\":\(quoted(challenge.value)),\"key_id\":\(quoted(keyID)),\"app_profile\":\(quoted(profile)),\"endpoint\":\(quoted(endpoint)),\"endpoint_epoch\":1,\"expires_at\":\(expiresAt)}"
    }

    static func delegation(
        audience: String,
        challenge: PushChallenge,
        installation: PushInstallation,
        generation: Int64,
        relayPubkey: String,
        notBefore: Int64,
        expiresAt: Int64
    ) -> String {
        "buzz.push.delegate.v1\n{\"v\":1,\"audience\":\(quoted(audience)),\"challenge_id\":\(quoted(challenge.id)),\"challenge\":\(quoted(challenge.value)),\"installation_handle\":\(quoted(installation.handle)),\"endpoint_epoch\":\(installation.endpointEpoch),\"generation\":\(generation),\"relay_pubkey\":\(quoted(relayPubkey)),\"not_before\":\(notBefore),\"expires_at\":\(expiresAt)}"
    }

    static func revokeInstallation(
        audience: String,
        challenge: PushChallenge,
        installation: PushInstallation,
        newEpoch: Int64
    ) -> String {
        "buzz.push.revoke-installation.v1\n{\"v\":1,\"audience\":\(quoted(audience)),\"challenge_id\":\(quoted(challenge.id)),\"challenge\":\(quoted(challenge.value)),\"installation_handle\":\(quoted(installation.handle)),\"endpoint_epoch\":\(installation.endpointEpoch),\"new_endpoint_epoch\":\(newEpoch)}"
    }

    static func rotateEndpoint(
        audience: String,
        challenge: PushChallenge,
        installation: PushInstallation,
        newEpoch: Int64,
        endpoint: String
    ) -> String {
        "buzz.push.rotate-endpoint.v1\n{\"v\":1,\"audience\":\(quoted(audience)),\"challenge_id\":\(quoted(challenge.id)),\"challenge\":\(quoted(challenge.value)),\"installation_handle\":\(quoted(installation.handle)),\"endpoint_epoch\":\(installation.endpointEpoch),\"new_endpoint_epoch\":\(newEpoch),\"endpoint\":\(quoted(endpoint))}"
    }

    static func revokeDelegation(
        audience: String,
        challenge: PushChallenge,
        installation: PushInstallation,
        relayPubkey: String,
        generation: Int64
    ) -> String {
        "buzz.push.revoke-delegation.v1\n{\"v\":1,\"audience\":\(quoted(audience)),\"challenge_id\":\(quoted(challenge.id)),\"challenge\":\(quoted(challenge.value)),\"installation_handle\":\(quoted(installation.handle)),\"relay_pubkey\":\(quoted(relayPubkey)),\"generation\":\(generation)}"
    }

    private static func quoted(_ string: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try! encoder.encode([string])
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }
}

private extension Data {
    init?(base64URLEncoded value: String) {
        var normalized = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        self.init(base64Encoded: normalized)
    }
}

private struct VersionRequest: Encodable { let v = 1 }
private struct EnrollmentRequest: Codable {
    let v = 1
    let challengeID: String
    let challenge: String
    let keyID: String
    let attestation: String
    let profile: String
    let endpoint: String
    let endpointEpoch = 1
    let expiresAt: Int64
    enum CodingKeys: String, CodingKey {
        case v, challenge, endpoint, attestation
        case challengeID = "challenge_id"
        case keyID = "key_id"
        case profile = "app_profile"
        case endpointEpoch = "endpoint_epoch"
        case expiresAt = "expires_at"
    }
}

struct PendingEnrollment: Codable, Sendable {
    let gatewayOrigin: String
    let tokenHash: String
    let profile: String
    let body: Data
}

protocol PushEnrollmentJournal: Sendable {
    func load() -> PendingEnrollment?
    func save(_ pending: PendingEnrollment) throws
    func clear()
}

final class KeychainPushEnrollmentJournal: PushEnrollmentJournal, @unchecked Sendable {
    static let shared = KeychainPushEnrollmentJournal()
    private let service = "net.steelbeach.hive.push.enrollment"
    private let account = "pending-v1"

    func load() -> PendingEnrollment? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return try? JSONDecoder().decode(PendingEnrollment.self, from: data)
    }

    func save(_ pending: PendingEnrollment) throws {
        let data = try JSONEncoder().encode(pending)
        let key: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update = SecItemUpdate(key as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            var add = key
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw PushGatewayError.journalFailure }
        } else if update != errSecSuccess {
            throw PushGatewayError.journalFailure
        }
    }

    func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
private struct DelegationRequest: Encodable {
    let v = 1
    let challengeID: String
    let challenge: String
    let installationHandle: String
    let endpointEpoch: Int64
    let generation: Int64
    let relayPubkey: String
    let notBefore: Int64
    let expiresAt: Int64
    let assertion: String
    enum CodingKeys: String, CodingKey {
        case v, challenge, generation, assertion
        case challengeID = "challenge_id"
        case installationHandle = "installation_handle"
        case endpointEpoch = "endpoint_epoch"
        case relayPubkey = "relay_pubkey"
        case notBefore = "not_before"
        case expiresAt = "expires_at"
    }
}
private struct RevokeRequest: Encodable {
    let v = 1
    let challengeID: String
    let challenge: String
    let installationHandle: String
    let endpointEpoch: Int64
    let newEndpointEpoch: Int64
    let assertion: String
    enum CodingKeys: String, CodingKey {
        case v, challenge, assertion
        case challengeID = "challenge_id"
        case installationHandle = "installation_handle"
        case endpointEpoch = "endpoint_epoch"
        case newEndpointEpoch = "new_endpoint_epoch"
    }
}
private struct RevokeDelegationRequest: Encodable {
    let v = 1
    let challengeID: String
    let challenge: String
    let installationHandle: String
    let relayPubkey: String
    let generation: Int64
    let assertion: String
    enum CodingKeys: String, CodingKey {
        case v, challenge, generation, assertion
        case challengeID = "challenge_id"
        case installationHandle = "installation_handle"
        case relayPubkey = "relay_pubkey"
    }
}
private struct RotateEndpointRequest: Encodable {
    let v = 1
    let challengeID: String
    let challenge: String
    let installationHandle: String
    let endpointEpoch: Int64
    let newEndpointEpoch: Int64
    let endpoint: String
    let assertion: String
    enum CodingKeys: String, CodingKey {
        case v, challenge, endpoint, assertion
        case challengeID = "challenge_id"
        case installationHandle = "installation_handle"
        case endpointEpoch = "endpoint_epoch"
        case newEndpointEpoch = "new_endpoint_epoch"
    }
}
private struct ChallengeResponse: Decodable {
    let challengeID: String
    let challenge: String
    enum CodingKeys: String, CodingKey { case challenge; case challengeID = "challenge_id" }
}
private struct EnrollmentResponse: Decodable {
    let installationHandle: String
    let endpointEpoch: Int64
    let expiresAt: Int64
    enum CodingKeys: String, CodingKey {
        case installationHandle = "installation_handle"
        case endpointEpoch = "endpoint_epoch"
        case expiresAt = "expires_at"
    }
}
private struct DelegationResponse: Decodable { let endpointGrant: String; enum CodingKeys: String, CodingKey { case endpointGrant = "endpoint_grant" } }
private struct StatusResponse: Decodable { let status: String }
