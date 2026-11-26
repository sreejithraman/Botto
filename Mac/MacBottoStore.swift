import BottoCore
import Foundation
import Observation
import Security
import UniformTypeIdentifiers

@MainActor @Observable
final class MacBottoStore {
    private(set) var bot: BotProfile?
    private(set) var channels: [T3ChannelSummary] = []
    /// The open space. Nil shows the new-space page.
    private(set) var selectedChannelID: String?
    private(set) var openedConversation: OpenedConversation?
    private(set) var brain: T3BotBrainSnapshot?
    private(set) var soulDraft: MacAutosaver?
    private(set) var memoryDraft: MacAutosaver?
    private var proseWorkspace: ProseWorkspace?
    var drafts: [String: String] = [:]
    let fresh = MacFreshDraft()
    private(set) var pendingMutationNotice: String?

    private struct ProseWorkspace: Equatable {
        let profile: String
        let root: String
    }
    private(set) var models: [T3ModelOption] = []
    /// Nil until the engine has looked for providers on this Mac.
    private(set) var providers: [T3ProviderStatus]?
    private(set) var isCheckingProviders = false
    /// Files Botto saved under outputs/, loaded when something needs them.
    private(set) var outputs: [T3OutputFile]?
    private(set) var routines: [T3ScheduledRoutine]?
    private(set) var isConnected = false
    private(set) var isConnecting = false
    private(set) var isOpeningChannel = false
    private(set) var isSending = false
    private(set) var isStopping = false
    private(set) var respondingRequestIDs: Set<String> = []
    private(set) var stagedAttachments: [MacStagedAttachment] = []
    private(set) var error: String?
    /// The trailing Botto inspector (⌘I).
    var showsInspector = false

    var selectedChannel: T3ChannelSummary? { channels.first { $0.id == selectedChannelID } }
    /// Botto's folder. The local engine runs on this Mac, so the path is a real local folder.
    var workspaceRoot: String? { brain?.workspaceRoot ?? service.currentBotWorkspaceRoot }
    var isUploading: Bool { stagedAttachments.contains { $0.state == .uploading } }
    var readyAttachments: [ChatAttachment] { stagedAttachments.compactMap(\.uploaded) }
    /// Aggregate liveliness for the face: any space that needs the user wins over work.
    var botStatus: BotStatus {
        let live = channels.filter { !$0.isArchived }
        if live.contains(where: { $0.status == .waiting }) { return .waiting }
        if live.contains(where: { $0.status == .working }) { return .working }
        return bot?.status ?? .idle
    }

    /// Nobody has named this bot yet, so it introduces itself before anything else. Setup that stopped partway
    /// stays up to be tried again.
    var needsBotSetup: Bool {
        isConnected && (settingUpBot || bot.map { T3FirstRun.needsBotSetup($0, spaces: channels) } ?? false)
    }
    private var settingUpBot = false
    /// The last look failed, or found nothing that can answer yet.
    var wantsProviderCheck: Bool { isConnected && (providers == nil || models.isEmpty || !providersNeedingSetup.isEmpty) }
    /// Claude and Codex, when neither they nor any other provider can answer yet.
    var providersNeedingSetup: [T3ProviderStatus] { isConnected ? T3FirstRun.providersNeedingSetup(providers ?? []) : [] }
    /// Without a conversation there is nothing to keep on screen, so provider help can have the whole page.
    var hasStartedTalking: Bool { channels.contains(where: \.hasMessages) }
    /// The guide has the window's detail, so a new space has nowhere to open.
    /// A first send keeps its page.
    var showsProviderGuide: Bool { !providersNeedingSetup.isEmpty && !hasStartedTalking && !fresh.ownsFirstSend }
    var canStartSpace: Bool { isConnected && !showsProviderGuide }

    private let service: any T3BotBrainControlling
    private var pushService: T3BotService? { service as? T3BotService }

    func observePush(_ activity: @escaping (T3PushActivity) -> Void) {
        pushService?.onPushActivity = activity
    }

    @ObservationIgnored var onPushScope: ((T3PushScope?) -> Void)?
    private let exchange = T3PairingExchange()
    private let session: MacSessionPersistence
    private var connectionID = UUID()
    private var openID = UUID()
    private var sessionWrite: Task<Void, Never>?

    init(session: MacSessionPersistence = MacSessionPersistence(), service: any T3BotBrainControlling = T3BotService()) {
        self.session = session
        self.service = service
        service.onEvent = { [weak self] event in self?.receive(event) }
    }

