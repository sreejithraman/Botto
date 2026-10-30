import Foundation
import BottoCore

enum BotAvatarScope: Equatable {
    case profile
    case selectedChat
}

struct BotAvatarPresentation: Equatable {
    static let idle = Self(activity: .idle, enteredAt: .distantPast)
    static let offline = Self(activity: .offline, enteredAt: .distantPast)

    let activity: BotMotionActivity
    let enteredAt: Date
    let workStartedAt: Date?
    let reactionID: UUID?
    var accessibilityStatus: String? { activity == .offline ? "Offline" : nil }

    init(activity: BotMotionActivity, enteredAt: Date, workStartedAt: Date? = nil, reactionID: UUID? = nil) {
        self.activity = activity
        self.enteredAt = enteredAt
        self.workStartedAt = workStartedAt
        self.reactionID = reactionID
    }
}

/// Transient motion clocks belong to the workspace, never the persisted chat book.
struct BotAvatarActivityLedger {
    private var chats: [ChatID: BotAvatarPresentation] = [:]
    private var profiles: [ExactID: BotAvatarPresentation] = [:]
    private var lineage: UUID?
    private(set) var reaction: TurnReaction?

    func chat(_ id: ChatID) -> BotAvatarPresentation { chats[id] ?? .idle }
    func profile(_ id: ExactID) -> BotAvatarPresentation { profiles[id] ?? .idle }

    mutating func record(chat: ChatID, status: BotStatus?, at: Date) {
        chats[chat] = transition(from: chats[chat], activity: .observed(status), at: at)
    }
    mutating func record(profile: ExactID, activity: BotMotionActivity, at: Date) {
        profiles[profile] = transition(from: profiles[profile], activity: activity, at: at)
    }
    mutating func accept(_ opened: OpenedConversation) {
        guard let facts = opened.activity else { retire(); return }
        if lineage != facts.lineage { reaction = nil }
        lineage = facts.lineage
        if opened.snapshot.isWorking || !opened.snapshot.pendingRequests.isEmpty { reaction = nil }
        else if let incoming = facts.reaction { reaction = incoming }
    }
    mutating func retire() { lineage = nil; reaction = nil }

    private func transition(from previous: BotAvatarPresentation?, activity: BotMotionActivity, at: Date) -> BotAvatarPresentation {
        if previous?.activity == activity, let previous { return previous }
        return .init(activity: activity, enteredAt: at, workStartedAt: activity == .working ? at : nil)
    }
}
