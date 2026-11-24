import Foundation
import Observation
import UIKit
import BottoCore

@MainActor @Observable final class AppStore {
    enum Link: Equatable { case unconfigured, connecting, online, offline }

    struct InboxEntry: Identifiable {
        let bot: BotProfile
        let aggregate: ChatAggregate?
        var id: String { bot.id }
        var needsAttention: Bool { aggregate?.attentionChat != nil || aggregate?.status == .waiting }
        var isUnread: Bool { aggregate?.selectedChatIsUnread == true }
        fileprivate var priority: Int {
            switch bot.status {
            case .waiting: 0
            case .working: 1
            case .idle: isUnread ? 2 : 3
            }
        }
    }

    /// Captured synchronously at a file-card tap. The workspace owns its exact access.
    struct ArtifactDestination: Identifiable, Sendable {
        let id = UUID()
        let attachment: ChatAttachment
        /// Every attachment of the producing message, in reading order.
        let siblings: [ChatAttachment]
        let conversation: Conversation
        fileprivate let producingMessage: ChatMessage?
        fileprivate let workspace: ConversationWorkspace
        fileprivate let intent: ArtifactIntent?
        fileprivate let identity: SessionIdentity
        fileprivate let library: WorkspaceLibrary
        fileprivate let localOwner: ArtifactPresentationKey
        fileprivate let localEpoch: UUID
    }

    fileprivate struct ArtifactPresentationKey: Equatable, Sendable {
        let cache: UUID
        let account: [Data?]
        let chat: ChatID
        let root: ExactID
        let tip: ExactID
        let profile: Data
        let runtime: Data
        let stored: Data
    }

    /// The downloaded bytes retain their capture until the consumer installs them.
    @MainActor final class ReplyFileDownload {
        let artifact: DownloadedArtifact
        private var destination: ArtifactDestination?

        fileprivate init(artifact: DownloadedArtifact, destination: ArtifactDestination) {
            self.artifact = artifact; self.destination = destination
        }

        func finishInstallation() {
            guard let destination else { return }
            self.destination = nil
            if let intent = destination.intent { destination.workspace.finishArtifact(intent) }
            destination.library.reconcileOriginalConsumers()
        }
    }

    struct AvatarDestination: Identifiable {
        let id = UUID()
        let profile: BotProfile
        fileprivate let workspaceGeneration: UUID
        fileprivate let configurationID: UUID
        fileprivate let account: [Data]
        fileprivate let installID: Data?
        fileprivate let demo: Bool

        // A local draft belongs to an account, not to a particular socket lifetime.
        @MainActor func isCurrent(in store: AppStore) -> Bool {
            guard let configuration = store.configuration,
                  store.avatarWorkspaceGeneration == workspaceGeneration,
                  configuration.id == configurationID, store.isDemo == demo,
                  Self.account(for: configuration) == account,
                  store.history.bots.contains(where: { $0.id == profile.id }) else { return false }
            // A cached setup may learn its installation ID on its first connection.
            return installID == nil || configuration.installID.map { Data($0.utf8) } == installID
        }

        fileprivate static func account(for configuration: ConnectionConfiguration) -> [Data] {
            [configuration.serverURL.absoluteString, configuration.username,
             configuration.nativeCredential?.provider ?? "basic"].map { Data($0.utf8) }
                + AppStore.backendAccount(configuration).compactMap { $0 }
        }
    }

    @MainActor private final class BotRefresh {
        var task: Task<Void, Never>?
        var active: [UUID: CheckedContinuation<Bool, Never>] = [:]
        var pending: [UUID: CheckedContinuation<Bool, Never>] = [:]
    }

    @MainActor private final class BotInvalidationRefresh {
        var task: Task<Void, Never>?
        var pending = false
    }

    private struct ConnectionLifecycle {
        private enum Phase {
            case unconfigured, waiting, connecting(ConnectionConfiguration)
            case interrupted(ConnectionConfiguration), online, offline
        }
        private var phase: Phase = .unconfigured
        private(set) var generation = UUID()
        private(set) var recoveryGeneration = UUID()
        private(set) var serverInfo: ServerInfo?
        private(set) var errorMessage: String?

        var link: Link {
            switch phase {
            case .unconfigured: .unconfigured
            case .waiting, .connecting: .connecting
            case .online: .online
            case .interrupted, .offline: .offline
            }
        }
        var candidate: ConnectionConfiguration? {
            switch phase {
            case .connecting(let candidate), .interrupted(let candidate): candidate
            default: nil
            }
        }
        var isSuspended: Bool { if case .waiting = phase { true } else { false } }
        func ownsAttempt(_ owner: UUID) -> Bool { generation == owner && candidate != nil }

        mutating func restore(hasSavedSetup: Bool) {
            phase = hasSavedSetup ? .offline : .unconfigured
            errorMessage = nil
        }
        mutating func savedSetupFailed(_ error: any Error) { errorMessage = error.localizedDescription }
        mutating func awaitStartup() { phase = .waiting }

        mutating func begin(_ candidate: ConnectionConfiguration) -> UUID {
            generation = UUID()
            phase = .connecting(candidate)
            errorMessage = nil
            return generation
        }
        mutating func updateCandidate(_ updated: ConnectionConfiguration) {
            guard let candidate, updated.id == candidate.id, updated.serverURL == candidate.serverURL else { return }
            switch phase {
            case .connecting: phase = .connecting(updated)
            case .interrupted: phase = .interrupted(updated)
            default: break
            }
        }
        mutating func complete(_ owner: UUID, info: ServerInfo) -> Bool {
            guard ownsAttempt(owner) else { return false }
            phase = .online
            serverInfo = info; errorMessage = nil
            return true
        }
        mutating func cancel(_ owner: UUID, hasSavedSetup: Bool, failure: (any Error)? = nil) -> Bool {
            guard ownsAttempt(owner) else { return false }
            generation = UUID()
            phase = hasSavedSetup ? .offline : .unconfigured
            if let failure { errorMessage = failure.localizedDescription }
            return true
        }
        mutating func suspend(hasSavedSetup: Bool) {
            generation = UUID()
            phase = hasSavedSetup ? .waiting : .unconfigured
        }
        mutating func forget() {
            generation = UUID(); phase = .unconfigured
            serverInfo = nil; errorMessage = nil
        }
        mutating func credentialStorageFailed(_ error: any Error, hasSavedSetup: Bool) {
            generation = UUID()
            phase = hasSavedSetup ? .offline : .unconfigured
            errorMessage = error.localizedDescription
        }
        mutating func disconnected(_ reason: String) {
            if let candidate { phase = .interrupted(candidate) }
            else { phase = .offline }
            // Socket recovery retains the event owner while retiring attachment reads.
            recoveryGeneration = UUID()
            errorMessage = reason
        }
        mutating func recovered(_ info: ServerInfo) -> Bool {
            guard candidate == nil else { return false }
            phase = .online
            serverInfo = info; errorMessage = nil
            return true
        }
    }
    private var connection = ConnectionLifecycle() {
        didSet { library.setOnline(connection.link == .online) }
    }
    var link: Link { pendingService != nil && connection.link != .online ? .connecting : connection.link }
    private(set) var configuration: ConnectionConfiguration?
    private(set) var savedSetupLoadFailed = false
    var serverInfo: ServerInfo? { connection.serverInfo }
    private var cachedBots: [BotProfile] = [] { didSet { library.observeBots(cachedBots, evidence: .cached) } }
    private(set) var t3Channels: [T3ChannelSummary] = []
    private var pinned: Set<ExactID> = []
    private var unpinned: Set<ExactID> = []
    private(set) var chats: ConversationWorkspace
    let t3Push: T3PushCoordinator
    var t3PushScope: T3PushScope? {
        guard !isDemo, let t3 = configuration?.t3, !t3.environmentID.isEmpty, let project = t3.projectID else { return nil }
        return .init(environmentID: t3.environmentID, projectID: project)
    }

