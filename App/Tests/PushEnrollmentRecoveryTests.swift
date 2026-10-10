import CryptoKit
import Foundation
import NostrCore
import Testing
@testable import Hive

struct PushEnrollmentRecoveryTests {
    private let challenge = #"{"challenge_id":"11111111-1111-4111-8111-111111111111","challenge":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}"#
    private let token = Data([1, 2, 3])
    private let expiry: Int64 = 1_900_000_000

    private func record(origin: String = "https://push.example", hash: String? = nil) -> PushInstallationRecord {
        PushInstallationRecord(
            gatewayOrigin: origin,
            tokenHash: hash ?? Data(SHA256.hash(data: token)).hexString,
            installation: PushInstallation(keyID: "old-key", handle: "old-handle", endpointEpoch: 4,
                                           expiresAt: expiry, profile: PushGatewayClient.appProfile)
        )
    }

    private func client(_ transport: FakeHTTPTransport, journal: RecoveryJournal) throws -> PushGatewayClient {
        try #require(PushGatewayClient(baseURL: URL(string: "https://push.example")!,
                                       transport: transport, enrollmentJournal: journal))
    }

    @Test func conflictRevokesWithOriginalKeyAndEpochThenEnrollsOnce() async throws {
        let transport = FakeHTTPTransport()
        let journal = RecoveryJournal()
        let store = RecoveryStore([record()])
        let attester = RecoveryAttester()
        await transport.enqueue(status: 200, body: challenge)
        await transport.enqueue(status: 409, body: #"{"error":"installation_conflict"}"#)
        await transport.enqueue(status: 200, body: challenge)
        await transport.enqueue(status: 200, body: #"{"status":"ok"}"#)
        await transport.enqueue(status: 200, body: challenge)
        await transport.enqueue(status: 201, body: #"{"installation_handle":"new-handle","endpoint_epoch":1,"expires_at":1900000000}"#)

        let result = try await PushEnrollmentRecovery(store: store).enroll(
            gateway: client(transport, journal: journal), token: token, expiresAt: expiry, attester: attester
        )

        #expect(result.handle == "new-handle")
        #expect(await attester.assertionKeys == ["old-key"])
        #expect(await attester.generatedKeys == 2)
        let requests = await transport.requests
        #expect(requests.count == 6)
        #expect(requests[3].url.path == "/v1/installations/revoke")
        let body = try #require(JSONSerialization.jsonObject(with: requests[3].body) as? [String: Any])
        #expect(body["installation_handle"] as? String == "old-handle")
        #expect(body["endpoint_epoch"] as? Int == 4)
        #expect(body["new_endpoint_epoch"] as? Int == 5)
        let expected = PushAttestationTranscript.revokeInstallation(
            audience: "https://push.buzz.xyz/v1/installations/revoke",
            challenge: PushChallenge(id: "11111111-1111-4111-8111-111111111111",
                                     value: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"),
            installation: record().installation, newEpoch: 5
        )
        #expect(await attester.assertionHashes == [Data(SHA256.hash(data: Data(expected.utf8)))])
        #expect(try store.load().map(\.installation.handle) == ["new-handle"])
        #expect(journal.load() != nil)
    }

    @Test(arguments: ["missing", "other-gateway", "other-token"])
    func conflictCannotRevokeWithoutMatchingCredentials(_ scenario: String) async throws {
        let transport = FakeHTTPTransport()
        let records: [PushInstallationRecord]
        switch scenario {
        case "other-gateway": records = [record(origin: "https://another.example")]
        case "other-token": records = [record(hash: "different-token-hash")]
        default: records = []
        }
        let store = RecoveryStore(records)
        let journal = RecoveryJournal()
        await transport.enqueue(status: 200, body: challenge)
        await transport.enqueue(status: 409, body: #"{"error":"installation_conflict"}"#)
        await #expect(throws: PushGatewayError.missingInstallationCredentials) {
            _ = try await PushEnrollmentRecovery(store: store).enroll(
                gateway: client(transport, journal: journal), token: token,
                expiresAt: expiry, attester: RecoveryAttester()
            )
        }
        #expect(await transport.requests.count == 2)
        #expect(try store.load() == records)
        #expect(journal.load() != nil)
    }

    @Test(arguments: [401, 404, 500])
    func failedRevokeRetainsCredentialsAndEnrollmentJournal(_ status: Int) async throws {
        let transport = FakeHTTPTransport()
        let original = record()
        let store = RecoveryStore([original])
        let journal = RecoveryJournal()
        await transport.enqueue(status: 200, body: challenge)
        await transport.enqueue(status: 409, body: #"{"error":"installation_conflict"}"#)
        await transport.enqueue(status: 200, body: challenge)
        await transport.enqueue(status: status, body: #"{"error":"not_authorized"}"#)
        let recovery = PushEnrollmentRecovery(store: store, now: { 1_800_000_000 })
        await #expect(throws: PushGatewayError.httpStatus(status)) {
            _ = try await recovery.enroll(gateway: client(transport, journal: journal), token: token,
                                         expiresAt: expiry, attester: RecoveryAttester())
        }
        #expect(try store.load() == [original])
        #expect(journal.load() != nil)
        #expect(await transport.requests.count == 4)
    }

    @Test func retryIsBoundedWhenGatewayStillReportsConflict() async throws {
        let transport = FakeHTTPTransport()
        let journal = RecoveryJournal()
        await transport.enqueue(status: 200, body: challenge)
        await transport.enqueue(status: 409, body: #"{"error":"installation_conflict"}"#)
        await transport.enqueue(status: 200, body: challenge)
        await transport.enqueue(status: 200, body: #"{"status":"ok"}"#)
        await transport.enqueue(status: 200, body: challenge)
        await transport.enqueue(status: 409, body: #"{"error":"installation_conflict"}"#)
        await #expect(throws: PushGatewayError.installationConflict) {
            _ = try await PushEnrollmentRecovery(store: RecoveryStore([record()])).enroll(
                gateway: client(transport, journal: journal), token: token,
                expiresAt: expiry, attester: RecoveryAttester()
            )
        }
        #expect(await transport.requests.count == 6)
    }

    @Test func expired404CanBeDiscardedBeforeRetry() async throws {
        let transport = FakeHTTPTransport()
        let store = RecoveryStore([record()])
        let journal = RecoveryJournal()
        await transport.enqueue(status: 200, body: challenge)
        await transport.enqueue(status: 409, body: #"{"error":"installation_conflict"}"#)
        await transport.enqueue(status: 200, body: challenge)
        await transport.enqueue(status: 404, body: #"{"error":"not_authorized"}"#)
        await transport.enqueue(status: 200, body: challenge)
        await transport.enqueue(status: 201, body: #"{"installation_handle":"new-handle","endpoint_epoch":1,"expires_at":2000000000}"#)
        let recovery = PushEnrollmentRecovery(store: store, now: { 1_900_000_001 })
        _ = try await recovery.enroll(gateway: client(transport, journal: journal), token: token,
                                     expiresAt: 2_000_000_000, attester: RecoveryAttester())
        #expect(try store.load().map(\.installation.handle) == ["new-handle"])
    }

    @Test func unrelated409DoesNotTriggerRevocation() async throws {
        let transport = FakeHTTPTransport()
        let journal = RecoveryJournal()
        await transport.enqueue(status: 200, body: challenge)
        await transport.enqueue(status: 409, body: #"{"error":"different_conflict"}"#)
        await #expect(throws: PushGatewayError.httpStatus(409)) {
            _ = try await PushEnrollmentRecovery(store: RecoveryStore([record()])).enroll(
                gateway: client(transport, journal: journal), token: token,
                expiresAt: expiry, attester: RecoveryAttester()
            )
        }
        #expect(await transport.requests.count == 2)
    }

    @Test func lostEnrollmentResponseReplaysExactRequestAndArchivesCredentials() async throws {
        let transport = FakeHTTPTransport()
        let journal = RecoveryJournal()
        let store = RecoveryStore([])
        let gateway = try client(transport, journal: journal)
        let attester = RecoveryAttester()
        let recovery = PushEnrollmentRecovery(store: store)
        await transport.enqueue(status: 200, body: challenge)
        await transport.enqueueFailure(.connectionClosed)
        await #expect(throws: TransportError.connectionClosed) {
            _ = try await recovery.enroll(gateway: gateway, token: token, expiresAt: expiry, attester: attester)
        }
        #expect(store.load().isEmpty)
        #expect(journal.load() != nil)
        await transport.enqueue(status: 201, body: #"{"installation_handle":"replayed","endpoint_epoch":1,"expires_at":1900000000}"#)
        let installation = try await recovery.enroll(
            gateway: gateway, token: token, expiresAt: expiry, attester: attester
        )
        let requests = await transport.requests
        #expect(requests.count == 3)
        #expect(requests[1].body == requests[2].body)
        #expect(await attester.generatedKeys == 1)
        #expect(store.load().first?.installation == installation)
    }

    @Test func staleDefaultsCannotOverwriteArchivedRotationCredentials() throws {
        let old = record()
        let rotated = PushInstallation(keyID: old.installation.keyID, handle: old.installation.handle,
                                       endpointEpoch: 5, expiresAt: expiry, profile: PushGatewayClient.appProfile)
        let archive = PushInstallationRecord(gatewayOrigin: old.gatewayOrigin, tokenHash: "rotated-token",
                                             installation: rotated)
        let store = RecoveryStore([archive])
        let recovery = PushEnrollmentRecovery(store: store)
        let gateway = try client(FakeHTTPTransport(), journal: RecoveryJournal())
        try recovery.remember(old.installation, gateway: gateway, tokenHash: old.tokenHash)
        #expect(store.load() == [archive])
        #expect(try recovery.restoredRecord(for: old.installation, gateway: gateway) == archive)
    }
}

private final class RecoveryStore: PushInstallationStore, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [PushInstallationRecord]
    init(_ records: [PushInstallationRecord]) { self.records = records }
    func load() -> [PushInstallationRecord] { lock.withLock { records } }
    func save(_ record: PushInstallationRecord) {
        lock.withLock {
            records.removeAll {
                $0.gatewayOrigin == record.gatewayOrigin && $0.installation.handle == record.installation.handle
            }
            records.append(record)
        }
    }
    func remove(_ record: PushInstallationRecord) { lock.withLock { records.removeAll { $0 == record } } }
}

private final class RecoveryJournal: PushEnrollmentJournal, @unchecked Sendable {
    private let lock = NSLock()
    private var value: PendingEnrollment?
    func load() -> PendingEnrollment? { lock.withLock { value } }
    func save(_ pending: PendingEnrollment) { lock.withLock { value = pending } }
    func clear() { lock.withLock { value = nil } }
}

private actor RecoveryAttester: PushAttesting {
    private(set) var generatedKeys = 0
    private(set) var assertionKeys: [String] = []
    private(set) var assertionHashes: [Data] = []
    func generateKey() async throws -> String {
        generatedKeys += 1
        return "new-key-\(generatedKeys)"
    }
    func attest(keyID: String, clientData: Data) async throws -> Data { Data([1]) }
    func assertion(keyID: String, clientDataHash: Data) async throws -> Data {
        assertionKeys.append(keyID)
        assertionHashes.append(clientDataHash)
        return Data([2])
    }
}
