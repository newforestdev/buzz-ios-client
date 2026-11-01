import Foundation
import NostrCore

/// A channel-scoped workflow definition stored by the relay as a replaceable event.
public struct ChannelWorkflow: Identifiable, Sendable, Equatable {
    public let id: String
    public let channelID: String
    public let ownerPubkey: String
    public let content: String
    public let createdAt: Int64

    public var summary: ChannelWorkflowSummary {
        ChannelWorkflowSummary(content: content)
    }

    init(event: NostrEvent, channelID: String) {
        id = event.firstValue(forTag: "d") ?? event.id
        self.channelID = channelID
        ownerPubkey = event.pubkey
        content = event.content
        createdAt = event.createdAt
    }
}

/// The fields Steelbeach needs to display and manage a workflow.
public struct ChannelWorkflowSummary: Sendable, Equatable {
    public let name: String
    public let enabled: Bool
    public let trigger: String
    public let editable: Bool

    init(content: String) {
        let object = ChannelWorkflowDefinitionCodec.decode(content)
        name = object?["name"] as? String ?? ChannelWorkflowDefinitionCodec.yamlScalar(content, key: "name") ?? "Untitled workflow"
        enabled = object?["enabled"] as? Bool ?? ChannelWorkflowDefinitionCodec.yamlBool(content, key: "enabled") ?? true
        let triggerObject = object?["trigger"] as? [String: Any]
        trigger = triggerObject?["on"] as? String
            ?? ChannelWorkflowDefinitionCodec.yamlScalar(content, key: "on", under: "trigger")
            ?? "workflow"
        editable = name != "Untitled workflow" && trigger != "workflow"
    }
}

public extension ChannelWorkflow {
    /// Returns the same definition with its relay-side enabled flag changed.
    /// Unknown fields and actions are retained, including definitions authored on desktop.
    func content(enabled: Bool) -> String {
        if var object = ChannelWorkflowDefinitionCodec.decode(content) {
            object["enabled"] = enabled
            if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
               let json = String(data: data, encoding: .utf8) { return json }
        }

        var lines = content.components(separatedBy: .newlines)
        if let index = lines.firstIndex(where: { line in
            let indent = line.prefix(while: { $0 == " " }).count
            return indent == 0 && line.hasPrefix("enabled:")
        }) {
            lines[index] = "enabled: \(enabled ? "true" : "false")"
        } else {
            lines.append("enabled: \(enabled ? "true" : "false")")
        }
        return lines.joined(separator: "\n")
    }
}

/// Encoding helpers. JSON is a valid YAML 1.2 document, so the relay's existing YAML
/// parser accepts definitions written here while keeping JSONDecoder available on iOS.
enum ChannelWorkflowDefinitionCodec {
    static func decode(_ content: String) -> [String: Any]? {
        guard let data = content.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data),
              let object = value as? [String: Any] else { return nil }
        return object
    }

    static func yamlScalar(_ content: String, key: String, under parent: String? = nil) -> String? {
        let lines = content.components(separatedBy: .newlines)
        var inParent = parent == nil
        let expectedIndent = parent == nil ? 0 : 2
        for line in lines {
            let indent = line.prefix(while: { $0 == " " }).count
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let parent {
                if indent == 0 { inParent = trimmed == "\(parent):"; continue }
                if !inParent { continue }
            }
            guard indent == expectedIndent, trimmed.hasPrefix("\(key):") else { continue }
            let raw = String(trimmed.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else { return nil }
            if raw.first == "\"", let data = raw.data(using: .utf8),
               let value = try? JSONSerialization.jsonObject(with: data) as? String { return value }
            if raw.first == "'", raw.last == "'" {
                return String(raw.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
            }
            return raw
        }
        return nil
    }

    static func yamlBool(_ content: String, key: String) -> Bool? {
        guard let value = yamlScalar(content, key: key)?.lowercased() else { return nil }
        if value == "true" { return true }
        if value == "false" { return false }
        return nil
    }
}
