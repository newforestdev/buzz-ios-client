import CryptoKit
import Foundation
import NostrCore
import BuzzKit
@testable import Hive
import Testing

struct PushGatewayClientTests {
    @Test func transcriptEscapingMatchesGatewayJSONWithoutEscapingSlashes() throws {
        let value = "https://push.example/\"\\\n\r\t\u{08}\u{0C}\u{01}é"
        let transcript = PushAttestationTranscript.enrollment(
            audience: value, challenge: PushChallenge(id: "challenge", value: "nonce"),
            keyID: "key", profile: "profile", endpoint: "token", expiresAt: 1
        )
        let json = try #require(transcript.split(separator: "\n", maxSplits: 1).last)
        #expect(json.contains("https://push.example/"))
        #expect(json.contains("\\u0001"))
        let decoded = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(decoded["audience"] as? String == value)
    }

    @Test func generationWatermarkSurvivesRevocationAndCannotOverflow() {
        #expect(PushLeaseGeneration.next(after: 0) == 1)
        #expect(PushLeaseGeneration.next(after: 7) == 8)
        #expect(PushLeaseGeneration.next(after: Int64.max) == nil)
    }

    @Test func activeReplacementsAndTombstonesAdvancePastSameSecondTimestamp() {
        let firstActive = PushLeaseTimestamp.next(now: 1_800_000_000, last: nil)
        let secondActive = PushLeaseTimestamp.next(now: 1_800_000_000, last: firstActive)
        let inactiveTombstone = PushLeaseTimestamp.next(now: 1_800_000_000, last: secondActive)

        #expect(firstActive == 1_800_000_000)
        #expect(secondActive == 1_800_000_001)
        #expect(inactiveTombstone == 1_800_000_002)
        #expect(PushLeaseTimestamp.next(now: 1_800_000_000, last: Int64.max) == nil)
    }