    func shouldPresentPush(_ envelope: PushEnvelope) -> Bool {
        guard let scope = t3PushScope else { return false }
        return t3Push.shouldPresent(envelope, scope: scope,
                                    visible: chats.visibleChatIdentity.map(PushDestination.init))
    }
    private(set) var notificationNavigationRevision = UUID()
    /// The mounted scene retains the receipt that lets an accepted tap dismiss its cover.
    @MainActor final class NotificationPresentation {
        fileprivate let present: @MainActor () -> Void
        fileprivate init(present: @escaping @MainActor () -> Void) { self.present = present }
    }
    @ObservationIgnored private weak var notificationPresentation: NotificationPresentation?
    /// Dismiss the root cover in the same actor turn that commits the notification destination.
    func bindNotificationPresentation(_ present: @escaping @MainActor () -> Void) -> NotificationPresentation {
        let presentation = NotificationPresentation(present: present)
        notificationPresentation = presentation
        return presentation
    }
    /// An authenticated tap outlives connection and workspace lifetimes; its workspace claim does not.
    private struct PendingPushNavigation {
        var intent: PushNavigationIntent
        var claim: NavigationClaim?
        var supersededOpening: Bool
    }
    @ObservationIgnored private var pendingPushNotification: PendingPushNavigation?
    private var t3NotificationLaunchScope: T3PushScope?
    var t3NotificationOwnsLaunch: Bool {
        t3NotificationLaunchScope.map { $0 == t3PushScope } ?? false
    }
    @ObservationIgnored private var notificationRouting: UUID?
    /// A tap attached nothing after superseding the selected bot's opening.
    private var openingInterrupted = false
    private(set) var library: WorkspaceLibrary
    private(set) var cacheLoadFailed = false
    @ObservationIgnored private var protectedCaches: Set<UUID> = []
    var history: LocalHistory {
        .init(bots: cachedBots, book: chats.persisted(), pinned: pinned, unpinned: unpinned,
              t3Channels: configuration?.t3 == nil ? nil : t3Channels)
    }
    private(set) var isDemo = false
    var isRefreshing: Bool { botRefresh != nil }
    var openingID: String? {
        guard let selectedBotID, chatSelection(for: selectedBotID)?.isOpening == true else { return nil }
        return selectedBotID
    }
    var uploading: Set<String> { chats.uploadingProfiles }
    @ObservationIgnored private var selectedBotStorage: String?
    @ObservationIgnored private var selectionRevision = UUID()
    var selectedBotID: String? {
        get { access(keyPath: \.selectedBotID); return selectedBotStorage }
        set {
            pendingPushNotification = nil
            selectBotID(newValue)
        }
    }
    private enum SelectionPresentation {
        case retire, preserveNavigation(NavigationClaim), attachmentCommit
    }
    @discardableResult private func selectBotID(_ value: String?, presentation: SelectionPresentation = .retire,
                                               while isCurrent: () -> Bool = { true }) -> Bool {
        guard isCurrent() else { return false }
        // Every write supersedes older ones, including a write that leaves the bytes unchanged.
        let attempt = UUID(); selectionRevision = attempt
        guard selectedBotStorage.map({ Data($0.utf8) }) != value.map({ Data($0.utf8) }) else { return true }
        return withMutation(keyPath: \.selectedBotID) {
            // Observation can synchronously replace navigation or recover the connection.
            guard selectionRevision == attempt, isCurrent() else { return false }
            let workspace = chats
            selectedBotStorage = value
            retireArtifactPresentation()
            guard selectionRevision == attempt, isCurrent() else { return false }
            switch presentation {
            case .retire: workspace.retirePresentation()
            case .preserveNavigation(let claim): workspace.retirePresentation(preserving: claim)
            case .attachmentCommit: break
            }
            return selectionRevision == attempt && isCurrent()
        }
    }
    /// Also captured by rendered rows to reject a tap queued before retirement.
    private(set) var artifactGeneration = UUID()
    private var artifactPresentationEpoch = UUID()
    private var artifactPresentationKey: ArtifactPresentationKey?
    private var generalNotice: String?
    private var historySaveFailure: LocalHistory.SaveFailure?
    var notice: String? {
        get { generalNotice ?? historySaveFailure?.errorDescription }
        set {
            generalNotice = newValue
            if newValue == nil { historySaveFailure = nil }
        }
    }
    var connectionError: String? { connection.errorMessage }
    var pendingConnectionInput: String? {
        didSet { if pendingConnectionInput != nil { acceptConnectionChoice() } }
    }
    var showsConnection = false {
        didSet {
            if showsConnection && !oldValue {
                acceptConnectionChoice()
                retireArtifactPresentation(); chats.retirePresentation()
            }
            else if !showsConnection && oldValue { reconcileArtifactPresentation() }
        }
    }

    /// Names the connection sheet an attempt may close: reopening it is a newer choice.
    @ObservationIgnored private var connectionChoice = UUID()
    private func acceptConnectionChoice() {
        connectionChoice = UUID()
        retireHeldNotification()
    }

    @ObservationIgnored private var service: any BotService
    @ObservationIgnored private var liveService: any BotService
    @ObservationIgnored private let injectedService: (any BotService)?
    @ObservationIgnored private let makeService: (ConnectionConfiguration?) -> any BotService
    private final class PendingService {
        let id = UUID()
        let service: any BotService
        var configuration: ConnectionConfiguration

        init(service: any BotService, configuration: ConnectionConfiguration) {
            self.service = service
            self.configuration = configuration
        }
    }
    private var pendingService: PendingService?
    @ObservationIgnored private var demoConnectionID: UUID?
    @ObservationIgnored private let artifactCache: ArtifactCache
    private var mountedArtifactScope: ArtifactCacheScope?
    @ObservationIgnored private let persistence: ConnectionPersistence
    @ObservationIgnored private let cleanupHistory: (UUID?) throws -> Void
    @ObservationIgnored private var richReplies: RichReplyPresentations?
    private var generation: UUID { connection.generation }
    private var avatarWorkspaceGeneration = UUID()
    private var attachmentRecoveryGeneration: UUID { connection.recoveryGeneration }
    private(set) var hasStarted = false
    @ObservationIgnored private var active = true
    @ObservationIgnored private var cacheTask: Task<Void, Never>?
    private var botRefresh: BotRefresh?
    @ObservationIgnored private var botInvalidationRefresh: BotInvalidationRefresh?
    @ObservationIgnored private let waitForBotInvalidationInterval: @MainActor () async throws -> Void
    private let avatars: BotAvatarStore
    @ObservationIgnored private var avatarSaves: [String: UUID] = [:]

