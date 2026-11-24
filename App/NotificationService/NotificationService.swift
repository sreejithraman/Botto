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
              let preview = Self.preview(envelope), !preview.title.isEmpty || !preview.body.isEmpty
        else { finish(request.content); return }
        content.title = preview.title
        content.body = preview.body
        finish(content)
    }

    private static func preview(_ envelope: PushEnvelope) -> PushPreview? {
        guard let pairings = try? PushPairingVault.loadT3(),
              let pairing = pairings.first(where: { $0.matches(envelope) }) else { return nil }
        return pairing.preview(envelope)
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
