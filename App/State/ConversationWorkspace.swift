import Foundation
import Observation
import BottoCore

struct WorkspaceScope: Hashable, Sendable {
    let cacheID: UUID
    let exactAccount: [Data?]
    let incarnation: UUID
}
struct PresentationOwner: Hashable, Sendable {
    fileprivate let workspace: WorkspaceScope
    let chat: ChatID
    fileprivate let recovery: UUID
    fileprivate let presentation: UUID
    fileprivate let access: ConversationAccess?
    var epoch: UUID { presentation }
}
struct OpeningIntent: Sendable {
    fileprivate let scope: WorkspaceScope
    fileprivate let epoch: UUID
    fileprivate let profile: ExactID
    fileprivate let attention: Bool
}
struct SelectionIntent { fileprivate let owner: PresentationOwner; fileprivate let target: ChatID }
struct ChatCloseIntent { fileprivate let owner: PresentationOwner; fileprivate let target: ChatID }
struct ChatReopenIntent { fileprivate let owner: PresentationOwner; fileprivate let target: ChatID }
struct ClosedChat: Identifiable { let id: ChatID; let title: String }
struct CreationIntent {
    fileprivate let owner: PresentationOwner
    fileprivate let operation: UUID
    fileprivate let reservation: WorkspaceOperationReservation
}
struct SendIntent {
    fileprivate let delivery: MessageDelivery
    fileprivate let reservation: WorkspaceOperationReservation
    fileprivate let owner: PresentationOwner
    fileprivate let operation: UUID
    fileprivate let source: SessionIdentity
    fileprivate let revision: UUID
    fileprivate let text: String
    fileprivate let attachments: [ChatAttachment]
    fileprivate let stagedIDs: Set<UUID>
}
struct StopIntent {
    fileprivate let owner: PresentationOwner
    fileprivate let operation: UUID
    fileprivate let reservation: WorkspaceOperationReservation
}
struct RequestIntent {
    fileprivate let owner: PresentationOwner
    fileprivate let operation: UUID
    fileprivate let request: PendingRequest
}
struct ImportIntent: Equatable, Sendable {
    fileprivate let owner: PresentationOwner
    fileprivate let id: UUID
    fileprivate let reservation: WorkspaceOperationReservation
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.owner == rhs.owner && lhs.id == rhs.id }
}
struct ArtifactIntent: Identifiable, Sendable {
    fileprivate let reservation: WorkspaceOperationReservation
    let id: UUID
    fileprivate let owner: PresentationOwner
    fileprivate let attachment: ChatAttachment
}
struct RequestRow: Identifiable {
    let id: UUID
    let request: PendingRequest
    let intent: RequestIntent
}
enum ActivityPresentation: Equatable, Sendable {
    case unobserved
    case current(BotStatus)
    case historical(ActivityObservation)
    case unavailable(lastKnown: ActivityObservation?)

    var currentStatus: BotStatus? {
        if case .current(let status) = self { return status }
        return nil
    }
    var label: String? {
        switch self {
        case .unobserved, .current(.idle): nil
        case .current(.working): "Working"
        case .current(.waiting): "Needs you"
        case .historical(let observation), .unavailable(.some(let observation)):
            switch observation.status {
            case .idle: nil
            case .working: "Previously working"
            case .waiting: "Previously waiting"
            }
        case .unavailable(nil): "Activity unavailable"
        }
    }
    var symbol: String {
        switch self {
        case .current(.waiting): BottoTheme.needsYouSymbol
        case .current(.working): "circle.dotted"
        case .historical, .unavailable(.some): "clock"
        case .unavailable(nil): "questionmark.circle"
        case .unobserved, .current(.idle): "bubble.left"
        }
    }
    var accessibilityLabel: String? {
        guard let label else { return nil }
        switch self {
        case .historical(let observation), .unavailable(.some(let observation)):
            return "\(label), last checked \(observation.observedAt.formatted(date: .abbreviated, time: .shortened))"
        default: return label
        }
    }
}
struct ChatCard: Identifiable {
    let id: ChatID
    let title: String
    let userPreview: String
    let replyPreview: String
    let isMain: Bool
    let isPreferred: Bool
    let unread: Bool
    let activity: ActivityPresentation
    var status: BotStatus? { activity.currentStatus }
    let isAvailable: Bool
    let isOffline: Bool
}
struct ChatSelection {
    let owner: PresentationOwner
    let snapshot: Conversation?
    let identity: SessionIdentity?
    let isUnverified: Bool
    let isOpening: Bool
}

struct ChatHapticFeedback: Equatable {
    let id: UUID
    let event: HapticEvent
    let chat: ChatID
    let viewLifetime: UUID
}

struct ChatScreen {
    let owner: PresentationOwner
    let title: String
    let snapshot: Conversation?
    let requests: [RequestRow]
    let canAct: Bool
    let canEditDraft: Bool
    let selectedViewLifetime: UUID
    let canCreate: Bool
    let isOpening: Bool
    let isSending: Bool
    let isUploading: Bool
    let isCreating: Bool
    let isLoadingDirectory: Bool
    let error: String?
    let attachments: [ChatAttachment]
    let needsReattachment: Bool
    let directoryComplete: Bool
    let queuedEdit: QueuedMessageEdit?
    let canReplaceQueuedEdit: Bool
    let canSaveQueuedEdit: Bool
    let workPhase: ConversationWorkPhase?
    var selectedChatID: ChatID { owner.chat }
    var epoch: UUID { owner.epoch }
}
struct ChatAggregate {
    let count: Int
    let unreadCount: Int
    let selectedChatIsUnread: Bool
    let activity: ActivityPresentation
    var status: BotStatus? { activity.currentStatus }
    let hasUnknownActivity: Bool
    let directoryComplete: Bool
    let attentionChat: ChatID?
    let preview: ConversationPreview?
    let hasHistory: Bool
}

/// Capture-to-install reservation. Value-intent copies share its lifetime; a discarded
/// intent releases its barrier without needing an asynchronous dispatch to run.
nonisolated final class WorkspaceOperationReservation: Sendable {
    private let release: @Sendable () -> Void
    init(release: @escaping @Sendable () -> Void) { self.release = release }
    deinit { release() }
}

private struct ReadObservationKey: Hashable, Sendable {
    let profile: ExactID
    let root: ExactID
    let stored: ExactID
    let preview: Data
    let count: Int?
    let date: Date?
    init(_ summary: SessionSummary) {
        profile = summary.identity.profile; root = summary.identity.root; stored = summary.identity.stored
        preview = Data(summary.preview.utf8); count = summary.messageCount; date = summary.updatedAt
    }
    func matches(_ identity: SessionIdentity) -> Bool {
        profile == identity.profile && root == identity.root && stored == identity.stored
    }
    func matches(_ evidence: ChatSummaryEvidence?) -> Bool {
        evidence?.inventoryTip == stored && evidence?.preview == preview
            && evidence?.messageCount == count && evidence?.updatedAt == date
    }
}