    init(service: (any BotService)? = nil, persistence: ConnectionPersistence? = nil,
         t3Push: T3PushCoordinator? = nil,
         cleanupHistory: ((UUID?) throws -> Void)? = nil, artifactCache: ArtifactCache? = nil, avatarNow: @escaping () -> Date = Date.init,
         waitForBotInvalidationInterval: @escaping @MainActor () async throws -> Void = {
             try await Task.sleep(for: .seconds(5))
         }, makeService: @escaping @MainActor (ConnectionConfiguration?) -> any BotService = {
             _ in T3BotService()
         }) {
        let liveService = service ?? makeService(nil)
        self.artifactCache = artifactCache ?? (persistence == nil ? .shared : ArtifactCache(root: nil))
        self.injectedService = service
        self.makeService = makeService
        self.liveService = liveService
        self.service = liveService
        self.library = WorkspaceLibrary(service: liveService)
        self.chats = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: .init(), service: liveService, onDirty: {})
        self.persistence = persistence ?? .keychain
        self.waitForBotInvalidationInterval = waitForBotInvalidationInterval
        self.t3Push = t3Push ?? (persistence == nil ? T3PushCoordinator() : T3PushCoordinator(load: { [] }, save: { _ in }))
        self.avatars = BotAvatarStore(now: avatarNow)
        // Injected vaults need not own the app's one production cache directory.
        self.cleanupHistory = cleanupHistory ?? (persistence == nil ? { try LocalHistory.removeUnreachable(keeping: $0) } : { _ in })
        if loadSavedSetup(), configuration != nil { connection.awaitStartup() }
    }

    @discardableResult private func loadSavedSetup() -> Bool {
        do {
            let saved = try persistence.load()
            savedSetupLoadFailed = false
            configuration = saved.flatMap { $0.t3 != nil || injectedService != nil ? $0 : nil }
            // Leave older setup and cache alone until the user successfully pairs a Mac.
            if saved != nil, configuration == nil {
                connection.restore(hasSavedSetup: false)
                return true
            }
        }
        catch {
            savedSetupLoadFailed = true; connection.savedSetupFailed(error)
            return false
        }
        liveService = injectedService ?? makeService(configuration)
        service = liveService
        artifactCache.prune(reachableConfigurationIDs: Set(configuration.map { [$0.id] } ?? []))
        connection.restore(hasSavedSetup: configuration != nil)
        var loaded = LocalHistory()
        cacheLoadFailed = false
        if let configuration {
            do { loaded = try LocalHistory.load(for: configuration.id) }
            catch {
                cacheLoadFailed = true; protectedCaches.insert(configuration.id)
                notice = error.localizedDescription + " Your saved connection is still available; cache saving is paused."
            }
        }
        mount(loaded, configuration: configuration)
        if !cacheLoadFailed { cleanHistory(keeping: configuration?.id) }
        return true
    }

    private nonisolated static func backendAccount(_ configuration: ConnectionConfiguration) -> [Data?] {
        guard let t3 = configuration.t3 else { return [] }
        return [Data("t3".utf8), Data(t3.environmentID.utf8), t3.projectID.map { Data($0.utf8) }]
    }

    static func artifactScope(_ configuration: ConnectionConfiguration) -> ArtifactCacheScope {
        .init(configurationID: configuration.id, serverURL: Data(configuration.serverURL.absoluteString.utf8),
            installationID: configuration.installID.map { Data($0.utf8) }, username: Data(configuration.username.utf8),
            provider: configuration.nativeCredential.map { Data($0.provider.utf8) },
            backend: configuration.t3.map { _ in backendAccount(configuration) })
    }

    private func mount(_ history: LocalHistory, configuration: ConnectionConfiguration?) {
        historySaveFailure = nil
        t3Models = []
        t3ModelsGeneration = nil
        t3ComposerRequest = nil
        chats.retireWorkspace()
        library.retire()
        mountedArtifactScope = isDemo ? nil : configuration.map(Self.artifactScope)
        let cache = mountedArtifactScope.map { artifactCache.session(scope: $0) }
        library = WorkspaceLibrary(service: service, cache: cache)
        library.seed(book: history.book, bots: history.bots)
        library.setOnline(isConnected)
        Task { [library] in await library.restore() }
        cachedBots = history.bots; pinned = history.pinned; unpinned = history.unpinned
        t3Channels = history.t3Channels ?? []
        let scope = WorkspaceScope(cacheID: configuration?.id ?? UUID(),
            exactAccount: configuration.map(Self.richReplyAccount) ?? [], incarnation: UUID())
        chats = ConversationWorkspace(scope: scope, book: history.book, service: service,
            onDirty: { [weak self] in self?.reconcileArtifactPresentation(); self?.scheduleSave() })
        chats.onAcceptedTranscript = { [weak self, weak library] publication in
            guard let self, let library, library === self.library else { return }
            library.accept(publication)
            library.reconcileOriginalConsumers()
        }
        library.onDisputesResolved = { [weak chats] in chats?.resolveDisputes($0, on: $1) }
        chats.onPresentationChange = { [weak self] in self?.retireArtifactDownloads() }
        chats.onUserNavigation = { [weak self] in self?.pendingPushNotification = nil }
        var chatWasVisible = false
        chats.onVisibleChatChange = { identity in
            // Repeated hidden publications must not cancel feedback in a covering sheet.
            if chatWasVisible, identity == nil { BottoHaptics.shared.cancel() }
            chatWasVisible = identity != nil
        }
        chats.onHapticFeedback = { BottoHaptics.shared.play($0.event) }
        chats.observeProfiles(cachedBots)
        reconcileArtifactPresentation()
    }

    @discardableResult func retrySavedSetup() -> Bool {
        guard configuration == nil, !isDemo else { return false }
        return loadSavedSetup()
    }

    private func cleanHistory(keeping id: UUID?) {
        guard protectedCaches.isEmpty else { return }
        do { try cleanupHistory(id) }
        catch { notice = "Some old cached history couldn’t be removed. Try again after unlocking your device." }
    }

    var inbox: [InboxEntry] {
        let aggregates = chats.aggregates(profiles: cachedBots.compactMap { try? ExactID($0.id) })
        return cachedBots.map { bot in
            inboxEntry(bot, aggregate: (try? ExactID(bot.id)).flatMap { aggregates[$0] })
        }.sorted {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            if $0.bot.updatedAt != $1.bot.updatedAt { return ($0.bot.updatedAt ?? .distantPast) > ($1.bot.updatedAt ?? .distantPast) }
            return $0.bot.name.localizedStandardCompare($1.bot.name) == .orderedAscending
        }
    }
    var bots: [BotProfile] { inbox.map(\.bot) }
    func bot(withID id: String) -> BotProfile? {
        let bytes = Data(id.utf8)
        return cachedBots.first { Data($0.id.utf8) == bytes }.map { bot in
            inboxEntry(bot, aggregate: (try? ExactID(bot.id)).map { chats.aggregate(profile: $0) }).bot
        }
    }
    private func inboxEntry(_ bot: BotProfile, aggregate: ChatAggregate?) -> InboxEntry {
        var copy = bot
        if let aggregate { copy.status = aggregate.status ?? .idle }
        copy.preview = aggregate?.preview?.text ?? ""
        if let preview = aggregate?.preview { copy.updatedAt = preview.timestamp }
        return .init(bot: copy, aggregate: aggregate)
    }
    var selectedBot: BotProfile? {
        guard let selectedBotID else { return nil }
        let identity = Data(selectedBotID.utf8)
        return cachedBots.first { Data($0.id.utf8) == identity }
    }
    var isConnected: Bool { link == .online }
    /// View-owned operations must also belong to the current connection lifetime.
    var connectionGeneration: UUID { generation }
    var serverName: String {
        if isDemo { return "Demo workspace" }
        return configuration?.t3?.label ?? configuration?.serverURL.host ?? "Your Mac"
    }

    private var t3BrainService: (any T3BotBrainControlling)? { service as? any T3BotBrainControlling }
    var primaryT3Bot: BotProfile? { cachedBots.first }

    var selectedT3ChannelTitle: String? {
        guard let selectedBotID, let identity = chatSelection(for: selectedBotID)?.identity else { return nil }
        return t3Channels.first { Data($0.id.utf8) == identity.stored.bytes }?.displayTitle
            ?? chatScreen(for: selectedBotID)?.title
    }

    /// The space on screen, as the spaces list knows it.
    var selectedT3Channel: T3ChannelSummary? {
        guard let id = selectedT3ChannelID else { return nil }
        return t3Channels.first { $0.id == id }
    }

    /// Models the host offers, kept for the composer's model chip once loaded in this connection.
    private(set) var t3Models: [T3ModelOption] = []
    @ObservationIgnored private var t3ModelsGeneration: UUID?

    func loadT3ModelsIfNeeded() async {
        guard isConnected, t3ModelsGeneration != generation else { return }
        let owner = generation
        guard let models = try? await availableT3Models(), generation == owner else { return }
        t3Models = models
        t3ModelsGeneration = owner
    }

    /// A display name for a space's model; falls back to the host's model ID.
    func t3ModelLabel(provider: String?, model: String?) -> String? {
        guard let model else { return nil }
        return t3Models.first { $0.modelID == model && (provider == nil || $0.providerInstanceID == provider) }?.label ?? model
    }

    /// One-shot request from the new-space page for the next space's composer to open an attachment picker.
    struct T3ComposerRequest: Equatable {
        enum Kind: Equatable { case photos, files }
        let kind: Kind
        let owner: PresentationOwner
    }
    var t3ComposerRequest: T3ComposerRequest?

    @discardableResult func openT3Channel(_ channel: T3ChannelSummary) async -> Bool {
        await openT3Channel(channel, authority: nil)
    }

    private func openT3Channel(_ channel: T3ChannelSummary, authority savedAuthority: BotNavigationAuthority?) async -> Bool {
        guard !Task.isCancelled, let bot = primaryT3Bot, let profile = try? ExactID(bot.id), let thread = try? ExactID(channel.id),
              let current = t3Channels.first(where: { Data($0.id.utf8) == thread.bytes }),
              let authority = savedAuthority ?? captureBotAuthority(),
              ownsBotNavigation(authority),
              selectBotID(bot.id, presentation: .preserveNavigation(authority.claim), while: {
                  ownsBotNavigation(authority)
              }), ownsBotNavigation(authority) else { return false }
        let identity = SessionIdentity(profile: profile, root: thread, stored: thread, aliases: [])
        let summary = SessionSummary(identity: identity, title: current.displayTitle, isCanonical: false, persistence: .durable,
                                     preview: current.preview.isEmpty ? nil : current.preview, updatedAt: current.updatedAt)
        let opened = await authority.workspace.openStoredChat(summary, claim: authority.claim)
        if opened, isCurrentLifetime(authority) { publishT3Channels() }
        return opened
    }

    /// A space without a title is named by T3 from its first message.
    func createT3Space(title: String? = nil) async throws -> CreatedSession {
        try await withT3Service { try await $0.createChat(title: title) }
    }

    /// The new-space page: a space the user named, or one T3 names from the first message, opened and then sent.
    /// Report the creation before opening so the user can find an interrupted start in Spaces.
    /// Once open, a failed send keeps the text in that Space's own draft.
    @discardableResult func startT3Space(named name: String = "", with text: String, model: T3ModelOption? = nil,
                                         send: Bool = true,
                                         onCreated: @MainActor (SessionIdentity) -> Void = { _ in }) async throws -> SessionIdentity {
        try Task.checkCancellation()
        guard isConnected, let authority = captureBotAuthority() else { throw T3ServiceError.disconnected }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = try await createT3Space(title: title.isEmpty ? nil : title).summary.identity
        onCreated(identity)
        let threadID = identity.stored.text
        guard ownsBotNavigation(authority) else { throw ConversationServiceError.staleConversation }
        guard primaryT3Bot.map({ Data($0.id.utf8) }) == identity.profile.bytes,
              let channel = t3Channels.first(where: { Data($0.id.utf8) == identity.stored.bytes }) else {
            throw T3ServiceError.missingChannel
        }
        if let model {
            try await setT3ChannelModel(threadID: threadID, providerInstanceID: model.providerInstanceID, model: model.modelID)
        }
        guard await openT3Channel(channel, authority: authority) else {
            throw T3ServiceError.missingChannel
        }
        let workspace = authority.workspace
        guard !Task.isCancelled, isCurrentConnection(authority),
              let selection = workspace.selection(profile: identity.profile), selection.matches(identity),
              workspace.canEditDraft(selection.owner) else { throw ConversationServiceError.staleConversation }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return identity }
        workspace.editDraft(text, owner: selection.owner)
        if send, let intent = workspace.captureSend(selection.owner) { await workspace.send(intent) }
        return identity
    }

    func renameT3Channel(threadID: String, title: String) async throws {
        try await withT3Service { try await $0.renameChannel(threadID: threadID, title: title) }
    }

    func setT3ChannelPinned(threadID: String, pinned: Bool) async throws {
        try await withT3Service { try await $0.setChannelPinned(threadID: threadID, pinned: pinned) }
    }

    func archiveT3Channel(threadID: String, archived: Bool) async throws {
        try await withT3Service { try await $0.archiveChannel(threadID: threadID, archived: archived) }
    }

    func loadT3BotBrain() async throws -> T3BotBrainSnapshot {
        try await withT3Service { try await $0.loadBotBrain() }
    }

    func saveT3Soul(_ markdown: String, replacing expected: String) async throws {
        try await withT3Service { try await $0.saveSoul(markdown, replacing: expected) }
    }

    func saveT3Memory(_ markdown: String, replacing expected: String) async throws {
        try await withT3Service { try await $0.saveMemory(markdown, replacing: expected) }
    }

    func saveT3Manifest(_ manifest: T3BotManifest) async throws {
        try await withT3Service { try await $0.saveManifest(manifest) }
        _ = await refreshBots()
    }

    /// Renames Botto on the host; the service reads the saved profile first, so other edits survive.
    func renameT3Bot(_ name: String) async throws {
        guard let bot = primaryT3Bot else { throw T3ServiceError.disconnected }
        _ = try await withT3Service { try await $0.updateProfile(BotProfileEdit(name: name), for: bot) }
        _ = await refreshBots()
    }

    /// The bot still waits for someone to name it and pick its face. Setup that stopped partway counts, so it can
    /// be tried again.
    var needsT3BotSetup: Bool {
        guard !isDemo, let bot = primaryT3Bot else { return false }
        return settingUpT3Bot == configuration?.id || T3FirstRun.needsBotSetup(bot, spaces: t3Channels)
    }
    /// The workspace whose setup started and hasn't finished.
    private var settingUpT3Bot: UUID?

    /// The first-run page: names the bot and its main space and keeps the face.
    func setUpT3Bot(name: String, face: BotFace) async throws {
        settingUpT3Bot = configuration?.id
        try await withT3Service { try await $0.setUpBot(name: name, face: face) }
        _ = await refreshBots()
        settingUpT3Bot = nil
    }

    /// The model new chats start with; nil lets the host choose.
    @discardableResult func setT3DefaultModel(_ option: T3ModelOption?) async throws -> T3BotManifest {
        let manifest = try await withT3Service { try await $0.setDefaultModel(option) }
        _ = await refreshBots()
        return manifest
    }

    func availableT3Models() async throws -> [T3ModelOption] {
        try await withT3Service { try await $0.availableModels() }
    }

    func readT3ProjectFile(relativePath: String) async throws -> String {
        try await withT3Service { try await $0.readProjectFile(relativePath: relativePath) }
    }

    /// The stored thread of the channel shown in the selected T3 chat.
    var selectedT3ChannelID: String? {
        guard let selectedBotID, let identity = chatSelection(for: selectedBotID)?.identity else { return nil }
        return t3Channels.first { Data($0.id.utf8) == identity.stored.bytes }?.id
    }

    func listT3Outputs() async throws -> [T3OutputFile] {
        try await withT3Service { try await $0.listOutputs() }
    }

    func downloadT3Output(_ output: T3OutputFile) async throws -> DownloadedArtifact {
        try await withT3Service { try await $0.downloadOutput(output) }
    }

    func listT3Routines() async throws -> [T3ScheduledRoutine] {
        try await withT3Service { try await $0.listRoutines() }
    }

    func createT3Routine(name: String, prompt: String, cron: String, threadID: String?) async throws -> T3ScheduledRoutine {
        try await withT3Service { try await $0.createRoutine(name: name, prompt: prompt, cron: cron, threadID: threadID) }
    }

    func setT3RoutineEnabled(id: String, enabled: Bool) async throws {
        try await withT3Service { try await $0.setRoutineEnabled(id: id, enabled: enabled) }
    }

    func deleteT3Routine(id: String) async throws {
        try await withT3Service { try await $0.deleteRoutine(id: id) }
    }

    func setT3ChannelModel(threadID: String, providerInstanceID: String, model: String) async throws {
        try await withT3Service {
            try await $0.setChannelModel(threadID: threadID, providerInstanceID: providerInstanceID, model: model)
        }
    }

    func markT3ChannelVisited(threadID: String) async throws {
        try await withT3Service { try await $0.markChannelVisited(threadID: threadID) }
    }

    private func withT3Service<Value>(_ action: @MainActor (any T3BotBrainControlling) async throws -> Value) async throws -> Value {
        guard let service = t3BrainService else { throw T3ServiceError.unsupported }
        guard active, isConnected, !showsConnection else { throw T3ServiceError.disconnected }
        let owner = generation, recovery = attachmentRecoveryGeneration
        try Task.checkCancellation()
        let result = try await action(service)
        try Task.checkCancellation()
        guard active, isConnected, generation == owner, attachmentRecoveryGeneration == recovery, !showsConnection else {
            throw T3ServiceError.disconnected
        }
        publishT3Channels()
        return result
    }

    private func publishT3Channels() {
        guard isConnected, let service = t3BrainService else { return }
        let priorPreviews = Dictionary(uniqueKeysWithValues: t3Channels.compactMap { channel -> (String, String)? in
            channel.preview.isEmpty ? nil : (channel.id, channel.preview)
        })
        let channels = service.currentT3Channels.map { channel -> T3ChannelSummary in
            guard channel.preview.isEmpty, let cached = priorPreviews[channel.id] else { return channel }
            return channel.replacingPreview(cached)
        }
        guard channels != t3Channels else { return }
        t3Channels = channels
        scheduleSave()
    }

    func avatar(for bot: BotProfile) -> UIImage? { avatars.image(for: bot) }
    func isLoadingAvatar(for bot: BotProfile) -> Bool { avatars.isLoading(bot) }
    func hasSavedAvatarImage(for bot: BotProfile) -> Bool {
        bot.hasAvatar == true && !avatars.isStaticPreview(for: bot)
    }

    func avatarDestination(for bot: BotProfile) -> AvatarDestination? {
        guard let configuration, let current = cachedBots.first(where: { $0.id == bot.id }) else { return nil }
        return AvatarDestination(profile: current, workspaceGeneration: avatarWorkspaceGeneration,
                                 configurationID: configuration.id,
                                 account: AvatarDestination.account(for: configuration),
                                 installID: configuration.installID.map { Data($0.utf8) }, demo: isDemo)
    }

    func generateAvatar(description: String, for destination: AvatarDestination) async throws -> BotAvatarGeometry {
        let owner = generation, recovery = attachmentRecoveryGeneration
        try validateAvatarDestination(destination, connection: owner, recovery: recovery)
        let geometry = try await service.generateAvatar(description: description, for: destination.profile)
        try validateAvatarDestination(destination, connection: owner, recovery: recovery)
        return geometry
    }

    func saveAvatar(_ choice: BotAvatarChoice, to destination: AvatarDestination) async throws {
        let owner = generation, recovery = attachmentRecoveryGeneration
        try validateAvatarDestination(destination, connection: owner, recovery: recovery)
        let id = destination.profile.id
        guard avatarSaves[id] == nil else { throw ConversationServiceError.avatarConflict }
        let attempt = UUID()
        avatarSaves[id] = attempt
        defer { if avatarSaves[id] == attempt { avatarSaves[id] = nil } }
        // The service revalidates the original avatar metadata before making one mutation.
        _ = try await service.setAvatar(choice, for: destination.profile)
        try validateAvatarDestination(destination, connection: owner, recovery: recovery)
        // Use the existing publication fence: an older inbox read cannot erase a saved face.
        let published = await refreshBots()
        try validateAvatarDestination(destination, connection: owner, recovery: recovery)
        guard published else { throw ConversationServiceError.avatarRefresh }
        if let id = configuration?.id {
            avatars.refresh(cachedBots, connectionID: id, using: service, revalidate: [destination.profile.id])
        }
    }

    func reloadAvatar(_ destination: AvatarDestination) async throws -> AvatarDestination {
        let owner = generation, recovery = attachmentRecoveryGeneration
        try validateAvatarDestination(destination, connection: owner, recovery: recovery)
        let published = await refreshBots()
        try validateAvatarDestination(destination, connection: owner, recovery: recovery)
        guard published, let bot = cachedBots.first(where: { $0.id == destination.profile.id }),
              let updated = avatarDestination(for: bot) else { throw ConversationServiceError.avatarReload }
        if let id = configuration?.id {
            avatars.refresh(cachedBots, connectionID: id, using: service, revalidate: [bot.id])
        }
        return updated
    }

    private func validateAvatarDestination(_ destination: AvatarDestination, connection: UUID, recovery: UUID) throws {
        guard isConnected, !Task.isCancelled, generation == connection,
              attachmentRecoveryGeneration == recovery,
              destination.isCurrent(in: self) else { throw ConversationServiceError.disconnected }
    }

    private func retireAvatarWorkspace(ifReplacingWith next: ConnectionConfiguration?) {
        // Credential rotation and first-time installation discovery keep local drafts.
        // Once revoked, a destination cannot return when the same setup is added again.
        guard let current = configuration, let next,
              current.id == next.id,
              AvatarDestination.account(for: current) == AvatarDestination.account(for: next),
              current.installID == nil || current.installID.map({ Data($0.utf8) }) == next.installID.map({ Data($0.utf8) }) else {
            avatarWorkspaceGeneration = UUID()
            return
        }
    }

    private func chatScreen(for botID: String) -> ChatScreen? {
        guard let profile = try? ExactID(botID) else { return nil }
        return chats.screen(profile: profile)
    }
    private func chatSelection(for botID: String) -> ChatSelection? {
        guard let profile = try? ExactID(botID) else { return nil }
        return chats.selection(profile: profile)
    }
    func conversation(for botID: String) -> Conversation? { chatSelection(for: botID)?.snapshot }
    func draft(for botID: String) -> String {
        guard let profile = try? ExactID(botID) else { return "" }
        return chats.openingDraft(profile: profile)
    }
    func attachments(for botID: String) -> [ChatAttachment] { chatScreen(for: botID)?.attachments ?? [] }
    func isPinned(_ bot: BotProfile) -> Bool {
        guard let id = try? ExactID(bot.id) else { return bot.isPinned }
        return !unpinned.contains(id) && (bot.isPinned || pinned.contains(id))
    }
    func togglePin(_ bot: BotProfile) {
        guard let id = try? ExactID(bot.id) else { return }
        if isPinned(bot) { pinned.remove(id); unpinned.insert(id) }
        else { unpinned.remove(id); pinned.insert(id) }
        scheduleSave()
    }
    func isUnread(_ bot: BotProfile) -> Bool {
        guard let profile = try? ExactID(bot.id) else { return false }
        return chats.aggregate(profile: profile).selectedChatIsUnread
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--demo") {
            await enterDemo()
            if arguments.contains("--demo-offline") {
                for channel in t3Channels where !channel.isMain { await openT3Channel(channel) }
                if let main = t3Channels.first(where: \.isMain) { await openT3Channel(main) }
                receive(.disconnected("The sample workspace is offline."))
            }
            return
        }
        #endif
        if let configuration { await connect(configuration) }
        else { await t3Push.resume(scope: nil) }
    }

    @discardableResult func connect(_ candidate: ConnectionConfiguration,
                                   onConnected: (@MainActor () -> Void)? = nil,
                                   onFailure: (@MainActor (any Error) -> Void)? = nil) async -> Bool {
        guard candidate.t3 != nil || injectedService != nil else { return false }
        if isDemo, candidate.id != demoConnectionID { leaveDemo() }
        guard isDemo || !savedSetupLoadFailed else { return false }
        let closesConnection = showsConnection ? connectionChoice : nil
        discardPendingService()
        let staged: PendingService?
        let owner: UUID
        let connectingService: any BotService
        // A reconnect to the saved workspace keeps its drafts and staged-file warnings.
        // Unresolved T3 pairing needs a staged service until it establishes its workspace.
        let boundWorkspace = candidate.t3.map {
            !$0.environmentID.isEmpty && $0.projectID?.isEmpty == false && $0.workspaceRoot?.isEmpty == false
        } ?? true
        let reconnectsSaved = candidate == configuration && boundWorkspace
        if injectedService == nil, !isDemo, !reconnectsSaved {
            let attempt = PendingService(service: makeService(candidate), configuration: candidate)
            pendingService = attempt
            staged = attempt
            owner = attempt.id
            connectingService = attempt.service
            connectingService.onEvent = { [weak self, weak attempt] event in
                guard let attempt, self?.pendingService === attempt else { return }
                if case .configuration(let updated) = event, updated.id == candidate.id {
                    attempt.configuration = updated
                }
            }
        } else {
            staged = nil
            owner = connection.begin(candidate)
            connectingService = service
            prepareServiceTransition(to: candidate)
            bindServiceEvents(owner: owner)
        }
        do {
            let info = try await withTaskCancellationHandler {
                try await connectingService.connect(configuration: candidate)
            } onCancel: {
                Task { @MainActor [weak self] in self?.cancelConnection(owner: owner) }
            }
            guard ownsConnectionAttempt(owner) else { return false }
            if Task.isCancelled { cancelConnection(owner: owner); return false }
            var saved = staged?.configuration ?? connection.candidate ?? candidate
            saved.installID = info.installID ?? saved.installID
            let previousID = configuration?.id
            let changedBackendAccount = configuration.map(Self.backendAccount) != Self.backendAccount(saved)
            let changedCache = previousID != saved.id || changedBackendAccount
            let preservesHistory = changedCache && canPreserveHistory(for: saved, confirmedBy: info)
            let replacementHistory: LocalHistory
            if preservesHistory {
                guard !cacheLoadFailed else { throw HistoryFailure.corrupt }
                replacementHistory = history.readOnly
            } else if previousID == saved.id, changedBackendAccount {
                guard !cacheLoadFailed else { throw HistoryFailure.corrupt }
                replacementHistory = .init()
            } else if previousID == saved.id { replacementHistory = history.readOnly }
            else { replacementHistory = try LocalHistory.load(for: saved.id) }
            if !isDemo {
                // A failed vault read cannot authorize overwriting setup or pruning caches.
                _ = try persistence.load()
                var replacement: LocalHistory.CacheReplacement?
                if changedCache {
                    if let previousID, previousID != saved.id, !protectedCaches.contains(previousID) {
                        try history.save(for: previousID)
                    }
                    replacement = try replacementHistory.prepareReplacement(for: saved.id)
                }
                do { try persistence.save(saved) }
                catch {
                    do { try replacement?.rollback() }
                    catch { notice = "Your previous setup is safe, but a temporary history cache couldn’t be removed." }
                    throw error
                }
            }
            let connectedOwner: UUID
            if let staged {
                pendingService = nil
                connectedOwner = connection.begin(saved)
                prepareServiceTransition(to: saved)
                service.onEvent = nil
                liveService = staged.service
                service = liveService
                bindServiceEvents(owner: connectedOwner)
            } else {
                connectedOwner = owner
            }
            let sameWorkspace = !changedCache && mountedArtifactScope == (isDemo ? nil : Self.artifactScope(saved))
            if staged != nil || !sameWorkspace { mount(replacementHistory, configuration: saved) }
            if changedCache { selectedBotID = nil; cacheLoadFailed = false }
            retireAvatarWorkspace(ifReplacingWith: saved)
            configuration = saved
            guard connection.complete(connectedOwner, info: info) else { return false }
            publishT3Channels()
            chats.setOnline(true)
            reconcileArtifactPresentation()
            if !isDemo {
                if let previousID, previousID != saved.id, !protectedCaches.contains(previousID) { LocalHistory.remove(for: previousID) }
                cleanHistory(keeping: saved.id)
            }
            let workspace = chats
            let restoration = selectedBot.flatMap { bot in
                (try? ExactID(bot.id)).flatMap { workspace.captureOpening(profile: $0) }
            }
            await refresh()
            guard generation == connectedOwner else { return false }
            if !isDemo {
                Task { [weak self] in
                    guard let self, self.generation == connectedOwner else { return }
                    await self.t3Push.resume(scope: self.t3PushScope)
                }
            }
            onConnected?()
            if connectionChoice == closesConnection { showsConnection = false }
            if let restoration, workspace === chats {
                await workspace.restoreAttachment(restoration)
                settleInterruptedOpening()
            }
            return true
        } catch {
            guard ownsConnectionAttempt(owner) else { return false }
            let cancelled = error is CancellationError || Task.isCancelled
            if !cancelled { onFailure?(error) }
            cancelConnection(owner: owner, failure: error)
            if !cancelled, !isConnected,
               candidate.id == configuration?.id, pendingPushNotification != nil {
                notice = notice ?? Self.t3PushReconnectNotice
            }
            return false
        }
    }

    private func prepareServiceTransition(to candidate: ConnectionConfiguration) {
        if candidate.id != configuration?.id || configuration.map(Self.richReplyAccount) != Self.richReplyAccount(candidate) {
            pendingPushNotification = nil
            t3NotificationLaunchScope = nil
            retireArtifactPresentation()
        }
        avatars.reset()
        service.disconnect()
        chats.retireConnection()
        cacheTask?.cancel()
        retireRefresh()
    }

    private func bindServiceEvents(owner: UUID) {
        service.onEvent = { [weak self] event in
            guard let self, self.generation == owner else { return }
            self.receive(event)
        }
    }

    private func ownsConnectionAttempt(_ owner: UUID) -> Bool {
        pendingService?.id == owner || connection.ownsAttempt(owner)
    }

    private func discardPendingService() {
        guard let pending = pendingService else { return }
        pendingService = nil
        pending.service.onEvent = nil
        pending.service.disconnect()
    }

    private func canPreserveHistory(for candidate: ConnectionConfiguration, confirmedBy info: ServerInfo) -> Bool {
        guard !isDemo, let previous = configuration, previous.t3 != nil,
              Self.backendAccount(previous) == Self.backendAccount(candidate),
              let installID = info.installID, !installID.isEmpty, previous.installID == installID,
              let oldOrigin = try? PairingAddress.parse(previous.serverURL.absoluteString, allowInsecureHTTP: true),
              let newOrigin = try? PairingAddress.parse(candidate.serverURL.absoluteString, allowInsecureHTTP: true),
              oldOrigin.scheme == newOrigin.scheme, oldOrigin.host == newOrigin.host,
              (oldOrigin.port ?? (oldOrigin.scheme == "https" ? 443 : 80))
                == (newOrigin.port ?? (newOrigin.scheme == "https" ? 443 : 80)),
              let paired = previous.t3, let verified = candidate.t3,
              paired.environmentID == installID, verified.environmentID == installID,
              let project = paired.projectID, !project.isEmpty,
              let oldRoot = paired.workspaceRoot, !oldRoot.isEmpty, let newRoot = verified.workspaceRoot else { return false }
        return oldRoot.utf8.elementsEqual(newRoot.utf8)
    }

    private func cancelConnection(owner: UUID, failure: (any Error)? = nil) {
        if pendingService?.id == owner {
            discardPendingService()
            if connection.isSuspended { connection.restore(hasSavedSetup: configuration != nil) }
            if let failure { connection.savedSetupFailed(failure) }
            return
        }
        guard connection.cancel(owner, hasSavedSetup: configuration != nil, failure: failure) else { return }
        service.disconnect()
        chats.retireConnection(); retireRefresh()
    }

    func refresh(revalidateAvatars: Bool = false) async {
        let owner = generation, recovery = attachmentRecoveryGeneration
        guard await refreshBots(), generation == owner, !Task.isCancelled, isConnected else { return }
        pendingPushNotification?.intent.recoveryRevision = UUID()
        await resumePushNavigation()
        guard revalidateAvatars, !Task.isCancelled, isConnected,
              generation == owner, attachmentRecoveryGeneration == recovery, let id = configuration?.id else { return }
        avatars.refresh(cachedBots, connectionID: id, using: service, revalidate: Set(cachedBots.map(\.id)))
    }

    private func refreshFromBotInvalidation() {
        guard active, isConnected, !showsConnection else { return }
        if let current = botInvalidationRefresh {
            current.pending = true
            return
        }
        let invalidation = BotInvalidationRefresh()
        let owner = generation, recovery = attachmentRecoveryGeneration
        botInvalidationRefresh = invalidation
        invalidation.task = Task { [weak self] in
            guard let self else { return }
            defer {
                if botInvalidationRefresh === invalidation { botInvalidationRefresh = nil }
            }
            repeat {
                guard !Task.isCancelled, botInvalidationRefresh === invalidation,
                      active, isConnected, !showsConnection,
                      generation == owner, attachmentRecoveryGeneration == recovery else { return }
                invalidation.pending = false
                await refresh()
                guard !Task.isCancelled, botInvalidationRefresh === invalidation,
                      generation == owner, attachmentRecoveryGeneration == recovery else { return }
                do { try await waitForBotInvalidationInterval() }
                catch { return }
            } while invalidation.pending
        }
    }

    func refreshLibraryIfNeeded() async {
        let library = library
        library.seed(book: chats.persisted(), bots: cachedBots)
        library.setOnline(isConnected)
        await library.refreshIfNeeded(evidence: .cached, bots: cachedBots)
    }

    func refreshLibrary(force: Bool = false) async {
        let library = library
        library.seed(book: chats.persisted(), bots: cachedBots)
        library.setOnline(isConnected)
        await library.refresh(evidence: .cached, bots: cachedBots, force: force)
    }

    @discardableResult func openLibraryChat(_ chat: LibraryChat,
        accepts: @MainActor (SessionIdentity, Conversation?) -> Bool = { _, _ in true }) async -> Bool {
        guard !Task.isCancelled, library.isCurrent(chat), bot(withID: chat.botID) != nil else { return false }
        let workspace = chats, sourceLibrary = library
        let connection = generation, recovery = attachmentRecoveryGeneration
        // The Library selection stays pending until commit. Any newer write supersedes it,
        // including one that leaves the selected bytes unchanged or writes nil.
        let selection = selectionRevision
        guard let intent = workspace.beginLibraryOpening(chat.identity), workspace === chats,
              generation == connection, attachmentRecoveryGeneration == recovery else { return false }
        let authority = BotNavigationAuthority(workspace: workspace, connection: connection, recovery: recovery, claim: intent.claim)
        let ownsLibrary: @MainActor () -> Bool = { [self] in
            !Task.isCancelled && sourceLibrary === library && !sourceLibrary.isRetired && sourceLibrary.isCurrent(chat)
        }
        let ownsSelection: @MainActor () -> Bool = { [self] in selectionRevision == selection && ownsLibrary() }
        let opened = await workspace.openLibraryChat(intent, isCurrent: ownsSelection, accepts: accepts) { [self] identity in
            identity.profile == chat.identity.profile && ownsSelection() &&
                commitAttachedSelection(chat.identity.profile, authority: authority, while: ownsLibrary)
        }
        return opened != nil
    }

    func openSearchMessage(_ target: SearchMessageTarget) async -> SearchMessageOpeningResult {
        let workspace = chats, sourceLibrary = library
        guard sourceLibrary.isCurrent(target.chat),
              let current = sourceLibrary.chats.first(where: { $0.id == target.chat.id }),
              TranscriptMessageIndex(.init(id: current.identity.root.text, storedID: current.identity.stored.text, profileID: current.botID,
                  messages: current.messages)).matches(target.message) else { return .unavailable }
        var rejected = false
        var attached: ChatMessage?
        let opened = await openLibraryChat(target.chat) { identity, snapshot in
            guard sourceLibrary.isCurrent(target.chat) else { rejected = true; return false }
            attached = target.resolve(identity: identity, snapshot: snapshot)
            rejected = attached == nil
            return attached != nil
        }
        guard !Task.isCancelled, workspace === chats, sourceLibrary === library else { return .superseded }
        guard opened else { return rejected ? .unavailable : .couldNotOpen }
        guard let attached, let selection = workspace.selection(profile: target.chat.identity.profile),
              workspace.isCurrent(selection.owner), let identity = selection.identity,
              SearchMessageTarget.sameSource(identity, target.chat.identity),
              TranscriptMessageIndex(selection.snapshot).matches(attached) else { return .unavailable }
        return .opened(.init(workspace: ObjectIdentifier(workspace), owner: selection.owner,
                             identity: identity, message: attached, query: target.query))
    }

    private func refreshBots() async -> Bool {
        guard isConnected, !Task.isCancelled else { return false }
        let waiterID = UUID(), owner = generation
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard isConnected, generation == owner, !Task.isCancelled else {
                    continuation.resume(returning: false); return
                }
                let refresh = botRefresh ?? BotRefresh()
                if botRefresh == nil { botRefresh = refresh }
                refresh.pending[waiterID] = continuation
                if refresh.task == nil {
                    refresh.task = Task { [weak self] in
                        await self?.runRefreshes(refresh, owner: owner)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelRefreshWaiter(waiterID)
            }
        }
    }

    private func cancelRefreshWaiter(_ waiterID: UUID) {
        let waiter = botRefresh?.active.removeValue(forKey: waiterID)
            ?? botRefresh?.pending.removeValue(forKey: waiterID)
        waiter?.resume(returning: false)
    }

    private func runRefreshes(_ refresh: BotRefresh, owner: UUID) async {
        let service = service
        while botRefresh === refresh, !refresh.pending.isEmpty {
            // Requests that arrive during this read belong to the next read.
            // Finish this batch at its publication, without waiting for future requests.
            refresh.active = refresh.pending
            refresh.pending = [:]
            var published = false
            do {
                let profiles = try await service.bots()
                guard generation == owner, botRefresh === refresh else { return }
                library.observeBots(profiles, evidence: .observed)
                cachedBots = profiles
                chats.observeProfiles(profiles)
                publishT3Channels()
                if let id = configuration?.id { avatars.refresh(profiles, connectionID: id, using: service) }
                await chats.refreshActivityDirectories(for: profiles)
                guard generation == owner, botRefresh === refresh else { return }
                chats.scheduleInboxHistory(for: profiles)
                scheduleSave()
                published = true
            } catch {
                guard generation == owner, botRefresh === refresh else { return }
                notice = error.localizedDescription
            }
            resumeRefreshWaiters(&refresh.active, published: published)
        }
        if botRefresh === refresh { botRefresh = nil }
    }

    private func resumeRefreshWaiters(_ waiters: inout [UUID: CheckedContinuation<Bool, Never>], published: Bool) {
        let current = waiters.values
        waiters = [:]
        for waiter in current { waiter.resume(returning: published) }
    }

    private func retireRefresh() {
        let invalidation = botInvalidationRefresh
        botInvalidationRefresh = nil
        invalidation?.task?.cancel()
        retireArtifactDownloads()
        avatarSaves = [:]
        avatars.cancel()
        guard let refresh = botRefresh else { return }
        // Recovery may retain the connection generation. Retire this read's identity
        // before cancellation so its late result cannot publish or clear a newer run.
        botRefresh = nil
        refresh.task?.cancel()
        resumeRefreshWaiters(&refresh.active, published: false)
        resumeRefreshWaiters(&refresh.pending, published: false)
    }

    func open(_ bot: BotProfile) async {
        guard let opening = prepareBotOpening(bot) else { return }
        await openBot(opening)
    }

    func openPushNotification(_ envelope: PushEnvelope) async {
        guard admitPushNotification(envelope) else { return }
        await resumePushNavigation()
    }

    func admitPushNotification(_ envelope: PushEnvelope) -> Bool {
        guard !isDemo, configuration != nil else {
            notice = isDemo ? "Leave demo to open this notification." : "Connect to your Mac to open this notification."
            return false
        }
        guard let scope = t3PushScope, let intent = t3Push.navigationIntent(envelope, scope: scope) else {
            notice = Self.unverifiedT3Notification
            return false
        }
        // Order the tap before awaiting a reconnect, roster read or attachment.
        t3NotificationLaunchScope = scope
        let supersededOpening = pendingPushNotification?.supersededOpening == true || hasUnsettledOpening
        pendingPushNotification = .init(intent: intent, claim: chats.captureNavigationClaim(), supersededOpening: supersededOpening)
        return true
    }
    /// Recovery can retire the admitted claim without retiring the tap. A retained tap may then claim
    /// again, because every newer navigation intent cancels the tap when it is admitted.
    private func pushNavigationClaim(for intent: PushNavigationIntent) -> NavigationClaim? {
        guard var pending = pendingPushNotification, pending.intent.id == intent.id else { return nil }
        if let claim = pending.claim, chats.ownsNavigation(claim) { return claim }
        pending.claim = chats.captureNavigationClaim()
        pendingPushNotification = pending
        return pending.claim
    }
    private func authorizesPushNavigation(_ intent: PushNavigationIntent) -> Bool {
        t3Push.authorizes(intent, scope: t3PushScope)
    }

    private static let unverifiedT3Notification = "This notification no longer has a verified destination."
    private static let t3PushReconnectNotice = "Reconnect to your Mac to open the notification’s Space."

    func resumePushNavigation() async {
        guard active, notificationRouting == nil, let intent = pendingPushNotification?.intent,
              !isDemo, let configuration else { return }
        let attempt = UUID(); notificationRouting = attempt
        defer {
            if notificationRouting == attempt {
                notificationRouting = nil
                if pendingPushNotification?.intent.id == intent.id { interruptSupersededOpening() }
                if let pending = pendingPushNotification?.intent, pending != intent {
                    Task { [weak self] in await self?.resumePushNavigation() }
                }
            }
        }
        if !isConnected {
            if pendingService != nil || connection.candidate != nil { return }
            guard await connect(configuration) else {
                if pendingPushNotification?.intent.id == intent.id { notice = Self.t3PushReconnectNotice }
                return
            }
        }
        guard await refreshBots() else {
            if pendingPushNotification?.intent.id == intent.id { notice = Self.t3PushReconnectNotice }
            return
        }
        guard !isDemo, self.configuration?.id == configuration.id, pendingPushNotification?.intent.id == intent.id else { return }
        let destination = intent.destination
        if !t3Channels.contains(where: { $0.id.utf8.elementsEqual(destination.storedID.utf8) }) {
            interruptSupersededOpening()
            pendingPushNotification = nil
            notice = "This notification’s Space is no longer available."
            return
        }
        guard authorizesPushNavigation(intent), bot(withID: destination.profileID) != nil,
              let profile = try? ExactID(destination.profileID),
              let root = try? ExactID(destination.rootID), let stored = try? ExactID(destination.storedID) else {
            interruptSupersededOpening()
            pendingPushNotification = nil
            notice = Self.unverifiedT3Notification
            return
        }
        let workspace = chats
        guard let claim = pushNavigationClaim(for: intent) else { return }
        let authority = BotNavigationAuthority(workspace: workspace, connection: generation,
                                               recovery: attachmentRecoveryGeneration, claim: claim)
        let ownsTap: @MainActor () -> Bool = { [self] in
            pendingPushNotification?.intent.id == intent.id && authorizesPushNavigation(intent) && !isDemo
        }
        let requested = SessionIdentity(profile: profile, root: root, stored: stored, aliases: [])
        let opened = await workspace.openNotificationChat(requested, claim: claim, exact: true,
                                                           isCurrent: ownsTap) { [self] _ in
            commitAttachedSelection(profile, authority: authority, while: ownsTap)
        }
        guard self.configuration?.id == configuration.id, chats === workspace, ownsTap() else { return }
        if opened {
            pendingPushNotification = nil; notice = nil; settleOpeningInterruption()
            presentAcceptedNotification()
        } else {
            notice = "Botto couldn’t open this notification’s Space. Reconnect and try again."
        }
    }

    /// The tap is newer than any cover still up, and every cover it lifts settles with its chat.
    private func presentAcceptedNotification() {
        if showsConnection { showsConnection = false }
        if pendingConnectionInput != nil { pendingConnectionInput = nil }
        notificationPresentation?.present()
        notificationNavigationRevision = UUID()
    }
    /// A newer navigation choice outranks a held notification.
    func retireHeldNotification() {
        guard pendingPushNotification != nil else { return }
        interruptSupersededOpening()
        pendingPushNotification = nil
        if notice == Self.t3PushReconnectNotice { notice = nil }
    }

    private var hasUnsettledOpening: Bool {
        guard let selectedBotID, let selection = chatSelection(for: selectedBotID) else { return false }
        return selection.isOpening || !chats.isCurrent(selection.owner)
    }
    private func interruptSupersededOpening() {
        if pendingPushNotification?.supersededOpening == true { openingInterrupted = true }
    }
    /// An unconditional write would invalidate every chat observing the retry.
    private func settleOpeningInterruption() {
        if openingInterrupted { openingInterrupted = false }
    }
    private func settleInterruptedOpening() {
        guard let selectedBotID, let screen = chatScreen(for: selectedBotID), canCompose(in: screen) else { return }
        settleOpeningInterruption()
    }
    func canCompose(in screen: ChatScreen) -> Bool {
        screen.canEditDraft && (screen.canAct || !isConnected)
    }
    /// The superseded opening stays retired, so only a fresh deliberate opening can settle this bot.
    func canRetryOpening(_ bot: BotProfile) -> Bool {
        guard openingInterrupted, selectedBotID.map({ Data($0.utf8) }) == Data(bot.id.utf8),
              let screen = chatScreen(for: bot.id), chatSelection(for: bot.id)?.isUnverified == false else { return false }
        return !screen.isOpening && !canCompose(in: screen)
    }

    func forgetConnectionWithPush() async {
        guard !isDemo else { return }
        let owner = generation
        let connectionID = configuration?.id
        let account = configuration.map(Self.richReplyAccount)
        guard await t3Push.disablePairings(matching: { _ in true }) else {
            notice = t3Push.notice ?? "Finish updating notifications before forgetting this connection."
            return
        }
        guard generation == owner, !isDemo, configuration?.id == connectionID,
              configuration.map(Self.richReplyAccount) == account else { return }
        forgetConnection()
        if configuration == nil { notice = t3Push.notice }
    }

    func artifactDestination(for attachment: ChatAttachment, botID: String, producingMessage: ChatMessage? = nil) -> ArtifactDestination? {
        guard active, !showsConnection, selectedBotID == botID,
              let screen = chatScreen(for: botID), let conversation = screen.snapshot,
              let localOwner = currentArtifactPresentationKey(), let source = chatSelection(for: botID)?.identity else { return nil }
        if let producingMessage, !TranscriptMessageIndex(conversation).matches(producingMessage) { return nil }
        let intent = chats.captureArtifact(attachment, owner: screen.owner)
        return .init(attachment: attachment, siblings: producingMessage.map { AttachmentPresentation.display($0).attachments } ?? [],
                     conversation: conversation, producingMessage: producingMessage, workspace: chats, intent: intent,
                     identity: source, library: library, localOwner: localOwner, localEpoch: artifactPresentationEpoch)
    }
    func artifactDestination(adjacentTo destination: ArtifactDestination, by step: Int) -> ArtifactDestination? {
        guard let index = destination.siblings.firstIndex(where: { $0.id == destination.attachment.id }),
              destination.siblings.indices.contains(index + step) else { return nil }
        return artifactDestination(for: destination.siblings[index + step], botID: destination.identity.profile.text,
                                   producingMessage: destination.producingMessage)
    }
    /// Completed local bytes retain their owner independently of socket/access epochs.
    func isAuthorizedArtifactPresentation(_ destination: ArtifactDestination) -> Bool {
        !showsConnection && destination.localEpoch == artifactPresentationEpoch
            && destination.localOwner == currentArtifactPresentationKey()
            && destination.producingMessage.map { TranscriptMessageIndex(conversation(for: destination.identity.profile.text)).matches($0) } != false
    }
    private func currentArtifactPresentationKey() -> ArtifactPresentationKey? {
        guard !showsConnection, let configuration, let selectedBotID,
              let selection = chatSelection(for: selectedBotID), let snapshot = selection.snapshot,
              !selection.isUnverified, let identity = selection.identity,
              Data(snapshot.profileID.utf8) == Data(selectedBotID.utf8) else { return nil }
        return .init(cache: configuration.id, account: Self.richReplyAccount(configuration),
                     chat: selection.owner.chat, root: identity.root, tip: identity.stored,
                     profile: Data(snapshot.profileID.utf8),
                     runtime: Data(snapshot.id.utf8), stored: Data(snapshot.storedID.utf8))
    }
    private func reconcileArtifactPresentation() {
        let key = currentArtifactPresentationKey()
        if key != artifactPresentationKey {
            artifactPresentationEpoch = UUID(); artifactPresentationKey = key
            library.reconcileOriginalConsumers()
        }
    }
    private func retireArtifactPresentation() {
        artifactPresentationEpoch = UUID(); artifactPresentationKey = currentArtifactPresentationKey()
        library.reconcileOriginalConsumers()
    }
    func canStartArtifactRead(_ destination: ArtifactDestination) -> Bool {
        isAuthorizedArtifactPresentation(destination)
            && (destination.intent == nil || isCurrentArtifactDestination(destination))
    }
    func isCurrentArtifactDestination(_ destination: ArtifactDestination) -> Bool {
        isAuthorizedArtifactPresentation(destination) && isConnected && active && !showsConnection && chats === destination.workspace
            && selectedBotID == destination.conversation.profileID
            && destination.intent.map { chats.isCurrentArtifact($0) } == true
    }
    func renewedArtifactDestination(_ destination: ArtifactDestination) -> ArtifactDestination? {
        guard isConnected, isAuthorizedArtifactPresentation(destination), destination.workspace === chats,
              destination.library === library, !isCurrentArtifactDestination(destination) else { return nil }
        return artifactDestination(for: destination.attachment, botID: destination.identity.profile.text,
            producingMessage: destination.producingMessage)
    }
    func downloadArtifact(_ destination: ArtifactDestination, force: Bool = false) async throws -> DownloadedArtifact {
        guard isAuthorizedArtifactPresentation(destination), destination.library === library else {
            throw ConversationServiceError.staleConversation
        }
        let key = await WorkspaceLibrary.originalKey(identity: destination.identity, attachment: destination.attachment,
            messages: destination.conversation.messages, producingMessage: destination.producingMessage)
        guard isAuthorizedArtifactPresentation(destination) else { throw ConversationServiceError.staleConversation }
        let download: @MainActor () async throws -> DownloadedArtifact = { [weak self] in
            guard let self, self.isAuthorizedArtifactPresentation(destination) else {
                throw ConversationServiceError.staleConversation
            }
            guard self.isConnected else { throw ConversationServiceError.disconnected }
            guard self.isCurrentArtifactDestination(destination), let intent = destination.intent else {
                throw ConversationServiceError.staleConversation
            }
            let artifact = try await destination.workspace.download(intent)
            guard self.isCurrentArtifactDestination(destination) else { throw ConversationServiceError.staleConversation }
            return artifact
        }
        let artifact: DownloadedArtifact
        if let key {
            artifact = try await destination.library.original(for: key, force: force, validateNetwork: { [weak self] in
                guard let self, self.isCurrentArtifactDestination(destination) else { throw ConversationServiceError.staleConversation }
            }, download: download)
        } else {
            // A valid selected capability may read a file without a retained producing occurrence.
            artifact = try await download()
        }
        guard isAuthorizedArtifactPresentation(destination) else { throw ConversationServiceError.staleConversation }
        return artifact
    }
    func finishArtifact(_ destination: ArtifactDestination) {
        if let intent = destination.intent { destination.workspace.finishArtifact(intent) }
        destination.library.reconcileOriginalConsumers()
    }
    private func retireArtifactDownloads() {
        reconcileArtifactPresentation()
        richReplies?.retire(); richReplies = nil
        artifactGeneration = UUID()
        library.reconcileOriginalConsumers()
    }

    fileprivate struct BotNavigationAuthority: Sendable {
        let workspace: ConversationWorkspace
        let connection: UUID
        let recovery: UUID
        let claim: NavigationClaim
    }
    struct BotOpening: Sendable {
        fileprivate let authority: BotNavigationAuthority
        fileprivate let profile: ExactID
        fileprivate let intent: OpeningIntent
    }
    /// A newer space selection supersedes earlier opens.
    private func captureBotAuthority() -> BotNavigationAuthority? {
        let workspace = chats
        guard !showsConnection, pendingConnectionInput == nil,
              let claim = workspace.captureNavigationClaim() else { return nil }
        pendingPushNotification = nil
        return .init(workspace: workspace, connection: generation, recovery: attachmentRecoveryGeneration, claim: claim)
    }
    private func isCurrentLifetime(_ authority: BotNavigationAuthority) -> Bool {
        chats === authority.workspace && generation == authority.connection && attachmentRecoveryGeneration == authority.recovery
    }
    private func isCurrentConnection(_ authority: BotNavigationAuthority) -> Bool {
        isCurrentLifetime(authority) && !showsConnection && pendingConnectionInput == nil
    }
    private func ownsBotNavigation(_ authority: BotNavigationAuthority) -> Bool {
        isCurrentConnection(authority) && authority.workspace.ownsNavigation(authority.claim)
    }
    /// Library attachments settle app selection inside their workspace commit,
    /// before the workspace publishes the chat, its saved selection or its grant.
    private func commitAttachedSelection(_ profile: ExactID, authority: BotNavigationAuthority,
                                         while isCurrent: () -> Bool) -> Bool {
        selectBotID(profile.text, presentation: .attachmentCommit) {
            isCurrentLifetime(authority) && authority.workspace.ownsNavigation(authority.claim) &&
                bot(withID: profile.text) != nil && isCurrent()
        }
    }
    func prepareBotOpening(_ bot: BotProfile, attention: Bool = false) -> BotOpening? {
        guard let profile = try? ExactID(bot.id), self.bot(withID: bot.id) != nil,
              let authority = captureBotAuthority(),
              selectBotID(profile.text, presentation: .preserveNavigation(authority.claim), while: {
                  ownsBotNavigation(authority) && self.bot(withID: bot.id) != nil
              }), let intent = authority.workspace.captureOpening(profile: profile, attention: attention, claim: authority.claim) else { return nil }
        let opening = BotOpening(authority: authority, profile: profile, intent: intent)
        return canOpenBot(opening) ? opening : nil
    }

    func canOpenBot(_ opening: BotOpening) -> Bool {
        ownsBotNavigation(opening.authority) && bot(withID: opening.profile.text) != nil &&
            selectedBotID.map({ Data($0.utf8) }) == opening.profile.bytes
    }
    func openBot(_ opening: BotOpening) async {
        guard canOpenBot(opening) else { return }
        if let space = T3ChatShelf.initialSpace(t3Channels) {
            let opened = await openT3Channel(space, authority: opening.authority)
            if !opened, !Task.isCancelled, isCurrentConnection(opening.authority), selectedT3ChannelID == nil {
                notice = String(localized: "That space didn’t open. Select Botto to try again.")
            }
        } else {
            await opening.authority.workspace.open(opening.intent)
        }
        settleInterruptedOpening()
    }

    func setActive(_ value: Bool) async {
        active = value
        #if DEBUG
        if value, isDemo, ProcessInfo.processInfo.arguments.contains("--demo-offline") {
            if connection.isSuspended { receive(.disconnected("The sample workspace is offline.")) }
            return
        }
        #endif
        if !value {
            discardPendingService()
            flush()
            service.disconnect()
            chats.retireConnection()
            connection.suspend(hasSavedSetup: configuration != nil)
            retireRefresh()
        } else {
            // Local persistence can recover after unlocking even if the network cannot.
            flush()
            if hasStarted, !isConnected, pendingService == nil, connection.candidate == nil, let configuration {
                if await connect(configuration) { return }
            }
            await t3Push.resume(scope: t3PushScope)
        }
    }

    func forgetConnection() {
        do {
            try persistence.remove()
            guard try persistence.load() == nil else {
                notice = "Botto couldn’t confirm that saved setup was removed. Try again."
                return
            }
        }
        catch { notice = error.localizedDescription; return }
        let oldID = configuration?.id
        pendingPushNotification = nil; notificationRouting = nil
        t3NotificationLaunchScope = nil
        if let oldID { artifactCache.discard(configurationID: oldID) }
        else { artifactCache.prune(reachableConfigurationIDs: []) }
        Task { [weak self, artifactCache] in
            do { try await artifactCache.drainMaintenance() }
            catch { self?.notice = "Saved setup was removed, but artifact cleanup couldn’t finish. Botto will retry when it opens again." }
        }
        retireAvatarWorkspace(ifReplacingWith: nil)
        discardPendingService()
        connection.forget(); retireRefresh()
        service.onEvent = nil; service.disconnect()
        cacheTask?.cancel()
        avatars.reset()
        liveService = injectedService ?? makeService(nil)
        service = liveService
        configuration = nil; mount(.init(), configuration: nil); selectedBotID = nil
        isDemo = false; savedSetupLoadFailed = false
        if let oldID, !protectedCaches.contains(oldID) { LocalHistory.remove(for: oldID) }
        cleanHistory(keeping: nil)
        demoConnectionID = nil
    }

    func enterDemo() async {
        guard flush() else { return }
        discardPendingService()
        retireAvatarWorkspace(ifReplacingWith: nil)
        service.disconnect(); service = DemoBotService()
        isDemo = true
        let demo = ConnectionConfiguration(serverURL: URL(string: "https://demo.botto.local")!,
            t3: T3Connection(environmentID: "demo", accessToken: "", projectID: DemoBotService.profileID))
        demoConnectionID = demo.id
        await connect(demo)
    }

    func leaveDemo() {
        t3NotificationLaunchScope = nil
        retireAvatarWorkspace(ifReplacingWith: nil)
        service.onEvent = nil; service.disconnect(); service = liveService
        connection.suspend(hasSavedSetup: false)
        retireRefresh(); isDemo = false; configuration = nil; mount(.init(), configuration: nil)
        demoConnectionID = nil
        avatars.reset()
        selectedBotID = nil
        loadSavedSetup()
    }

    private func receive(_ event: BotServiceEvent) {
        switch event {
        case .conversation(let chat):
            chats.receive(chat); richReplies?.reconcileCanonicalConversation()
            publishT3Channels()
        case .activity(let profile, let observations):
            chats.applyActivity(profile: profile, observations: observations)
        case .activityBatch(let updates):
            chats.applyActivity(updates)
        case .conversationDirectoryChanged(let profile):
            publishT3Channels()
            library.invalidateRevalidation()
            chats.invalidateActivityDirectory(profile)
            Task { await refresh() }
        case .botsChanged:
            publishT3Channels()
            library.invalidateRevalidation()
            refreshFromBotInvalidation()
        case .configuration(let updated):
            if connection.candidate != nil {
                connection.updateCandidate(updated)
                return
            }
            guard !isDemo, let configuration, updated.id == configuration.id,
                  updated.serverURL == configuration.serverURL else { return }
            retireAvatarWorkspace(ifReplacingWith: updated)
            if Self.richReplyAccount(configuration) != Self.richReplyAccount(updated) {
                retireArtifactPresentation()
                chats.retireConnection()
            }
            self.configuration = updated
            do { try persistence.save(updated) }
            catch {
                connection.credentialStorageFailed(error, hasSavedSetup: true)
                service.disconnect(); chats.retireConnection(); retireRefresh()
                notice = error.localizedDescription
            }
        case .disconnected(let reason):
            retireRefresh()
            chats.retireConnection(allowRecoveryPublication: active && !showsConnection && connection.candidate == nil)
            connection.disconnected(reason)
            for index in cachedBots.indices { cachedBots[index].status = .idle }
        case .connected(let info):
            guard active, connection.recovered(info) else { return }
            chats.setOnline(true)
            Task { await refresh() }
        }
    }

    private func scheduleSave() {
        cacheTask?.cancel()
        guard !isDemo else { return }
        cacheTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            self?.flush()
        }
    }

    @discardableResult func flush() -> Bool {
        guard !isDemo, let configuration else { return true }
        guard !cacheLoadFailed, !protectedCaches.contains(configuration.id) else {
            notice = notice ?? "Cache saving is paused because saved history couldn’t be opened safely. Your current workspace is still here."
            return false
        }
        do {
            try history.save(for: configuration.id)
            historySaveFailure = nil
            return true
        } catch {
            historySaveFailure = error
            return false
        }
    }
}


