import SwiftUI
import BottoCore

/// Saved-bot surfaces share activity selection, clocks, reactions and image precedence here.
struct AppBotAvatar: View {
    let store: AppStore
    let bot: BotProfile
    var scope: BotAvatarScope = .profile
    var size: CGFloat = 56
    var fitsBody = false

    var body: some View {
        let value = store.avatarPresentation(for: bot, scope: scope)
        BotAvatar(profile: bot, image: store.avatar(for: bot), size: size,
            motion: value.activity.isWorkingPhase ? .working(since: value.workStartedAt ?? value.enteredAt) : .idle,
            presentation: value, fitsBody: fitsBody)
    }
}

/// Sender stamps identify presentation only; historical rows never borrow live activity.
struct ChatSenderAvatar: View {
    let sender: ChatMessage.MessageSender
    let profile: BotProfile?
    let image: UIImage?
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 32

    var body: some View {
        Group {
            if let profile {
                BotAvatar(profile: profile, image: image, size: size, motion: .still)
            } else {
                Text(String(sender.name.prefix(1)).uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
                    .background(BottoTheme.surface, in: Circle())
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// Remote and duplicate labels cannot select a local bot's saved appearance.
    nonisolated static func profile(for sender: ChatMessage.MessageSender, among profiles: [BotProfile]) -> BotProfile? {
        guard !sender.handle.contains("@"), !sender.handle.contains("/"), !sender.handle.contains(".") else { return nil }
        let exact = profiles.filter { $0.id.utf8.elementsEqual(sender.handle.utf8) }
        if !exact.isEmpty { return exact.count == 1 ? exact[0] : nil }
        let named = profiles.filter { $0.name.utf8.elementsEqual(sender.name.utf8) }
        return named.count == 1 ? named[0] : nil
    }
}

extension AppStore {
    func avatarPresentation(for bot: BotProfile, scope: BotAvatarScope = .profile) -> BotAvatarPresentation {
        if link == .offline { return .offline }
        guard let profile = try? ExactID(bot.id) else {
            return .init(activity: .unavailable, enteredAt: .distantPast)
        }
        return chats.avatarPresentation(profile: profile, scope: scope)
    }
}
