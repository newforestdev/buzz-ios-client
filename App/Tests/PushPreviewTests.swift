import Foundation
import NostrCore
import Testing
@testable import Hive

struct PushPreviewTests {
    private let timestamp: Int64 = 1_791_450_000
    private let channel = "11111111-1111-4111-8111-111111111111"
    private func context(_ key: PrivateKey, relay: String = "wss://relay.example") -> PushPreviewContext {
        PushPreviewContext(communityID: "test", relayURL: relay, keychainAccount: "test", pubkey: key.publicKey.hex,
                           directMessageChannelIDs: [channel], since: timestamp - 30,
                           lease: PushPreviewLease(active: true, expiresAt: timestamp + 60, subscriptions: [
                            PushLeaseSubscription(filter: Filter(kinds: [9, 40002, 45001, 45003],
                                                                 tagQueries: ["p": [key.publicKey.hex]])),
                            PushLeaseSubscription(filter: Filter(kinds: [9, 40002], tagQueries: ["h": [channel]])),
                           ]))
    }
    private func event(_ key: PrivateKey, text: String, tags: [[String]], age: Int64 = 0, kind: EventKind = .channelMessage) throws -> NostrEvent {
        try NostrEvent.signed(kind: kind, content: text, tags: tags,
                             createdAt: Date(timeIntervalSince1970: TimeInterval(timestamp - age)), with: key)
    }
    @Test func previewRequiresAuthenticIncomingRecentScopedMessage() throws {
        let own = try PrivateKey(), peer = try PrivateKey()
        let incoming = try event(peer, text: "Hello", tags: [["h", channel]])
        let selfMessage = try event(own, text: "Outgoing", tags: [["h", channel]])
        let unrelated = try event(peer, text: "Private elsewhere", tags: [["h", "22222222-2222-4222-8222-222222222222"]])
        let old = try event(peer, text: "Stale", tags: [["h", channel]], age: 31)
        let forged = NostrEvent(id: incoming.id, pubkey: incoming.pubkey, createdAt: incoming.createdAt,
                               kind: incoming.kind, tags: incoming.tags, content: "Tampered", sig: incoming.sig)
        #expect(PushPreviewClient.select(
            [selfMessage, unrelated, old, forged, incoming], context: context(own), excluding: [], now: timestamp
        )?.id == incoming.id)
        #expect(PushPreviewClient.select([incoming], context: context(own), excluding: [incoming.id], now: timestamp) == nil)
        let mention = try event(peer, text: "Mention", tags: [["p", own.publicKey.hex]])
        #expect(PushPreviewClient.select([mention], context: context(own), excluding: [], now: timestamp)?.id == mention.id)
    }
    @Test func previewSkipsDotPlaceholderAndKeepsTheRealReply() throws {
        let own = try PrivateKey(), peer = try PrivateKey()
        let reply = try event(peer, text: "The response is ready.", tags: [["h", channel]], age: 1)
        let placeholder = try event(peer, text: " . \n", tags: [["h", channel]])

        #expect(PushPreviewClient.select([reply, placeholder], context: context(own), excluding: [], now: timestamp)?.id == reply.id)
        #expect(PushPreviewClient.select([placeholder], context: context(own), excluding: [], now: timestamp) == nil)
    }
    @Test func fetchUsesSignedPrivateRelayQueryAndVerifiedSenderProfile() async throws {
        let own = try PrivateKey(), peer = try PrivateKey()
        let incoming = try event(peer, text: "Hello\nfrom the relay", tags: [["h", channel]])
        let profile = try event(peer, text: #"{"display_name":"Test Agent"}"#, tags: [], kind: .agentProfile)
        let transport = FakeHTTPTransport()
        await transport.enqueue(status: 200, body: try JSONEncoder().encode([incoming]))
        await transport.enqueue(status: 200, body: try JSONEncoder().encode([profile]))
        let now = timestamp
        let client = PushPreviewClient(transport: transport, signer: InMemorySigner(own), now: { Date(timeIntervalSince1970: TimeInterval(now)) })
        let preview = try await client.fetch(context: context(own), excluding: [])
        #expect(preview?.sender == "Test Agent")
        #expect(preview?.text == "Hello from the relay")
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests[0].url.absoluteString == "https://relay.example/query")
        let auth = try #require(requests[0].headers["Authorization"])
        #expect(NIP98.validate(header: auth, url: requests[0].url, method: "POST", body: requests[0].body))
        let filters = try #require(JSONSerialization.jsonObject(with: requests[0].body) as? [[String: Any]])
        #expect(filters[0]["#p"] as? [String] == [own.publicKey.hex])
        #expect(filters[1]["#h"] as? [String] == [channel])
    }

    @Test func previewCarriesThreadRootForNotificationRouting() async throws {
        let own = try PrivateKey(), peer = try PrivateKey()
        let root = String(repeating: "1", count: 64)
        let parent = String(repeating: "2", count: 64)
        let reply = try event(peer, text: "A thread reply", tags: [
            ["h", channel], ["e", root, "", "root"], ["e", parent, "", "reply"]
        ])
        let transport = FakeHTTPTransport()
        await transport.enqueue(status: 200, body: try JSONEncoder().encode([reply]))
        await transport.enqueue(status: 200, body: Data("[]".utf8))
        let client = PushPreviewClient(
            transport: transport,
            signer: InMemorySigner(own),
            now: { Date(timeIntervalSince1970: TimeInterval(timestamp)) }
        )

        #expect(try await client.fetch(context: context(own), excluding: [])?.threadRootID == root)
    }
    @Test func previewRejectsHttpWrongIdentityAndRelayFailure() async throws {
        let own = try PrivateKey(), other = try PrivateKey()
        let transport = FakeHTTPTransport()
        let client = PushPreviewClient(transport: transport, signer: InMemorySigner(own),
                                       now: { Date(timeIntervalSince1970: TimeInterval(timestamp)) })
        await #expect(throws: PushPreviewError.self) { _ = try await client.fetch(context: context(own, relay: "http://relay.example"), excluding: []) }
        await #expect(throws: PushPreviewError.self) { _ = try await client.fetch(context: context(other), excluding: []) }
        await transport.enqueue(status: 403, body: Data())
        await #expect(throws: PushPreviewError.self) { _ = try await client.fetch(context: context(own), excluding: []) }
    }
    @Test(arguments: ["missing", "inactive", "expired", "future-version"])
    func previewDoesNotQueryWithoutAnActiveLease(_ scenario: String) async throws {
        let own = try PrivateKey()
        var snapshot = context(own)
        switch scenario {
        case "inactive":
            snapshot.lease = PushPreviewLease(active: false, expiresAt: timestamp + 60,
                                              subscriptions: snapshot.lease!.subscriptions)
        case "expired":
            snapshot.lease = PushPreviewLease(active: true, expiresAt: timestamp,
                                              subscriptions: snapshot.lease!.subscriptions)
        case "future-version": snapshot.lease?.version = 2
        default: snapshot.lease = nil
        }
        let transport = FakeHTTPTransport()
        let client = PushPreviewClient(transport: transport, signer: InMemorySigner(own),
                                       now: { Date(timeIntervalSince1970: TimeInterval(timestamp)) })
        await #expect(throws: PushPreviewError.self) { _ = try await client.fetch(context: snapshot, excluding: []) }
        #expect(await transport.requests.isEmpty)
    }

    @Test func previewHonoursSavedKindsChannelAndIgnoreFilters() async throws {
        let own = try PrivateKey(), peer = try PrivateKey(), ignored = try PrivateKey()
        var snapshot = context(own)
        snapshot.lease = PushPreviewLease(active: true, expiresAt: timestamp + 60, subscriptions: [
            PushLeaseSubscription(filter: Filter(kinds: [9], tagQueries: ["h": [channel]]),
                                  ignore: [Filter(authors: [ignored.publicKey.hex])]),
        ])
        let covered = try event(peer, text: "Covered", tags: [["h", channel]], age: 1)
        let ignoredMessage = try event(ignored, text: "Ignored", tags: [["h", channel]])
        let mentionOutsideLease = try event(peer, text: "Outside", tags: [["p", own.publicKey.hex]])
        let otherKind = try event(peer, text: "Other kind", tags: [["h", channel]], kind: .richMessage)
        let transport = FakeHTTPTransport()
        await transport.enqueue(status: 200, body: try JSONEncoder().encode([
            covered, ignoredMessage, mentionOutsideLease, otherKind,
        ]))
        await transport.enqueue(status: 200, body: Data("[]".utf8))
        let client = PushPreviewClient(transport: transport, signer: InMemorySigner(own),
                                       now: { Date(timeIntervalSince1970: TimeInterval(timestamp)) })
        #expect(try await client.fetch(context: snapshot, excluding: [])?.eventID == covered.id)
        let requests = await transport.requests
        let filters = try JSONDecoder().decode([Filter].self, from: requests[0].body)
        #expect(filters.count == 1)
        #expect(filters[0].kinds == [9])
        #expect(filters[0].tagQueries == ["h": [channel]])
        #expect(filters[0].limit == 30)
    }

    @Test func unknownSavedSelectorIsRejectedInsteadOfBroadeningQuery() throws {
        let data = Data(##"{"filter":{"kinds":[9],"#h":["room"],"future_selector":"value"},"class":"default"}"##.utf8)
        #expect(throws: PushPreviewError.self) { _ = try JSONDecoder().decode(PushLeaseSubscription.self, from: data) }
    }

    @Test func legacyPreviewContextDoesNotGrantConsent() throws {
        let json = #"{"communityID":"old","relayURL":"wss://relay.example","keychainAccount":"old","pubkey":"old","directMessageChannelIDs":[],"since":0}"#
        let snapshot = try JSONDecoder().decode(PushPreviewContext.self, from: Data(json.utf8))
        #expect(snapshot.lease == nil)
    }

    @Test func leaseExpiryDuringMessageOrProfileFetchKeepsGenericFallback() async throws {
        for expireOnRead in [3, 4] {
            let own = try PrivateKey(), peer = try PrivateKey()
            let transport = FakeHTTPTransport()
            await transport.enqueue(status: 200, body: try JSONEncoder().encode([
                event(peer, text: "Hello", tags: [["h", channel]]),
            ]))
            await transport.enqueue(status: 200, body: Data("[]".utf8))
            let clock = ExpiringPreviewClock(timestamp: timestamp, expireOnRead: expireOnRead)
            let client = PushPreviewClient(transport: transport, signer: InMemorySigner(own), now: { clock.read() })
            #expect(try await client.fetch(context: context(own), excluding: []) == nil)
            #expect(await transport.requests.count == expireOnRead - 2)
        }
    }

}


private final class ExpiringPreviewClock: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    private let timestamp: Int64
    private let expireOnRead: Int
    init(timestamp: Int64, expireOnRead: Int) {
        self.timestamp = timestamp
        self.expireOnRead = expireOnRead
    }
    func read() -> Date {
        lock.withLock {
            reads += 1
            return Date(timeIntervalSince1970: TimeInterval(timestamp + (reads >= expireOnRead ? 60 : 0)))
        }
    }
}