    // MARK: Connection

    func connect(to server: LocalT3ServerManager, pairingAgain: Bool = false) async {
        guard server.state == .running else { return }
        await connect(origin: server.loopbackOrigin, pairingAgain: pairingAgain) { try await self.pair(with: server, attempt: $0) }
    }

    /// Connects with the saved session, or with a newly paired one when there is none.
    func connect(origin: URL, pairingAgain: Bool = false, pair: (_ attempt: UUID) async throws -> ConnectionConfiguration) async {
        guard !isConnected, !isConnecting else { return }
        let attempt = UUID()
        connectionID = attempt
        error = nil
        isConnecting = true
        defer { if connectionID == attempt { isConnecting = false } }

        do {
            let session = session
            await sessionWrite?.value
            let saved = pairingAgain ? nil : await Task.detached { session.load() }.value
            try checkConnection(attempt)
            if let data = saved, let stored = try? JSONDecoder().decode(T3Connection.self, from: data) {
                _ = try await service.connect(configuration: .init(serverURL: origin, t3: stored))
            } else {
                let paired = try await pair(attempt)
                try checkConnection(attempt)
                _ = try await service.connect(configuration: paired)
            }
            try checkConnection(attempt)
            bot = try await service.bots().first
            try checkConnection(attempt)
            channels = service.currentT3Channels
            isConnected = true
            isConnecting = false
            lookAround()
            if selectedChannelID == nil, fresh.createdSpace != nil { return }
            // Reopen the space from before a restart, else one that needs attention, else the main space.
            // The new-space page only stands in when the host can't hold a main space yet.
            if !channels.contains(where: { $0.isMain }) {
                await openChannel(nil)
            } else if let id = selectedChannelID, channels.contains(where: { $0.id == id }) {
                await openChannel(id)
            } else if let initial = T3ChatShelf.initialSpace(channels) {
                await openChannel(initial.id)
            }
        } catch {
            guard connectionID == attempt else { return }
            service.disconnect()
            isConnected = false
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    func disconnect() {
        connectionID = UUID()
        openID = UUID()
        service.disconnect()
        onPushScope?(nil)
        bot = nil
        channels = []
        openedConversation = nil
        brain = nil
        models = []
        providers = nil
        isCheckingProviders = false
        outputs = nil
        routines = nil
        isConnected = false
        isConnecting = false
        isOpeningChannel = false
        isSending = false
        isStopping = false
        respondingRequestIDs.removeAll()
        stagedAttachments.removeAll()
        error = nil
    }

    // MARK: Spaces

    func openChannel(_ id: String?) async {
        guard isConnected, let bot,
              !(selectedChannelID == id && (openedConversation != nil || isOpeningChannel)) else { return }
        let attempt = UUID()
        openID = attempt
        selectedChannelID = id
        openedConversation = nil
        stagedAttachments.removeAll()
        isOpeningChannel = true
        error = nil
        defer { if openID == attempt { isOpeningChannel = false } }
        do {
            let opened = try await readChannel(id, bot: bot)
            guard openID == attempt else { return }
            selectedChannelID = opened.identity.stored.text
            if openedConversation?.access != opened.access { openedConversation = opened }
        } catch T3ServiceError.missingModel where id == nil {
            return
        } catch {
            if openID == attempt, !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    private func readChannel(_ id: String?, bot: BotProfile) async throws -> OpenedConversation {
        let profile = try ExactID(bot.id)
        guard let id else { return try await service.openChat(.canonical(profile: profile, expectedRoot: nil)) }
        let thread = try ExactID(id)
        return try await service.openChat(.stored(.init(profile: profile, root: thread, stored: thread, aliases: [])))
    }

    /// Leaves the open space for the new-space page. Nothing is created until it has a name or a message.
    func showFreshPage() {
        openID = UUID()
        selectedChannelID = nil
        openedConversation = nil
        stagedAttachments.removeAll()
        isOpeningChannel = false
        error = nil
    }

    func startSpace() async {
        guard pendingMutationNotice == nil, isConnected, selectedChannelID == nil, let bot else { return }
        let navigation = openID
        var completed: String?
        await perform {
            completed = try await fresh.submit { title in
                let created = try await service.createChat(title: title)
                channels = service.currentT3Channels
                return created.summary.identity.stored.text
            } send: { id, text, files, model in
                guard openID == navigation else { throw CancellationError() }
                guard channels.contains(where: { $0.id == id && !$0.isArchived }) else {
                    throw T3ServiceError.missingChannel
                }
                if let model {
                    try await service.setChannelModel(threadID: id, providerInstanceID: model.providerInstanceID, model: model.modelID)
                }
                guard !text.isEmpty || !files.isEmpty else { return }
                let opened = try await readChannel(id, bot: bot)
                let attachments = try await uploadFreshFiles(files, access: opened.access)
                guard openID == navigation else { throw CancellationError() }
                _ = try await service.send(text: text, attachments: attachments, delivery: .queue,
                                           access: opened.access, operationID: UUID())
            }
        }
        if let completed, openID == navigation { await openChannel(completed) }
    }

    @discardableResult
    func send(text: String) async -> Bool {
        guard pendingMutationNotice == nil else { return false }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = readyAttachments
        guard !text.isEmpty || !attachments.isEmpty, !isSending, stagedAttachments.count == attachments.count,
              selectedChannel?.isArchived != true,
              let access = openedConversation?.access else { return false }
        let connection = connectionID
        isSending = true
        defer { if connectionID == connection { isSending = false } }
        let sent = await perform {
            _ = try await service.send(text: text, attachments: attachments, delivery: .queue,
                                       access: access, operationID: UUID())
        }
        if sent, openedConversation?.access == access {
            let sentIDs = Set(attachments.map(\.id))
            stagedAttachments.removeAll { $0.uploaded.map { sentIDs.contains($0.id) } ?? false }
        }
        return sent
    }

    /// Reads, checks and uploads local files into the open space's staging area.
    func attach(_ urls: [URL]) async {
        guard let access = openedConversation?.access, selectedChannel?.isArchived != true else { return }
        let channel = selectedChannelID
        error = nil
        for url in urls where url.isFileURL {
            guard stagedAttachments.count < AttachmentLimits.count else {
                error = AttachmentLimits.message
                return
            }
            let name = url.lastPathComponent
            let mimeType = MacAttachmentKind.mimeType(for: url)
            let loaded = try? await Self.readLocalFile(url)
            guard selectedChannelID == channel, openedConversation?.access == access else { return }
            guard let data = loaded else {
                error = "Couldn’t read “\(name)”."
                continue
            }
            let staged = stagedAttachments.reduce(0) { $0 + $1.byteCount }
            let limit = MacAttachmentKind.isImage(mimeType) ? 10 * 1024 * 1024 : AttachmentLimits.fileBytes
            guard !data.isEmpty, data.count <= limit, staged + data.count <= AttachmentLimits.totalBytes else {
                error = data.isEmpty ? "“\(name)” is empty." : AttachmentLimits.message
                continue
            }
            let item = MacStagedAttachment(name: name, mimeType: mimeType, byteCount: data.count)
            stagedAttachments.append(item)
            do {
                let uploaded = try await service.upload(data: data, filename: name, mimeType: mimeType, access: access)
                guard selectedChannelID == channel, openedConversation?.access == access,
                      let index = stagedAttachments.firstIndex(where: { $0.id == item.id }) else { return }
                stagedAttachments[index].state = .ready(uploaded)
            } catch {
                guard let index = stagedAttachments.firstIndex(where: { $0.id == item.id }) else { return }
                stagedAttachments[index].state = .failed(error.localizedDescription)
            }
        }
    }

    private func uploadFreshFiles(_ urls: [URL], access: ConversationAccess) async throws -> [ChatAttachment] {
        guard urls.count <= AttachmentLimits.count else { throw ConversationServiceError.attachmentLimit }
        var attachments: [ChatAttachment] = []
        var bytes = 0
        for url in urls {
            let data = try await Self.readLocalFile(url)
            bytes += data.count
            guard bytes <= AttachmentLimits.totalBytes else { throw ConversationServiceError.attachmentLimit }
            let attachment = try await service.upload(data: data, filename: url.lastPathComponent,
                                                      mimeType: MacAttachmentKind.mimeType(for: url), access: access)
            attachments.append(attachment)
        }
        return attachments
    }

    private static func readLocalFile(_ url: URL) async throws -> Data {
        try await Task.detached { try Data(contentsOf: url, options: .mappedIfSafe) }.value
    }

    func dismissError() {
        error = nil
    }

    func acknowledgeUncertainAction() {
        pendingMutationNotice = nil
    }

    func recordMutationFailure(_ failure: any Error) {
        if case ConversationServiceError.uncertain = failure {
            pendingMutationNotice = failure.localizedDescription
        } else if !(failure is CancellationError) {
            error = failure.localizedDescription
        }
    }

    func removeStagedAttachment(_ id: UUID) {
        stagedAttachments.removeAll { $0.id == id }
    }

    func stop() async {
        guard !isStopping, let access = openedConversation?.access else { return }
        let connection = connectionID
        isStopping = true
        defer { if connectionID == connection { isStopping = false } }
        await perform { _ = try await service.stop(access: access, operationID: UUID()) }
    }

    func respond(to request: PendingRequest, response: RequestResponse) async {
        guard !respondingRequestIDs.contains(request.id), let access = openedConversation?.access else { return }
        let connection = connectionID
        respondingRequestIDs.insert(request.id)
        defer { if connectionID == connection { respondingRequestIDs.remove(request.id) } }
        await perform {
            _ = try await service.respond(to: request, response: response, access: access, operationID: UUID())
        }
    }

    @discardableResult
    func renameChannel(threadID: String, title: String) async -> Bool {
        await perform { try await service.renameChannel(threadID: threadID, title: title) }
    }

    func setChannelPinned(threadID: String, pinned: Bool) async {
        await perform { try await service.setChannelPinned(threadID: threadID, pinned: pinned) }
    }

    func archiveChannel(threadID: String, archived: Bool) async {
        await perform { try await service.archiveChannel(threadID: threadID, archived: archived) }
    }

    func markRead(threadID: String) async {
        await perform { try await service.markChannelVisited(threadID: threadID) }
    }

    /// Switches the open space's model. Other spaces keep their own.
    func setChannelModel(_ option: T3ModelOption) async {
        guard let id = selectedChannelID else { return }
        await perform {
            try await service.setChannelModel(threadID: id, providerInstanceID: option.providerInstanceID, model: option.modelID)
        }
    }

    /// The label for a space's model chip: the host's name for it when known.
    func modelLabel(for chat: T3ChannelSummary?) -> String {
        if let chat, let model = chat.model {
            return models.first { $0.modelID == model && (chat.providerInstanceID == nil || $0.providerInstanceID == chat.providerInstanceID) }?
                .label ?? model
        }
        if let model = bot?.model { return models.first { $0.modelID == model }?.label ?? model }
        return "Automatic"
    }

    func downloadAttachment(_ attachment: ChatAttachment) async throws -> DownloadedArtifact {
        guard let access = openedConversation?.access else { throw T3ServiceError.disconnected }
        return try await live { try await service.downloadArtifact(attachment, access: access) }
    }

    // MARK: Botto

    func loadBrain() async {
        let connection = connectionID
        let soulRevision = soulDraft?.refreshRevision
        let memoryRevision = memoryDraft?.refreshRevision
        await perform {
            let snapshot = try await service.loadBotBrain()
            try checkConnection(connection)
            brain = snapshot
            guard let bot else { return }
            let scope = ProseWorkspace(profile: bot.id, root: snapshot.workspaceRoot)
            if proseWorkspace == scope {
                soulDraft?.refresh(snapshot.soulMarkdown, revision: soulRevision)
                memoryDraft?.refresh(snapshot.memoryMarkdown, revision: memoryRevision)
            } else {
                proseWorkspace = scope
                soulDraft = MacAutosaver(initial: snapshot.soulMarkdown) { [weak self] value, expected in
                    guard let self, self.ownsProse(scope) else { throw T3ServiceError.disconnected }
                    try await self.saveSoul(value, replacing: expected)
                }
                memoryDraft = MacAutosaver(initial: snapshot.memoryMarkdown) { [weak self] value, expected in
                    guard let self, self.ownsProse(scope) else { throw T3ServiceError.disconnected }
                    try await self.saveMemory(value, replacing: expected)
                }
            }
        }
    }

    private func ownsProse(_ scope: ProseWorkspace) -> Bool {
        bot?.id == scope.profile && service.currentBotWorkspaceRoot == scope.root
    }

    var hasUnsavedProse: Bool { soulDraft?.hasUnsavedEdits == true || memoryDraft?.hasUnsavedEdits == true }

    func flushProse() async {
        async let soul: Void? = soulDraft?.flush()
        async let memory: Void? = memoryDraft?.flush()
        _ = await (soul, memory)
    }

    func loadModels() async {
        guard isConnected, let options = try? await live({ try await service.availableModels() }) else { return }
        models = options
    }

    /// Has the engine look for providers that work.
    func loadProviders() async {
        guard isConnected, !isCheckingProviders else { return }
        let connection = connectionID
        isCheckingProviders = true
        defer { if connectionID == connection { isCheckingProviders = false } }
        guard let found = try? await live({ try await service.providers() }), connectionID == connection else { return }
        let hadNone = models.isEmpty || !providersNeedingSetup.isEmpty
        let hadNoSpace = channels.isEmpty
        providers = found
        // A provider that just became ready brings its models, and with them the main space.
        guard hadNone, providersNeedingSetup.isEmpty else { return }
        await loadModels()
        guard connectionID == connection else { return }
        channels = service.currentT3Channels
        // Someone on the new-space page keeps it.
        if hadNoSpace { await openInitialSpace() }
    }

    private func openInitialSpace() async {
        guard selectedChannelID == nil, !fresh.ownsFirstSend, let initial = T3ChatShelf.initialSpace(channels) else { return }
        await openChannel(initial.id)
    }

    /// What this connection can think with.
    private func lookAround() {
        Task {
            await loadModels()
            await loadProviders()
        }
    }

    func loadOutputs() async {
        guard isConnected, let files = try? await live({ try await service.listOutputs() }) else { return }
        outputs = files
    }

    func downloadOutput(_ output: T3OutputFile) async throws -> DownloadedArtifact {
        try await live { try await service.downloadOutput(output) }
    }

    func readSkill(relativePath: String) async throws -> String {
        try await live { try await service.readProjectFile(relativePath: relativePath) }
    }

    /// Debounced autosaves call these; the service applies them in order.
    func saveSoul(_ markdown: String, replacing expected: String? = nil) async throws {
        try await live { try await service.saveSoul(markdown, replacing: expected) }
        if let brain {
            self.brain = .init(manifest: brain.manifest, soulMarkdown: markdown, memoryMarkdown: brain.memoryMarkdown,
                               skills: brain.skills, workspaceRoot: brain.workspaceRoot)
        }
    }

    func saveMemory(_ markdown: String, replacing expected: String? = nil) async throws {
        try await live { try await service.saveMemory(markdown, replacing: expected) }
        if let brain {
            self.brain = .init(manifest: brain.manifest, soulMarkdown: brain.soulMarkdown, memoryMarkdown: markdown,
                               skills: brain.skills, workspaceRoot: brain.workspaceRoot)
        }
    }

    func renameBot(_ name: String) async throws {
        guard let bot else { throw T3ServiceError.disconnected }
        self.bot = try await live { try await service.updateProfile(.init(name: name), for: bot) }
    }

    /// The first-run page: names the bot and its main space and keeps the face.
    func setUpBot(name: String, face: BotFace) async throws {
        settingUpBot = true
        let refreshed = try await live { () -> BotProfile? in
            try await service.setUpBot(name: name, face: face)
            return try await service.bots().first
        }
        if let refreshed { bot = refreshed }
        channels = service.currentT3Channels
        settingUpBot = false
        // The main space can appear after connecting, and saying hello leads there.
        await openInitialSpace()
    }

    func setLook(_ choice: BotAvatarChoice) async throws {
        guard let bot else { throw T3ServiceError.disconnected }
        self.bot = try await live { try await service.setAvatar(choice, for: bot) }
    }

    /// Nil is "Automatic": the host's default model.
    func setDefaultModel(_ option: T3ModelOption?) async throws {
        let manifest = try await live { try await service.setDefaultModel(option) }
        if let brain {
            self.brain = .init(manifest: manifest, soulMarkdown: brain.soulMarkdown, memoryMarkdown: brain.memoryMarkdown,
                               skills: brain.skills, workspaceRoot: brain.workspaceRoot)
        }
        if let profile = try? await live({ try await service.bots().first }) { bot = profile }
    }

    func loadRoutines() async {
        guard isConnected, let loaded = try? await live({ try await service.listRoutines() }) else { return }
        routines = loaded
    }

    func setRoutineEnabled(_ routine: T3ScheduledRoutine, enabled: Bool) async throws {
        try await live { try await service.setRoutineEnabled(id: routine.id, enabled: enabled) }
        await loadRoutines()
    }

    func deleteRoutine(_ routine: T3ScheduledRoutine) async throws {
        try await live { try await service.deleteRoutine(id: routine.id) }
        routines?.removeAll { $0.id == routine.id }
    }

    /// A routine without a space gets its own, named after it.
    func createRoutine(name: String, prompt: String, schedule: T3RoutineSchedule) async throws {
        let routine = try await live { try await service.createRoutine(name: name, prompt: prompt, schedule: schedule, threadID: nil) }
        routines = (routines ?? []).filter { $0.id != routine.id } + [routine]
        channels = service.currentT3Channels
    }

    // MARK: Plumbing

    /// Runs one host call for the current connection, so a late reply can't land in a newer one.
    private func live<Value>(_ action: () async throws -> Value) async throws -> Value {
        guard isConnected else { throw T3ServiceError.disconnected }
        let connection = connectionID
        let value = try await action()
        try checkConnection(connection)
        return value
    }

    @discardableResult
    private func perform(_ action: () async throws -> Void) async -> Bool {
        guard isConnected else { return false }
        let connection = connectionID
        error = nil
        do {
            try await action()
            try checkConnection(connection)
            return true
        } catch {
            if (error as? ConversationServiceError) == .uncertain || (connectionID == connection && !Task.isCancelled) {
                recordMutationFailure(error)
            }
            return false
        }
    }

    private func pair(with server: LocalT3ServerManager, attempt: UUID) async throws -> ConnectionConfiguration {
        if let startup = server.startupLinks.pairingURL {
            do {
                return try await redeem(startup, using: server.loopbackOrigin)
            } catch where Self.invalidPairingCredential(error) {
                try checkConnection(attempt)
            }
        }
        return try await redeem(server.mintPairingLink(), using: server.loopbackOrigin)
    }

    private func redeem(_ rawLink: String, using origin: URL) async throws -> ConnectionConfiguration {
        guard let url = T3RouteFormatter.pairingURL(from: rawLink, routeOrigin: origin) else {
            throw T3PairingError.invalidOrigin
        }
        let input = try T3PairingExchange.parse(url)
        return try await exchange.exchangePairingCredential(origin: origin, credential: input.credential,
                                                            clientLabel: "Botto for Mac").configuration
    }

    private func checkConnection(_ attempt: UUID) throws {
        try Task.checkCancellation()
        guard connectionID == attempt else { throw CancellationError() }
    }

    private func remember(_ configuration: T3Connection?) {
        guard let configuration, configuration.projectID?.isEmpty == false,
              configuration.workspaceRoot?.isEmpty == false,
              let encoded = try? JSONEncoder().encode(configuration) else { return }
        let session = session
        let previous = sessionWrite
        sessionWrite = Task.detached {
            await previous?.value
            session.save(encoded)
        }
    }

    private static func invalidPairingCredential(_ error: any Error) -> Bool {
        switch error {
        case T3PairingError.httpStatus(400), T3PairingError.httpStatus(401), T3PairingError.httpStatus(403): true
        default: false
        }
    }

    private func receive(_ event: BotServiceEvent) {
        switch event {
        case .configuration(let configuration):
            remember(configuration.t3)
        case .botsChanged:
            guard isConnected else { return }
            channels = service.currentT3Channels
            let connection = connectionID
            Task {
                let refreshed = try? await service.bots().first
                guard isConnected, connectionID == connection, let refreshed else { return }
                bot = refreshed
            }
        case .connected:
            // Connecting looks around on its own; a reconnection has to.
            if !isConnecting { lookAround() }
            onPushScope?(pushService?.currentPushScope)
            isConnected = true
            isConnecting = false
            error = nil
            channels = service.currentT3Channels
            let connection = connectionID
            Task {
                if let refreshed = try? await service.bots().first, isConnected, connectionID == connection {
                    bot = refreshed
                }
            }
        case .conversation(let opened):
            guard opened.identity.stored.text == selectedChannelID,
                  openedConversation?.access == opened.access ||
                  (openedConversation == nil && (isOpeningChannel || isConnected)) else { return }
            openedConversation = opened
        case .disconnected(let reason):
            onPushScope?(nil)
            openID = UUID()
            openedConversation = nil
            isConnected = false
            isConnecting = false
            isOpeningChannel = false
            isSending = false
            isStopping = false
            respondingRequestIDs.removeAll()
            stagedAttachments.removeAll()
            error = reason
        default: break
        }
    }
}

@MainActor @Observable
final class MacFreshDraft {
    var name = ""
    var text = ""
    var files: [URL] = []
    private(set) var model: T3ModelOption?
    private(set) var createdSpace: String?
    private(set) var isSubmitting = false

    /// A first send runs, or its space waits for the message it didn't get.
    var ownsFirstSend: Bool { isSubmitting || createdSpace != nil }
    var offersAutomaticModel: Bool { createdSpace == nil || model == nil }

    func selectModel(_ option: T3ModelOption?) {
        guard option != nil || offersAutomaticModel else { return }
        model = option
    }

    func submit(create: (String?) async throws -> String,
                send: (String, String, [URL], T3ModelOption?) async throws -> Void) async throws -> String? {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isSubmitting, !title.isEmpty || !message.isEmpty || !files.isEmpty else { return nil }
        let files = files
        let model = model
        isSubmitting = true
        defer { isSubmitting = false }
        let id: String
        if let createdSpace {
            id = createdSpace
        } else {
            id = try await create(title.isEmpty ? nil : title)
            createdSpace = id
        }
        try await send(id, message, files, model)
        createdSpace = nil
        name = ""
        text = ""
        self.files = []
        self.model = nil
        return id
    }
}

struct MacStagedAttachment: Identifiable, Equatable {
    enum State: Equatable {
        case uploading
        case ready(ChatAttachment)
        case failed(String)
    }

    let id = UUID()
    let name: String
    let mimeType: String
    let byteCount: Int
    var state: State = .uploading

    var uploaded: ChatAttachment? {
        if case .ready(let attachment) = state { attachment } else { nil }
    }
}

enum MacAttachmentKind {
    static func mimeType(for url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    static func isImage(_ mimeType: String) -> Bool {
        ["image/jpeg", "image/png", "image/webp", "image/gif"].contains(mimeType.lowercased())
    }

    static func symbol(for mimeType: String) -> String {
        let type = UTType(mimeType: mimeType)
        if type?.conforms(to: .image) == true { return "photo" }
        if type?.conforms(to: .pdf) == true { return "doc.richtext" }
        if type?.conforms(to: .movie) == true { return "film" }
        if type?.conforms(to: .audio) == true { return "waveform" }
        if type?.conforms(to: .archive) == true { return "doc.zipper" }
        if type?.conforms(to: .sourceCode) == true || type?.conforms(to: .json) == true {
            return "chevron.left.forwardslash.chevron.right"
        }
        if type?.conforms(to: .text) == true { return "doc.text" }
        return "doc"
    }
}

/// A single secret slot. The Keychain backs the app; tests substitute memory.
protocol MacSecretSlot: Sendable {
    func read() -> Data?
    @discardableResult func write(_ data: Data) -> Bool
    func delete()
}

struct MacKeychainSlot: MacSecretSlot {
    var service = "com.sree.botto.mac.local-t3"
    var account = "loopback-session"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func read() -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    func write(_ data: Data) -> Bool {
        let update = [kSecValueData as String: data] as CFDictionary
        let status = SecItemUpdate(query as CFDictionary, update)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrLabel as String] = "Botto local T3 session"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

/// Keeps the loopback session out of plaintext preferences.
/// A pre-Keychain `UserDefaults` copy moves into the slot once and is then removed.
/// When the slot refuses writes (for example an unsigned build without Keychain access),
/// the session lives in memory only and the app re-pairs with its local server on next launch.
final class MacSessionPersistence: @unchecked Sendable {
    static let legacyDefaultsKey = "localT3Session"
    private let slot: any MacSecretSlot
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var memory: Data?

    init(slot: any MacSecretSlot = MacKeychainSlot(), defaults: UserDefaults = .standard) {
        self.slot = slot
        self.defaults = defaults
    }

    func load() -> Data? {
        if let legacy = defaults.data(forKey: Self.legacyDefaultsKey) {
            defaults.removeObject(forKey: Self.legacyDefaultsKey)
            if let decoded = try? JSONDecoder().decode(T3Connection.self, from: legacy),
               decoded.projectID?.isEmpty != false || decoded.workspaceRoot?.isEmpty != false {
                lock.withLock { memory = legacy }
            } else {
                save(legacy)
            }
        }
        if let stored = slot.read() { return stored }
        return lock.withLock { memory }
    }

    func save(_ data: Data) {
        let persisted = slot.write(data)
        lock.withLock { memory = persisted ? nil : data }
    }
}
