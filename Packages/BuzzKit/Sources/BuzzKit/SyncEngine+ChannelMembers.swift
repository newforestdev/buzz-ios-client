import Foundation
import NostrCore

public enum ChannelMemberAdditionError: Error, Equatable, Sendable {
    case noIdentity
    case notAuthorized
    case rejected(OKReason)
    case publishFailed(RelayConnectionError)
}

public extension SyncEngine {
    /// Adds a person to a channel through the NIP-29 group-admin command.
    func addChannelMember(channelID: String, pubkey: String, isAgent: Bool) async throws {
        guard let identity = selfPubkeyHex else {
            throw ChannelMemberAdditionError.noIdentity
        }
        guard (try? store.channelLifecyclePermissions(identity: identity, channel: channelID))?.canArchive == true else {
            throw ChannelMemberAdditionError.notAuthorized
        }

        var tags = [["h", channelID], ["p", pubkey.lowercased()]]
        if isAgent {
            tags.append(["role", "bot"])
        }
        let event = try await signer.sign(
            kind: .groupAddUser,
            content: "",
            tags: tags,
            createdAt: now()
        )
        do {
            _ = try await connection.publishAwaitingResponse(event)
        } catch RelayConnectionError.publishRejected(let reason) {
            throw ChannelMemberAdditionError.rejected(reason)
        } catch let error as RelayConnectionError {
            throw ChannelMemberAdditionError.publishFailed(error)
        }

        requestDirectoryRefresh()
    }
}
