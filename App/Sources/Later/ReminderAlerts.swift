import UserNotifications

/// A tap on a reminder's alert, carried from the notification centre into the app.
///
/// # Why this exists
///
/// A reminder's alert is a *local* notification (see ``ReminderScheduler``), and iOS hands a
/// tap on one to `UNUserNotificationCenter`'s delegate — one process-wide slot, with no
/// SwiftUI equivalent. So the delegate is a small object that does exactly one thing: say
/// which reminder was tapped.
///
/// # Where the tap goes
///
/// To ``onOpen``, which ``AppEnvironment`` sets to ask ``AppNavigator`` for
/// ``AppDestination/later``. The mapping lives *there* rather than here so this object stays
/// "a tap happened, on this reminder" and the object that owns both halves says what a tap
/// means — and so a tapped alert travels the one path a screen asked for from outside the
/// view tree already travels. That path is what selects the Home tab (``RootView``) before
/// ``ChannelListView`` pushes, and a value read by the sidebar alone could not do that half:
/// the tab selection lives above it, so a tap arriving while Activity is on screen would
/// push Later behind a tab nobody is looking at.
///
/// # Why the delegate is installed in `init`
///
/// "The delegate must be set before the application returns from
/// `application:didFinishLaunchingWithOptions:`" — `UNUserNotificationCenter.h`. A tap that
/// *launches* the app is delivered right after that returns, so a delegate installed from a
/// `.task` — which runs after the first render — would miss precisely the case this feature
/// is for. This object is built by ``AppEnvironment``, which is built in ``HiveApp``'s stored
/// property, which runs during launch.
@MainActor
final class ReminderAlerts {
    /// Called with the tapped reminder's id.
    ///
    /// Set by ``AppEnvironment`` in its own `init`, which is also where this object is built
    /// — one synchronous span on the main actor with no suspension in it, so there is no
    /// moment at which the delegate below exists and this does not.
    ///
    /// The id is passed even though today's handler ignores it: it is what "open Later *on
    /// the reminder that came due*" would need, and this is the only place that fact exists.
    var onOpen: ((String) -> Void)?
    /// Called for a tap on a reconnect-only remote push; reminder routing remains intact.
    var onRemoteWake: (() -> Void)?
    var onRemoteConversation: ((String, String, String?) -> Void)?

    /// The delegate itself. Held because `UNUserNotificationCenter.delegate` is `weak`, and
    /// a delegate nobody retains stops being one the moment `init` returns.
    private let delegate = Delegate()

    init() {
        delegate.onOpen = { [weak self] id in self?.onOpen?(id) }
        delegate.onRemoteWake = { [weak self] in self?.onRemoteWake?() }
        delegate.onRemoteConversation = { [weak self] channel, community, focus in self?.onRemoteConversation?(channel, community, focus) }
        UNUserNotificationCenter.current().delegate = delegate
    }
}

/// The notification-centre delegate, kept apart from the type above:
/// `UNUserNotificationCenterDelegate` is a plain Objective-C protocol carrying no actor
/// isolation, and mixing it into a `@MainActor` type makes the conformance the interesting
/// part of a class whose job is to forward one string.
private final class Delegate: NSObject, UNUserNotificationCenterDelegate {
    /// Set once, from the main actor, before this delegate is installed.
    var onOpen: (@MainActor @Sendable (String) -> Void)?
    var onRemoteWake: (@MainActor @Sendable () -> Void)?
    var onRemoteConversation: (@MainActor @Sendable (String, String, String?) -> Void)?

    /// Keeps local reminders visible while suppressing the system copy of remote messages.
    /// The live conversation already displays a remote message when Hive is open; showing an
    /// APNs banner over it duplicates the same response. Background delivery remains unchanged.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        if notification.request.trigger is UNPushNotificationTrigger {
            return []
        }
        return [.banner, .sound, .list]
    }

    /// The tap. Only the id crosses to the main actor — `UNNotificationResponse` itself
    /// stays here.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        // UIKit updates its window snapshot from this completion. The async delegate
        // bridge completes on a cooperative executor and crashes on iOS 26; explicitly
        // finish on the main actor, after queuing navigation but before network work.
        let userInfo = response.notification.request.content.userInfo
        let channel = userInfo["hive.channel_id"] as? String
        let community = userInfo["hive.community_id"] as? String
        let threadRootID = (userInfo["hive.thread_root_id"] as? String).flatMap { id in
            id.count == 64 && id.allSatisfy(\.isHexDigit) ? id : nil
        }
        let reminder = userInfo[ReminderScheduler.reminderIDKey] as? String
        let isRemote = response.notification.request.trigger is UNPushNotificationTrigger
        Task { @MainActor [onRemoteWake, onRemoteConversation, onOpen] in
            if let channel, let community {
                onRemoteConversation?(channel, community, threadRootID)
            }
            if let reminder, !reminder.isEmpty { onOpen?(reminder) }
            if isRemote {
                onRemoteWake?()
            }
            completionHandler()
        }
    }
}
