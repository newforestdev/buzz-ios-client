import Foundation
import UserNotifications
import NostrCore

/// Apple receives only a generic wake; the signed message preview is fetched on-device.
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((UNNotificationContent) -> Void)?
    private var fallback: UNMutableNotificationContent?
    private var work: Task<Void, Never>?
    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content); return
        }
        content.title = "Steelbeach"; content.body = "New message"; content.sound = .default
        lock.withLock { handler = contentHandler; fallback = content }
        work = Task { [weak self] in
            guard let self else { return }
            var result: PushMessagePreview?
            let context = PushPreviewCustody.load()
            if let context {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 8
                configuration.timeoutIntervalForResource = 16
                let client = PushPreviewClient(transport: URLSessionHTTPTransport(session: URLSession(configuration: configuration)),
                                               signer: KeychainSigner(account: context.keychainAccount))
                result = try? await client.fetch(context: context,
                    excluding: PushPreviewCustody.notifiedIDs(communityID: context.communityID))
            }
            if Task.isCancelled || PushPreviewCustody.load() != context
                || context?.lease?.isActive(at: Int64(Date().timeIntervalSince1970)) != true { result = nil }
            self.finish(preview: result, context: context)
        }
    }
    override func serviceExtensionTimeWillExpire() {
        work?.cancel()
        finish(preview: nil, context: nil)
    }
    private func finish(preview: PushMessagePreview?, context: PushPreviewContext?) {
        let completion: (((UNNotificationContent) -> Void), UNNotificationContent)? = lock.withLock {
            guard let handler, let content = fallback else { return nil }
            self.handler = nil
            if let preview, let context {
                content.title = preview.sender; content.body = preview.text
                content.threadIdentifier = preview.channelID ?? context.communityID
                if let channelID = preview.channelID {
                    content.userInfo["hive.channel_id"] = channelID
                    content.userInfo["hive.community_id"] = context.communityID
                    if let rootID = preview.threadRootID {
                        content.userInfo["hive.thread_root_id"] = rootID
                    }
                }
                PushPreviewCustody.markNotified(preview.eventID, communityID: context.communityID)
            }
            return (handler, content)
        }
        if let completion { completion.0(completion.1) }
    }
}
