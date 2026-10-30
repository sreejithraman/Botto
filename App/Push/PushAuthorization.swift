import Foundation
import UIKit
import UserNotifications
import BottoCore

@MainActor struct PushAuthorization {
    var requestPermission: () async throws -> Bool
    var deviceToken: () async throws -> String
    static var system: Self {
        .init(requestPermission: { try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) },
              deviceToken: { try await PushTokenRegistration.shared.register() })
    }
}

@MainActor final class PushTokenRegistration {
    static let shared = PushTokenRegistration()
    private var waiting: [UUID: CheckedContinuation<String, Error>] = [:]

    func register() async throws -> String {
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            waiting[id] = continuation
            UIApplication.shared.registerForRemoteNotifications()
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                self?.waiting.removeValue(forKey: id)?.resume(throwing: PushError.tokenUnavailable)
            }
        }
    }
    func received(_ token: String) {
        let callbacks = Array(waiting.values); waiting.removeAll()
        callbacks.forEach { $0.resume(returning: token) }
    }
    func failed() {
        let callbacks = Array(waiting.values); waiting.removeAll()
        callbacks.forEach { $0.resume(throwing: PushError.tokenUnavailable) }
    }
}

@MainActor final class PushNotificationBridge: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private static var latestToken: String?
    private static var pendingTaps: [PushEnvelope] = []
    static var onToken: ((String) -> Void)? {
        didSet { if let latestToken { onToken?(latestToken) } }
    }
    static var onTap: ((PushEnvelope) -> Void)? {
        didSet {
            guard let onTap else { return }
            let pending = pendingTaps; pendingTaps.removeAll()
            pending.forEach(onTap)
        }
    }
    static var shouldPresent: ((PushEnvelope) -> Bool)?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Self.latestToken = token
        PushTokenRegistration.shared.received(token)
        Self.onToken?(token)
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        PushTokenRegistration.shared.failed()
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        guard let envelope = try? PushEnvelope.parse(userInfo: notification.request.content.userInfo) else { return [] }
        return await MainActor.run {
            Self.shouldPresent?(envelope) == false ? [] : [.banner, .list, .sound]
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let envelope = try? PushEnvelope.parse(userInfo: response.notification.request.content.userInfo) else { return }
        await MainActor.run {
            if let onTap = Self.onTap { onTap(envelope) }
            else {
                Self.pendingTaps.append(envelope)
                if Self.pendingTaps.count > 8 { Self.pendingTaps.removeFirst(Self.pendingTaps.count - 8) }
            }
        }
    }
}