/// One mounted cache, one selected attachment. No live authority is encoded in the book.
@MainActor @Observable final class ConversationWorkspace {
    private let scope: WorkspaceScope
    @ObservationIgnored private var bookStorage: ConversationBook
    private var screenBook: ConversationBook {
        access(keyPath: \.screenBook)
        return bookStorage
    }
    private var book: ConversationBook {
        access(keyPath: \.book)
        return screenBook
    }
    private var draftBook: ConversationBook {
        access(keyPath: \.draftBook)
        return screenBook
    }
    private var completeBook: ConversationBook {
        access(keyPath: \.draftBook)
        return book
    }
    private func mutateBook<Result>(_ mutation: (inout ConversationBook) -> Result) -> Result {
        withMutation(keyPath: \.screenBook) { mutation(&bookStorage) }
    }
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let service: any BotService
    @ObservationIgnored private let onDirty: @MainActor () -> Void
    @ObservationIgnored var onPresentationChange: (@MainActor () -> Void)?
    @ObservationIgnored var onVisibleChatChange: (@MainActor (SessionIdentity?) -> Void)?
    @ObservationIgnored var onUserNavigation: (@MainActor () -> Void)?
    @ObservationIgnored var onHapticFeedback: (@MainActor (ChatHapticFeedback) -> Void)?
    private var selected: ChatID?
    private var locallySelected: ChatID?
    private var presentation = UUID()
    private var recovery = UUID()
    private var online = false
    private var retired = false
    private var live: OpenedConversation?
    // Local origin survives connection retries, but never travels with the persisted book.
    @ObservationIgnored private var initialMainBindings: [ExactID: ConversationBook.InitialMainBinding] = [:]
    private struct RecoveryHandoff {
        let owner: PresentationOwner
        let retiredAccess: ConversationAccess?
        var pending: OpenedConversation?
    }
    @ObservationIgnored private var recoveryHandoff: RecoveryHandoff?
    // Rejected recovery grants stay rejected if their frame arrives after connected.
    @ObservationIgnored private var retiredRecoveryAccesses: Set<ConversationAccess> = []
    private var opening: UUID?
    private var selectedViewLifetime = UUID()
    private var transcriptVisible = false
    @ObservationIgnored private var lastFeedbackReaction: UUID?
    @ObservationIgnored private var lastFeedbackSignal: UUID?
    private struct StopFeedback {
        let owner: PresentationOwner
        let viewLifetime: UUID
        let operation: UUID
        var acknowledged = false
        var signal: UUID?
    }
    @ObservationIgnored private var stopFeedback: StopFeedback?
    private var readHint: ReadObservationKey?
    private var attemptedReads: Set<ReadObservationKey> = []
    private var readAuthorityBlocked = false
    private var pendingOperations: [UUID: ChatID] = [:]
    @ObservationIgnored private var foregroundRead: (id: UUID, task: Task<Void, Never>)?
    @ObservationIgnored private var retiringForegroundReads: Set<UUID> = []
    @ObservationIgnored private var activityStorage: [ChatID: ObservedActivity] = [:]
    private var activity: [ChatID: ObservedActivity] {
        access(keyPath: \.activity)
        return activityStorage
    }
    private func mutateActivity(_ mutation: (inout [ChatID: ObservedActivity]) -> Void) {
        withMutation(keyPath: \.activity) { mutation(&activityStorage) }
    }
    @ObservationIgnored private var profileActivityStorage: [ExactID: BotStatus] = [:]
    private var profileActivity: [ExactID: BotStatus] {
        access(keyPath: \.profileActivity)
        return profileActivityStorage
    }
    private func mutateProfileActivity(_ mutation: (inout [ExactID: BotStatus]) -> Void) {
        withMutation(keyPath: \.profileActivity) { mutation(&profileActivityStorage) }
    }
    private var avatarActivity = BotAvatarActivityLedger()
    private var availability: [ChatID: Bool] = [:]
    private var complete: [ExactID: Bool] = [:]
    private var activityDirectories: Set<ExactID> = []
    private var errors: [ChatID: String] = [:]
    private var directoryWarnings: [ExactID: String] = [:]
    private var sends: [ChatID: UUID] = [:]
    private var stops: [ChatID: UUID] = [:]
    private let queuedEditing = QueuedMessageEditing()
    private var answers: [ChatID: [String: UUID]] = [:]
    private var creations: [ExactID: UUID] = [:]
    private var uncertainCreation: Set<ExactID> = []
    private var dispatched: Set<UUID> = []
    private var imports: [UUID: PresentationOwner] = [:]
    private var uploadReservations: [ChatID: UUID] = [:]
    private struct Staged {
        let id: UUID
        let attachment: ChatAttachment
        let bytes: Int
        let source: SessionIdentity
        var valid: Bool
    }
    private var staging: [ChatID: [Staged]] = [:]
    private struct DirectoryRead {
        let id: UUID
        let recovery: UUID
        let presentation: UUID
        let task: Task<ConversationDirectory, Error>
    }
    @ObservationIgnored private var directoryReads: [ExactID: DirectoryRead] = [:]
    private struct InboxPreviewRead {
        let id: UUID
        let recovery: UUID
        let task: Task<ConversationPreviewRead, Error>
    }
    @ObservationIgnored private var inboxPreviewReads: [ChatID: InboxPreviewRead] = [:]
    @ObservationIgnored private var inboxPreviewRefresh: (id: UUID, task: Task<Void, Never>)?
    @ObservationIgnored private var pendingInboxProfiles: Set<ExactID> = []
    @ObservationIgnored private var inboxProfiles: Set<ExactID> = []
    private var loadingDirectories: Set<ExactID> = []
    private var requestRows: [RequestRow] = []
    private var cachedRequests: [ChatID: (source: SessionIdentity, requests: [PendingRequest])] = [:]
    private struct QuestionDraft {
        let request: PendingRequest
        var text: String
    }
    // Text survives an owner change; row IDs and intents never do.
    private var questionDrafts: [ChatID: (source: SessionIdentity, drafts: [QuestionDraft])] = [:]
    @ObservationIgnored private var downloads: [UUID: Task<DownloadedArtifact, Error>] = [:]

