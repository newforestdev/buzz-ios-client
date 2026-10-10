import Foundation
import NostrCore

/// The same subscription is encrypted into the relay lease and saved locally
/// for preview queries. Keep ignore filters as well as positive selectors.
struct PushLeaseSubscription: Codable, Equatable, Sendable {
    let filter: Filter
    var className = "default"
    var ignore: [Filter]?

    enum CodingKeys: String, CodingKey { case filter, ignore; case className = "class" }

    init(filter: Filter, ignore: [Filter]? = nil) {
        self.filter = filter
        self.ignore = ignore
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Filter ignores unknown scalar fields. Check the raw keys first so a
        // future selector cannot be silently dropped and broaden a query.
        let raw = try container.nestedContainer(keyedBy: FilterKey.self, forKey: .filter)
        try Self.validate(raw.allKeys)
        if container.contains(.ignore) {
            var rawIgnore = try container.nestedUnkeyedContainer(forKey: .ignore)
            while !rawIgnore.isAtEnd {
                let value = try rawIgnore.nestedContainer(keyedBy: FilterKey.self)
                try Self.validate(value.allKeys)
            }
        }
        filter = try container.decode(Filter.self, forKey: .filter)
        className = try container.decode(String.self, forKey: .className)
        ignore = try container.decodeIfPresent([Filter].self, forKey: .ignore)
    }

    private static func validate(_ keys: [FilterKey]) throws {
        let known: Set<String> = ["ids", "authors", "kinds", "since", "until", "limit"]
        guard keys.allSatisfy({ known.contains($0.stringValue) || $0.stringValue.hasPrefix("#") }) else {
            throw PushPreviewError.invalidContext
        }
    }

    private struct FilterKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}

struct PushPreviewLease: Codable, Equatable, Sendable {
    var version = 1
    let active: Bool
    let expiresAt: Int64
    let subscriptions: [PushLeaseSubscription]

    func isActive(at now: Int64) -> Bool {
        version == 1 && active && expiresAt > now && !subscriptions.isEmpty && subscriptions.count <= 16
    }

    func queryFilters(pubkey: String, since: Int64, now: Int64) throws -> [Filter] {
        guard isActive(at: now) else { throw PushPreviewError.invalidContext }
        return try subscriptions.compactMap { subscription in
            var filter = subscription.filter
            // Only narrowed message subscriptions are supported. This is also a
            // fail-closed check for malformed snapshots constructed in memory.
            guard filter.search == nil, subscription.ignore?.allSatisfy({ $0.search == nil }) ?? true,
                  filter.tagQueries["p"]?.contains(pubkey) == true || filter.tagQueries["h"]?.isEmpty == false
            else { throw PushPreviewError.invalidContext }
            let supported: Set<EventKind> = [9, 40002, 45001, 45003]
            filter.kinds = (filter.kinds ?? Array(supported)).filter(supported.contains).sorted { $0.rawValue < $1.rawValue }
            filter.since = max(filter.since ?? since, max(since, now - 300))
            filter.until = min(filter.until ?? now + 30, now + 30)
            filter.limit = min(max(filter.limit ?? 30, 0), 30)
            guard filter.kinds?.isEmpty == false, filter.limit != 0,
                  (filter.since ?? 0) <= (filter.until ?? 0) else { return nil }
            return filter
        }
    }

    func covers(_ event: NostrEvent) -> Bool {
        subscriptions.contains { subscription in
            Self.matches(subscription.filter, event: event)
                && !(subscription.ignore?.contains { Self.matches($0, event: event) } ?? false)
        }
    }

    private static func matches(_ filter: Filter, event: NostrEvent) -> Bool {
        guard filter.search == nil,
              filter.kinds?.contains(event.kind) ?? true,
              filter.ids?.contains(where: { event.id.hasPrefix($0) }) ?? true,
              filter.authors?.contains(where: { event.pubkey.hasPrefix($0) }) ?? true,
              filter.since.map({ event.createdAt >= $0 }) ?? true,
              filter.until.map({ event.createdAt <= $0 }) ?? true else { return false }
        return filter.tagQueries.allSatisfy { key, values in
            event.tags.contains { $0.count > 1 && $0[0] == key && values.contains($0[1]) }
        }
    }
}
