import Foundation
import Security
import NostrCore

/// The active identity's preview configuration, kept in device-only Keychain custody.
struct PushPreviewContext: Codable, Equatable, Sendable {
    let communityID: String
    let relayURL: String
    let keychainAccount: String
    let pubkey: String
    let directMessageChannelIDs: [String]
    let since: Int64
    var lease: PushPreviewLease?
}

/// Both targets use the host app's Keychain access group; identity keys stay in place.
enum PushPreviewCustody {
    private static let service = "net.steelbeach.hive.push-preview"
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecUseDataProtectionKeychain as String: true]
    }
    static func save(_ context: PushPreviewContext) throws {
        try write(try JSONEncoder().encode(context), account: "active")
    }
    static func load() -> PushPreviewContext? {
        read("active").flatMap { try? JSONDecoder().decode(PushPreviewContext.self, from: $0) }
    }
    static func clear() { SecItemDelete(query("active") as CFDictionary) }
    static func notifiedIDs(communityID: String) -> Set<String> {
        guard let data = read("notified-" + communityID),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(ids)
    }
    static func markNotified(_ eventID: String, communityID: String) {
        var ids = Array(notifiedIDs(communityID: communityID))
        ids.append(eventID)
        if let data = try? JSONEncoder().encode(Array(ids.suffix(100))) {
            try? write(data, account: "notified-" + communityID)
        }
    }
    private static func read(_ account: String) -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &value) == errSecSuccess else { return nil }
        return value as? Data
    }
    private static func write(_ data: Data, account: String) throws {
        var q = query(account)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let result = SecItemAdd(q as CFDictionary, nil)
        if result == errSecDuplicateItem {
            let status = SecItemUpdate(query(account) as CFDictionary,
                                      [kSecValueData as String: data] as CFDictionary)
            guard status == errSecSuccess else { throw PushPreviewError.custody }
        } else if result != errSecSuccess { throw PushPreviewError.custody }
    }
}

enum PushPreviewError: Error { case custody, invalidContext, relayUnavailable }
struct PushMessagePreview: Equatable, Sendable {
    let eventID: String
    let sender: String
    let text: String
    let channelID: String?
    var threadRootID: String? = nil
}

/// Fetches only incoming messages covered by the active lease, over authenticated HTTPS.
struct PushPreviewClient: Sendable {
    let transport: any HTTPTransport
    let signer: any EventSigner
    let now: @Sendable () -> Date
    init(transport: any HTTPTransport, signer: any EventSigner, now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport; self.signer = signer; self.now = now
    }
    func fetch(context: PushPreviewContext, excluding: Set<String>) async throws -> PushMessagePreview? {
        guard context.lease?.isActive(at: Int64(now().timeIntervalSince1970)) == true else {
            throw PushPreviewError.invalidContext
        }
        guard var url = URLComponents(string: context.relayURL),
              ["wss", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil,
              try await signer.publicKey().hex == context.pubkey else { throw PushPreviewError.invalidContext }
        url.scheme = "https"; url.path = "/query"; url.query = nil; url.fragment = nil
        guard let queryURL = url.url else { throw PushPreviewError.invalidContext }
        let queryTime = Int64(now().timeIntervalSince1970)
        guard let lease = context.lease else { throw PushPreviewError.invalidContext }
        let filters = try lease.queryFilters(pubkey: context.pubkey, since: context.since, now: queryTime)
        guard !filters.isEmpty else { return nil }
        let events = try await query(filters, url: queryURL)
        guard let event = Self.select(events, context: context, excluding: excluding, now: Int64(now().timeIntervalSince1970)) else { return nil }
        let profiles = try? await query([Filter(authors: [event.pubkey], kinds: [0, 10100], limit: 2)], url: queryURL)
        let profile = profiles?.filter { [0, 10100].contains($0.kind.rawValue) && $0.pubkey == event.pubkey && $0.isValid }.max { $0.createdAt < $1.createdAt }
        let sender = Self.senderName(profile: profile, pubkey: event.pubkey)
        try Task.checkCancellation()
        guard lease.isActive(at: Int64(now().timeIntervalSince1970)) else { return nil }
        return PushMessagePreview(
            eventID: event.id,
            sender: sender,
            text: Self.previewText(event),
            channelID: event.firstValue(forTag: "h"),
            threadRootID: event.threadReference.isReply ? event.threadReference.rootID : nil
        )
    }
    private func query(_ filters: [Filter], url: URL) async throws -> [NostrEvent] {
        try Task.checkCancellation()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let body = try encoder.encode(filters)
        let authorization = try await NIP98.authorizationHeader(url: url, method: "POST", body: body, signer: signer)
        let (data, status) = try await transport.post(body: body, to: url,
            headers: ["Content-Type": "application/json", "Authorization": authorization])
        guard status == 200, data.count <= 2_000_000 else { throw PushPreviewError.relayUnavailable }
        return try JSONDecoder().decode([NostrEvent].self, from: data)
    }
    static func select(_ events: [NostrEvent], context: PushPreviewContext, excluding: Set<String>, now: Int64) -> NostrEvent? {
        guard let lease = context.lease, lease.isActive(at: now) else { return nil }
        return events.filter { e in
            e.isValid && !isPlaceholder(e) && e.pubkey != context.pubkey && !excluding.contains(e.id)
                && e.createdAt >= max(context.since, now - 300) && e.createdAt <= now + 30
                && [9, 40002, 45001, 45003].contains(Int(e.kind.rawValue)) && lease.covers(e)
        }.max { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }
    private static func isPlaceholder(_ event: NostrEvent) -> Bool {
        let kind = Int(event.kind.rawValue)
        guard kind == 9 || kind == 40002 else { return false }
        if event.tags.contains(where: { $0.first.map { ["imeta", "url", "image"].contains($0) } == true }) {
            return false
        }
        let normalized = clean(event.content, limit: 180)
        return normalized.isEmpty || (kind == 9 && normalized == ".")
    }
    static func senderName(profile: NostrEvent?, pubkey: String) -> String {
        if let profile, let data = profile.content.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["display_name", "displayName", "name"] {
                if let name = object[key] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return clean(name, limit: 80)
                }
            }
        }
        return "Someone · " + String(pubkey.prefix(8))
    }
    static func previewText(_ event: NostrEvent) -> String {
        if let data = event.content.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["text", "body", "content", "title"] {
                if let text = object[key] as? String, !text.isEmpty { return clean(text, limit: 180) }
            }
            return "New message"
        }
        let text = clean(event.content, limit: 180)
        return text.isEmpty ? "New message" : text
    }
    private static func clean(_ text: String, limit: Int) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) })
            .split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(limit).description
    }
}
