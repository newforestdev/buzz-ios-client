import Foundation
import NostrCore
import OSLog

/// The outbox drain: sending queued messages, mapping the relay's verdict through
/// the store's disposition policy, and the coalescing that keeps overlapping drain
/// requests from stranding a row.
extension SyncEngine {
    /// Queues a signed protocol event that is not a channel message. Used by addressable
    /// client control records such as NIP-PL leases; it still travels through the durable
    /// outbox so a temporary relay disconnect cannot silently drop the update.
    @discardableResult
    public func enqueueProtocolEvent(
        kind: EventKind,
        content: String,
        tags: [[String]] = [],
        maxContentBytes: Int = 65_536,
        createdAt: Date? = nil
    ) async throws -> OutboxEntry {
        let entry = try await store.enqueue(
            kind: kind,
            content: content,
            in: "",
            tags: tags,
            with: signer,
            maxContentBytes: maxContentBytes,
            createdAt: createdAt
        )
        await drainOutbox()
        return entry
    }

    /// Signs and queues a message, then drains — the app's send path. The event id
    /// exists the moment it is signed, so the timeline renders the pending send
    /// optimistically and the same row simply changes state on confirmation. The
    /// drain sends it now if the socket is live; otherwise it waits for the next
    /// `.ready`, and the queued row survives a relaunch.
    @discardableResult
    public func enqueue(
        kind: EventKind = .channelMessage,
        content: String,
        in channel: String,
        tags: [[String]] = [],
        maxContentBytes: Int = OutboxPolicy.maxContentBytes
    ) async throws -> OutboxEntry {
        let entry = try await store.enqueue(
            kind: kind,
            content: content,
            in: channel,
            tags: tags,
            with: signer,
            maxContentBytes: maxContentBytes
        )
        await drainOutbox()
        return entry
    }

    /// Resumes HTTP media uploads immediately, then drains relay-bound rows when
    /// the engine is running. Otherwise the row waits for the next `.ready` — and this
    /// asks for that `.ready` now rather than whenever the connection's own schedule
    /// reaches it. See ``nudgeConnection()``.
    public func drainOutbox() async {
        await resumeMediaUploads()
        guard state == .running else {
            await nudgeConnection()
            return
        }
        await requestDrain(generation: readyGeneration)
    }

    /// Asks the connection to reopen now, because somebody just tried to send.
    ///
    /// Somebody pressing send is the strongest statement of intent this engine
    /// receives, and it was the only one that never reached the socket: a row enqueued
    /// while the connection was backing off simply waited for the next `.ready`, which
    /// the connection's own schedule puts up to ``ReconnectPolicy/cap`` — thirty
    /// seconds — away. ``RelayConnection/reconnectNow()`` cancels that sleep, and is
    /// already what pull-to-refresh calls; this gives the send path the same lever.
    ///
    /// Two deliberate limits.
    ///
    /// **Foreground only.** A backgrounded app released its socket on purpose
    /// (``RelayConnectionConfig/backgroundGrace``); reviving it for a queued row would
    /// spend battery to beat a deadline nobody is watching. The next foreground
    /// reconnects anyway.
    ///
    /// **Rate-limited.** A nudge arriving while the connection is still backing off
    /// resets its attempt counter, so an ungated one would let a run of sends retry a
    /// dead network on a tight loop for as long as somebody kept typing. See
    /// ``SyncEngineConfig/connectionNudgeInterval``.
    func nudgeConnection() async {
        guard isForeground, !isStopped else { return }
        let moment = now()
        if let last = lastConnectionNudge,
           moment.timeIntervalSince(last) < config.connectionNudgeInterval {
            return
        }
        lastConnectionNudge = moment
        await connection.reconnectNow()
    }

    /// Returns a failed send to the queue and drains, so an explicit human retry is
    /// a fresh start rather than a continuation of the backoff that gave up.
    public func retry(_ eventID: String) async throws {
        if try await store.retryOutboxMedia(eventID) {
            scheduleMediaPump(eventID: eventID, retryIfRunning: true)
            return
        }
        try await store.retry(eventID)
        await drainOutbox()
    }