    @Test func enrollmentSignsExactOrderedTranscriptAndSendsHexToken() async throws {
        let transport = FakeHTTPTransport()
        let journal = MemoryPushEnrollmentJournal()
        await transport.enqueue(status: 200, body: #"""
        {"challenge_id":"11111111-1111-4111-8111-111111111111",
            "challenge":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "expires_at":1900000000}
        """#)
        await transport.enqueue(status: 201, body: #"""
        {"installation_handle":"22222222-2222-4222-8222-222222222222",
            "endpoint_epoch":1,
            "expires_at":1900000000}
        """#)
        let attester = RecordingPushAttester()
        let client = try #require(PushGatewayClient(baseURL: URL(string: "https://push.example")!, transport: transport, enrollmentJournal: journal))

        let installation = try await client.enroll(
            token: Data([0x00, 0xab, 0xff]),
            profile: "buzz-ios-dogfood",
            expiresAt: 1_900_000_000,
            attester: attester
        )

        #expect(installation.handle == "22222222-2222-4222-8222-222222222222")
        let transcript = await attester.attestedClientData
        #expect(String(decoding: transcript!, as: UTF8.self) == "buzz.push.enroll.v1\n{\"v\":1"
            + ",\"audience\":\"https://push.buzz.xyz/v1/installations\""
            + ",\"challenge_id\":\"11111111-1111-4111-8111-111111111111\""
            + ",\"challenge\":\"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\""
            + ",\"key_id\":\"test-key-id\""
            + ",\"app_profile\":\"buzz-ios-dogfood\""
            + ",\"endpoint\":\"00abff\""
            + ",\"endpoint_epoch\":1"
            + ",\"expires_at\":1900000000}")
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests[0].url.absoluteString == "https://push.example/v1/installations/challenges")
        #expect(requests[1].url.absoluteString == "https://push.example/v1/installations")
        #expect(requests[1].headers["Content-Type"] == "application/json")
        #expect(String(decoding: requests[1].body, as: UTF8.self).contains("\"endpoint\":\"00abff\""))
        #expect(!String(decoding: requests[1].body, as: UTF8.self).contains("00:ab:ff"))
        #expect(journal.load() != nil)
        client.completeEnrollmentJournal()
        #expect(journal.load() == nil)
    }

    @Test func delegationHashesExactTranscriptAndReturnsOpaqueGrant() async throws {
        let transport = FakeHTTPTransport()
        await transport.enqueue(status: 200, body: #"""
        {"challenge_id":"11111111-1111-4111-8111-111111111111",
            "challenge":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "expires_at":1900000000}
        """#)
        await transport.enqueue(status: 201, body: #"{"endpoint_grant":"grant:opaque-value"}"#)
        let attester = RecordingPushAttester()
        let installation = PushInstallation(
            keyID: "test-key-id",
            handle: "22222222-2222-4222-8222-222222222222",
            endpointEpoch: 1,
            expiresAt: 1_900_000_000,
            profile: "buzz-ios-dogfood"
        )
        let client = try #require(PushGatewayClient(baseURL: URL(string: "https://push.example")!, transport: transport))

        let grant = try await client.delegate(
            installation: installation,
            relayPubkey: String(repeating: "a", count: 64),
            generation: 3,
            expiresAt: 1_800_000_000,
            attester: attester
        )

        #expect(grant == "grant:opaque-value")
        let requests = await transport.requests
        let requestBody = try #require(JSONSerialization.jsonObject(with: requests[1].body) as? [String: Any])
        let notBefore = try #require(requestBody["not_before"] as? Int64)
        let transcript = "buzz.push.delegate.v1\n{\"v\":1"
            + ",\"audience\":\"https://push.buzz.xyz/v1/delegations\""
            + ",\"challenge_id\":\"11111111-1111-4111-8111-111111111111\""
            + ",\"challenge\":\"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\""
            + ",\"installation_handle\":\"22222222-2222-4222-8222-222222222222\""
            + ",\"endpoint_epoch\":1"
            + ",\"generation\":3"
            + ",\"relay_pubkey\":\"\(String(repeating: "a", count: 64))\""
            + ",\"not_before\":\(notBefore)"
            + ",\"expires_at\":1800000000}"
        #expect(await attester.assertionHashes.last == Data(SHA256.hash(data: Data(transcript.utf8))))
    }

    @Test func gatewayMustBeHttpsAndChallengeMustBeWellFormed() async throws {
        let invalidClient = PushGatewayClient(baseURL: URL(string: "http://push.example")!)
        #expect({ if case nil = invalidClient { true } else { false } }())
        let transport = FakeHTTPTransport()
        await transport.enqueue(status: 200, body: #"{"challenge_id":"not-a-uuid","challenge":"bad","expires_at":1900000000}"#)
        let client = try #require(PushGatewayClient(baseURL: URL(string: "https://push.example")!, transport: transport))
        await #expect(throws: PushGatewayError.invalidResponse) {
            _ = try await client.enroll(
                token: Data([0x01]), profile: "buzz-ios-dogfood", expiresAt: 1_900_000_000,
                attester: RecordingPushAttester()
            )
        }
    }

    @Test func leaseUsesRelayKindsAndAddsMentionAndDMChannelFilters() async throws {
        let userKey = try PrivateKey()
        let executorKey = try PrivateKey()
        let descriptorJSON = """
        {"origin":"wss://relay.example",
        "keys":[{"id":"key-1",
        "pubkey":"\(executorKey.publicKey.hex)",
        "current":true}],
        "app_profiles":[{"id":"buzz-ios-dogfood",
        "transport":"apns"}],
        "push_kinds":[9,
        40002,
        45001,
        45003],
        "limitation":{"max_h":2,
        "max_subscriptions_per_lease":16}}
        """
        let descriptor = try JSONDecoder().decode(RelayPushDescriptor.self, from: Data(descriptorJSON.utf8))
        let signer = InMemorySigner(userKey)
        let lease = try await PushLeaseBuilder.build(
            descriptor: descriptor,
            endpointGrant: "capability:opaque",
            selfPubkey: userKey.publicKey.hex,
            generation: 2,
            expiresAt: 1_900_000_000,
            signer: signer,
            directMessageChannelIDs: [
                "123e4567-e89b-42d3-a456-426614174000",
                "123e4567-e89b-42d3-a456-426614174001",
                "123e4567-e89b-42d3-a456-426614174002",
            ],
            d: String(repeating: "c", count: 32)
        )
        let plaintext = try NIP44.decrypt(
            lease.content,
            conversationKey: NIP44.conversationKey(privateKey: executorKey, peer: userKey.publicKey)
        )
        let payload = try #require(JSONSerialization.jsonObject(with: Data(plaintext.utf8)) as? [String: Any])
        #expect(payload["origin"] as? String == "wss://relay.example")
        #expect(payload["app_profile"] as? String == "buzz-ios-dogfood")
        #expect(payload["endpoint"] as? String == "capability:opaque")
        let subscriptions = try #require(payload["subscriptions"] as? [[String: Any]])
        #expect(subscriptions.count == 3)
        let mentionFilter = try #require(subscriptions[0]["filter"] as? [String: Any])
        #expect(mentionFilter["kinds"] as? [Int] == [9, 40002, 45001, 45003])
        #expect(mentionFilter["#p"] as? [String] == [userKey.publicKey.hex])
        let mentionIgnore = try #require(subscriptions[0]["ignore"] as? [[String: Any]])
        #expect(mentionIgnore.first?["kinds"] as? [Int] == [9, 40002, 45001, 45003])
        #expect(mentionIgnore.first?["authors"] as? [String] == [userKey.publicKey.hex])
        let dmFilters = subscriptions.dropFirst().compactMap { $0["filter"] as? [String: Any] }
        #expect(dmFilters.count == 2)
        #expect(dmFilters.allSatisfy { $0["kinds"] as? [Int] == [9, 40002] })
        #expect(dmFilters.flatMap { $0["#h"] as? [String] ?? [] } == [
            "123e4567-e89b-42d3-a456-426614174000",
            "123e4567-e89b-42d3-a456-426614174001",
            "123e4567-e89b-42d3-a456-426614174002",
        ])
        #expect(subscriptions.dropFirst().allSatisfy {
            guard let ignore = ($0["ignore"] as? [[String: Any]])?.first else { return false }
            return ignore["kinds"] as? [Int] == [9, 40002, 45001, 45003]
                && ignore["authors"] as? [String] == [userKey.publicKey.hex]
        })
        let savedSubscriptions = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(lease.previewLease.subscriptions)
        ) as? [[String: Any]]
        #expect(NSDictionary(dictionary: ["subscriptions": subscriptions])
            == NSDictionary(dictionary: ["subscriptions": savedSubscriptions ?? []]))
        #expect(lease.previewLease.expiresAt == 1_900_000_000)
        #expect(!plaintext.contains("1059"))
        #expect(!plaintext.contains("token"))
        #expect(lease.tags == [["d", String(repeating: "c", count: 32)], ["expiration", "1900000000"], ["exec", "key-1"], ["alt", "Push lease"]])
    }

    @Test func leaseFailsInsteadOfDroppingDMChannelsPastDescriptorSubscriptionLimit() async throws {
        let userKey = try PrivateKey()
        let executorKey = try PrivateKey()
        let descriptorJSON = """
        {"origin":"wss://relay.example",
        "keys":[{"id":"key-1",
        "pubkey":"\(executorKey.publicKey.hex)",
        "current":true}],
        "app_profiles":[{"id":"buzz-ios-dogfood",
        "transport":"apns"}],
        "push_kinds":[9,
        40002,
        45001,
        45003],
        "limitation":{"max_h":2,
        "max_subscriptions_per_lease":2}}
        """
        let descriptor = try JSONDecoder().decode(RelayPushDescriptor.self, from: Data(descriptorJSON.utf8))
        await #expect(throws: PushLeaseError.tooManyDirectMessageChannels) {
            _ = try await PushLeaseBuilder.build(
                descriptor: descriptor,
                endpointGrant: "capability:opaque",
                selfPubkey: userKey.publicKey.hex,
                generation: 2,
                expiresAt: 1_900_000_000,
                signer: InMemorySigner(userKey),
                directMessageChannelIDs: [
                    "123e4567-e89b-42d3-a456-426614174000",
                    "123e4567-e89b-42d3-a456-426614174001",
                    "123e4567-e89b-42d3-a456-426614174002",
                ],
                d: String(repeating: "c", count: 32)
            )
        }
    }
}

private final class MemoryPushEnrollmentJournal: PushEnrollmentJournal, @unchecked Sendable {
    private let lock = NSLock()
    private var value: PendingEnrollment?
    func load() -> PendingEnrollment? { lock.withLock { value } }
    func save(_ pending: PendingEnrollment) { lock.withLock { value = pending } }
    func clear() { lock.withLock { value = nil } }
}

private actor RecordingPushAttester: PushAttesting {
    private(set) var attestedClientData: Data?
    private(set) var assertionHashes: [Data] = []

    func generateKey() async throws -> String { "test-key-id" }
    func attest(keyID: String, clientData: Data) async throws -> Data {
        attestedClientData = clientData
        return Data([1, 2, 3])
    }
    func assertion(keyID: String, clientDataHash: Data) async throws -> Data {
        assertionHashes.append(clientDataHash)
        return Data([4, 5, 6])
    }
}
