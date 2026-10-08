import Foundation
import NostrCore
import Testing
@testable import Hive

struct PushPreviewTests {
    private let timestamp: Int64 = 1_791_450_000
    private let channel = "11111111-1111-4111-8111-111111111111"
    private func context(_ key: PrivateKey, relay: String = "wss://relay.example") -> PushPreviewContext {
        PushPreviewContext(communityID: "test", relayURL: relay, keychainAccount: "test", pubkey: key.publicKey.hex,
                           directMessageChannelIDs: [channel], since: timestamp - 30)
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
        #expect(PushPreviewClient.select([selfMessage, unrelated, old, forged, incoming], context: context(own), excluding: [], now: timestamp)?.id == incoming.id)
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
        let client = PushPreviewClient(transport: transport, signer: InMemorySigner(own))
        await #expect(throws: PushPreviewError.self) { _ = try await client.fetch(context: context(own, relay: "http://relay.example"), excluding: []) }
        await #expect(throws: PushPreviewError.self) { _ = try await client.fetch(context: context(other), excluding: []) }
        await transport.enqueue(status: 403, body: Data())
        await #expect(throws: PushPreviewError.self) { _ = try await client.fetch(context: context(own), excluding: []) }
    }
}