    /// Drops a queued send without delivering it — the "delete" action on an own
    /// pending or failed row. Best-effort: if the relay has already accepted a
    /// `sending` row the log holds it and it renders sent, which is the honest
    /// outcome; there is nothing left to unsend.
    public func discard(_ eventID: String) async throws {
        let removable = try await store.discard(eventID)
        guard let mediaStagingStore else { return }
        for key in removable { try? mediaStagingStore.remove(key) }
    }

    /// Requests a drain, coalescing with any in-flight one. If a drain is already
    /// running, this records that another pass is wanted and returns; the running
    /// drain re-runs once more when it finishes. That single-drain-at-a-time
    /// discipline stops two passes from double-sending a row, while the re-run
    /// guarantees a request that arrived mid-drain (a fresh `.ready`) is still
    /// served.
    private static let outboxLog = Logger(subsystem: "Steelbeach", category: "Outbox")

    func requestDrain(generation: Int) async {
        // Read-state snapshots are independent of messages and related actions. Keep
        // every other event in one ordered lane (including reactions and withdrawals).
        async let messages: Void = drainLane(readState: false)
        async let readState: Void = drainLane(readState: true)
        _ = await (messages, readState)
        _ = generation
    }

    private func drainLane(readState: Bool) async {
        guard !drainInFlight.contains(readState) else {
            drainPending.insert(readState)
            return
        }
        drainInFlight.insert(readState)
        defer { drainInFlight.remove(readState) }
        repeat {
            drainPending.remove(readState)
            let generation = readyGeneration
            let entries = (try? await store.pendingSends()) ?? []
            for entry in entries where (entry.event.kind == .readState) == readState {
                guard generation == readyGeneration, state == .running, !isStopped else { return }
                if let retryAfter = outboxRetryAfter[entry.id], retryAfter > Date() {
                    break // Preserve order within this lane during retry backoff.
                }
                outboxRetryAfter.removeValue(forKey: entry.id)
                await send(entry)
                if outboxRetryAfter[entry.id] != nil { break }
            }
        } while drainPending.contains(readState) && state == .running && !isStopped
    }

    // MARK: - One send

    /// Hands one queued send to the relay and applies the outcome. Success (an
    /// `OK true`, or a `duplicate:` the connection already treats as success) moves
    /// it into the log; a rejection routes through the store's disposition policy; a
    /// connection loss leaves it `sending` for the next drain.
    private func send(_ entry: OutboxEntry) async {
        let started = Date()
        let queueAge = max(0, started.timeIntervalSince1970 - Double(entry.event.createdAt))
        Self.outboxLog.info("Publish started kind=\(entry.event.kind.rawValue) queueAgeSeconds=\(queueAge, format: .fixed(precision: 1)) attempt=\(entry.attempts + 1)")
        do {
            try await store.markSending(entry.event.id)
            try await connection.publish(entry.event)
            let acknowledged = Date()
            do {
                try await store.confirmSent(entry.event)
            } catch {
                Self.outboxLog.error("Confirmation save failed kind=\(entry.event.kind.rawValue)")
                try? await store.markFailed(entry.event.id, error: "The server received this, but Steelbeach couldn't save the confirmation.", retryable: true)
                return
            }
            let ackSeconds = acknowledged.timeIntervalSince(started)
            let saveSeconds = Date().timeIntervalSince(acknowledged)
            Self.outboxLog.info("Publish confirmed kind=\(entry.event.kind.rawValue) ackSeconds=\(ackSeconds, format: .fixed(precision: 2)) saveSeconds=\(saveSeconds, format: .fixed(precision: 2))")
            // After the confirm and not before it: a subscriber is told the send landed,
            // which is only true once the row has moved into the log.
            publishSentConfirmation(entry.event)
        } catch let error as RelayConnectionError {
            Self.outboxLog.warning("Publish failed kind=\(entry.event.kind.rawValue) elapsedSeconds=\(Date().timeIntervalSince(started), format: .fixed(precision: 2)) error=\(String(describing: error), privacy: .private)")
            await handlePublishFailure(error, entry: entry)
        } catch {
            Self.outboxLog.error("Outbox state update failed kind=\(entry.event.kind.rawValue)")
            try? await store.markFailed(entry.event.id, error: "Steelbeach couldn't prepare this message to send.", retryable: true)
        }
    }

