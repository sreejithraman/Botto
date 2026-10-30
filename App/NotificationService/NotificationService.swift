import Foundation
import BottoCore
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    private let lock = NSLock()
    private var completion: ((UNNotificationContent) -> Void)?
    private var fallback: UNNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        lock.lock(); completion = contentHandler; fallback = request.content; lock.unlock()
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent,
              let envelope = try? PushEnvelope.parse(userInfo: request.content.userInfo),
              let state = try? PushPairingVault.load(),
              let pairing = state.pairings.first(where: { $0.installationID == envelope.installationID && $0.deviceID == envelope.deviceID }),
              pairing.preferences.previews,
              let preview = try? envelope.decrypt(key: pairing.key), preview.profileID.utf8.elementsEqual(pairing.host.profileID.utf8),
              !preview.title.isEmpty || !preview.body.isEmpty else { finish(request.content); return }
        content.title = preview.title
        content.body = preview.body
        finish(content)
    }

    override func serviceExtensionTimeWillExpire() {
        lock.lock(); let content = fallback; lock.unlock()
        if let content { finish(content) }
    }

    private func finish(_ content: UNNotificationContent) {
        lock.lock(); let handler = completion; completion = nil; fallback = nil; lock.unlock()
        handler?(content)
    }
}
