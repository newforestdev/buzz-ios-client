import Foundation
import BuzzKit

extension AppEnvironment {
    /// Registers the latest APNs endpoint for the active identity only after the separate
    /// relay-wakeup opt-in has been enabled.
    func registerPushToken(_ token: Data, additionalDMChannelIDs: [String] = []) async {
        guard settings.pushNotificationsEnabled,
              let community = communities.active,
              let signer,
              let engine,
              let store
        else { return }
        do {
            let pubkey = try await signer.publicKey().hex
            var dmChannelIDs = Set(try store.channelList(selfPubkey: pubkey)
                .filter(\.isDirectMessage)
                .map(\.id))
            dmChannelIDs.formUnion(additionalDMChannelIDs)
            let previewSince = Int64(Date().timeIntervalSince1970) - 2
            let lease = try await PushLeaseCoordinator.shared.activate(
                token: token,
                relayURLString: community.relayURLString,
                signer: signer,
                engine: engine,
                directMessageChannelIDs: Array(dmChannelIDs)
            )
            // Only expose the subscriptions after the lease is durably queued.
            // A sign-out or community switch during enrollment must not restore consent.
            guard settings.pushNotificationsEnabled, communities.active?.id == community.id,
                  selfPubkeyHex == pubkey else { return }
            try PushPreviewCustody.save(PushPreviewContext(
                communityID: community.id.uuidString,
                relayURL: community.relayURLString,
                keychainAccount: community.keychainAccount,
                pubkey: pubkey,
                directMessageChannelIDs: Array(dmChannelIDs).sorted(),
                since: previewSince,
                lease: lease
            ))
            PushNotifications.shared.setRegistrationError(nil)
        } catch {
            guard !(error is CancellationError), settings.pushNotificationsEnabled,
                  communities.active?.id == community.id else { return }
            let message: String
            if case PushLeaseError.tooManyDirectMessageChannels = error {
                message = "This relay has more direct message channels than its alert limit supports."
            } else if case PushLeaseError.invalidDirectMessageChannel = error {
                message = "Couldn’t update relay alerts because a direct message channel ID is invalid."
            } else if case PushGatewayError.missingInstallationCredentials = error {
                message = "An earlier alert registration is still active, but this device no longer has its recovery key. "
                    + "Ask the gateway operator to clear it, or wait for it to expire."
            } else if case PushGatewayError.installationConflict = error {
                message = "An earlier alert registration is still active. Automatic recovery couldn’t clear it. "
                    + "Ask the gateway operator to check the registration."
            } else if case PushGatewayError.httpStatus(let status) = error {
                message = "Couldn’t set up relay alerts (gateway response \(status)). Check the relay connection and try again."
            } else {
                message = "Couldn’t set up relay alerts. Check the relay connection and try again."
            }
            PushNotifications.shared.setRegistrationError(message)
        }
    }

    /// Replaces the lease after a DM is opened in the foreground. The next APNs wake then
    /// covers the channel that has just entered this identity's relay directory.
    func refreshPushLease(openedDMChannelID: String? = nil) async {
        guard settings.pushNotificationsEnabled,
              let token = PushNotifications.shared.deviceToken
        else { return }
        await registerPushToken(token, additionalDMChannelIDs: openedDMChannelID.map { [$0] } ?? [])
    }

    /// Revokes the current community's gateway delegation, then publishes its inactive lease
    /// while this session still has the identity key and relay connection.
    func revokePushLease() async {
        PushPreviewCustody.clear()
        PushLeaseCoordinator.shared.cancelPendingActivation()
        guard let community = communities.active,
              let signer,
              let engine
        else { return }
        await PushLeaseCoordinator.shared.revoke(
            relayURLString: community.relayURLString,
            signer: signer,
            engine: engine
        )
    }
}