extension AppStore {
    /// Exact nonsecret account facts plus the existing lifecycle incarnations.
    /// The memberwise constructor remains private to this source file.
    struct RichReplyDestination: Hashable {
        fileprivate let owner: PresentationOwner
        fileprivate let configurationID: UUID
        fileprivate let account: [Data?]
        fileprivate let connection: UUID
        fileprivate let recovery: UUID
        fileprivate let artifact: UUID
        fileprivate let profile: Data
        fileprivate let runtime: Data
        fileprivate let stored: Data
    }
    static func richReplyAccount(_ configuration: ConnectionConfiguration) -> [Data?] {
        [configuration.serverURL.absoluteString, configuration.installID, configuration.username,
         configuration.nativeCredential?.provider ?? "basic"].map { $0.map { Data($0.utf8) } }
            + backendAccount(configuration)
    }
    private func richReplyDestination(for botID: String) -> RichReplyDestination? {
        guard active, link != .connecting, !showsConnection,
              selectedBotID.map({ Data($0.utf8) }) == Data(botID.utf8),
              let configuration,
              let origin = URLComponents(url: configuration.serverURL, resolvingAgainstBaseURL: false),
              origin.user == nil, origin.password == nil, origin.query == nil, origin.fragment == nil,
              let selection = chatSelection(for: botID), !selection.isOpening, chats.isCurrent(selection.owner),
              let chat = selection.snapshot,
              Data(chat.profileID.utf8) == Data(botID.utf8) else { return nil }
        return .init(owner: selection.owner, configurationID: configuration.id, account: Self.richReplyAccount(configuration),
                     connection: generation, recovery: attachmentRecoveryGeneration,
                     artifact: artifactGeneration, profile: Data(botID.utf8),
                     runtime: Data(chat.id.utf8), stored: Data(chat.storedID.utf8))
    }
    func isCurrentRichReplyDestination(_ destination: RichReplyDestination) -> Bool {
        chats.isCurrent(destination.owner) && richReplyDestination(for: String(decoding: destination.profile, as: UTF8.self)) == destination
    }
    func richReplyIsWorking(destination: RichReplyDestination) -> Bool? {
        guard isCurrentRichReplyDestination(destination) else { return nil }
        return conversation(for: String(decoding: destination.profile, as: UTF8.self))?.isWorking
    }
    func richReplyBlocks(messageID: Data, destination: RichReplyDestination) -> [ExactReplyBlock]? {
        guard isCurrentRichReplyDestination(destination),
              let chat = conversation(for: String(decoding: destination.profile, as: UTF8.self)),
              let message = chat.messages.first(where: { Data($0.id.utf8) == messageID }),
              message.role == .assistant, TranscriptMessageIndex(chat).matches(message) else { return nil }
        let streaming = chat.isWorking && chat.messages.last.map { Data($0.id.utf8) } == messageID
        return ReplyContent(message: message, isStreaming: streaming,
                            filePreviewsAreSettled: !chat.isWorking).blocks
            .filter { $0.isComplete && ($0.previewFormat != nil || $0.filePreview != nil) }.map(ExactReplyBlock.init)
    }
    func downloadReplyFile(_ block: ReplyContent.Block, messageID: Data,
                           destination: RichReplyDestination, force: Bool = false) async throws -> ReplyFileDownload {
        guard let reference = block.filePreview,
              richReplyBlocks(messageID: messageID, destination: destination)?.contains(ExactReplyBlock(block)) == true,
              let message = conversation(for: String(decoding: destination.profile, as: UTF8.self))?.messages.first(where: { Data($0.id.utf8) == messageID }),
              let file = artifactDestination(for: reference.attachment,
                  botID: String(decoding: destination.profile, as: UTF8.self), producingMessage: message) else {
            throw ConversationServiceError.staleConversation
        }
        let artifact = try await downloadArtifact(file, force: force)
        return ReplyFileDownload(artifact: artifact, destination: file)
    }
    func richReplyContext(for botID: String, messageID: String) -> RichReplyContext {
        guard let destination = richReplyDestination(for: botID) else { return .chat(nil) }
        if richReplies?.isCurrent != true {
            richReplies?.retire()
            richReplies = RichReplyPresentations(owner: self, destination: destination)
        }
        return richReplies?.message(messageID) ?? .chat(nil)
    }
}
