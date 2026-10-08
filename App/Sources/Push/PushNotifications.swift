import DeviceCheck
import CryptoKit
import Foundation
import Observation
import UIKit
import UserNotifications

/// The Apple API that keeps the App Attest calls deterministic in tests.
protocol PushAttesting: Sendable {
    func generateKey() async throws -> String
    func attest(keyID: String, clientData: Data) async throws -> Data
    func assertion(keyID: String, clientDataHash: Data) async throws -> Data
}

struct ApplePushAttester: PushAttesting {
    func generateKey() async throws -> String {
        guard DCAppAttestService.shared.isSupported else { throw PushAttestationError.unsupported }
        return try await DCAppAttestService.shared.generateKey()
    }

    func attest(keyID: String, clientData: Data) async throws -> Data {
        let clientDataHash = Data(SHA256.hash(data: clientData))
        return try await DCAppAttestService.shared.attestKey(keyID, clientDataHash: clientDataHash)
    }

    func assertion(keyID: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.generateAssertion(keyID, clientDataHash: clientDataHash)
    }
}

enum PushAttestationError: Error { case unsupported }

/// Owns the system permission and APNs registration lifecycle. A remote payload is only a
/// reconnect hint; it never selects a relay or carries notification content.
@MainActor
@Observable
final class PushNotifications {
    static let shared = PushNotifications()

    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    private(set) var deviceToken: Data?
    private(set) var registrationError: String?
    var onWake: (@MainActor @Sendable () -> Void)?
    var onToken: (@MainActor @Sendable (Data) -> Void)?

    private init() {}

    func requestPermissionAndRegister() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let granted: Bool
        do {
            granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
        } catch {
            await refreshAuthorization()
            return false
        }
        await refreshAuthorization()
        if granted { registerForRemoteNotifications() }
        return granted
    }

    func refreshAuthorization() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }

    func disableRemoteRegistration() {
        UIApplication.shared.unregisterForRemoteNotifications()
        deviceToken = nil
        registrationError = nil
    }

    func setRegistrationError(_ message: String?) { registrationError = message }

    func didRegister(deviceToken: Data) {
        guard !deviceToken.isEmpty else { return }
        self.deviceToken = deviceToken
        // Enrollment and lease replacement are asynchronous and occur only after explicit
        // opt-in. The composition root installs the handler once the active identity exists.
        onToken?(deviceToken)
    }

    func didReceiveWake() { onWake?() }

    func didFailToRegister() {
        registrationError = "Couldn’t register for alerts with Apple. Check your connection and try again."
    }
}

@MainActor
final class HiveApplicationDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushNotifications.shared.didRegister(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        PushNotifications.shared.didFailToRegister()
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        PushNotifications.shared.didReceiveWake()
        completionHandler(.newData)
    }

}
