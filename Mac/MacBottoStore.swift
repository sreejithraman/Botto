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
    var freshDraft = ""
    var freshName = ""
    var freshFiles: [URL] = []
    private var freshCreatedSpace: String?
    private var pendingMutationNotice: String?

    private struct ProseWorkspace: Equatable {
        let profile: String
        let root: String
    }
    private(set) var models: [T3ModelOption] = []
    /// Files Botto saved under outputs/, loaded when something needs them.
    private(set) var outputs: [T3OutputFile]?
    private(set) var routines: [T3ScheduledRoutine]?
    private(set) var isConnected = false
    private(set) var isConnecting = false
    private(set) var isOpeningChannel = false
    private(set) var isStartingSpace = false
    private(set) var isSending = false
    private(set) var isStopping = false
    private(set) var respondingRequestIDs: Set<String> = []
    private(set) var stagedAttachments: [MacStagedAttachment] = []
    private(set) var error: String?
    /// The trailing Botto inspector (⌘I).
    var showsInspector = false
    /// The model the next new space starts with. Nil keeps Botto's default.
    var freshModel: T3ModelOption?

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

    private let service = T3BotService()
    private let exchange = T3PairingExchange()
    private let session: MacSessionPersistence
    private var connectionID = UUID()
    private var openID = UUID()
    private var sessionWrite: Task<Void, Never>?

    init(session: MacSessionPersistence = MacSessionPersistence()) {
        self.session = session
        service.onEvent = { [weak self] event in self?.receive(event) }
    }

    // MARK: Connection

    func connect(to server: LocalT3ServerManager, pairingAgain: Bool = false) async {
        guard server.state == .running, !isConnected, !isConnecting else { return }
        let attempt = UUID()
        connectionID = attempt
        error = nil
        isConnecting = true
        defer { if connectionID == attempt { isConnecting = false } }

        do {
            let origin = server.loopbackOrigin
            let session = session
            await sessionWrite?.value
            let saved = pairingAgain ? nil : await Task.detached { session.load() }.value
            try checkConnection(attempt)
            if let data = saved, let stored = try? JSONDecoder().decode(T3Connection.self, from: data) {
                _ = try await service.connect(configuration: .init(serverURL: origin, t3: stored))
            } else {
                try await pairAndConnect(to: server, attempt: attempt)
            }
            try checkConnection(attempt)
            bot = try await service.bots().first
            try checkConnection(attempt)
            channels = service.currentT3Channels
            isConnected = true
            isConnecting = false
            Task { await loadModels() }
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
        bot = nil
        channels = []
        openedConversation = nil
        brain = nil
        models = []
        outputs = nil
        routines = nil
        isConnected = false
        isConnecting = false
        isOpeningChannel = false
        isStartingSpace = false
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
            let profile = try ExactID(bot.id)
            let target: SessionTarget
            if let id {
                let thread = try ExactID(id)
                target = .stored(.init(profile: profile, root: thread, stored: thread, aliases: []))
            } else {
                target = .canonical(profile: profile, expectedRoot: nil)
            }
            let opened = try await service.openChat(target)
            guard openID == attempt else { return }
            selectedChannelID = opened.identity.stored.text
            if openedConversation?.access != opened.access { openedConversation = opened }
        } catch T3ServiceError.missingModel where id == nil {
            return
        } catch {
            if openID == attempt, !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    /// Leaves the open space for the new-space page. Nothing is created until it has a name or a message.
    func showFreshPage() {
        openID = UUID()
        selectedChannelID = nil
        openedConversation = nil
        stagedAttachments.removeAll()
        isOpeningChannel = false
        freshModel = nil
        error = nil
    }

    /// Starts a space from the new-space page: create, open, attach, then send the first message.
    /// Without a name, T3 names it from that message; with one, the message is optional.
    /// Returns the created space when its first message did not go out, so the caller can keep the draft there.
    func startSpace(named name: String = "", text: String, files: [URL]) async -> (spaceID: String?, sent: Bool) {
        guard pendingMutationNotice == nil else { error = pendingMutationNotice; return (nil, false) }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isConnected, !isStartingSpace, !text.isEmpty || !files.isEmpty || !name.isEmpty else { return (nil, false) }
        let connection = connectionID
        let navigation = openID
        let model = freshModel
        isStartingSpace = true
        defer { if connectionID == connection { isStartingSpace = false } }
        let id: String
        if let created = freshCreatedSpace {
            guard channels.contains(where: { $0.id == created && !$0.isArchived }) else {
                error = T3ServiceError.missingChannel.localizedDescription
                return (created, false)
            }
            id = created
        } else {
            var created: String?
            let current = await perform {
                created = try await service.createChat(title: name.isEmpty ? nil : name).summary.identity.stored.text
            }
            guard let created else { return (nil, false) }
            freshCreatedSpace = created
            guard current else { return (created, false) }
            id = created
        }
        channels = service.currentT3Channels
        guard openID == navigation else { return (id, false) }
        if let model {
            guard await perform({
                try await service.setChannelModel(threadID: id, providerInstanceID: model.providerInstanceID, model: model.modelID)
            }) else { return (id, false) }
        }
        guard connectionID == connection, openID == navigation else { return (id, false) }
        freshModel = nil
        await openChannel(id)
        guard connectionID == connection, let opened = openedConversation, opened.identity.stored.text == id else {
            return (id, false)
        }
        if text.isEmpty, files.isEmpty {
            freshCreatedSpace = nil
            return (id, true)
        }
        let batch = await attach(files)
        guard connectionID == connection, batch.count == files.count else { return (id, false) }
        let sent = await send(text: text, firstSend: (opened.access, batch))
        if sent { freshCreatedSpace = nil }
        return (id, sent)
    }

    @discardableResult
    func send(text: String, firstSend: (access: ConversationAccess, files: [ChatAttachment])? = nil) async -> Bool {
        guard pendingMutationNotice == nil else { error = pendingMutationNotice; return false }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = readyAttachments
        guard !text.isEmpty || !attachments.isEmpty, !isSending, stagedAttachments.count == attachments.count,
              selectedChannel?.isArchived != true,
              let access = openedConversation?.access else { return false }
        if let firstSend, access != firstSend.access || attachments != firstSend.files { return false }
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
    @discardableResult
    func attach(_ urls: [URL]) async -> [ChatAttachment] {
        guard let access = openedConversation?.access, selectedChannel?.isArchived != true else { return [] }
        var batch: [ChatAttachment] = []
        let channel = selectedChannelID
        error = nil
        for url in urls where url.isFileURL {
            guard stagedAttachments.count < AttachmentLimits.count else {
                error = AttachmentLimits.message
                return batch
            }
            let name = url.lastPathComponent
            let mimeType = MacAttachmentKind.mimeType(for: url)
            let read = await Task.detached { () -> Result<Data, any Error> in
                Result { try Data(contentsOf: url, options: .mappedIfSafe) }
            }.value
            guard selectedChannelID == channel, openedConversation?.access == access else { return batch }
            let data: Data
            switch read {
            case .success(let loaded): data = loaded
            case .failure:
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
                      let index = stagedAttachments.firstIndex(where: { $0.id == item.id }) else { return batch }
                stagedAttachments[index].state = .ready(uploaded)
                batch.append(uploaded)
            } catch {
                guard let index = stagedAttachments.firstIndex(where: { $0.id == item.id }) else { return batch }
                stagedAttachments[index].state = .failed(error.localizedDescription)
            }
        }
        return batch
    }

    func dismissError() {
        pendingMutationNotice = nil
        error = nil
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
        await perform {
            let snapshot = try await service.loadBotBrain()
            try checkConnection(connection)
            brain = snapshot
            guard let bot else { return }
            let scope = ProseWorkspace(profile: bot.id, root: snapshot.workspaceRoot)
            if proseWorkspace != scope {
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
    func createRoutine(name: String, prompt: String, cron: String) async throws {
        let routine = try await live { try await service.createRoutine(name: name, prompt: prompt, cron: cron, threadID: nil) }
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
            if connectionID == connection {
                if case HermesServiceError.uncertain = error { pendingMutationNotice = error.localizedDescription }
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
            return false
        }
    }

    private func pairAndConnect(to server: LocalT3ServerManager, attempt: UUID) async throws {
        let configuration: ConnectionConfiguration
        if let startup = server.startupLinks.pairingURL {
            do {
                configuration = try await redeem(startup, using: server.loopbackOrigin)
            } catch where Self.invalidPairingCredential(error) {
                try checkConnection(attempt)
                configuration = try await redeem(server.mintPairingLink(), using: server.loopbackOrigin)
            }
        } else {
            configuration = try await redeem(server.mintPairingLink(), using: server.loopbackOrigin)
        }
        try checkConnection(attempt)
        _ = try await service.connect(configuration: configuration)
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
            isConnected = true
            isConnecting = false
            error = pendingMutationNotice
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
            openID = UUID()
            openedConversation = nil
            isConnected = false
            isConnecting = false
            isOpeningChannel = false
            isStartingSpace = false
            isSending = false
            isStopping = false
            respondingRequestIDs.removeAll()
            stagedAttachments.removeAll()
            error = reason
        default: break
        }
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
