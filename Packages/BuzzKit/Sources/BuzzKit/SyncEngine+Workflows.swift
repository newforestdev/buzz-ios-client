import Foundation
import NostrCore

public enum ChannelWorkflowError: Error, Equatable, Sendable {
    case noIdentity
    case notOwner
    case rejected(OKReason)
    case publishFailed(RelayConnectionError)
}

extension ChannelWorkflowError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noIdentity:
            "Sign in before saving a workflow."
        case .notOwner:
            "Only the workflow owner can change it."
        case let .rejected(reason):
            Self.message(for: reason)
        case let .publishFailed(error):
            switch error {
            case .notConnected:
                "The relay is not connected. Check your connection and try again."
            case .stopped:
                "The relay connection stopped before the workflow was saved."
            case .connectionLost:
                "The connection dropped before the relay confirmed the save. Try again."
            case let .authenticationFailed(message), let .authenticationRejected(message):
                "Relay authentication failed: \(message)"
            case .publishRejected(let reason):
                Self.message(for: reason)
            case .duplicatePublish:
                "This workflow save is already in progress. Try again in a moment."
            case .subscriptionClosed(let reason):
                Self.message(for: reason)
            case .timedOut:
                "The relay did not confirm the save in time. Check the workflow list before retrying."
            }
        }
    }

    private static func message(for reason: OKReason) -> String {
        switch reason {
        case let .duplicate(message), let .pow(message), let .rateLimited(message),
             let .invalid(message), let .restricted(message), let .authRequired(message),
             let .blocked(message), let .error(message):
            message.isEmpty ? "The relay rejected the workflow." : message
        case let .unspecified(message):
            message.isEmpty ? "The relay rejected the workflow." : message
        }
    }
}

public struct ChannelWorkflowSaveResult: Sendable, Equatable {
    public let workflowID: String
    public let webhookSecret: String?
}

public extension SyncEngine {
    /// Reads the replaceable workflow definitions attached to a channel.
    func channelWorkflows(_ channelID: String) async throws -> [ChannelWorkflow] {
        let filter = Filter(
            kinds: [EventKind(rawValue: 30620)],
            tagQueries: ["h": [channelID]]
        )
        let events = try await subscriptions.query([filter])
        var newestByCoordinate: [String: NostrEvent] = [:]
        for event in events where event.kind.rawValue == 30620 {
            guard event.firstValue(forTag: "h") == channelID,
                  let definitionID = event.firstValue(forTag: "d") else { continue }
            let coordinate = "\(event.pubkey):\(definitionID)"
            if let existing = newestByCoordinate[coordinate], existing.createdAt > event.createdAt {
                continue
            }
            newestByCoordinate[coordinate] = event
        }
        return newestByCoordinate.values
            .map { ChannelWorkflow(event: $0, channelID: channelID) }
            .sorted {
                let lhsName = $0.summary.name.localizedStandardCompare($1.summary.name)
                return lhsName == .orderedSame ? $0.id < $1.id : lhsName == .orderedAscending
            }
    }

    /// Creates a workflow using JSON syntax, which the relay accepts as YAML 1.2.
    @discardableResult
    func createChannelWorkflow(channelID: String, content: String) async throws -> ChannelWorkflowSaveResult {
        guard selfPubkeyHex != nil else { throw ChannelWorkflowError.noIdentity }
        let workflowID = UUID().uuidString.lowercased()
        let message = try await publishWorkflowDefinition(
            workflowID: workflowID,
            channelID: channelID,
            content: content
        )
        return ChannelWorkflowSaveResult(workflowID: workflowID, webhookSecret: webhookSecret(from: message))
    }

    /// Replaces a workflow definition while preserving its relay coordinate.
    func updateChannelWorkflow(_ workflow: ChannelWorkflow, content: String) async throws -> String? {
        guard let identity = selfPubkeyHex else { throw ChannelWorkflowError.noIdentity }
        guard workflow.ownerPubkey == identity else { throw ChannelWorkflowError.notOwner }
        let message = try await publishWorkflowDefinition(
            workflowID: workflow.id,
            channelID: workflow.channelID,
            content: content
        )
        return webhookSecret(from: message)
    }

    /// Enables or pauses a workflow without discarding fields this client does not edit.
    func setChannelWorkflow(_ workflow: ChannelWorkflow, enabled: Bool) async throws {
        _ = try await updateChannelWorkflow(workflow, content: workflow.content(enabled: enabled))
    }

    /// Deletes a workflow with the NIP-09 coordinate used by Buzz desktop.
    func deleteChannelWorkflow(_ workflow: ChannelWorkflow) async throws {
        guard let identity = selfPubkeyHex else { throw ChannelWorkflowError.noIdentity }
        guard workflow.ownerPubkey == identity else { throw ChannelWorkflowError.notOwner }
        let coordinate = "30620:\(identity):\(workflow.id)"
        let event = try await signer.sign(
            kind: .deletion,
            content: "",
            tags: [["a", coordinate]],
            createdAt: now()
        )
        try await publishWorkflowEvent(event)
    }

    /// Starts a workflow run. The relay restricts this operation to its owner.
    func triggerChannelWorkflow(_ workflow: ChannelWorkflow) async throws {
        guard let identity = selfPubkeyHex else { throw ChannelWorkflowError.noIdentity }
        guard workflow.ownerPubkey == identity else { throw ChannelWorkflowError.notOwner }
        let event = try await signer.sign(
            kind: EventKind(rawValue: 46020),
            content: "",
            tags: [["d", workflow.id]],
            createdAt: now()
        )
        _ = try await publishWorkflowEvent(event)
    }

    /// The HTTP endpoint matching this relay's WebSocket endpoint.
    func workflowWebhookURL(workflowID: String) -> URL? {
        guard var components = URLComponents(url: connection.relayURL, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = components.scheme == "wss" ? "https" : "http"
        components.path = "/hooks/\(workflowID)"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private func publishWorkflowDefinition(
        workflowID: String,
        channelID: String,
        content: String
    ) async throws -> String {
        let event = try await signer.sign(
            kind: EventKind(rawValue: 30620),
            content: content,
            tags: [["d", workflowID], ["h", channelID]],
            createdAt: now()
        )
        return try await publishWorkflowEvent(event)
    }

    private func publishWorkflowEvent(_ event: NostrEvent) async throws -> String {
        do {
            return try await connection.publishAwaitingResponse(event)
        } catch RelayConnectionError.publishRejected(let reason) {
            throw ChannelWorkflowError.rejected(reason)
        } catch let error as RelayConnectionError {
            throw ChannelWorkflowError.publishFailed(error)
        }
    }

    private func webhookSecret(from message: String) -> String? {
        let json = message.hasPrefix("response:") ? String(message.dropFirst("response:".count)) : message
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["webhook_secret"] as? String
    }
}