    init(scope: WorkspaceScope, book: ConversationBook, service: any BotService,
         now: @escaping () -> Date = { .now }, onDirty: @escaping @MainActor () -> Void) {
        self.scope = scope; self.bookStorage = book.readOnly.withReadContentProof; self.service = service; self.onDirty = onDirty
        self.now = now
        for preference in self.book.preferences {
            initialMainBindings[preference.profile] = self.book.captureInitialMainBinding(preference.main)
        }
    }
    func avatarPresentation(profile: ExactID, scope: BotAvatarScope) -> BotAvatarPresentation {
        let unavailable = BotAvatarPresentation(activity: .unavailable, enteredAt: .distantPast)
        guard online, !retired else { return .idle }
        let coarse = avatarActivity.profile(profile)
        guard opening == nil, let selected, book.record(selected)?.profile == profile,
              availability[selected] != false, let live else {
            guard scope == .selectedChat else { return coarse }
            let target = selected.flatMap { book.record($0)?.profile == profile ? $0 : nil } ?? book.opening(profile)
            guard let target, let record = book.record(target), availability[target] != false else { return unavailable }
            switch activityPresentation(record) {
            case .current: return avatarActivity.chat(target)
            case .unobserved, .historical: return .idle
            case .unavailable: return unavailable
            }
        }
        let selectedStatus: BotStatus = !live.snapshot.pendingRequests.isEmpty ? .waiting
            : live.snapshot.isWorking ? .working : .idle
        if scope == .profile, coarse.activity == .waiting { return coarse }
        if selectedStatus == .waiting { return avatarActivity.chat(selected) }
        if selectedStatus == .working {
            let fallback = avatarActivity.chat(selected)
            let facts = live.activity
            let activity: BotMotionActivity = switch facts?.phase {
            case .working, nil: .working
            case .thinking: .thinking
            case .tools: .tools
            case .replying: .replying
            }
            return .init(activity: activity, enteredAt: facts?.phaseStartedAt ?? fallback.enteredAt,
                         workStartedAt: facts?.workStartedAt ?? fallback.workStartedAt)
        }
        if scope == .profile, aggregate(profile: profile).status != .idle { return coarse }
        if let reaction = avatarActivity.reaction {
            return .init(activity: reaction.kind == .succeeded ? .finished : .failed,
                         enteredAt: reaction.occurredAt, reactionID: reaction.id)
        }
        return scope == .profile ? coarse : avatarActivity.chat(selected)
    }
    private func refreshAvatarProfile(_ profile: ExactID) {
        let activity: BotMotionActivity = switch aggregate(profile: profile).activity {
        case .current(let status): .observed(status)
        case .unobserved, .historical: .idle
        case .unavailable: .unavailable
        }
        avatarActivity.record(profile: profile, activity: activity, at: now())
    }
    func persisted() -> ConversationBook { completeBook.readOnly }
    var uploadingProfiles: Set<String> { Set(uploadReservations.keys.compactMap { book.record($0)?.profile.text }) }
    private func ensureProfile(_ profile: ExactID) {
        guard book.preference(profile) == nil else { return }
        let id = mutateBook { $0.ensureProfile(profile) }
        initialMainBindings[profile] = book.captureInitialMainBinding(id)
    }
    func observeProfiles(_ profiles: [BotProfile]) {
        guard !retired else { return }
        inboxProfiles = Set(profiles.compactMap { try? ExactID($0.id) })
        var knownProfiles = Set(book.preferences.map(\.profile))
        for bot in profiles {
            guard let profile = try? ExactID(bot.id) else { continue }
            if knownProfiles.insert(profile).inserted { ensureProfile(profile) }
        }
        mutateProfileActivity { current in
            for bot in profiles {
                guard let profile = try? ExactID(bot.id) else { continue }
                current[profile] = bot.status
            }
        }
        for bot in profiles {
            guard let profile = try? ExactID(bot.id) else { continue }
            refreshAvatarProfile(profile)
        }
    }
    func setOnline(_ value: Bool) {
        guard !retired else { return }
        online = value
        for preference in book.preferences { refreshAvatarProfile(preference.profile) }
        if !value { retireConnection() }
        else if let handoff = recoveryHandoff, isCurrent(handoff.owner), let pending = handoff.pending {
            receive(pending)
        }
    }
    func isCurrent(_ owner: PresentationOwner) -> Bool {
        !retired && owner.workspace == scope && owner.recovery == recovery && owner.presentation == presentation
            && owner.chat == selected && owner.access == live?.access
    }
    private func canAct(_ owner: PresentationOwner) -> Bool {
        isCurrent(owner) && online && opening == nil && owner.access != nil
            && screenBook.record(owner.chat)?.isUnverified == false && availability[owner.chat] != false
    }
    func canEditDraft(_ owner: PresentationOwner) -> Bool {
        isCurrent(owner) && screenBook.record(owner.chat)?.isUnverified == false && availability[owner.chat] != false
            && (canAct(owner) || locallySelected == owner.chat || opening != nil || readAuthorityBlocked || !online)
    }
    private func canActivate(_ owner: PresentationOwner) -> Bool {
        isCurrent(owner) && locallySelected == owner.chat && online && opening == nil
            && screenBook.record(owner.chat)?.isUnverified == false && availability[owner.chat] != false
    }
    func captureActivation(_ owner: PresentationOwner) -> SelectionIntent? {
        guard canActivate(owner) else { return nil }
        return captureSelection(owner.chat, owner: owner)
    }
    private func canCreateFrom(_ owner: PresentationOwner) -> Bool { canAct(owner) || canActivate(owner) }
    private func owner(_ id: ChatID) -> PresentationOwner {
        .init(workspace: scope, chat: id, recovery: recovery, presentation: presentation,
              access: selected == id ? live?.access : nil)
    }
    func selection(profile: ExactID) -> ChatSelection? {
        guard let id = selected.flatMap({ screenBook.record($0)?.profile == profile ? $0 : nil }) ?? screenBook.opening(profile),
              let record = screenBook.record(id) else { return nil }
        return .init(owner: owner(id),
                     snapshot: selected == id ? live?.snapshot ?? record.transcript : record.transcript,
                     identity: record.binding.identity, isUnverified: record.isUnverified,
                     isOpening: selected == id && opening != nil)
    }
    func screen(profile: ExactID) -> ChatScreen? {
        guard let selection = selection(profile: profile),
              let record = screenBook.record(selection.owner.chat) else { return nil }
        let rendered = selection.owner, id = rendered.chat
        let staged = staging[id] ?? []
        let snapshot = selection.snapshot
        let source = selected == id ? live?.identity ?? record.binding.identity : record.binding.identity
        let canSaveEdit = canEditDraft(rendered) && sends[id] == nil && uploadReservations[id] == nil && source.map {
            queuedEditing.canSave(id, source: $0, messages: snapshot?.queuedMessages ?? [])
        } == true
        return .init(owner: rendered, title: record.title,
            snapshot: snapshot,
            requests: isCurrent(rendered) ? requestRows : [], canAct: canAct(rendered),
            canEditDraft: canEditDraft(rendered),
            selectedViewLifetime: selectedViewLifetime,
            canCreate: canCreateFrom(rendered) && creations[profile] == nil && !uncertainCreation.contains(profile),
            isOpening: selection.isOpening, isSending: sends[id] != nil,
            isUploading: uploadReservations[id] != nil, isCreating: creations[profile] != nil,
            isLoadingDirectory: loadingDirectories.contains(profile), error: errors[id] ?? readOnlyExplanation(record) ?? directoryWarnings[profile],
            attachments: staged.map(\.attachment), needsReattachment: staged.contains { !$0.valid },
            directoryComplete: complete[profile] ?? false,
            queuedEdit: queuedEditing.edit(id),
            canReplaceQueuedEdit: source.map { queuedEditing.canReplace(id, source: $0, messages: snapshot?.queuedMessages ?? []) } == true,
            canSaveQueuedEdit: canSaveEdit,
            workPhase: selected == id && isCurrent(rendered) ? live?.activity?.phase : nil)
    }
    private func readOnlyExplanation(_ record: ChatRecord) -> String? {
        if record.isUnverified { return "Recovered history is read-only because Hermes hasn’t verified its original chat. Your draft and messages are preserved." }
        if availability[record.id] == false { return "This chat is unavailable on Hermes. Its cached messages and draft are preserved for reading." }
        return nil
    }
    private func status(_ id: ChatID) -> BotStatus? {
        guard online, case .known(let status, _) = activity[id] else { return nil }
        return status
    }
    private func activityPresentation(_ record: ChatRecord) -> ActivityPresentation {
        if online {
            switch activity[record.id] {
            case .known(let status, _): return .current(status)
            case .unknown: return .unavailable(lastKnown: record.lastKnownActivity)
            case nil: break
            }
        }
        return record.lastKnownActivity.map(ActivityPresentation.historical) ?? .unobserved
    }
    func cards(profile: ExactID) -> [ChatCard] {
        let prefs = book.preference(profile)
        return book.visible(profile).map { record in
            .init(id: record.id, title: record.title,
                userPreview: record.userPreview,
                replyPreview: record.replyPreview,
                isMain: record.id == prefs?.main, isPreferred: record.id == prefs?.preferred,
                unread: record.isUnread, activity: activityPresentation(record),
                isAvailable: true, isOffline: !online)
        }
    }
    func captureClose(_ chat: ChatID, owner: PresentationOwner) -> ChatCloseIntent? {
        guard isCurrent(owner), let record = book.record(chat),
              record.profile == book.record(owner.chat)?.profile,
              chat != book.preference(record.profile)?.main,
              book.visible(record.profile).contains(where: { $0.id == chat }),
              book.visible(record.profile).count > 1 else { return nil }
        return .init(owner: owner, target: chat)
    }
    func close(_ intent: ChatCloseIntent) -> ClosedChat? {
        guard captureClose(intent.target, owner: intent.owner) != nil,
              let record = book.record(intent.target) else { return nil }
        onUserNavigation?()
        if selected == intent.target {
            guard let replacement = book.visible(record.profile).first(where: { $0.id != intent.target })?.id else { return nil }
            avatarActivity.retire()
            live = nil; requestRows = []; retirePresentation(); selected = replacement
            locallySelected = replacement
            mutateBook {
                $0.update(intent.target) { $0.isClosedLocally = true }
                $0.updatePreference(record.profile) { $0.lastSelected = replacement }
            }
            rebuildRequests()
        } else {
            withMutation(keyPath: \.book) { bookStorage.update(intent.target) { $0.isClosedLocally = true } }
        }
        onDirty()
        return .init(id: record.id, title: record.title)
    }
    func closedChats(profile: ExactID) -> [ClosedChat] {
        let main = book.preference(profile)?.main
        return book.ordered(profile).filter { $0.id != main && $0.isClosedLocally == true }
            .map { .init(id: $0.id, title: $0.title) }
    }
    func captureReopening(_ chat: ChatID, owner: PresentationOwner) -> ChatReopenIntent? {
        guard isCurrent(owner), let record = book.record(chat), record.isClosedLocally == true,
              record.profile == book.record(owner.chat)?.profile else { return nil }
        return .init(owner: owner, target: chat)
    }
    func reopen(_ intent: ChatReopenIntent) {
        guard captureReopening(intent.target, owner: intent.owner) != nil else { return }
        withMutation(keyPath: \.book) { bookStorage.update(intent.target) { $0.isClosedLocally = nil } }
        onDirty()
    }
    func aggregate(profile: ExactID) -> ChatAggregate {
        aggregate(profile: profile, records: book.ordered(profile))
    }
    func aggregates(profiles: [ExactID]) -> [ExactID: ChatAggregate] {
        let records = book.orderedByProfile()
        return profiles.reduce(into: [:]) { values, profile in
            values[profile] = aggregate(profile: profile, records: records[profile] ?? [])
        }
    }
    private func aggregate(profile: ExactID, records: [ChatRecord]) -> ChatAggregate {
        // Preview follows the same saved opening choice as tapping the bot row.
        let openingChat = book.opening(profile).flatMap { id in records.first { $0.id == id } }
        let selectedChat = records.first { $0.id == selected }
            ?? book.opening(profile).flatMap { id in records.first { $0.id == id } }
        var unreadCount = 0, knownCount = 0
        var waiting: ChatID?, working = false
        var historical: ActivityObservation?, unavailable = false
        for record in records {
            if record.isUnread { unreadCount += 1 }
            guard let status = status(record.id) else {
                if online, case .unknown = activity[record.id] { unavailable = true }
                if let observation = record.lastKnownActivity, observation.isPreferredForDisplay(over: historical) {
                    historical = observation
                }
                continue
            }
            knownCount += 1
            switch status {
            case .waiting: if waiting == nil { waiting = record.id }
            case .working: working = true
            case .idle: break
            }
        }
        let known: BotStatus? = waiting != nil ? .waiting : working ? .working
            : knownCount == records.count && !records.isEmpty ? .idle : nil
        let covered = complete[profile] == true && knownCount == records.count
        let fallback = online && !covered && profileActivity[profile] != .idle ? profileActivity[profile] : nil
        let combined = known == .waiting || fallback == .waiting ? BotStatus.waiting
            : known == .working || fallback == .working ? .working : known
        let presentation: ActivityPresentation
        if let combined { presentation = .current(combined) }
        else if unavailable { presentation = .unavailable(lastKnown: historical) }
        else { presentation = historical.map(ActivityPresentation.historical) ?? .unobserved }
        return .init(count: records.count, unreadCount: unreadCount,
            selectedChatIsUnread: selectedChat?.isUnread ?? false, activity: presentation,
            hasUnknownActivity: knownCount != records.count, directoryComplete: complete[profile] ?? false,
            attentionChat: waiting, preview: openingChat?.inboxMessage, hasHistory: openingChat?.hasInboxHistory ?? false)
    }
    func captureOpening(profile: ExactID, attention: Bool = false) -> OpeningIntent? {
        guard !retired, book.preference(profile) != nil else { return nil }
        return .init(scope: scope, epoch: presentation, profile: profile, attention: attention)
    }
    func open(_ intent: OpeningIntent) async {
        guard !Task.isCancelled, !retired, intent.scope == scope, intent.epoch == presentation,
              book.preference(intent.profile) != nil else { return }
        onUserNavigation?()
        if intent.attention { await openAttention(profile: intent.profile) }
        else { await openBot(profile: intent.profile) }
    }
    func openBot(profile: ExactID) async {
        guard !retired else { return }
        ensureProfile(profile)
        guard let id = book.opening(profile) else { return }
        await attach(id)
    }
    @discardableResult func openNotificationChat(_ destination: SessionIdentity, isCurrent: @MainActor () -> Bool) async -> Bool {
        guard isCurrent(), online, !retired, !Task.isCancelled else { return false }
        let epoch = presentation, connection = recovery
        do {
            let directory = try await service.conversations(profile: destination.profile)
            guard isCurrent(), online, !retired, !Task.isCancelled, presentation == epoch, recovery == connection else { return false }
            let matches = directory.summaries.filter { summary in
                summary.identity.profile == destination.profile
                    && (summary.identity.root == destination.root || summary.identity.aliases.contains(destination.root))
            }
            guard matches.count == 1, let summary = matches.first else { return false }
            ensureProfile(destination.profile)
            let id = mutateBook { $0.merge(summary, initialMainBinding: initialMainBindings[destination.profile]) }
            availability[id] = true
            guard let accepted = await attach(id, isCurrent: isCurrent, restoreOnFailure: true) else { return false }
            return isCurrent() && self.isCurrent(accepted)
        } catch { return false }
    }
    func restoreAttachment(profile: ExactID) async {
        if let selected, book.record(selected)?.profile == profile, live != nil || opening != nil { return }
        await openBot(profile: profile)
    }
    func openAttention(profile: ExactID) async {
        guard !retired else { return }
        ensureProfile(profile)
        if let waiting = aggregate(profile: profile).attentionChat { await attach(waiting); return }
        // Read inventory without first opening the preferred chat and marking it read.
        if selected == nil || selected.flatMap({ book.record($0)?.profile }) != profile {
            avatarActivity.retire()
            live = nil; requestRows = []; retirePresentation(); selected = book.opening(profile)
        }
        guard let screen = screen(profile: profile) else { return }
        await refreshDirectory(screen.owner)
        guard isCurrent(screen.owner) else { return }
        if let waiting = aggregate(profile: profile).attentionChat { await attach(waiting) }
        else { errors[screen.owner.chat] = "Botto couldn’t identify the waiting chat. Refresh the chat list." }
    }
    func captureSelection(_ chat: ChatID, owner: PresentationOwner) -> SelectionIntent? {
        guard isCurrent(owner), book.record(chat)?.profile == book.record(owner.chat)?.profile else { return nil }
        return .init(owner: owner, target: chat)
    }
    func select(_ intent: SelectionIntent) async {
        guard !Task.isCancelled, isCurrent(intent.owner), book.record(intent.target)?.profile == book.record(intent.owner.chat)?.profile else { return }
        onUserNavigation?()
        await attach(intent.target)
    }
    @discardableResult private func attach(_ id: ChatID, isCurrent: @MainActor () -> Bool = { true }, restoreOnFailure: Bool = false) async -> PresentationOwner? {
        guard isCurrent(), !retired, let record = book.record(id) else { return nil }
        let previousSelection = selected, previousPreference = book.preference(record.profile)?.lastSelected
        let previousLocalSelection = locallySelected
        if locallySelected != id { locallySelected = nil }
        avatarActivity.retire()
        live = nil; requestRows = []; retirePresentation(); selected = id
        mutateBook {
            $0.update(id) { $0.isClosedLocally = nil }
            $0.updatePreference(record.profile) { $0.lastSelected = id }
        }; rebuildRequests(); onDirty()
        guard online, !record.isUnverified, availability[id] != false else { return nil }
        let attempt = UUID(); opening = attempt
        let epoch = presentation, connection = recovery
        var accepted: PresentationOwner?
        let initialMainBinding = initialMainBindings[record.profile]
        defer {
            if opening == attempt {
                opening = nil
                if !isCurrent() || (restoreOnFailure && accepted == nil), !retired, recovery == connection, presentation == epoch, selected == id {
                    retirePresentation(); selected = previousSelection; readAuthorityBlocked = true
                    locallySelected = previousLocalSelection
                    mutateBook {
                        $0.update(id) { $0.isClosedLocally = record.isClosedLocally }
                        $0.updatePreference(record.profile) { $0.lastSelected = previousPreference }
                    }
                    rebuildRequests(); onDirty()
                }
            }
        }
        let target: SessionTarget
        switch record.binding {
        case .provisionalMain: target = .canonical(profile: record.profile, expectedRoot: nil)
        case .identified(let identity, let canonical, _):
            target = canonical ? .canonical(profile: record.profile, expectedRoot: identity.root) : .stored(identity)
        }
        do {
            let opened = try await service.openChat(target)
            guard isCurrent(), !Task.isCancelled, !retired, recovery == connection, presentation == epoch, selected == id, opening == attempt
            else { retiredRecoveryAccesses.insert(opened.access); return nil }
            guard opened.identity.profile == record.profile,
                  Data(opened.snapshot.profileID.utf8) == record.profile.bytes else { throw HermesServiceError.wrongConversation }
            if let expected = record.binding.identity,
               expected.root != opened.identity.root && ConversationBook.proven(expected).isDisjoint(with: ConversationBook.proven(opened.identity)) {
                throw HermesServiceError.wrongConversation
            }
            let canonical = book.preference(record.profile)?.main == id
            let actual = mutateBook { $0.merge(.init(identity: opened.identity, title: record.title, isCanonical: canonical, persistence: .unknown),
                                               initialMainBinding: initialMainBinding) }
            selected = actual; mutateBook { $0.updatePreference(record.profile) { $0.lastSelected = actual } }
            if (staging[actual] ?? []).contains(where: { $0.source.stored != opened.identity.stored }) { invalidateStaging(actual) }
            live = opened; locallySelected = nil; readAuthorityBlocked = false; availability[actual] = true; errors[actual] = nil
            mutateBook { $0.cache(opened.snapshot, for: actual, readEvidence: opened.readEvidence) }; updateActivity(opened, id: actual); rebuildRequests(); onDirty()
            accepted = owner(actual)
            return accepted
        } catch {
            guard isCurrent(), !retired, recovery == connection, presentation == epoch, selected == id else { return nil }
            errors[id] = error.localizedDescription
            return nil
        }
    }
    func refreshDirectory(_ owner: PresentationOwner) async {
        guard isCurrent(owner), online, let profile = book.record(owner.chat)?.profile else { return }
        await refreshDirectory(profile: profile)
    }
    func refreshActivityDirectories(for profiles: [BotProfile]) async {
        guard online, !retired, !Task.isCancelled else { return }
        let active = Set(profiles.compactMap { try? ExactID($0.id) })
        activityDirectories.formIntersection(active)
        let profiles = active.subtracting(activityDirectories)
        await withTaskGroup(of: Void.self) { group in
            for profile in profiles {
                group.addTask { await self.refreshDirectory(profile: profile) }
            }
        }
    }
    func scheduleInboxPreviews(for profiles: [BotProfile]) {
        scheduleInboxPreviews(profiles: Set(profiles.compactMap { try? ExactID($0.id) }))
    }
    private func scheduleInboxPreviews(profiles: Set<ExactID>) {
        guard online, !retired else { return }
        pendingInboxProfiles.formUnion(profiles)
        guard inboxPreviewRefresh == nil else { return }
        let id = UUID(), epoch = recovery
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if inboxPreviewRefresh?.id == id { inboxPreviewRefresh = nil } }
            while !Task.isCancelled, online, !retired, recovery == epoch, !pendingInboxProfiles.isEmpty {
                let batch = pendingInboxProfiles
                pendingInboxProfiles = []
                await refreshInboxPreviews(profiles: batch)
            }
        }
        inboxPreviewRefresh = (id, task)
    }
    func refreshInboxPreviews(profiles: Set<ExactID>) async {
        guard online, !retired, !Task.isCancelled else { return }
        var remaining = profiles.makeIterator()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                if let profile = remaining.next() { group.addTask { await self.refreshInboxPreview(profile: profile) } }
            }
            while await group.next() != nil {
                guard !Task.isCancelled else { group.cancelAll(); return }
                if let profile = remaining.next() { group.addTask { await self.refreshInboxPreview(profile: profile) } }
            }
        }
    }
    private func refreshInboxPreview(profile: ExactID) async {
        guard online, !retired, !Task.isCancelled, inboxProfiles.contains(profile),
              let id = book.opening(profile), let record = book.record(id), !record.isUnverified,
              let identity = record.binding.identity, availability[id] != false else { return }
        if selected == id, live != nil { return }
        let read: InboxPreviewRead
        if let existing = inboxPreviewReads[id], existing.recovery == recovery { read = existing }
        else {
            let service = service
            read = .init(id: UUID(), recovery: recovery,
                task: Task { try await service.conversationPreview(identity) })
            inboxPreviewReads[id] = read
        }
        let summary = record.summary, message = record.inboxMessage
        defer { if inboxPreviewReads[id]?.id == read.id { inboxPreviewReads[id] = nil } }
        do {
            let result = try await read.task.value
            guard result.isComplete, read.recovery == recovery, inboxPreviewReads[id]?.id == read.id else { return }
            let applied = mutateBook { book in
                // Observation callbacks run before this borrow and may retire the
                // connection or publish a newer transcript.
                guard !retired, online, read.recovery == recovery, inboxPreviewReads[id]?.id == read.id,
                      inboxProfiles.contains(profile), book.opening(profile) == id,
                      let current = book.record(id), current.binding.identity == identity,
                      current.summary == summary, current.inboxMessage == message,
                      selected != id || live == nil else { return false }
                book.update(id) { $0.inboxPreview = .init(message: result.preview) }
                return true
            }
            if applied { onDirty() }
        } catch {
            // Optional history reads preserve the cached excerpt and existing activity.
        }
    }
    func invalidateActivityDirectory(_ profile: ExactID) {
        guard online, !retired else { return }
        activityDirectories.remove(profile); complete[profile] = false
        directoryReads.removeValue(forKey: profile)?.task.cancel()
        loadingDirectories.remove(profile)
    }
    private func refreshDirectory(profile: ExactID) async {
        guard online, !retired, !Task.isCancelled else { return }
        let read: DirectoryRead
        if let existing = directoryReads[profile], existing.recovery == recovery,
           existing.presentation == presentation { read = existing }
        else {
            let service = service
            read = .init(id: UUID(), recovery: recovery, presentation: presentation,
                task: Task { try await service.conversations(profile: profile) })
            directoryReads[profile] = read; loadingDirectories.insert(profile)
        }
        defer {
            if directoryReads[profile]?.id == read.id { directoryReads[profile] = nil; loadingDirectories.remove(profile) }
        }
        do {
            let directory = try await read.task.value
            // One waiter's cancellation cannot discard a shared read in the same workspace epochs.
            guard !retired, online, directoryReads[profile]?.id == read.id,
                  read.recovery == recovery, read.presentation == presentation else { return }
            directoryReads[profile] = nil; loadingDirectories.remove(profile)
            if selected.flatMap({ book.record($0)?.profile }) == profile { readHint = nil }
            var available: Set<ChatID> = []
            for summary in directory.summaries where summary.identity.profile == profile {
                let initialMainBinding = initialMainBindings[profile]
                let id = mutateBook { $0.merge(summary, initialMainBinding: initialMainBinding) }
                available.insert(id); availability[id] = true
                reconcileRequestSource(id)
                if selected == id { readHint = ReadObservationKey(summary) }
                let incoming = directory.activity[summary.identity]
                if case .known(_, let incomingAt) = incoming,
                   case .known(_, let currentAt) = activity[id], currentAt > incomingAt {
                    // A completed inventory read cannot restore an older sampled status.
                } else if let incoming { recordActivity(incoming, for: id) }
                else { mutateActivity { $0[id] = nil } }
                if selected == id, let live { updateActivity(live, id: id) }
            }
            if directory.isComplete {
                for record in book.ordered(profile) where !available.contains(record.id) {
                    availability[record.id] = false
                    if selected == record.id, let current = live {
                        retiredRecoveryAccesses.insert(current.access)
                        live = nil
                        avatarActivity.retire()
                        retireActionOwnership()
                    }
                    reconcileRequestSource(record.id)
                    if selected != record.id || live == nil {
                        recordActivity(.unknown("This chat is unavailable on Hermes"), for: record.id)
                    }
                }
                uncertainCreation.remove(profile)
            }
            complete[profile] = directory.isComplete
            if directory.isComplete { activityDirectories.insert(profile) }
            else { activityDirectories.remove(profile) }
            directoryWarnings[profile] = directory.warning ?? (directory.isComplete ? nil : "Some chats couldn’t be loaded. Cached chats are preserved.")
            refreshAvatarProfile(profile)
            rebuildRequests()
            onDirty()
        } catch {
            guard !retired, online, directoryReads[profile]?.id == read.id,
                  read.recovery == recovery, read.presentation == presentation else { return }
            directoryReads[profile] = nil; loadingDirectories.remove(profile)
            activityDirectories.remove(profile)
            directoryWarnings[profile] = error.localizedDescription; complete[profile] = false
            for record in book.ordered(profile) {
                if selected != record.id || live == nil {
                    recordActivity(.unknown(error.localizedDescription), for: record.id)
                }
            }
            refreshAvatarProfile(profile)
        }
    }
    func preferOpening(_ chat: ChatID?, owner: PresentationOwner) {
        guard isCurrent(owner), let profile = book.record(owner.chat)?.profile,
              chat == nil || book.record(chat!)?.profile == profile else { return }
        mutateBook { $0.updatePreference(profile) { $0.preferred = chat } }; onDirty()
        scheduleInboxPreviews(profiles: [profile])
    }
    func draft(_ owner: PresentationOwner) -> String { draftBook.record(owner.chat)?.draft.text ?? "" }
    func editDraft(_ text: String, owner: PresentationOwner) {
        guard canEditDraft(owner),
              book.record(owner.chat).map({ Data($0.draft.text.utf8) }) != Data(text.utf8) else { return }
        withMutation(keyPath: \.draftBook) {
            bookStorage.update(owner.chat) { $0.draft = .init(text: text, revision: UUID()) }
        }
        onDirty()
    }
    func displayed(_ owner: PresentationOwner) {
        guard isCurrent(owner), opening == nil, let chat = live?.snapshot ?? book.record(owner.chat)?.transcript else { return }
        let observation = online ? live.flatMap { publication -> ChatSummaryEvidence? in
            guard let evidence = publication.readEvidence?.summaryObservedBeforeRead,
                  let identity = book.record(owner.chat)?.binding.identity,
                  identity.profile == publication.identity.profile, identity.root == publication.identity.root,
                  identity.stored == publication.identity.stored,
                  evidence.identity.profile == identity.profile, evidence.identity.root == identity.root,
                  evidence.identity.stored == identity.stored else { return nil }
            return ChatSummaryEvidence(evidence)
        } : nil
        let seen = book.record(owner.chat)?.seen
        var applied = false
        withMutation(keyPath: \.book) {
            guard isCurrent(owner), opening == nil, let current = bookStorage.record(owner.chat),
                  Self.sameSeenCursor(current.seen, seen) else { return }
            bookStorage.update(owner.chat) { record in
                // A callback may publish newer content; acknowledge only the captured rendered chat.
                if record.summary == nil, let observation { record.summary = observation }
                record.displayed(chat, acknowledging: observation, at: .now)
            }
            applied = true
        }
        if applied { onDirty() }
    }
    private static func sameSeenCursor(_ a: SeenCursor?, _ b: SeenCursor?) -> Bool {
        (a == nil) == (b == nil) && a?.messageID == b?.messageID && a?.observedAt == b?.observedAt &&
            a?.content == b?.content && a?.summary == b?.summary && a?.rawMessageCount == b?.rawMessageCount
    }
    /// Called by the mounted view on coverage changes. Covering a transcript prevents
    /// new optional work; an already dispatched read remains workspace-owned.
    func setTranscriptVisible(_ visible: Bool, owner: PresentationOwner) {
        guard isCurrent(owner) else { return }
        transcriptVisible = visible
        if visible { displayed(owner); considerForegroundRead() }
        onVisibleChatChange?(visibleChatIdentity)
    }
    var visibleChatIdentity: SessionIdentity? {
        guard transcriptVisible, online, !retired, let selected, let live,
              let record = book.record(selected), !record.isUnverified,
              let identity = record.binding.identity, sameSource(identity, live.identity) else { return nil }
        return identity
    }
    private func considerForegroundRead() {
        guard transcriptVisible, online, !retired, opening == nil, foregroundRead == nil,
              !readAuthorityBlocked, let id = selected, let current = live,
              let record = book.record(id), !record.isUnverified, record.hasUnseenSummary,
              let identity = record.binding.identity, sameSource(identity, current.identity),
              let hint = readHint, hint.matches(identity), hint.matches(record.summary),
              !attemptedReads.contains(hint),
              current.readEvidence.map({ ReadObservationKey($0.summaryObservedBeforeRead) }) != hint,
              !current.snapshot.isWorking, current.snapshot.pendingRequests.isEmpty,
              sends[id] == nil, stops[id] == nil, (answers[id] ?? [:]).isEmpty,
              creations[identity.profile] == nil, uploadReservations[id] == nil,
              !imports.values.contains(where: { $0.chat == id }),
              !pendingOperations.values.contains(id), downloads.isEmpty else { return }
        let attempt = UUID(), lifetime = selectedViewLifetime
        // Reserve and retire synchronously, before a caller can queue an action or
        // SwiftUI can cancel its old owner task. The cached display stays mounted.
        attemptedReads.insert(hint)
        readAuthorityBlocked = true
        if let access = live?.access { retiredRecoveryAccesses.insert(access) }
        live = nil
        retireActionOwnership()
        opening = attempt
        let operationOwner = owner(id)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performForegroundRead(attempt, owner: operationOwner, lifetime: lifetime, source: identity)
        }
        foregroundRead = (attempt, task)
    }
    private func performForegroundRead(_ attempt: UUID, owner: PresentationOwner, lifetime: UUID,
                                       source: SessionIdentity) async {
        defer {
            retiringForegroundReads.remove(attempt)
            if foregroundRead?.id == attempt {
                foregroundRead = nil
                if opening == attempt { opening = nil }
            }
        }
        guard !Task.isCancelled, foregroundRead?.id == attempt, opening == attempt,
              selectedViewLifetime == lifetime, isCurrent(owner) else { return }
        do {
            let opened = try await service.openChat(.stored(source))
            guard !Task.isCancelled, foregroundRead?.id == attempt, opening == attempt,
                  selectedViewLifetime == lifetime, isCurrent(owner) else {
                retiredRecoveryAccesses.insert(opened.access); return
            }
            guard sameSource(opened.identity, source),
                  Data(opened.snapshot.profileID.utf8) == source.profile.bytes,
                  Data(opened.snapshot.storedID.utf8) == source.stored.bytes,
                  book.record(owner.chat)?.binding.identity.map({ sameSource($0, source) }) == true else {
                retiredRecoveryAccesses.insert(opened.access)
                throw HermesServiceError.wrongConversation
            }
            // A fresh access always retires artifacts, renders and action callbacks,
            // even for identical content. Only the selected visual lifetime survives.
            retireActionOwnership()
            retiredRecoveryAccesses.remove(opened.access)
            live = opened; readAuthorityBlocked = false
            availability[owner.chat] = true; errors[owner.chat] = nil
            mutateBook { $0.cache(opened.snapshot, for: owner.chat, readEvidence: opened.readEvidence) }
            updateActivity(opened, id: owner.chat); rebuildRequests(); onDirty()
            // No displayed() call here: only the fresh, visible view may acknowledge.
        } catch {
            guard foregroundRead?.id == attempt, selectedViewLifetime == lifetime, isCurrent(owner) else { return }
            live = nil; avatarActivity.retire(); requestRows = []; errors[owner.chat] = error.localizedDescription
        }
    }
    private func reserveOperation(_ id: UUID, chat: ChatID) -> WorkspaceOperationReservation {
        pendingOperations[id] = chat
        return WorkspaceOperationReservation { [weak self] in
            Task { @MainActor [weak self] in self?.finishOperation(id) }
        }
    }
    private func finishOperation(_ id: UUID) {
        guard let chat = pendingOperations.removeValue(forKey: id) else { return }
        imports[id] = nil
        if sends[chat] == id { sends[chat] = nil }
        if stops[chat] == id { stops[chat] = nil }
        if let profile = book.record(chat)?.profile, creations[profile] == id { creations[profile] = nil }
        considerForegroundRead()
    }
    func captureCreation(_ owner: PresentationOwner) -> CreationIntent? {
        guard canCreateFrom(owner), let profile = book.record(owner.chat)?.profile,
              creations[profile] == nil, !uncertainCreation.contains(profile) else { return nil }
        let operation = UUID(); creations[profile] = operation
        return .init(owner: owner, operation: operation, reservation: reserveOperation(operation, chat: owner.chat))
    }
    func create(_ intent: CreationIntent) async {
        guard !dispatched.contains(intent.operation) else { return }
        defer { withExtendedLifetime(intent.reservation) { finishOperation(intent.operation) } }
        guard let profile = book.record(intent.owner.chat)?.profile, creations[profile] == intent.operation else { return }
        guard !Task.isCancelled, canCreateFrom(intent.owner) else { return }
        onUserNavigation?()
        dispatched.insert(intent.operation)
        defer { if creations[profile] == intent.operation { creations[profile] = nil } }
        do {
            let receipt = try await service.createConversation(profile: profile, operationID: intent.operation)
            guard !retired, receipt.operationID == intent.operation, receipt.summary.identity.profile == profile else { return }
            let id = mutateBook { $0.merge(receipt.summary) }; availability[id] = true; reconcileRequestSource(id); onDirty()
            // The identified late result is retained, but cannot navigate a newer presentation.
            if !Task.isCancelled, isCurrent(intent.owner) { await attach(id) }
        } catch {
            guard !retired else { return }
            errors[intent.owner.chat] = error.localizedDescription
            if error as? HermesServiceError == .uncertain { uncertainCreation.insert(profile) }
        }
    }
    func captureSend(_ owner: PresentationOwner, delivery: MessageDelivery = .queue) -> SendIntent? {
        guard canAct(owner), let record = book.record(owner.chat), let source = live?.identity,
              sends[owner.chat] == nil, uploadReservations[owner.chat] == nil else { return nil }
        let staged = staging[owner.chat] ?? []
        guard staged.allSatisfy(\.valid), !record.draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !staged.isEmpty else { return nil }
        guard delivery != .steer || (live?.snapshot.isWorking == true && staged.isEmpty) else { return nil }
        let operation = UUID(); sends[owner.chat] = operation
        return .init(delivery: delivery, reservation: reserveOperation(operation, chat: owner.chat), owner: owner, operation: operation, source: source, revision: record.draft.revision,
                     text: record.draft.text, attachments: staged.map(\.attachment), stagedIDs: Set(staged.map(\.id)))
    }
    func send(_ intent: SendIntent) async {
        guard !dispatched.contains(intent.operation) else { return }
        defer { withExtendedLifetime(intent.reservation) { finishOperation(intent.operation) } }
        guard !Task.isCancelled, canAct(intent.owner), sends[intent.owner.chat] == intent.operation,
              let access = intent.owner.access,
              book.record(intent.owner.chat)?.draft.revision == intent.revision,
              Set((staging[intent.owner.chat] ?? []).map(\.id)) == intent.stagedIDs,
              (staging[intent.owner.chat] ?? []).allSatisfy(\.valid) else { return }
        dispatched.insert(intent.operation); sends[intent.owner.chat] = intent.operation
        let feedbackLifetime = selectedViewLifetime
        errors[intent.owner.chat] = nil
        defer { if sends[intent.owner.chat] == intent.operation { sends[intent.owner.chat] = nil } }
        do {
            let receipt = try await service.send(text: intent.text, attachments: intent.attachments, delivery: intent.delivery, access: access, operationID: intent.operation)
            guard !retired, receipt.operationID == intent.operation, sameSource(receipt.source, intent.source),
                  book.record(intent.owner.chat)?.profile == intent.source.profile else { return }
            if book.record(intent.owner.chat)?.draft.revision == intent.revision {
                mutateBook { $0.update(intent.owner.chat) { $0.draft = .init(text: "", revision: UUID()) } }
            }
            staging[intent.owner.chat]?.removeAll { intent.stagedIDs.contains($0.id) }
            if case .needsLocalRepair = receipt.journal {
                errors[intent.owner.chat] = "Hermes accepted this message, but its local receipt needs repair. Don’t resend it."
                emitFeedback(.warning, owner: intent.owner, lifetime: feedbackLifetime)
            } else {
                emitFeedback(.accepted, owner: intent.owner, lifetime: feedbackLifetime)
            }
            onDirty()
        } catch {
            if !retired { errors[intent.owner.chat] = error.localizedDescription }
            emitFailure(error, owner: intent.owner, lifetime: feedbackLifetime)
        }
    }
    private func sameSource(_ lhs: SessionIdentity, _ rhs: SessionIdentity) -> Bool {
        lhs.profile == rhs.profile && lhs.root == rhs.root && lhs.stored == rhs.stored
    }
    func beginQueuedEdit(_ message: QueuedMessage, owner: PresentationOwner) {
        guard isCurrent(owner), canEditDraft(owner), message.canEdit, !message.isSteering,
              let record = book.record(owner.chat), let source = live?.identity ?? record.binding.identity,
              (live?.snapshot ?? record.transcript)?.queuedMessages.contains(where: { $0 == message }) == true else { return }
        queuedEditing.begin(message, source: source, chat: owner.chat)
    }
    func queuedEditText(_ owner: PresentationOwner, id: UUID) -> String? {
        guard !retired, owner.workspace == scope, owner.chat == selected,
              let edit = queuedEditing.edit(owner.chat), edit.id == id else { return nil }
        return edit.text
    }
    func updateQueuedEdit(_ text: String, owner: PresentationOwner) {
        guard isCurrent(owner), canEditDraft(owner) else { return }
        queuedEditing.update(text, chat: owner.chat)
    }
    func cancelQueuedEdit(_ owner: PresentationOwner) {
        guard isCurrent(owner) else { return }
        queuedEditing.cancel(owner.chat)
    }
    func keepQueuedEditAsDraft(_ owner: PresentationOwner) {
        guard isCurrent(owner), canEditDraft(owner), let edit = queuedEditing.edit(owner.chat),
              !edit.isSaving else { return }
        let existing = draft(owner)
        let text = existing.isEmpty || existing.utf8.elementsEqual(edit.text.utf8) ? edit.text : existing + "\n\n" + edit.text
        editDraft(text, owner: owner)
        queuedEditing.cancel(owner.chat)
    }
    func saveQueuedEdit(_ owner: PresentationOwner) async {
        guard !Task.isCancelled, canAct(owner), let live, let access = owner.access,
              sends[owner.chat] == nil, uploadReservations[owner.chat] == nil,
              queuedEditing.canSave(owner.chat, source: live.identity, messages: live.snapshot.queuedMessages) else { return }
        let source = live.identity
        let receipt = await queuedEditing.save(owner.chat, source: source, messages: live.snapshot.queuedMessages) { message, text, operation in
            let reservation = self.reserveOperation(operation, chat: owner.chat)
            self.sends[owner.chat] = operation
            defer { withExtendedLifetime(reservation) { self.finishOperation(operation) } }
            guard !Task.isCancelled, self.canAct(owner), let current = self.live,
                  self.sameSource(current.identity, source),
                  current.snapshot.queuedMessages.contains(where: { $0 == message && $0.canEdit && !$0.isSteering }) else {
                throw HermesServiceError.queuedMessageUnavailable
            }
            self.dispatched.insert(operation)
            return try await self.service.replaceQueuedMessage(message, text: text, access: access, operationID: operation)
        }
        guard !retired, let receipt, sameSource(receipt.source, source) else { return }
        if case .needsLocalRepair = receipt.journal {
            errors[owner.chat] = "Hermes saved this edit, but its local receipt needs repair. Don’t send it again."
        }
        onDirty()
    }

    func captureStop(_ owner: PresentationOwner) -> StopIntent? {
        guard canAct(owner), live?.snapshot.isWorking == true, stops[owner.chat] == nil else { return nil }
        let operation = UUID(); stops[owner.chat] = operation
        return .init(owner: owner, operation: operation, reservation: reserveOperation(operation, chat: owner.chat))
    }
    func stop(_ intent: StopIntent) async {
        guard !dispatched.contains(intent.operation) else { return }
        defer { withExtendedLifetime(intent.reservation) { finishOperation(intent.operation) } }
        guard !Task.isCancelled, canAct(intent.owner), stops[intent.owner.chat] == intent.operation, let access = intent.owner.access else { return }
        dispatched.insert(intent.operation); stops[intent.owner.chat] = intent.operation
        let feedbackLifetime = selectedViewLifetime
        let source = live?.identity
        stopFeedback = .init(owner: intent.owner, viewLifetime: feedbackLifetime, operation: intent.operation)
        defer { if stops[intent.owner.chat] == intent.operation { stops[intent.owner.chat] = nil } }
        do {
            let receipt = try await service.stop(access: access, operationID: intent.operation)
            guard receipt.operationID == intent.operation, let source, sameSource(receipt.source, source),
                  stopFeedback?.operation == intent.operation else { return }
            stopFeedback?.acknowledged = true
            finishStopFeedback()
        } catch {
            if stopFeedback?.operation == intent.operation { stopFeedback = nil }
            if !retired { errors[intent.owner.chat] = error.localizedDescription }
            emitFailure(error, owner: intent.owner, lifetime: feedbackLifetime)
        }
    }
    private func reconcileRequestSource(_ id: ChatID) {
        guard !retired, let record = book.record(id), !record.isUnverified,
              availability[id] != false, let source = record.binding.identity else {
            cachedRequests[id] = nil; questionDrafts[id] = nil
            if selected == id { requestRows = [] }
            return
        }
        if let cached = cachedRequests[id], !sameSource(cached.source, source) {
            cachedRequests[id] = nil
            if selected == id { requestRows = [] }
        }
        if let cached = questionDrafts[id], !sameSource(cached.source, source) { questionDrafts[id] = nil }
    }
    private func rebuildRequests() {
        guard !retired, let id = selected else { requestRows = []; return }
        reconcileRequestSource(id)
        guard let record = book.record(id), !record.isUnverified, availability[id] != false,
              let source = record.binding.identity else { requestRows = []; return }
        let rendered = owner(id)
        let pending = live.flatMap { sameSource($0.identity, source) ? $0.snapshot.pendingRequests : nil }
            ?? cachedRequests[id]?.requests ?? []
        questionDrafts[id]?.drafts.removeAll { draft in !pending.contains { $0.hasSameWireRevision(as: draft.request) } }
        requestRows = pending.map { request in
            let previous = requestRows.filter { $0.request.id.utf8.elementsEqual(request.id.utf8) }
            let unique = pending.filter { $0.id.utf8.elementsEqual(request.id.utf8) }.count == 1
            let existing = unique && previous.count == 1 ? previous.first {
                $0.request.hasSameWireRevision(as: request) && $0.intent.owner == rendered
            } : nil
            return existing ?? .init(id: UUID(), request: request, intent: .init(owner: rendered, operation: UUID(), request: request))
        }
        cachedRequests[id] = (source, pending)
    }
    func currentRequestRow(matching row: RequestRow, owner: PresentationOwner) -> RequestRow? {
        guard isCurrent(owner), row.intent.owner == owner else { return nil }
        let matches = requestRows.filter { $0.id == row.id || $0.request.id.utf8.elementsEqual(row.request.id.utf8) }
        guard matches.count == 1, let current = matches.first, current.id == row.id,
              current.intent.owner == owner, current.request.hasSameWireRevision(as: row.request) else { return nil }
        return current
    }
    func requestDraft(_ row: RequestRow, owner: PresentationOwner) -> String {
        guard currentRequestRow(matching: row, owner: owner) != nil, let source = book.record(owner.chat)?.binding.identity,
              let cached = questionDrafts[owner.chat], sameSource(cached.source, source) else { return "" }
        return cached.drafts.first { $0.request.hasSameWireRevision(as: row.request) }?.text ?? ""
    }
    func editRequestDraft(_ text: String, row: RequestRow, owner: PresentationOwner) {
        guard canEditDraft(owner), currentRequestRow(matching: row, owner: owner) != nil, row.request.kind == .question,
              let source = book.record(owner.chat)?.binding.identity else { return }
        var drafts = questionDrafts[owner.chat].flatMap { sameSource($0.source, source) ? $0.drafts : nil } ?? []
        drafts.removeAll { $0.request.hasSameWireRevision(as: row.request) }
        drafts.append(.init(request: row.request, text: text))
        questionDrafts[owner.chat] = (source, drafts)
    }
    func answer(_ intent: RequestIntent, response: RequestResponse) async {
        // A rendered request already blocks optional reads. Its reservation begins
        // only on dispatch, never merely by creating a request row.
        defer { considerForegroundRead() }
        let current = live?.snapshot.pendingRequests.filter { $0.id.utf8.elementsEqual(intent.request.id.utf8) } ?? []
        guard !Task.isCancelled, canAct(intent.owner), current.count == 1, current[0].hasSameWireRevision(as: intent.request),
              requestRows.contains(where: { $0.intent.operation == intent.operation && $0.intent.owner == intent.owner && $0.request.hasSameWireRevision(as: intent.request) }),
              answers[intent.owner.chat]?[intent.request.id] == nil, !dispatched.contains(intent.operation),
              let access = intent.owner.access else { return }
        errors[intent.owner.chat] = nil
        dispatched.insert(intent.operation); answers[intent.owner.chat, default: [:]][intent.request.id] = intent.operation
        let feedbackLifetime = selectedViewLifetime
        let source = live?.identity
        defer {
            if answers[intent.owner.chat]?[intent.request.id] == intent.operation { answers[intent.owner.chat]?[intent.request.id] = nil }
        }
        do {
            let receipt = try await service.respond(to: intent.request, response: response, access: access, operationID: intent.operation)
            guard receipt.operationID == intent.operation, let source, sameSource(receipt.source, source) else { return }
            emitFeedback(.accepted, owner: intent.owner, lifetime: feedbackLifetime)
        }
        catch {
            guard !retired else { return }
            errors[intent.owner.chat] = error.localizedDescription
            emitFailure(error, owner: intent.owner, lifetime: feedbackLifetime)
            // Core consumed this operation before its local validation. A later deliberate
            // correction needs a fresh attempt, while this old intent stays tombstoned.
            if let rejection = error as? HermesServiceError,
               [.invalidResponse, .responseTooLong].contains(rejection), canAct(intent.owner),
               let index = requestRows.firstIndex(where: {
                   $0.intent.operation == intent.operation && $0.intent.owner == intent.owner && $0.request.hasSameWireRevision(as: intent.request)
               }) {
                let row = requestRows[index]
                requestRows[index] = .init(id: row.id, request: row.request,
                    intent: .init(owner: intent.owner, operation: UUID(), request: row.request))
            }
        }
    }
    func captureImport(_ owner: PresentationOwner) -> ImportIntent? {
        guard canAct(owner) else { return nil }
        let id = UUID()
        let intent = ImportIntent(owner: owner, id: id, reservation: reserveOperation(id, chat: owner.chat))
        imports[id] = owner
        return intent
    }
    func cancelImport(_ intent: ImportIntent) {
        if imports[intent.id] == intent.owner { finishOperation(intent.id) }
    }
    func upload(_ data: Data, filename: String, mimeType: String, to intent: ImportIntent) async {
        defer { withExtendedLifetime(intent.reservation) { finishOperation(intent.id) } }
        guard !Task.isCancelled, imports.removeValue(forKey: intent.id) == intent.owner, canAct(intent.owner),
              uploadReservations[intent.owner.chat] == nil, let access = intent.owner.access else { return }
        guard let source = live?.identity else { return }
        let id = intent.owner.chat, current = staging[intent.owner.chat] ?? []
        let feedbackLifetime = selectedViewLifetime
        let used = current.reduce(0) { $0 + $1.bytes }
        let reserved = AttachmentLimits.reservationBytes(dataCount: data.count, filename: filename, mimeType: mimeType)
        guard !data.isEmpty, data.count <= AttachmentLimits.fileBytes, current.count < AttachmentLimits.count,
              reserved <= AttachmentLimits.totalBytes - used else {
            errors[id] = AttachmentLimits.message
            emitFeedback(.error, owner: intent.owner, lifetime: feedbackLifetime)
            return
        }
        uploadReservations[id] = intent.id
        defer { if uploadReservations[id] == intent.id { uploadReservations[id] = nil } }
        do {
            let attachment = try await service.upload(data: data, filename: filename, mimeType: mimeType, access: access)
            guard canAct(intent.owner), uploadReservations[id] == intent.id, !Task.isCancelled else { return }
            let bytes = attachment.byteCount ?? reserved
            guard bytes > 0, bytes <= AttachmentLimits.fileBytes, bytes <= AttachmentLimits.totalBytes - used else {
                errors[id] = AttachmentLimits.message
                emitFeedback(.error, owner: intent.owner, lifetime: feedbackLifetime)
                return
            }
            staging[id, default: []].append(.init(id: UUID(), attachment: attachment, bytes: bytes, source: source, valid: true))
            emitFeedback(.accepted, owner: intent.owner, lifetime: feedbackLifetime)
        } catch {
            if isCurrent(intent.owner), !Task.isCancelled { errors[id] = error.localizedDescription }
            emitFailure(error, owner: intent.owner, lifetime: feedbackLifetime)
        }
    }
    func removeAttachment(_ attachment: ChatAttachment, owner: PresentationOwner) {
        guard isCurrent(owner), let index = staging[owner.chat]?.firstIndex(where: { $0.attachment == attachment }) else { return }
        staging[owner.chat]?.remove(at: index)
    }
    func captureArtifact(_ attachment: ChatAttachment, owner: PresentationOwner) -> ArtifactIntent? {
        guard canAct(owner) else { return nil }
        let id = UUID()
        return .init(reservation: reserveOperation(id, chat: owner.chat), id: id, owner: owner, attachment: attachment)
    }
    func isCurrentArtifact(_ intent: ArtifactIntent) -> Bool { canAct(intent.owner) }
    func finishArtifact(_ intent: ArtifactIntent) { finishOperation(intent.id) }
    func download(_ intent: ArtifactIntent) async throws -> DownloadedArtifact {
        try Task.checkCancellation()
        guard canAct(intent.owner), let access = intent.owner.access else { throw HermesServiceError.staleConversation }
        let task = Task { try await service.downloadArtifact(intent.attachment, access: access) }
        let operation = UUID()
        downloads[operation] = task
        defer { downloads[operation] = nil; considerForegroundRead() }
        let artifact = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation()
        guard canAct(intent.owner), !task.isCancelled else { throw HermesServiceError.staleConversation }
        return artifact
    }
    private func updateActivity(_ opened: OpenedConversation, id: ChatID, previous: OpenedConversation? = nil) {
        let snapshot = opened.snapshot
        avatarActivity.accept(opened)
        recordActivity(.known(!snapshot.pendingRequests.isEmpty ? .waiting : snapshot.isWorking ? .working : .idle, now()), for: id)
        refreshAvatarProfile(opened.identity.profile)
        updateFeedback(opened, previous: previous, id: id)
    }

    private func emitFeedback(_ event: HapticEvent, owner: PresentationOwner, lifetime: UUID, id: UUID = UUID()) {
        guard !retired, online, transcriptVisible, owner.workspace == scope, owner.recovery == recovery,
              selected == owner.chat, selectedViewLifetime == lifetime, !Task.isCancelled else { return }
        onHapticFeedback?(.init(id: id, event: event, chat: owner.chat, viewLifetime: lifetime))
    }

    private func emitFailure(_ error: any Error, owner: PresentationOwner, lifetime: UUID) {
        guard !(error is CancellationError) else { return }
        emitFeedback(.failure(error), owner: owner, lifetime: lifetime)
    }

    private func finishStopFeedback() {
        guard let pending = stopFeedback, pending.acknowledged, let signal = pending.signal else { return }
        stopFeedback = nil
        emitFeedback(.stopped, owner: pending.owner, lifetime: pending.viewLifetime, id: signal)
    }

    private func updateFeedback(_ opened: OpenedConversation, previous: OpenedConversation?, id: ChatID) {
        let activity = opened.activity
        let reaction = activity?.reaction, signal = activity?.signal
        let newReaction = reaction != nil && reaction?.id != lastFeedbackReaction
        let newSignal = signal != nil && signal?.id != lastFeedbackSignal
        if let reaction { lastFeedbackReaction = reaction.id }
        if let signal { lastFeedbackSignal = signal.id }
        guard let previous, let activity, previous.activity?.lineage == activity.lineage else { return }
        let owner = owner(id), lifetime = selectedViewLifetime
        if let reaction, newReaction {
            stopFeedback = nil
            emitFeedback(reaction.kind == .succeeded ? .replyFinished : .error,
                         owner: owner, lifetime: lifetime, id: reaction.id)
        }
        guard let signal, newSignal else { return }
        switch signal.kind {
        case .turnStarted:
            stopFeedback = nil
        case .replyText:
            emitFeedback(.streaming, owner: owner, lifetime: lifetime, id: signal.id)
        case .request:
            let fresh = opened.snapshot.pendingRequests.contains { request in
                request.kind != .unsupported && !previous.snapshot.pendingRequests.contains {
                    $0.hasSameWireRevision(as: request)
                }
            }
            if fresh { emitFeedback(.attention, owner: owner, lifetime: lifetime, id: signal.id) }
        case .stopped:
            guard transcriptVisible else { stopFeedback = nil; return }
            stopFeedback?.signal = signal.id
            finishStopFeedback()
        }
    }
    private func recordActivity(_ observation: ObservedActivity, for id: ChatID) {
        mutateActivity { $0[id] = observation }
        let status: BotStatus? = if case .known(let value, _) = observation { value } else { nil }
        avatarActivity.record(chat: id, status: status, at: now())
        if case .known(let status, let date) = observation {
            withMutation(keyPath: \.book) {
                bookStorage.update(id) { $0.lastKnownActivity = .init(status: status, observedAt: date) }
            }
        }
    }
    func receive(_ publication: OpenedConversation) {
        // A canceled Core open can emit before returning. Until it drains, only
        // the currently installed grant can publish; explicit opens install their
        // fenced return directly. The canceled result is then tombstoned below.
        if readAuthorityBlocked || (!retiringForegroundReads.isEmpty && publication.access != live?.access) {
            retiredRecoveryAccesses.insert(publication.access)
            return
        }
        guard !retired, !retiredRecoveryAccesses.contains(publication.access),
              opening == nil, let id = selected, let record = book.record(id),
              !record.isUnverified, let expected = record.binding.identity,
              expected.profile == publication.identity.profile, expected.root == publication.identity.root,
              Data(publication.snapshot.profileID.utf8) == publication.identity.profile.bytes else { return }
        if let handoff = recoveryHandoff {
            guard isCurrent(handoff.owner), publication.access != handoff.retiredAccess else { return }
            if !online {
                // Recovery may publish before connected. Keep it inert until this owner is online.
                if let previous = handoff.pending, previous.access != publication.access {
                    retiredRecoveryAccesses.insert(previous.access)
                }
                recoveryHandoff?.pending = publication
                return
            }
            if let retiredAccess = handoff.retiredAccess { retiredRecoveryAccesses.insert(retiredAccess) }
            recoveryHandoff = nil
        } else if !online {
            retiredRecoveryAccesses.insert(publication.access)
            return
        }
        let previous = live
        if publication.access != previous?.access || Data(publication.snapshot.id.utf8) != previous.map({ Data($0.snapshot.id.utf8) })
            || publication.identity.stored != previous?.identity.stored {
            retireActionOwnership()
        }
        if (staging[id] ?? []).contains(where: { $0.source.stored != publication.identity.stored }) { invalidateStaging(id) }
        live = publication
        let canonical = book.preference(publication.identity.profile)?.main == id
        _ = mutateBook { $0.merge(.init(identity: publication.identity, title: record.title,
            isCanonical: canonical, persistence: .unknown)) }
        mutateBook { $0.cache(publication.snapshot, for: id, readEvidence: publication.readEvidence) }
        updateActivity(publication, id: id, previous: previous); rebuildRequests(); onDirty()
    }
    /// Lightweight inventory activity never changes selection, transcripts, seen or grants.
    func applyActivity(profile: ExactID, observations: [SessionIdentity: ObservedActivity]) {
        applyActivity([.init(profile: profile, observations: observations)])
    }
    private func activityTarget(_ identity: SessionIdentity, profile: ExactID,
                                observation: ObservedActivity, records: [ChatRecord]) -> ChatID? {
        guard identity.profile == profile,
              let id = ConversationBook.matching(identity, among: records),
              selected != id || live == nil else { return nil }
        if case .known(_, let sampledAt) = observation,
           case .known(_, let currentAt) = activityStorage[id], currentAt > sampledAt { return nil }
        return id
    }
    func applyActivity(_ updates: [ProfileActivityUpdate]) {
        guard !retired, online, !updates.isEmpty else { return }
        let expectedRecovery = recovery
        let initialRecords = Dictionary(grouping: bookStorage.records, by: \.profile)
        guard updates.contains(where: { update in
            update.observations.contains { identity, observation in
                guard let id = activityTarget(identity, profile: update.profile, observation: observation,
                                              records: initialRecords[update.profile] ?? []) else { return false }
                return bookStorage.record(id)?.profile == update.profile
            }
        }) else { return }
        let mayWriteHistory = updates.contains { update in
            update.observations.values.contains { observation in
                if case .known = observation { return true }
                return false
            }
        }
        var appliedProfiles: Set<ExactID> = []
        var avatarObservations: [ChatID: ObservedActivity] = [:]
        func reduceAndInstall() {
            guard !retired, online, recovery == expectedRecovery else { return }
            let records = Dictionary(grouping: bookStorage.records, by: \.profile)
            var positions: [ChatID: Int] = [:]
            for index in bookStorage.records.indices where positions[bookStorage.records[index].id] == nil {
                positions[bookStorage.records[index].id] = index
            }
            for update in updates {
                var appliedProfile = false
                for (identity, observation) in update.observations {
                    guard let id = activityTarget(identity, profile: update.profile, observation: observation,
                                                  records: records[update.profile] ?? []),
                          let index = positions[id], bookStorage.records[index].profile == update.profile else { continue }
                    activityStorage[id] = observation
                    avatarObservations[id] = observation
                    if case .known(let status, let date) = observation {
                        bookStorage.records[index].lastKnownActivity = .init(status: status, observedAt: date)
                    }
                    appliedProfile = true
                }
                if appliedProfile {
                    profileActivityStorage[update.profile] = nil
                    appliedProfiles.insert(update.profile)
                }
            }
        }
        // Complete every will-change callback before borrowing or reducing canonical state.
        withMutation(keyPath: \.activity) {
            withMutation(keyPath: \.profileActivity) {
                if mayWriteHistory {
                    withMutation(keyPath: \.book) { reduceAndInstall() }
                } else { reduceAndInstall() }
            }
        }
        guard !appliedProfiles.isEmpty else { return }
        for (id, observation) in avatarObservations {
            let status: BotStatus? = if case .known(let value, _) = observation { value } else { nil }
            avatarActivity.record(chat: id, status: status, at: now())
        }
        for profile in appliedProfiles { refreshAvatarProfile(profile) }
        onDirty()
    }
    private func invalidateStaging(_ id: ChatID) {
        guard let count = staging[id]?.count else { return }
        for index in 0..<count { staging[id]?[index].valid = false }
    }
    private func retireRecoveryHandoff() {
        if let handoff = recoveryHandoff {
            if let access = handoff.retiredAccess { retiredRecoveryAccesses.insert(access) }
            if let pending = handoff.pending { retiredRecoveryAccesses.insert(pending.access) }
        }
        recoveryHandoff = nil
    }
    func retirePresentation() {
        selectedViewLifetime = UUID(); transcriptVisible = false; readHint = nil; attemptedReads = []
        stopFeedback = nil
        onVisibleChatChange?(nil)
        if let read = foregroundRead {
            retiringForegroundReads.insert(read.id)
            read.task.cancel(); foregroundRead = nil
        }
        if readAuthorityBlocked { live = nil }
        retireActionOwnership()
    }
    private func retireActionOwnership() {
        retireRecoveryHandoff()
        presentation = UUID(); opening = nil; imports = [:]; uploadReservations = [:]; requestRows = []
        creations = creations.filter { dispatched.contains($0.value) }
        pendingOperations = pendingOperations.filter { dispatched.contains($0.key) }
        sends = sends.filter { dispatched.contains($0.value) }
        stops = stops.filter { dispatched.contains($0.value) }
        for download in downloads.values { download.cancel() }; downloads = [:]
        onPresentationChange?()
        // A current service attachment may still be used by a freshly rendered owner.
        rebuildRequests()
    }
    func retireConnection(allowRecoveryPublication: Bool = false) {
        let retiredAccess = recoveryHandoff?.pending?.access ?? live?.access ?? recoveryHandoff?.retiredAccess
        avatarActivity = BotAvatarActivityLedger()
        online = false; recovery = UUID(); live = nil
        for id in staging.keys { invalidateStaging(id) }
        for read in directoryReads.values { read.task.cancel() }
        inboxPreviewRefresh?.task.cancel(); inboxPreviewRefresh = nil; pendingInboxProfiles = []
        for read in inboxPreviewReads.values { read.task.cancel() }
        inboxPreviewReads = [:]
        directoryReads = [:]; loadingDirectories = []; mutateActivity { $0 = [:] }; mutateProfileActivity { $0 = [:] }; activityDirectories = []
        retirePresentation()
        // A new connection may provide a genuinely fresh recovery attachment.
        // Canceled reads still drain behind their separate publication fence.
        readAuthorityBlocked = false
        if allowRecoveryPublication, !retired, let id = selected, let record = book.record(id),
           !record.isUnverified, record.binding.identity != nil {
            recoveryHandoff = .init(owner: owner(id), retiredAccess: retiredAccess)
        }
    }
    func retireWorkspace() {
        retired = true; initialMainBindings = [:]; cachedRequests = [:]; questionDrafts = [:]; retireConnection()
    }
}
