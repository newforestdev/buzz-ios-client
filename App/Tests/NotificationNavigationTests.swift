import BuzzKit
import Foundation
import NostrCore
import Testing
@testable import Hive

@MainActor
struct NotificationNavigationTests {
    @Test func notificationRouteCanOpenChannelWithoutSearchingForTheMessage() {
        let id = EntityID(community: UUID(), native: UUID().uuidString.lowercased())
        let focus = ConversationFocus(messageID: String(repeating: "a", count: 64), sentAt: 123)
        let route = ChannelListView.route(for: .conversation(id, focus: focus))
        #expect(route?.location == .channel(id.native))
        #expect(route?.focus == focus)
        let notificationRoute = ChannelListView.route(for: .conversation(id))
        #expect(notificationRoute?.location == .channel(id.native))
        #expect(notificationRoute?.focus == nil)
    }

    @Test func notificationRouteCanOpenThreadWithoutSearchingForTheReply() {
        let id = EntityID(community: UUID(), native: UUID().uuidString.lowercased())
        let root = String(repeating: "b", count: 64)
        let route = ChannelListView.route(for: .conversation(id, threadRootID: root))
        #expect(route?.location == .thread(channelID: id.native, rootID: root))
        #expect(route?.focus == nil)
    }

    @Test func reenteringConversationRefreshesAndRetriesFailedReadMark() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let peer = try Fixture()
        _ = try await store.ingest(batch: [try peer.message("First", in: "dm", at: 100)], phase: .live)
        let marker = RetryReadMarker(store: store)
        let model = ChannelTimelineModel(channel: "dm", store: store, sender: StubSender(), readStateMarking: marker)
        model.primeIfNeeded()
        await model.beginReading()
        #expect(try await store.effectiveReadFrontier(context: "dm") == nil)
        // The destination was retained while another surface was open. Its initial
        // mark failed and a reply arrived while its observation was stopped.
        _ = try await store.ingest(batch: [try peer.message("Reply", in: "dm", at: 200)], phase: .live)
        await model.beginReading()
        #expect(model.rows.last?.createdAt == 200)
        #expect(try await store.effectiveReadFrontier(context: "dm") == 200)
    }

    @Test func retryDoesNotMarkArrivalsHeldBehindTheReadersPlace() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let peer = try Fixture()
        _ = try await store.ingest(batch: [try peer.message("Visible", in: "dm", at: 100)], phase: .live)
        let marker = RetryReadMarker(store: store, failFirst: false)
        let model = ChannelTimelineModel(channel: "dm", store: store, sender: StubSender(), readStateMarking: marker)
        model.primeIfNeeded()
        model.isAtBottom = false
        _ = try await store.ingest(batch: [try peer.message("Held", in: "dm", at: 200)], phase: .live)
        await model.beginReading()
        #expect(model.rows.last?.createdAt == 100)
        #expect(try await store.effectiveReadFrontier(context: "dm") == 100)
    }

    @Test func leavingMarksLatestRenderedMessageBeforeFlushing() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let peer = try Fixture()
        _ = try await store.ingest(batch: [try peer.message("First", in: "dm", at: 100)], phase: .live)
        let marker = RetryReadMarker(store: store, failFirst: false)
        let model = ChannelTimelineModel(channel: "dm", store: store, sender: StubSender(), readStateMarking: marker)
        model.primeIfNeeded()
        await model.beginReading()
        _ = try await store.ingest(batch: [try peer.message("New activity", in: "dm", at: 200)], phase: .live)
        model.mergeHead(model.fetch(before: nil))
        await model.endReading()
        #expect(try await store.effectiveReadFrontier(context: "dm") == 200)
    }
}

private actor RetryReadMarker: ReadStateMarking {
    let store: BuzzEventStore
    var failFirst: Bool
    var pending: [String: Int64] = [:]
    var revision: Int64 = 0
    init(store: BuzzEventStore, failFirst: Bool = true) { self.store = store; self.failFirst = failFirst }
    func markRead(channel: String, upTo: Int64) async { pending[channel] = max(pending[channel] ?? 0, upTo) }
    func flushReadMarks() async {
        let marks = pending; pending = [:]
        if failFirst { failFirst = false; return }
        revision += 1
        try? await store.applyReadState(author: "self", slot: "test", contexts: marks,
            sourceCreatedAt: revision, sourceEventID: String(repeating: "a", count: 64))
    }
}
