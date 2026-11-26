import SwiftUI
import BottoCore

/// Saved-bot surfaces share activity selection, clocks and reactions here.
struct AppBotAvatar: View {
    let store: AppStore
    let bot: BotProfile
    var scope: BotAvatarScope = .profile
    var size: CGFloat = 56
    var fitsBody = false

    var body: some View {
        let value = store.avatarPresentation(for: bot, scope: scope)
        BotAvatar(profile: bot, size: size,
            motion: value.activity.isWorkingPhase ? .working(since: value.workStartedAt ?? value.enteredAt) : .idle,
            presentation: value, fitsBody: fitsBody)
    }
}

extension AppStore {
    func avatarPresentation(for bot: BotProfile, scope: BotAvatarScope = .profile) -> BotAvatarPresentation {
        if link == .offline { return .offline }
        if let profile = try? ExactID(bot.id) {
            let value = chats.avatarPresentation(profile: profile, scope: scope)
            if value.activity != .unavailable { return value }
        }
        if scope == .profile {
            if t3Channels.contains(where: \.needsYou) {
                return .init(activity: .waiting, enteredAt: .now)
            }
            if t3Channels.contains(where: { !$0.isArchived && $0.status == .working }) {
                return .init(activity: .working, enteredAt: .now)
            }
        }
        return .idle
    }
}