    private func scheduleOutboxRetry(_ id: String, reason: OKReason, attempts: Int) {
        let delay = max(1, reason.retryAfterSeconds ?? min(30, 1 << min(attempts - 1, 5)))
        let deadline = Date().addingTimeInterval(TimeInterval(delay))
        outboxRetryAfter[id] = deadline
        Self.outboxLog.notice("Transient refusal; retry scheduled in \(delay) seconds")
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            await self?.retryAfterBackoff(id, deadline: deadline)
        }
    }

    private func retryAfterBackoff(_ id: String, deadline: Date) async {
        guard outboxRetryAfter[id] == deadline else { return }
        outboxRetryAfter.removeValue(forKey: id)
        guard !isStopped else { return }
        await drainOutbox()
    }

    /// Maps a publish failure onto the outbox.
    private func handlePublishFailure(_ error: RelayConnectionError, entry: OutboxEntry) async {
        switch error {
        case let .publishRejected(reason):
            let resolution = try? await store.resolve(reason, for: entry.event.id, with: signer)
            if case let .resigned(newID)? = resolution {
                // The relay's ±15-minute gate rejected a stale timestamp; the store
                // re-signed under a fresh one. Resend the new row immediately — its
                // fresh timestamp is self-limiting, so this cannot loop.
                if let fresh = try? await store.entry(id: newID) {
                    await send(fresh)
                }
            }
            if case let .retrying(attempts)? = resolution {
                scheduleOutboxRetry(entry.id, reason: reason, attempts: attempts)
            }
            if case .failed? = resolution {
                // A terminal write refusal is often the first signal that an
                // already-open screen lost access. Reconcile its directory state
                // promptly so the UI becomes read-only.
                requestDirectoryRefresh()
            }
            // The store records the result. Transient refusals also get a scheduled
            // retry; they must not wait indefinitely for an unrelated reconnect.

        case .connectionLost, .timedOut:
            // Outcome unknown: the row stays `sending` and the next drain resends it.
            // A publish that got no answer is also the earliest evidence available that
            // the socket is dead — earlier than the idle watchdog, which tolerates
            // `pingInterval + pingDeadline` of silence before it suspects anything — so
            // it drives the reconnect rather than waiting for one. This is the half of
            // the send-side nudge that covers a socket which still *looks* alive: a
            // reader cannot tell, so the failed send tells us instead.
            await nudgeConnection()

        case .notConnected, .stopped, .duplicatePublish:
            // Outcome unknown or transient, and none of them want the socket revived:
            // `notConnected` is the deliberate background release, `stopped` a sign-out,
            // and `duplicatePublish` means another in-flight publish already owns this
            // id. The row stays `sending` and the next drain resends it.
            break

        case let .authenticationFailed(message), let .authenticationRejected(message):
            // `publish` waits for NIP-42 authentication before writing the EVENT.
            // A rejected handshake therefore reaches this path without an event
            // verdict. Leaving the row as `sending` makes it look in flight forever;
            // retain it as an explicit, retryable failure instead.
            try? await store.markFailed(entry.event.id, error: message, retryable: true)

        case .subscriptionClosed:
            // Publish does not open a subscription. Keep this exhaustive in case a
            // future connection implementation routes one through the send path.
            try? await store.markFailed(
                entry.event.id,
                error: "The relay closed the message subscription.",
                retryable: true
            )
        }
    }
}
