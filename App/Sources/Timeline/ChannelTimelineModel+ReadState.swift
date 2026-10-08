import BuzzKit
import Foundation

// MARK: - Read state

/// Mark-on-view: how far the reader has demonstrably seen, and when that is published.
///
/// Its own file, beside the model rather than in it, because it is the one concern here
/// that leaves the device — the NIP-RS frontier is shared with every other client the
/// account is signed in to, and grow-only.
extension ChannelTimelineModel {
    /// Refreshes the rendered head and retries its read mark on every entry. A retained
    /// navigation destination may have stopped observing while another screen was open;
    /// an earlier best-effort mark may also have failed before the store applied it.
    func beginReading() async {
        lastMarkedReadAt = 0
        mergeHead(fetch(before: nil))
        guard let readStateMarking, let newest = rows.last?.createdAt else { return }
        await readStateMarking.markRead(channel: channel, upTo: newest)
        await readStateMarking.flushReadMarks()
    }

    /// Marks the channel read up to the newest *rendered* message, once per advance —
    /// mark-on-view. Fires the moment the channel opens and again whenever a newer
    /// message becomes viewable while the view is up; a scroll back through older
    /// history leaves the newest rendered row unchanged, so it re-marks nothing.
    ///
    /// The newest *rendered* row, not the newest loaded one. While the tail is frozen
    /// the reader can see nothing past the boundary, and the NIP-RS frontier is
    /// grow-only and shared with every other device — so advancing it past held-back
    /// arrivals is not recoverable: the pill said "3 new messages" while the sidebar row
    /// for the same channel dropped to zero unread and un-bolded, and backing out lost
    /// the marker everywhere.
    ///
    /// Called from ``ChannelTimelineModel/rebuild()``, so it tracks the rendered set for
    /// any reason it advances — an arrival, the channel opening, an older page, or the
    /// freeze releasing — and the `lastMarkedReadAt` guard makes every redundant call free.
    ///
    /// Fire-and-forget so the observation loop never blocks on the publish, and
    /// grow-only on the engine side so a redundant call is a no-op.
    func markReadIfNeeded() {
        guard let readStateMarking,
              let newest = rows.last?.createdAt, newest > lastMarkedReadAt else { return }
        lastMarkedReadAt = newest
        let channel = self.channel
        Task { await readStateMarking.markRead(channel: channel, upTo: newest) }
    }

    /// Marks the newest rendered message and publishes the final frontier on the way out.
    ///
    /// The marks above publish a couple of seconds after they stop arriving, which is
    /// invisible from *inside* a channel: nothing on this screen renders read state. The two
    /// surfaces that do — the sidebar's unread count and the Activity feed — are exactly what
    /// leaving reveals, so the flush belongs on the way out. A no-op when the window is
    /// already empty, which it usually is.
    func endReading() async {
        guard let readStateMarking else { return }
        if let newest = rows.last?.createdAt {
            lastMarkedReadAt = max(lastMarkedReadAt, newest)
            await readStateMarking.markRead(channel: channel, upTo: newest)
        }
        await readStateMarking.flushReadMarks()
    }
}
