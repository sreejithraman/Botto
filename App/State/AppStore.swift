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
        }
    }

    @MainActor private final class BotRefresh {
        var task: Task<Void, Never>?
        var active: [UUID: CheckedContinuation<Bool, Never>] = [:]
        var pending: [UUID: CheckedContinuation<Bool, Never>] = [:]
    }

    private(set) var link: Link = .unconfigured {
        didSet { library.setOnline(link == .online) }
    }
    private(set) var configuration: ConnectionConfiguration?
    private(set) var savedSetupLoadFailed = false
    private(set) var serverInfo: ServerInfo?
    private var cachedBots: [BotProfile] = [] { didSet { library.observeBots(cachedBots, evidence: .cached) } }
    private var pinned: Set<ExactID> = []
    private var unpinned: Set<ExactID> = []
    private(set) var chats: ConversationWorkspace
    let push: PushCoordinator
    private(set) var notificationNavigationRevision = UUID()
    @ObservationIgnored private var pendingPushNotification: PushNavigationIntent?
    @ObservationIgnored private var notificationRouting: UUID?
    private(set) var library: WorkspaceLibrary
    private(set) var cacheLoadFailed = false
    @ObservationIgnored private var protectedCaches: Set<UUID> = []
    var history: LocalHistory {
        .init(bots: cachedBots, book: chats.persisted(), pinned: pinned, unpinned: unpinned)
    }
    private(set) var isDemo = false
    var isRefreshing: Bool { botRefresh != nil }
    var openingID: String? {
        guard let selectedBotID, chatSelection(for: selectedBotID)?.isOpening == true else { return nil }
        return selectedBotID
    }
    var uploading: Set<String> { chats.uploadingProfiles }
    var selectedBotID: String? {
        didSet {
            if selectedBotID.map({ Data($0.utf8) }) != oldValue.map({ Data($0.utf8) }) {
                retireArtifactPresentation()
                chats.retirePresentation()
            }
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
    var connectionError: String?
    var pendingConnectionInput: String?
    var showsConnection = false {
        didSet {
            if showsConnection && !oldValue { retireArtifactPresentation(); chats.retirePresentation() }
            else if !showsConnection && oldValue { reconcileArtifactPresentation() }
        }
    }

    @ObservationIgnored private var service: any BotService
    @ObservationIgnored private let liveService: any BotService
    @ObservationIgnored private var demoConnectionID: UUID?
    @ObservationIgnored private let artifactCache: ArtifactCache
    private var mountedArtifactScope: ArtifactCacheScope?
    @ObservationIgnored private let persistence: ConnectionPersistence
    @ObservationIgnored private let cleanupHistory: (UUID?) throws -> Void
    @ObservationIgnored private var richReplies: RichReplyPresentations?
    private var generation = UUID()
    private var avatarWorkspaceGeneration = UUID()
    // Automatic socket recovery keeps the event owner, but retires pending attachments.
    @ObservationIgnored private var attachmentRecoveryGeneration = UUID()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var active = true
    @ObservationIgnored private var cacheTask: Task<Void, Never>?
    @ObservationIgnored private var connectingConfiguration: ConnectionConfiguration?
    // Refresh consumes the previous token, even if secure storage is temporarily locked.
    // Retain the replacement independently of the visible workspace and socket owner.
    @ObservationIgnored private var rotatedConfigurations: [UUID: ConnectionConfiguration] = [:]
    private var botRefresh: BotRefresh?
    private let avatars: BotAvatarStore
    @ObservationIgnored private var avatarSaves: [String: UUID] = [:]

    init(service: (any BotService)? = nil, persistence: ConnectionPersistence? = nil, push: PushCoordinator? = nil,
         cleanupHistory: ((UUID?) throws -> Void)? = nil, artifactCache: ArtifactCache? = nil, avatarNow: @escaping () -> Date = Date.init) {
        let liveService = service ?? HermesBotService()
        self.artifactCache = artifactCache ?? (persistence == nil ? .shared : ArtifactCache(root: nil))
        self.liveService = liveService
        self.service = liveService
        self.library = WorkspaceLibrary(service: liveService)
        self.chats = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: .init(), service: liveService, onDirty: {})
        self.persistence = persistence ?? .keychain
        if let push { self.push = push }
        else if persistence != nil {
            var savedPush = PushSavedState()
            self.push = PushCoordinator(persistence: .init(load: { savedPush }, save: { savedPush = $0 }),
                authorization: .init(requestPermission: { false }, deviceToken: { throw PushError.tokenUnavailable }))
        } else { self.push = PushCoordinator() }
        self.avatars = BotAvatarStore(now: avatarNow)
        // Injected vaults need not own the app's one production cache directory.
        self.cleanupHistory = cleanupHistory ?? (persistence == nil ? { try LocalHistory.removeUnreachable(keeping: $0) } : { _ in })
        if loadSavedSetup(), configuration != nil { link = .connecting }
        bindPushNotifications()
    }

    @discardableResult private func loadSavedSetup() -> Bool {
        do { configuration = try persistence.load() }
        catch {
            savedSetupLoadFailed = true; connectionError = error.localizedDescription
            return false
        }
        savedSetupLoadFailed = false; connectionError = nil
        artifactCache.prune(reachableConfigurationIDs: Set(configuration.map { [$0.id] } ?? []))
        link = configuration == nil ? .unconfigured : .offline
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

    private static func artifactScope(_ configuration: ConnectionConfiguration) -> ArtifactCacheScope {
        .init(configurationID: configuration.id, serverURL: Data(configuration.serverURL.absoluteString.utf8),
            installationID: configuration.installID.map { Data($0.utf8) }, username: Data(configuration.username.utf8),
            provider: configuration.nativeCredential.map { Data($0.provider.utf8) })
    }

    private func mount(_ history: LocalHistory, configuration: ConnectionConfiguration?) {
        historySaveFailure = nil
        chats.retireWorkspace()
        library.retire()
        mountedArtifactScope = isDemo ? nil : configuration.map(Self.artifactScope)
        let cache = mountedArtifactScope.map { artifactCache.session(scope: $0) }
        library = WorkspaceLibrary(service: service, cache: cache)
        library.seed(book: history.book, bots: history.bots)
        library.setOnline(isConnected)
        Task { [library] in await library.restore() }
        cachedBots = history.bots; pinned = history.pinned; unpinned = history.unpinned
        let scope = WorkspaceScope(cacheID: configuration?.id ?? UUID(),
            exactAccount: configuration.map(Self.richReplyAccount) ?? [], incarnation: UUID())
        chats = ConversationWorkspace(scope: scope, book: history.book, service: service,
            onDirty: { [weak self] in self?.reconcileArtifactPresentation(); self?.scheduleSave() })
        chats.onAcceptedTranscript = { [weak self, weak library] publication, previous, title in
            guard let self, let library, library === self.library else { return }
            let evidence: WorkspaceLibrary.TranscriptEvidence = publication.historyReadStartedAt.map {
                .read(startedAt: $0, observedSource: publication.observedSource)
            }
                ?? .incremental(previous: previous)
            library.accept(identity: publication.identity, snapshot: publication.snapshot, title: title, evidence: evidence)
            library.reconcileOriginalConsumers()
        }
        chats.onPresentationChange = { [weak self] in self?.retireArtifactDownloads() }
        chats.onUserNavigation = { [weak self] in self?.pendingPushNotification = nil }
        var chatWasVisible = false
        chats.onVisibleChatChange = { [weak self] identity in
            self?.push.updateVisibility(destination: identity.map(PushDestination.init))
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
    var needsYou: [BotProfile] { inbox.filter(\.needsAttention).map(\.bot) }
    var isConnected: Bool { link == .online }
    /// View-owned operations must also belong to the current connection lifetime.
    var connectionGeneration: UUID { generation }
    var serverName: String { isDemo ? "Demo workspace" : configuration?.serverURL.host ?? "Your Hermes" }

    func avatar(for bot: BotProfile) -> UIImage? { avatars.image(for: bot) }
    func isLoadingAvatar(for bot: BotProfile) -> Bool { avatars.isLoading(bot) }

    func avatarDestination(for bot: BotProfile) -> AvatarDestination? {
        guard let configuration, let current = cachedBots.first(where: { $0.id == bot.id }) else { return nil }
        return AvatarDestination(profile: current, workspaceGeneration: avatarWorkspaceGeneration,
                                 configurationID: configuration.id,
                                 account: AvatarDestination.account(for: configuration),
                                 installID: configuration.installID.map { Data($0.utf8) }, demo: isDemo)
    }

    func saveAvatar(_ choice: BotAvatarChoice, to destination: AvatarDestination) async throws {
        let owner = generation, recovery = attachmentRecoveryGeneration
        try validateAvatarDestination(destination, connection: owner, recovery: recovery)
        let id = destination.profile.id
        guard avatarSaves[id] == nil else { throw HermesServiceError.avatarConflict }
        let attempt = UUID()
        avatarSaves[id] = attempt
        defer { if avatarSaves[id] == attempt { avatarSaves[id] = nil } }
        // The service revalidates the original avatar metadata before making one mutation.
        _ = try await service.setAvatar(choice, for: destination.profile)
        try validateAvatarDestination(destination, connection: owner, recovery: recovery)
        // Use the existing publication fence: an older inbox read cannot erase a saved face.
        let published = await refreshBots()
        try validateAvatarDestination(destination, connection: owner, recovery: recovery)
        guard published else { throw HermesServiceError.avatarRefresh }
    }

    func reloadAvatar(_ destination: AvatarDestination) async throws -> AvatarDestination {
        let owner = generation, recovery = attachmentRecoveryGeneration
        try validateAvatarDestination(destination, connection: owner, recovery: recovery)
        let published = await refreshBots()
        try validateAvatarDestination(destination, connection: owner, recovery: recovery)
        guard published, let bot = cachedBots.first(where: { $0.id == destination.profile.id }),
              let updated = avatarDestination(for: bot) else { throw HermesServiceError.avatarReload }
        if let id = configuration?.id {
            avatars.refresh(cachedBots, connectionID: id, using: service, revalidate: [bot.id])
        }
        return updated
    }

    func saveProfile(_ edit: BotProfileEdit, avatar: BotAvatarChoice?, to destination: AvatarDestination) async throws {
        let owner = generation, recovery = attachmentRecoveryGeneration
        try validateAvatarDestination(destination, connection: owner, recovery: recovery)
        let id = destination.profile.id
        guard avatarSaves[id] == nil else { throw HermesServiceError.profileConflict }
        let attempt = UUID()
        avatarSaves[id] = attempt
        defer { if avatarSaves[id] == attempt { avatarSaves[id] = nil } }
        let changesMetadata = edit.name != nil || edit.description != nil
        var metadataSaved = false
        do {
            if changesMetadata {
                _ = try await service.updateProfile(edit, for: destination.profile)
                metadataSaved = true
                try validateAvatarDestination(destination, connection: owner, recovery: recovery)
            }
            if let avatar {
                _ = try await service.setAvatar(avatar, for: destination.profile)
                try validateAvatarDestination(destination, connection: owner, recovery: recovery)
            }
        } catch {
            if metadataSaved { throw HermesServiceError.partialProfile }
            throw error
        }
        let published = await refreshBots()
        try validateAvatarDestination(destination, connection: owner, recovery: recovery)
        guard published else { throw HermesServiceError.partialProfile }
    }

    private func validateAvatarDestination(_ destination: AvatarDestination, connection: UUID, recovery: UUID) throws {
        guard isConnected, !Task.isCancelled, generation == connection,
              attachmentRecoveryGeneration == recovery,
              destination.isCurrent(in: self) else { throw HermesServiceError.disconnected }
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
        guard let profile = try? ExactID(botID), let id = chats.persisted().opening(profile) else { return "" }
        return chats.persisted().record(id)?.draft.text ?? ""
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
        guard !started else { return }
        started = true
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--demo") {
            await enterDemo()
            if arguments.contains("--demo-offline") {
                for bot in bots { await open(bot) }
                selectedBotID = nil
                receive(.disconnected("The sample workspace is offline."))
            }
            return
        }
        if let index = arguments.firstIndex(of: "--fixture-server"), arguments.indices.contains(index + 1),
           let url = URL(string: arguments[index + 1]), ["127.0.0.1", "localhost"].contains(url.host ?? "") {
            await connect(ConnectionConfiguration(serverURL: url, username: "botto-test", password: "botto-test"))
            return
        }
        #endif
        if let configuration { await connect(configuration) }
    }

    @discardableResult func connect(_ candidate: ConnectionConfiguration,
                                   onConnected: (@MainActor () -> Void)? = nil,
                                   onFailure: (@MainActor (any Error) -> Void)? = nil) async -> Bool {
        if isDemo, candidate.id != demoConnectionID { leaveDemo() }
        guard isDemo || !savedSetupLoadFailed else { return false }
        let candidate = rotatedConfigurations[candidate.id].flatMap {
            $0.serverURL == candidate.serverURL ? $0 : nil
        } ?? candidate
        if candidate.id != configuration?.id || configuration.map(Self.richReplyAccount) != Self.richReplyAccount(candidate) {
            pendingPushNotification = nil
            retireArtifactPresentation()
        }
        generation = UUID()
        avatars.reset()
        let owner = generation
        push.retireConnection()
        service.disconnect()
        chats.retireConnection()
        cacheTask?.cancel()
        retireRefresh()
        link = .connecting; connectionError = nil
        connectingConfiguration = candidate
        service.onEvent = { [weak self] event in
            guard let self else { return }
            // Token rotation may finish while a socket is being replaced. Keep the saved
            // credential current even when ordinary screen events belong to an old owner.
            if case .configuration = event { self.receive(event); return }
            guard self.generation == owner else { return }
            self.receive(event)
        }
        do {
            if !isDemo { try persistSavedRotation() }
            let info = try await withTaskCancellationHandler {
                try await service.connect(configuration: candidate)
            } onCancel: {
                Task { @MainActor [weak self] in self?.cancelConnection(owner: owner) }
            }
            guard generation == owner else { return false }
            if Task.isCancelled { cancelConnection(owner: owner); return false }
            var saved = connectingConfiguration ?? candidate
            saved.installID = info.installID ?? saved.installID
            let previousID = configuration?.id
            let preservesHistory = configuration?.id != saved.id && canPreserveHistory(for: saved, confirmedBy: info)
            let replacementHistory: LocalHistory
            if preservesHistory {
                guard !cacheLoadFailed else { throw HistoryFailure.corrupt }
                replacementHistory = history.readOnly
            } else if previousID == saved.id { replacementHistory = history.readOnly }
            else { replacementHistory = try LocalHistory.load(for: saved.id) }
            if !isDemo {
                // A failed vault read cannot authorize overwriting setup or pruning caches.
                _ = try persistence.load()
                var replacement: LocalHistory.CacheReplacement?
                if previousID != saved.id {
                    if let previousID, !protectedCaches.contains(previousID) { try history.save(for: previousID) }
                    replacement = try replacementHistory.prepareReplacement(for: saved.id)
                }
                do { try persistence.save(saved) }
                catch {
                    do { try replacement?.rollback() }
                    catch { notice = "Your previous setup is safe, but a temporary history cache couldn’t be removed." }
                    throw error
                }
            }
            if rotatedConfigurations[saved.id] != nil { rotatedConfigurations[saved.id] = saved }
            let changedCache = configuration?.id != saved.id
            let sameWorkspace = !changedCache && mountedArtifactScope == Self.artifactScope(saved)
            if !sameWorkspace { mount(replacementHistory, configuration: saved) }
            if changedCache { selectedBotID = nil; cacheLoadFailed = false }
            connectingConfiguration = nil
            retireAvatarWorkspace(ifReplacingWith: saved)
            configuration = saved; serverInfo = info; link = .online; chats.setOnline(true)
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
            guard generation == owner else { return false }
            bindPushNotifications()
            Task { [weak self] in
                guard let self, self.generation == owner else { return }
                await self.push.refresh()
                guard self.generation == owner else { return }
                await self.push.resume()
            }
            onConnected?()
            showsConnection = false
            if let restoration, workspace === chats {
                await workspace.restoreAttachment(restoration)
            }
            return true
        } catch {
            guard generation == owner else { return false }
            if !(error is CancellationError), !Task.isCancelled { onFailure?(error) }
            cancelConnection(owner: owner)
            connectionError = error.localizedDescription
            return false
        }
    }

    private func canPreserveHistory(for candidate: ConnectionConfiguration, confirmedBy info: ServerInfo) -> Bool {
        guard !isDemo, let previous = configuration,
              let installID = info.installID, !installID.isEmpty, previous.installID == installID,
              !previous.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              previous.username == candidate.username,
              let oldOrigin = try? PairingAddress.parse(previous.serverURL.absoluteString, allowInsecureHTTP: true),
              let newOrigin = try? PairingAddress.parse(candidate.serverURL.absoluteString, allowInsecureHTTP: true),
              oldOrigin.scheme == newOrigin.scheme, oldOrigin.host == newOrigin.host,
              (oldOrigin.port ?? (oldOrigin.scheme == "https" ? 443 : 80))
                == (newOrigin.port ?? (newOrigin.scheme == "https" ? 443 : 80)) else { return false }
        // Both password login and native basic verify this account through /api/auth/me.
        let provider = previous.nativeCredential?.provider ?? "basic"
        return !provider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && provider == (candidate.nativeCredential?.provider ?? "basic")
    }

    private func cancelConnection(owner: UUID) {
        guard generation == owner, connectingConfiguration != nil else { return }
        generation = UUID(); connectingConfiguration = nil
        service.disconnect()
        chats.retireConnection(); retireRefresh()
        link = configuration == nil ? .unconfigured : .offline
    }

    func refresh(revalidateAvatars: Bool = false) async {
        let owner = generation, recovery = attachmentRecoveryGeneration
        guard await refreshBots(), generation == owner, !Task.isCancelled, isConnected else { return }
        pendingPushNotification?.recoveryRevision = UUID()
        await resumePushNavigation()
        guard revalidateAvatars, !Task.isCancelled, isConnected,
              generation == owner, attachmentRecoveryGeneration == recovery, let id = configuration?.id else { return }
        avatars.refresh(cachedBots, connectionID: id, using: service, revalidate: Set(cachedBots.map(\.id)))
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
        let originalBot = selectedBotID.map { Data($0.utf8) }
        guard let intent = workspace.beginLibraryOpening(chat.identity) else { return false }
        let opened = await workspace.openLibraryChat(intent, accepts: accepts) { [self] identity in
            guard !Task.isCancelled, workspace === chats, sourceLibrary === library, !sourceLibrary.isRetired,
                  selectedBotID.map({ Data($0.utf8) }) == originalBot,
                  identity.profile == chat.identity.profile,
                  bot(withID: chat.botID) != nil, sourceLibrary.isCurrent(chat) else { return false }
            selectedBotID = chat.botID
            return true
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
                bindPushNotifications()
                if let id = configuration?.id { avatars.refresh(profiles, connectionID: id, using: service) }
                await chats.refreshActivityDirectories(for: profiles)
                guard generation == owner, botRefresh === refresh else { return }
                chats.scheduleInboxPreviews(for: profiles)
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
        pendingPushNotification = nil; selectedBotID = bot.id
        guard let profile = try? ExactID(bot.id) else { return }
        await chats.openBot(profile: profile)
    }

    private func bindPushNotifications() {
        let chosenProfile = cachedBots.first { bot in
            push.selectedProfileID.map { Data($0.utf8) } == Data(bot.id.utf8)
        }?.id ?? selectedBotID ?? cachedBots.first?.id
        push.bind(service: service, configuration: configuration, isDemo: isDemo,
                  profileID: chosenProfile)
        push.configureProfiles(cachedBots)
    }

    var notificationTestDestination: PushDestination? {
        guard let profileID = push.selectedProfileID, let profile = try? ExactID(profileID),
              let selection = chats.selection(profile: profile), !selection.isUnverified,
              let identity = selection.identity else { return nil }
        return .init(identity: identity)
    }

    func openPushNotification(_ envelope: PushEnvelope) async {
        guard !isDemo, configuration != nil else {
            notice = isDemo ? "Leave demo to open this notification." : "Connect to your Hermes host to open this notification."
            return
        }
        bindPushNotifications()
        guard let intent = push.navigationIntent(envelope) else {
            notice = "This notification no longer has a verified chat destination. Open your bot's chats to continue."
            return
        }
        pendingPushNotification = intent
        await resumePushNavigation()
    }
    private func resumePushNavigation() async {
        guard active, notificationRouting == nil, let intent = pendingPushNotification,
              !isDemo, let configuration else { return }
        let attempt = UUID(); notificationRouting = attempt
        defer {
            if notificationRouting == attempt {
                notificationRouting = nil
                if pendingPushNotification != nil, pendingPushNotification != intent {
                    Task { [weak self] in await self?.resumePushNavigation() }
                }
            }
        }
        if !isConnected {
            guard await connect(configuration) else {
                notice = "Reconnect to your Hermes host to open the notification's chat."
                return
            }
        }
        guard await refreshBots() else {
            notice = "Reconnect to your Hermes host to open the notification's chat."
            return
        }
        bindPushNotifications()
        let readiness = await push.navigationReadiness(intent)
        guard !isDemo, self.configuration?.id == configuration.id, pendingPushNotification?.id == intent.id else { return }
        if readiness == .unavailable { notice = "Reconnect to your Hermes host to open the notification's chat."; return }
        let destination = intent.destination
        guard readiness == .current, push.authorizesNavigation(intent), let bot = bot(withID: destination.profileID),
              let profile = try? ExactID(destination.profileID),
              let root = try? ExactID(destination.rootID), let stored = try? ExactID(destination.storedID) else {
            pendingPushNotification = nil
            notice = "This notification no longer has a verified chat destination. Open your bot's chats to continue."
            return
        }
        let workspace = chats
        let opened = await workspace.openNotificationChat(.init(profile: profile, root: root, stored: stored, aliases: [])) { self.pendingPushNotification?.id == intent.id && self.push.authorizesNavigation(intent) }
        guard self.configuration?.id == configuration.id, chats === workspace,
              pendingPushNotification?.id == intent.id, push.authorizesNavigation(intent), !isDemo else { return }
        if opened {
            selectedBotID = bot.id
            pendingPushNotification = nil; notice = nil
            notificationNavigationRevision = UUID()
        } else {
            notice = "Botto couldn’t open this notification's chat. Reconnect and try again."
        }
    }

    func forgetConnectionWithPush() async {
        guard !isDemo else { return }
        let owner = generation
        let connectionID = configuration?.id
        let account = configuration.map(Self.richReplyAccount)
        let removed = await push.prepareToForget()
        guard generation == owner, !isDemo, configuration?.id == connectionID,
              configuration.map(Self.richReplyAccount) == account else { return }
        guard removed else {
            notice = push.notice ?? "Botto couldn’t remove notification pairings. Check Notifications, then try again."
            return
        }
        let pushNotice = push.notice
        forgetConnection()
        if configuration == nil, let pushNotice { notice = pushNotice }
    }

    func artifactDestination(for attachment: ChatAttachment, botID: String, producingMessage: ChatMessage? = nil) -> ArtifactDestination? {
        guard active, !showsConnection, selectedBotID == botID,
              let screen = chatScreen(for: botID), let conversation = screen.snapshot,
              let localOwner = currentArtifactPresentationKey(), let source = chatSelection(for: botID)?.identity else { return nil }
        if let producingMessage, !TranscriptMessageIndex(conversation).matches(producingMessage) { return nil }
        let intent = chats.captureArtifact(attachment, owner: screen.owner)
        return .init(attachment: attachment, conversation: conversation, producingMessage: producingMessage, workspace: chats, intent: intent,
                     identity: source, library: library, localOwner: localOwner, localEpoch: artifactPresentationEpoch)
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
            throw HermesServiceError.staleConversation
        }
        #if DEBUG
        let startupTrace = UUID()
        print("[DEBUG-native-startup] \(startupTrace) app-key-start \(ProcessInfo.processInfo.systemUptime)")
        #endif
        let key = await WorkspaceLibrary.originalKey(identity: destination.identity, attachment: destination.attachment,
            messages: destination.conversation.messages, producingMessage: destination.producingMessage)
        #if DEBUG
        print("[DEBUG-native-startup] \(startupTrace) app-key-ready \(ProcessInfo.processInfo.systemUptime)")
        #endif
        guard isAuthorizedArtifactPresentation(destination) else { throw HermesServiceError.staleConversation }
        let download: @MainActor () async throws -> DownloadedArtifact = { [weak self] in
            guard let self, self.isCurrentArtifactDestination(destination), let intent = destination.intent else {
                throw HermesServiceError.staleConversation
            }
            #if DEBUG
            print("[DEBUG-native-startup] network-enter \(ProcessInfo.processInfo.systemUptime)")
            #endif
            let artifact = try await destination.workspace.download(intent)
            guard self.isCurrentArtifactDestination(destination) else { throw HermesServiceError.staleConversation }
            return artifact
        }
        let artifact: DownloadedArtifact
        if let key {
            artifact = try await destination.library.original(for: key, force: force, validateNetwork: { [weak self] in
                guard let self, self.isCurrentArtifactDestination(destination) else { throw HermesServiceError.staleConversation }
            }, download: download)
        } else {
            // A valid selected capability may read a file without a retained producing occurrence.
            artifact = try await download()
        }
        guard isAuthorizedArtifactPresentation(destination) else { throw HermesServiceError.staleConversation }
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

    func create(_ draft: BotDraft, onFailure: (@MainActor (any Error) -> Void)? = nil) async -> BotProfile? {
        guard isConnected, !Task.isCancelled else { return nil }
        let owner = generation
        do {
            let bot = try await service.createBot(draft)
            guard generation == owner, !Task.isCancelled else { return nil }
            let published = await refreshBots()
            guard generation == owner, !Task.isCancelled else { return nil }
            guard published, cachedBots.contains(where: { $0.id == bot.id }) else {
                notice = "Your bot was created, but Botto couldn’t load it in the inbox. Refresh the inbox before creating another bot."
                onFailure?(HermesServiceError.partialCreation)
                return nil
            }
            return bot
        } catch {
            if generation == owner, !Task.isCancelled {
                notice = error.localizedDescription
                if !(error is CancellationError) { onFailure?(error) }
            }
            return nil
        }
    }

    func setActive(_ value: Bool) async {
        active = value
        #if DEBUG
        if value, isDemo, ProcessInfo.processInfo.arguments.contains("--demo-offline") { return }
        #endif
        if !value {
            push.deactivate()
            flush()
            service.disconnect()
            chats.retireConnection()
            generation = UUID(); retireRefresh(); link = configuration == nil ? .unconfigured : .connecting
            connectingConfiguration = nil
        } else {
            // Local persistence can recover after unlocking even if the network cannot.
            flush()
            if started, !isConnected, connectingConfiguration == nil, let configuration { await connect(configuration) }
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
        if let oldID { artifactCache.discard(configurationID: oldID) }
        else { artifactCache.prune(reachableConfigurationIDs: []) }
        Task { [weak self, artifactCache] in
            do { try await artifactCache.drainMaintenance() }
            catch { self?.notice = "Saved setup was removed, but artifact cleanup couldn’t finish. Botto will retry when it opens again." }
        }
        retireAvatarWorkspace(ifReplacingWith: nil)
        generation = UUID(); retireRefresh()
        service.onEvent = nil; service.disconnect()
        cacheTask?.cancel()
        avatars.reset()
        configuration = nil; serverInfo = nil; mount(.init(), configuration: nil); selectedBotID = nil
        connectingConfiguration = nil
        rotatedConfigurations = [:]
        isDemo = false; link = .unconfigured; connectionError = nil; savedSetupLoadFailed = false
        if let oldID, !protectedCaches.contains(oldID) { LocalHistory.remove(for: oldID) }
        cleanHistory(keeping: nil)
        demoConnectionID = nil
        service = liveService
        bindPushNotifications()
    }

    func enterDemo() async {
        guard flush() else { return }
        push.deactivate()
        retireAvatarWorkspace(ifReplacingWith: nil)
        service.disconnect(); service = DemoBotService()
        isDemo = true
        let demo = ConnectionConfiguration(serverURL: URL(string: "https://demo.botto.local")!)
        demoConnectionID = demo.id
        await connect(demo)
    }

    func leaveDemo() {
        retireAvatarWorkspace(ifReplacingWith: nil)
        service.onEvent = nil; service.disconnect(); service = liveService
        generation = UUID(); retireRefresh(); isDemo = false; configuration = nil; mount(.init(), configuration: nil)
        demoConnectionID = nil
        avatars.reset()
        selectedBotID = nil; link = .unconfigured
        loadSavedSetup()
        bindPushNotifications()
    }

    private func receive(_ event: BotServiceEvent) {
        switch event {
        case .conversation(let chat):
            chats.receive(chat); richReplies?.reconcileCanonicalConversation()
        case .activity(let profile, let observations):
            chats.applyActivity(profile: profile, observations: observations)
        case .activityBatch(let updates):
            chats.applyActivity(updates)
        case .conversationDirectoryChanged(let profile):
            library.invalidateRevalidation()
            chats.invalidateActivityDirectory(profile)
            Task { await refresh() }
        case .botsChanged:
            library.invalidateRevalidation()
            Task { await refresh() }
        case .configuration(let updated):
            rotatedConfigurations[updated.id] = updated
            if updated.id == connectingConfiguration?.id, updated.serverURL == connectingConfiguration?.serverURL {
                connectingConfiguration = updated
            }
            if updated.id == configuration?.id {
                retireAvatarWorkspace(ifReplacingWith: updated)
                if configuration.map(Self.richReplyAccount) != Self.richReplyAccount(updated) {
                    push.retireConnection()
                    retireArtifactPresentation()
                    chats.retireConnection()
                }
                if updated.serverURL == configuration?.serverURL { configuration = updated }
            }
            do {
                // A retired refresh can still consume its old token. Update that saved
                // connection even while a different workspace or the demo is visible.
                try persistSavedRotation()
            } catch {
                generation = UUID(); connectingConfiguration = nil
                service.disconnect(); chats.retireConnection(); retireRefresh()
                link = configuration == nil ? .unconfigured : .offline
                notice = error.localizedDescription; connectionError = error.localizedDescription
            }
        case .disconnected(let reason):
            retireRefresh()
            chats.retireConnection(allowRecoveryPublication: active && !showsConnection && connectingConfiguration == nil)
            attachmentRecoveryGeneration = UUID()
            link = .offline; connectionError = reason
            for index in cachedBots.indices { cachedBots[index].status = .idle }
        case .connected(let info):
            guard active, connectingConfiguration == nil else { return }
            serverInfo = info; link = .online; connectionError = nil; chats.setOnline(true)
            Task { await refresh() }
        }
    }

    private func persistSavedRotation() throws {
        guard !rotatedConfigurations.isEmpty else { return }
        // New candidates remain transactional: commit them only after connect succeeds.
        // Their retained token still replaces any stale caller input on a later attempt.
        if let saved = try persistence.load(), let rotated = rotatedConfigurations[saved.id],
           saved.serverURL == rotated.serverURL, saved != rotated {
            try persistence.save(rotated)
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
    private static func richReplyAccount(_ configuration: ConnectionConfiguration) -> [Data?] {
        [configuration.serverURL.absoluteString, configuration.installID, configuration.username,
         configuration.nativeCredential?.provider ?? "basic"].map { $0.map { Data($0.utf8) } }
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
            throw HermesServiceError.staleConversation
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
