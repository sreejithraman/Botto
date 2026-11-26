import Foundation
import BottoCore

/// A separate, labeled workspace. It never connects to a host or performs work.
@MainActor final class DemoBotService: T3BotBrainControlling {
    static let profileID = "milo"
    var onEvent: ((BotServiceEvent) -> Void)?
    private var bot = BotProfile(id: "milo", name: "Milo",
        description: "Turns loose ends into a clear next step.",
        appearance: BotAvatarChoice.face(.init(shape: .squircle, color: "#f97316")).appearance)
    private let mainID = "milo"
    private var soul = "I turn loose ends into a clear next step."
    private var memory = "This workspace contains sample projects."
    private var manifest = T3BotManifest(displayName: "Milo", mainThreadID: "milo")
    private var pinned: Set<String> = []
    private var archived: Set<String> = []
    private var visited: [String: Date] = [:]
    private var chats: [Data: Conversation] = [:]
    private var artifacts: [Data: [String: DownloadedArtifact]] = [:]
    #if DEBUG
    private var fixtureCalls: [String: Int] = [:]
    private var connectionCount = 0
    private let gateDirectory: URL?
    private var performanceReplyNumber = 0
    private var automationHandoff: ChatMessage?
    private let performanceFixture: Bool
    private let performanceChunkDelay: Duration
    private let rotatesChatAccess = ProcessInfo.processInfo.arguments.contains("--rotate-chat-access-demo")

    init(gateDirectory: URL? = nil,
         performanceFixture: Bool = ProcessInfo.processInfo.arguments.contains("--performance-demo"),
         performanceChunkDelay: Duration = .milliseconds(20)) {
        self.performanceFixture = performanceFixture
        self.performanceChunkDelay = performanceChunkDelay
        self.gateDirectory = gateDirectory ?? ProcessInfo.processInfo.environment["BOTTO_UI_TEST_BOT_GATE"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
    #endif
    private var tasks: [Data: Task<Void, Never>] = [:]
    private struct UploadGrant {
        let source: SessionIdentity
        let attachment: ChatAttachment
        let bytes: Int
    }
    private var uploads: [UUID: UploadGrant] = [:]
    private var operations: Set<UUID> = []
    private var identities: [Data: SessionIdentity] = [:]
    private var titles: [Data: String] = [:]
    private var order: [Data] = []
    private var issuer = ConversationIssuer<SessionIdentity>()
    private var selected: (identity: SessionIdentity, access: ConversationAccess)?
    private var connection = UUID()
    private var opening = UUID()
    private var connected = false
    private var activity: ConversationActivity?

    func connect(configuration: ConnectionConfiguration) async throws -> ServerInfo {
        issuer.close()
        issuer = ConversationIssuer()
        selected = nil; activity = nil; connection = UUID(); connected = false
        uploads = [:]; operations = []
        let epoch = connection
        #if DEBUG
        connectionCount += 1
        if connectionCount > 1 { try await waitForUITestFixture("connect") }
        #endif
        guard connection == epoch else { throw ConversationServiceError.staleConversation }
        connected = true
        if chats.isEmpty {
            seed()
            #if DEBUG
            if performanceFixture { seedPerformanceDemo() }
            if ProcessInfo.processInfo.arguments.contains("--automation-demo") || ProcessInfo.processInfo.arguments.contains("--automation-live-demo") { seedAutomationDemo() }
            #endif
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--attribution-demo") { seedAttributionDemo() }
            #endif
            registerSpace(mainID, title: "Main Space")
            seedSideChats()
        }
        return ServerInfo(version: "Demo")
    }
    func disconnect() {
        connected = false; connection = UUID(); selected = nil; activity = nil; issuer.close()
        uploads = [:]
    }
    func bots() async throws -> [BotProfile] {
        guard connected else { throw ConversationServiceError.disconnected }
        let epoch = connection
        let profile = try ExactID(bot.id)
        onEvent?(.activityBatch([.init(profile: profile, observations: observations(profile))]))
        guard connected, connection == epoch else { throw ConversationServiceError.staleConversation }
        return [bot]
    }


    func updateProfile(_ edit: BotProfileEdit, for profile: BotProfile) async throws -> BotProfile {
        try requireProfile(ExactID(profile.id))
        if let name = edit.name {
            bot.name = name
            manifest.displayName = name
        }
        onEvent?(.botsChanged)
        return bot
    }

    func setAvatar(_ choice: BotAvatarChoice, for profile: BotProfile) async throws -> BotProfile {
        let epoch = connection
        #if DEBUG
        try await waitForUITestFixture("avatar")
        #endif
        guard connection == epoch else { throw ConversationServiceError.staleConversation }
        try requireProfile(ExactID(profile.id))
        bot.appearance = choice.applying(to: bot.appearance ?? BotAppearance())
        bot.hasAvatar = false
        bot.lookRevision = (bot.lookRevision ?? 0) + 1
        manifest.avatar = bot.appearance
        return bot
    }

    var currentBotWorkspaceRoot: String? { nil }

    var currentT3Channels: [T3ChannelSummary] {
        order.compactMap { key in
            guard let chat = chats[key] else { return nil }
            let id = chat.storedID
            let updatedAt = chat.messages.last?.timestamp
            return T3ChannelSummary(id: id, title: titles[key] ?? "", isMain: id == mainID,
                isPinned: pinned.contains(id), isArchived: archived.contains(id),
                isUnread: updatedAt.map { $0 > (visited[id] ?? .distantPast) } ?? false,
                status: status(chat), preview: chat.messages.last?.text ?? "", updatedAt: updatedAt,
                hasMessages: !chat.messages.isEmpty)
        }
    }

    func loadBotBrain() async throws -> T3BotBrainSnapshot {
        try requireProfile(ExactID(bot.id))
        return .init(manifest: manifest, soulMarkdown: soul, memoryMarkdown: memory, skills: [], workspaceRoot: "")
    }

    func saveSoul(_ markdown: String, replacing expected: String?) async throws {
        try requireProfile(ExactID(bot.id))
        if let expected, !soul.utf8.elementsEqual(expected.utf8) { throw T3ServiceError.proseChanged }
        soul = markdown
    }

    func saveMemory(_ markdown: String, replacing expected: String?) async throws {
        try requireProfile(ExactID(bot.id))
        if let expected, !memory.utf8.elementsEqual(expected.utf8) { throw T3ServiceError.proseChanged }
        memory = markdown
    }

    func saveManifest(_ manifest: T3BotManifest) async throws {
        try requireProfile(ExactID(bot.id))
        self.manifest = manifest
    }

    func setDefaultModel(_ option: T3ModelOption?) async throws -> T3BotManifest {
        try requireProfile(ExactID(bot.id))
        guard option == nil else { throw T3ServiceError.unsupported }
        manifest.providerInstanceID = nil
        manifest.model = nil
        bot.model = nil
        return manifest
    }

    func createChat(title: String?) async throws -> CreatedSession {
        try await createConversation(profile: ExactID(bot.id), operationID: UUID(), title: title)
    }

    func renameChannel(threadID: String, title: String) async throws {
        let key = try spaceKey(threadID)
        titles[key] = title
    }

    func setChannelPinned(threadID: String, pinned: Bool) async throws {
        _ = try spaceKey(threadID)
        if pinned { self.pinned.insert(threadID) } else { self.pinned.remove(threadID) }
    }

    func archiveChannel(threadID: String, archived: Bool) async throws {
        _ = try spaceKey(threadID)
        guard threadID != mainID else { throw T3ServiceError.unsupported }
        if archived { self.archived.insert(threadID) } else { self.archived.remove(threadID) }
    }

    func markChannelVisited(threadID: String) async throws {
        _ = try spaceKey(threadID)
        visited[threadID] = .now
    }

    func availableModels() async throws -> [T3ModelOption] { [] }

    func readProjectFile(relativePath: String) async throws -> String {
        switch relativePath {
        case "SOUL.md": return soul
        case "MEMORY.md": return memory
        default: throw T3ServiceError.unsupported
        }
    }

    func listOutputs() async throws -> [T3OutputFile] {
        sampleFiles.keys.sorted().compactMap { path in
            sampleFiles[path].map { T3OutputFile(name: $0.filename, relativePath: path, mimeType: $0.mimeType) }
        }
    }

    func downloadOutput(_ output: T3OutputFile) async throws -> DownloadedArtifact {
        guard let file = sampleFiles[output.relativePath] else { throw ConversationServiceError.invalidAttachment }
        return file
    }

    private var sampleFiles: [String: DownloadedArtifact] { artifacts[Data("canvas".utf8)] ?? [:] }

    private func spaceKey(_ id: String) throws -> Data {
        try requireProfile(ExactID(bot.id))
        let key = Data(id.utf8)
        guard chats[key] != nil else { throw T3ServiceError.missingChannel }
        return key
    }


    static let sampleCharacter = try! BotAvatarGeometry(json: #"{"version":1,"id":"cat","name":"Cat","body":{"path":"M18 30 L18 14 Q18 10 24 14 L34 24 L66 24 L76 14 Q82 10 82 18 L82 72 Q82 86 68 86 L32 86 Q18 86 18 72 Z"},"eyes":{"x":50,"y":48,"spacing":16,"scale":1}}"#)

    func recentConversationHistory(_ identity: SessionIdentity) async throws -> ConversationHistoryWindow? {
        try requireProfile(identity.profile)
        guard identities[identity.root.bytes] == identity,
              let chat = chats[identity.root.bytes] else { throw ConversationServiceError.wrongConversation }
        let ids = Set(chat.messages.map { Data($0.id.utf8) })
        let proof = !chat.hasEarlierMessages && (chat.unavailableMessageIDs ?? []).isEmpty
            && ids.count == chat.messages.count && chat.messages.allSatisfy { $0.hasStableIdentity(storedID: identity.stored.text) }
            ? ConversationIdentityRead(identity: identity, messageIDs: ids) : nil
        return .init(messages: chat.messages, hasEarlierMessages: chat.hasEarlierMessages, identityRead: proof)
    }

    func conversationHistory(_ identity: SessionIdentity, offset: Int) async throws -> ConversationHistoryPage {
        try Task.checkCancellation()
        try requireProfile(identity.profile)
        guard offset >= 0, offset.isMultiple(of: 100), identities[identity.root.bytes] == identity,
              let chat = chats[identity.root.bytes] else { throw ConversationServiceError.wrongConversation }
        let end = max(0, chat.messages.count - offset)
        let start = max(0, end - 100)
        let messages = Array(chat.messages[start..<end])
        let sourceIDs = Set(messages.map { Data($0.id.utf8) })
        let identityRead = offset == 0 && start == 0 && !chat.hasEarlierMessages
            && (chat.unavailableMessageIDs ?? []).isEmpty && sourceIDs.count == messages.count
            && messages.allSatisfy { $0.hasStableIdentity(storedID: identity.stored.text) }
            ? ConversationIdentityRead(identity: identity, messageIDs: sourceIDs) : nil
        return ConversationHistoryPage(messages: messages,
            nextOffset: start > 0 ? offset + 100 : nil, isComplete: true,
            sourceIDs: sourceIDs, identityRead: identityRead)
    }

    func conversations(profile: ExactID) async throws -> ConversationDirectory {
        try requireProfile(profile)
        #if DEBUG
        let epoch = connection
        try await waitForUITestFixture("directory")
        if let gateDirectory, FileManager.default.fileExists(atPath: gateDirectory.appendingPathComponent("directory.fail").path) {
            throw CocoaError(.fileReadUnknown)
        }
        guard connected, connection == epoch else { throw ConversationServiceError.staleConversation }
        #endif
        let keys = order.filter { identities[$0]?.profile == profile }
        return ConversationDirectory(summaries: keys.compactMap(summary), activity: observations(profile), isComplete: true)
    }

    func createConversation(profile: ExactID, operationID: UUID) async throws -> CreatedSession {
        try await createConversation(profile: profile, operationID: operationID, title: nil)
    }

    private func createConversation(profile: ExactID, operationID: UUID, title: String?) async throws -> CreatedSession {
        try requireProfile(profile)
        try claim(operationID)
        let epoch = connection
        #if DEBUG
        try await waitForUITestFixture("create-chat")
        #endif
        guard connected, epoch == connection else { throw ConversationServiceError.staleConversation }
        let key = "demo-session-" + UUID().uuidString
        let root = try ExactID(key)
        identities[root.bytes] = SessionIdentity(profile: profile, root: root, stored: root, aliases: [])
        titles[root.bytes] = title ?? T3ChannelSummary.untitledWireTitle; order.append(root.bytes)
        chats[root.bytes] = Conversation(id: key, storedID: key, profileID: profile.text)
        onEvent?(.botsChanged)
        return CreatedSession(operationID: operationID, summary: summary(root.bytes)!)
    }

    func openChat(_ target: SessionTarget) async throws -> OpenedConversation {
        let readStartedAt = ContinuousClock.now
        let epoch = connection
        let request = UUID()
        opening = request
        issuer.retireAttachment(); selected = nil; activity = nil
        #if DEBUG
        try await waitForUITestFixture("open")
        #endif
        guard connected, epoch == connection, opening == request else { throw ConversationServiceError.staleConversation }
        let identity: SessionIdentity
        switch target {
        case .canonical(let profile, let expectedRoot):
            try requireProfile(profile)
            guard let main = identities[profile.bytes], expectedRoot == nil || expectedRoot == main.root else {
                throw ConversationServiceError.wrongConversation
            }
            identity = main
        case .stored(let requested):
            try requireProfile(requested.profile)
            guard identities[requested.root.bytes] == requested else { throw ConversationServiceError.wrongConversation }
            identity = requested
        }
        guard let chat = chats[identity.root.bytes] else { throw ConversationServiceError.missingChat }
        let evidence = summary(identity.root.bytes).map(ConversationReadEvidence.init)
        let access = try issuer.issue(identity)
        visited[identity.stored.text] = .now
        selected = (identity, access)
        activity = ConversationActivity(lineage: UUID(), phase: nil, workStartedAt: nil, phaseStartedAt: nil)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--automation-live-demo"), identity.profile.text == "milo", tasks[identity.root.bytes] == nil {
            startAutomationFixture(identity)
        }
        #endif
        return OpenedConversation(identity: identity, snapshot: chat, access: access, readEvidence: evidence, activity: activity,
            historyReadStartedAt: readStartedAt, observedSource: identity)
    }

    func send(text: String, attachments: [ChatAttachment], delivery: MessageDelivery, access: ConversationAccess,
              operationID: UUID) async throws -> MutationReceipt {
        let source = try issuer.resolve(access)
        try claim(operationID)
        #if DEBUG
        try await waitForUITestFixture("send")
        #endif
        guard try issuer.resolve(access) == source, var chat = chats[source.root.bytes] else {
            throw ConversationServiceError.staleConversation
        }
        if delivery == .steer {
            guard chat.isWorking, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConversationServiceError.steeringUnavailable
            }
            guard attachments.isEmpty else { throw ConversationServiceError.steeringAttachments }
            chat.messages.append(ChatMessage(id: "steer:" + operationID.uuidString, role: .user,
                                             text: text, timestamp: .now))
            publish(chat, source: source)
            return receipt(source, operationID)
        }
        guard attachments.count <= AttachmentLimits.count else { throw ConversationServiceError.attachmentLimit }
        let files = try attachments.map { attachment -> UploadGrant in
            guard let token = attachment.stagingID, let file = uploads[token],
                  file.source == source, file.attachment == attachment else { throw ConversationServiceError.invalidAttachment }
            return file
        }
        guard files.reduce(0, { $0 + $1.bytes }) <= AttachmentLimits.totalBytes else { throw ConversationServiceError.attachmentLimit }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty else {
            throw ConversationServiceError.invalidResponse
        }
        for attachment in attachments { if let token = attachment.stagingID { uploads[token] = nil } }
        chat.messages.append(ChatMessage(id: "submission:" + operationID.uuidString, role: .user, text: text,
                                         timestamp: .now, attachments: attachments))
        let key = source.root.bytes
        if titles[key] == T3ChannelSummary.untitledWireTitle, !text.isEmpty {
            titles[key] = String(text.prefix(56))
        }
        let wasWorking = chat.isWorking
        if wasWorking {
            chat.queuedMessages.append(QueuedMessage(id: operationID.uuidString, text: text,
                canEdit: attachments.isEmpty, submissionID: operationID.uuidString))
        }
        chat.isWorking = true
        if !wasWorking { beginActivity(source: source) }
        publish(chat, source: source)
        if !wasWorking {
            startReply(key: key, source: source)
        }
        // The local admission already happened. A later selection cannot change its source.
        #if DEBUG
        try await waitForUITestFixture("send-ack")
        #endif
        return receipt(source, operationID)
    }

    func replaceQueuedMessage(_ message: QueuedMessage, text: String, access: ConversationAccess,
                              operationID: UUID) async throws -> MutationReceipt {
        let source = try issuer.resolve(access)
        try claim(operationID)
        guard let original = chats[source.root.bytes], editableQueueIndex(message, in: original) != nil else {
            throw ConversationServiceError.queuedMessageUnavailable
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConversationServiceError.invalidResponse
        }
        #if DEBUG
        try await waitForUITestFixture("replace-queued")
        #endif
        guard try issuer.resolve(access) == source, var chat = chats[source.root.bytes] else {
            throw ConversationServiceError.staleConversation
        }
        // The active reply may have finished while Save was in flight. A started
        // or replaced admission must never turn this edit into another send.
        guard let index = editableQueueIndex(message, in: chat) else {
            throw ConversationServiceError.queuedMessageUnavailable
        }
        chat.queuedMessages.remove(at: index)
        if let submission = message.submissionID {
            chat.messages.removeAll { $0.id == "submission:" + submission }
        }
        chat.queuedMessages.append(QueuedMessage(id: operationID.uuidString, text: text,
            canEdit: true, submissionID: operationID.uuidString))
        chat.messages.append(ChatMessage(id: "submission:" + operationID.uuidString,
            role: .user, text: text, timestamp: .now))
        publish(chat, source: source)
        return receipt(source, operationID)
    }

    private func editableQueueIndex(_ message: QueuedMessage, in chat: Conversation) -> Int? {
        guard message.canEdit, !message.isSteering, let submission = message.submissionID,
              let index = chat.queuedMessages.firstIndex(where: {
                  $0 == message && Data($0.text.utf8) == Data(message.text.utf8)
              }),
              let echo = chat.messages.first(where: { $0.id == "submission:" + submission }),
              echo.role == .user, echo.attachments.isEmpty else { return nil }
        return index
    }

    private func startReply(key: Data, source: SessionIdentity) {
        let lineage = selected?.identity == source ? activity?.lineage : nil
        tasks[key] = Task { [weak self] in
            guard !Task.isCancelled else { return }
            #if DEBUG
            if let self, self.performanceFixture {
                await self.streamPerformanceReply(key: key, source: source, lineage: lineage)
                return
            }
            #endif
            do {
                try await Task.sleep(for: .milliseconds(850))
                #if DEBUG
                try await self?.waitForUITestFixture("reply")
                #endif
            } catch { return }
            guard let self, var latest = self.chats[key], !Task.isCancelled else { return }
            latest.messages.append(ChatMessage(id: UUID().uuidString, role: .assistant,
                text: "You’ve got the idea. In your connected workspace, this message goes straight to the bot running on your Mac, with its own tools, memory, and model.\n\nThis demo stays on your phone and doesn’t perform any work.", timestamp: .now))
            self.completeReply(latest, key: key, source: source, lineage: lineage, succeeded: true)
        }
    }

    private func completeReply(_ chat: Conversation, key: Data, source: SessionIdentity,
                               lineage: UUID?, succeeded: Bool) {
        var chat = chat
        tasks[key] = nil
        chat.isWorking = !chat.queuedMessages.isEmpty
        if chat.isWorking {
            let next = chat.queuedMessages.removeFirst()
            // Pending echoes are hidden by their submission identity. Move the
            // admitted user turn after the completed reply before revealing it.
            if let submission = next.submissionID,
               let index = chat.messages.firstIndex(where: { $0.id == "submission:" + submission }) {
                let message = chat.messages.remove(at: index)
                chat.messages.append(message)
            }
        }
        if selected?.identity == source, let current = activity, current.lineage == lineage {
            if chat.isWorking {
                beginActivity(source: source)
            } else {
                activity = ConversationActivity(lineage: current.lineage, phase: nil,
                    workStartedAt: nil, phaseStartedAt: nil,
                    reaction: succeeded && current.phase != nil ? TurnReaction(kind: .succeeded, occurredAt: .now) : nil,
                    signal: !succeeded && current.phase != nil ? .init(kind: .stopped) : nil)
            }
        }
        publish(chat, source: source)
        if chat.isWorking {
            startReply(key: key, source: source)
        }
    }

    func stop(access: ConversationAccess, operationID: UUID) async throws -> MutationReceipt {
        let source = try issuer.resolve(access)
        try claim(operationID)
        tasks[source.root.bytes]?.cancel(); tasks[source.root.bytes] = nil
        guard let chat = chats[source.root.bytes] else { throw ConversationServiceError.missingChat }
        completeReply(chat, key: source.root.bytes, source: source,
                      lineage: selected?.identity == source ? activity?.lineage : nil, succeeded: false)
        return receipt(source, operationID)
    }

    func respond(to request: PendingRequest, response: RequestResponse, access: ConversationAccess,
                 operationID: UUID) async throws -> MutationReceipt {
        let source = try issuer.resolve(access)
        try claim(operationID)
        #if DEBUG
        try await waitForUITestFixture("answer")
        #endif
        guard try issuer.resolve(access) == source, var chat = chats[source.root.bytes],
              chat.pendingRequests.contains(request) else { throw ConversationServiceError.staleConversation }
        guard request.kind != .unsupported else { throw ConversationServiceError.unsupportedRequest }
        switch response {
        case .choice(let choice):
            guard request.choices.contains(where: { $0.id == choice }) else { throw ConversationServiceError.invalidResponse }
        case .text(let text):
            guard request.kind == .question, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConversationServiceError.invalidResponse
            }
        }
        chat.pendingRequests.removeAll { $0.id == request.id }
        let text: String
        if case .choice("deny") = response { text = "Understood. I’ll keep the draft here." }
        else { text = "Approval received. In this demo, nothing is sent." }
        chat.messages.append(ChatMessage(id: UUID().uuidString, role: .assistant, text: text, timestamp: .now))
        chat.isWorking = false
        if selected?.identity == source, let current = activity {
            activity = ConversationActivity(lineage: current.lineage, phase: nil, workStartedAt: nil, phaseStartedAt: nil)
        }
        publish(chat, source: source)
        return receipt(source, operationID)
    }

    func upload(data: Data, filename: String, mimeType: String, access: ConversationAccess) async throws -> ChatAttachment {
        let source = try issuer.resolve(access)
        guard data.count <= AttachmentLimits.fileBytes else { throw ConversationServiceError.attachmentLimit }
        #if DEBUG
        try await waitForUITestFixture("upload")
        if ProcessInfo.processInfo.arguments.contains("--slow-upload-demo") { try await Task.sleep(for: .seconds(3)) }
        #endif
        guard try issuer.resolve(access) == source else { throw ConversationServiceError.staleConversation }
        let token = UUID()
        let attachment = ChatAttachment(name: filename, path: "/demo/" + UUID().uuidString + "/" + filename,
                                        mimeType: mimeType, byteCount: data.count, stagingID: token)
        uploads[token] = UploadGrant(source: source, attachment: attachment, bytes: data.count)
        artifacts[source.root.bytes, default: [:]][attachment.path] = DownloadedArtifact(data: data, filename: filename, mimeType: mimeType)
        return attachment
    }

    func downloadArtifact(_ attachment: ChatAttachment, access: ConversationAccess) async throws -> DownloadedArtifact {
        try Task.checkCancellation()
        let source = try issuer.resolve(access)
        #if DEBUG
        try await waitForUITestFixture("download")
        #endif
        guard try issuer.resolve(access) == source else { throw ConversationServiceError.staleConversation }
        var path = attachment.path
        if let url = URL(string: path), url.scheme == "file", url.host == nil || url.host == "" || url.host == "localhost" {
            path = url.path
        }
        guard let artifact = artifacts[source.root.bytes]?[path] else { throw ConversationServiceError.invalidAttachment }
        return artifact
    }

    func downloadArtifact(_ attachment: ChatAttachment, in identity: SessionIdentity) async throws -> DownloadedArtifact {
        try Task.checkCancellation()
        try requireProfile(identity.profile)
        guard identities[identity.root.bytes] == identity else { throw ConversationServiceError.wrongConversation }
        let epoch = connection
        #if DEBUG
        try await waitForUITestFixture("download")
        #endif
        try Task.checkCancellation()
        guard connected, connection == epoch, identities[identity.root.bytes] == identity else {
            throw ConversationServiceError.staleConversation
        }
        var path = attachment.path
        if let url = URL(string: path), url.scheme == "file", url.host == nil || url.host == "" || url.host == "localhost" {
            path = url.path
        }
        guard let artifact = artifacts[identity.root.bytes]?[path] else { throw ConversationServiceError.invalidAttachment }
        return artifact
    }

    private func claim(_ operation: UUID) throws {
        guard operations.insert(operation).inserted else { throw ConversationServiceError.staleConversation }
    }

    private func receipt(_ source: SessionIdentity, _ operation: UUID) -> MutationReceipt {
        MutationReceipt(operationID: operation, source: source, admissionID: operation.uuidString, journal: .saved)
    }

    private func requireProfile(_ profile: ExactID) throws {
        guard connected else { throw ConversationServiceError.disconnected }
        guard Data(bot.id.utf8) == profile.bytes else { throw ConversationServiceError.profileUnavailable }
    }

    private func status(_ chat: Conversation) -> BotStatus {
        !chat.pendingRequests.isEmpty ? .waiting : chat.isWorking ? .working : .idle
    }

    private func observations(_ profile: ExactID, keys: [Data]? = nil) -> [SessionIdentity: ObservedActivity] {
        let observedAt = Date.now
        var result: [SessionIdentity: ObservedActivity] = [:]
        for key in keys ?? order {
            guard let identity = identities[key], identity.profile == profile, let chat = chats[key] else { continue }
            result[identity] = .known(status(chat), observedAt)
        }
        return result
    }

    private func summary(_ key: Data) -> SessionSummary? {
        guard let identity = identities[key], let chat = chats[key] else { return nil }
        return SessionSummary(identity: identity, title: titles[key] ?? "", isCanonical: key == identity.profile.bytes,
                              persistence: .liveOnly, preview: chat.messages.last?.text ?? "",
                              updatedAt: chat.messages.last?.timestamp, messageCount: chat.messages.count)
    }

    private func registerSpace(_ id: String, title: String) {
        guard let root = try? ExactID(id), let profile = try? ExactID(bot.id) else { return }
        identities[root.bytes] = SessionIdentity(profile: profile, root: root, stored: root, aliases: [])
        titles[root.bytes] = title
        order.append(root.bytes)
    }

    private func seedSideChats() {
        for (suffix, title, text) in [
            ("weekend", "Weekend plan", "Keep Saturday open for a long walk and a late lunch."),
            ("research", "Research notes", "A separate place to gather sources and follow up on ideas.")
        ] {
            let key = "demo-milo-" + suffix
            registerSpace(key, title: title)
            chats[Data(key.utf8)] = Conversation(id: key, storedID: key, profileID: "milo", messages: [
                ChatMessage(id: key + "-welcome", role: .assistant, text: text, timestamp: .now)
            ])
        }
    }

    #if DEBUG
    /// Simulator UI tests opt in with a private temporary directory. A held
    /// request deliberately ignores cancellation, like a host that already acted.
    private func waitForUITestFixture(_ operation: String) async throws {
        guard let directory = gateDirectory else { return }
        let marker = directory.appendingPathComponent(operation)
        fixtureCalls[operation, default: 0] += 1
        let invocation = directory.appendingPathComponent("\(operation)-\(fixtureCalls[operation, default: 0])")
        try Data().write(to: invocation.appendingPathExtension("started"))
        try Data(String(fixtureCalls[operation, default: 0]).utf8).write(to: marker.appendingPathExtension("calls"))
        try Data().write(to: marker.appendingPathExtension("started"))
        try await Task.detached {
            // XCTest can spend thirty seconds waiting for one animation to settle.
            let deadline = Date.now.addingTimeInterval(120)
            while FileManager.default.fileExists(atPath: marker.appendingPathExtension("hold").path) ||
                  FileManager.default.fileExists(atPath: invocation.appendingPathExtension("hold").path) {
                guard Date.now < deadline else { throw CocoaError(.fileReadUnknown) }
                try await Task.sleep(for: .milliseconds(20))
            }
        }.value
        try Data().write(to: invocation.appendingPathExtension("returned"))
        try Data().write(to: marker.appendingPathExtension("returned"))
    }
    #endif

    private func beginActivity(source: SessionIdentity) {
        guard selected?.identity == source, let current = activity else { return }
        let now = Date.now
        activity = ConversationActivity(lineage: current.lineage, phase: .working,
                                        workStartedAt: now, phaseStartedAt: now, signal: .init(kind: .turnStarted))
    }

    private func markReplying(source: SessionIdentity, lineage: UUID?) {
        guard selected?.identity == source, let current = activity, current.lineage == lineage,
              current.phase != nil else { return }
        activity = ConversationActivity(lineage: current.lineage, phase: .replying,
                                        workStartedAt: current.workStartedAt,
                                        phaseStartedAt: current.phase == .replying ? current.phaseStartedAt : .now,
                                        signal: .init(kind: .replyText))
    }

    private func publish(_ chat: Conversation, source: SessionIdentity) {
        chats[source.root.bytes] = chat
        guard connected else { return }
        if let selected, selected.identity == source {
            var access = selected.access
            #if DEBUG
            if rotatesChatAccess {
                // Model Core's execution/request/completion refreshes. The old
                // grant retires, but an admitted send still ACKs its captured source.
                guard let refreshed = try? issuer.issue(source) else { return }
                access = refreshed
                self.selected = (source, refreshed)
            }
            #endif
            // This demo reads its complete local record synchronously, rather
            // than projecting a partial remote delta.
            let evidence = summary(source.root.bytes).map(ConversationReadEvidence.init)
            let publishedActivity = activity
            if let current = activity, current.reaction != nil || current.signal != nil {
                activity = ConversationActivity(lineage: current.lineage, phase: current.phase,
                    workStartedAt: current.workStartedAt, phaseStartedAt: current.phaseStartedAt)
            }
            onEvent?(.conversation(OpenedConversation(identity: source, snapshot: chat, access: access,
                                                     readEvidence: evidence, activity: publishedActivity)))
        }
        onEvent?(.botsChanged)
    }

    private func seed() {
        let now = Date.now
        chats[Data("milo".utf8)] = Conversation(id: "demo-milo", storedID: "milo", profileID: "milo", messages: [
            ChatMessage(id: "m1", role: .user, text: "Help me get a handle on tomorrow.", timestamp: now.addingTimeInterval(-900)),
            ChatMessage(id: "m2", role: .assistant, text: "A little breathing room for tomorrow.\n\nYour first meeting is at 10. I’d keep the hour before it for the proposal. It’s the one thing that will make the rest of the day easier.", timestamp: now.addingTimeInterval(-850)),
            ChatMessage(id: "m3", role: .assistant, text: "I also drafted a note to move the project check-in to Thursday. Take a look before it goes anywhere.", timestamp: now.addingTimeInterval(-180))
        ], pendingRequests: [PendingRequest(id: "demo-approval", kind: .approval, title: "Send the check-in note?",
            detail: "To: Jordan\n\nCould we move our check-in to Thursday at 2? That gives us time to finish the proposal first.",
            choices: [.init(id: "once", label: "Allow once"), .init(id: "deny", label: "Keep draft")], queueID: "demo-queue")])
        chats[Data("scout".utf8)] = Conversation(id: "demo-scout", storedID: "scout", profileID: Self.profileID, messages: [
            .init(id: "s1", role: .user, text: "Find a quiet spot for a long weekend. Somewhere with good walks.", timestamp: now.addingTimeInterval(-1800)),
            .init(id: "s2", role: .tool, text: "Compared trails, train routes, and places to stay.", timestamp: now.addingTimeInterval(-1500), toolName: "Research"),
            .init(id: "s3", role: .assistant, text: "Three directions I’d explore:\n\n**Hudson**: easy train, small galleries, a slow morning by the river.\n\n**Cold Spring**: best for a real hike without a car.\n\n**Beacon**: a good mix of art, walks, and coffee.\n\nI’d start with Cold Spring if being outside is the point.", timestamp: now.addingTimeInterval(-1200))
        ])
        chats[Data("iris".utf8)] = Conversation(id: "demo-iris", storedID: "iris", profileID: Self.profileID, messages: [
            .init(id: "i1", role: .user, text: "Can you make this introduction sound less formal?", timestamp: now.addingTimeInterval(-4000)),
            .init(id: "i2", role: .assistant, text: "Here’s a lighter opening:\n\n“We’ve been thinking about a simpler way to do this. Here’s what we tried, what surprised us, and where we’re going next.”\n\nIt gets to the idea sooner and gives people a reason to keep reading.", timestamp: now.addingTimeInterval(-3600))
        ])
        chats[Data("atlas".utf8)] = Conversation(id: "demo-atlas", storedID: "atlas", profileID: Self.profileID, messages: [
            .init(id: "a1", role: .assistant, text: "Saturday, without overplanning it.\n\nStart at the market around 9. Walk along the water after coffee. Lunch is a short walk away, and the afternoon is yours.\n\nWant me to find a rainy-day alternative?", timestamp: now.addingTimeInterval(-8000))
        ])
        registerSpace("scout", title: "Weekend research")
        registerSpace("iris", title: "Writing desk")
        registerSpace("atlas", title: "Saturday plans")
        seedRichDemo(now: now)
    }

    #if DEBUG
    private func seedAttributionDemo() {
        chats[Data("milo".utf8)] = Conversation(id: "demo-milo", storedID: "milo", profileID: "milo", messages: [
            .init(id: "authored", role: .user, text: "Check the service and coordinate with Gustavo."),
            .init(id: "assistant-intro", role: .assistant, text: "I’ll check the service and follow up."),
            .init(id: "work-one", role: .tool, text: "{\"content\":\"## Service check\\n\\nThe service is healthy.\",\"exit_code\":0}", toolName: "terminal"),
            .init(id: "work-two", role: .tool, text: "The scheduled check is active.", toolName: "cronjob_manage"),
            .init(id: "background", role: .user,
                  text: "[ASYNC DELEGATION BATCH COMPLETE — deleg_sample]\nThe background check finished successfully.",
                  displayKind: "async_delegation_complete", displayText: "Background check finished"),
            .init(id: "process-result", role: .user,
                  text: "[IMPORTANT: Background process proc_demo completed normally (exit code 0).]\nCommand: /usr/bin/python3 health_check.py\n{\"status\":\"healthy\"}",
                  displayKind: "process_complete", displayText: "Background Process Finished: /usr/bin/python3 health_check.py"),
            .init(id: "gustavo", role: .user, text: "Message from 🤖 Gustavo (@gustavo): The service has recovered. Please own the follow-up.",
                  displayKind: "internal_notification"),
            .init(id: "assistant-followup", role: .assistant, text: "I’ll own the follow-up and keep you posted."),
            .init(id: "human-hi", role: .user, text: "Hi"),
            .init(id: "human-hi-control", role: .assistant, text: "[SILENT]", isSilent: false)
        ], queuedMessages: [
            .init(id: "sample-process", text: "[IMPORTANT: Background process proc_sample completed normally (exit code 0).]\nSample diagnostic output.",
                  submissionID: "[\"completion\",\"proc_sample\",100]")
        ])
    }

    private func seedAutomationDemo() {
        let now = Date(timeIntervalSince1970: 1_792_872_000)
        let wrapper = "[Cronjob \"Mac service incident diagnosis\" output — scheduled job, not the user. Review it, act on anything that needs action, and summarize for the chat.]\n\n"
        let payload = wrapper + "{\"service\":\"local sample\",\"status\":\"recovered\",\"ack\":\"inspection only\"}\n" +
            String(repeating: "Diagnostic sample: health check passed. No command was executed.\n", count: 2000)
        chats[Data("milo".utf8)]?.messages = [
            .init(id: "monitoring-request", role: .user, text: "Keep an eye on the Mac service.", timestamp: now.addingTimeInterval(-300)),
            .init(id: "scheduled-check", role: .user, text: payload, timestamp: now, displayKind: "internal_notification"),
            .init(id: "service-response", role: .assistant, text: "The service recovered and is healthy. No restart is needed. I’ll keep monitoring it.", timestamp: now.addingTimeInterval(5)),
            .init(id: "silent-result", role: .assistant, text: "[SILENT]", timestamp: now.addingTimeInterval(10), isSilent: true)
        ]
        automationHandoff = chats[Data("milo".utf8)]?.messages[1]
        if ProcessInfo.processInfo.arguments.contains("--automation-live-demo") {
            chats[Data("milo".utf8)]?.pendingRequests = []
            chats[Data("milo".utf8)]?.messages = (0..<24).map { index in
                .init(id: "history-\(index)", role: .assistant,
                      text: "Monitoring history \(index). " + String(repeating: "The service was healthy. ", count: 8))
            }
        }
    }

    private func startAutomationFixture(_ source: SessionIdentity) {
        let epoch = connection
        tasks[source.root.bytes] = Task { [weak self] in
            guard let self else { return }
            do {
                try await waitForUITestFixture("automation")
                guard connected, connection == epoch, let handoff = automationHandoff, var chat = chats[source.root.bytes] else { return }
                chat.messages.append(handoff)
                chat.messages.append(.init(id: "silent-check", role: .assistant, text: "[SILENT]", isSilent: true))
                publish(chat, source: source)
                if let gateDirectory { try Data().write(to: gateDirectory.appendingPathComponent("automation.delivered")) }
                try await waitForUITestFixture("automation-reply")
                guard connected, connection == epoch, var latest = chats[source.root.bytes] else { return }
                latest.messages.append(.init(id: "useful-check-response", role: .assistant, text: "The service needs your attention."))
                publish(latest, source: source)
            } catch { return }
        }
    }

    /// Opt-in, deterministic stress data. Ordinary Demo keeps its small sample workspace.
    private func seedPerformanceDemo() {
        let now = Date(timeIntervalSince1970: 1_790_208_000)
        let paragraphs = (0..<8).map { index in
            "Paragraph \(index). **Native text** keeps a readable history with [a source](https://example.com). " +
                String(repeating: "A conversation should stay responsive while new words arrive. ", count: 5)
        }.joined(separator: "\n\n")
        if ProcessInfo.processInfo.arguments.contains("--heavy-history-performance-demo") {
            let text = (0..<48).map { index in
                "Section \(index). **Measured history** with [a source](https://example.com). " +
                    String(repeating: "Keep the complete text readable while moving through older messages. ", count: 4)
            }.joined(separator: "\n\n")
            chats[Data("scout".utf8)]?.messages = (0..<30).flatMap { group -> [ChatMessage] in
                let prefix = "heavy-\(group)-"
                let date = now.addingTimeInterval(Double(group))
                return [.init(id: prefix + "question", role: .user,
                              text: "Heavy history question \(group).\n\n" + text, timestamp: date)] +
                    (0..<8).map { tool in
                        ChatMessage(id: prefix + "tool-\(tool)", role: .tool,
                                    text: "Tool result \(group).\(tool).\n\n" + text, timestamp: date)
                    } + [.init(id: prefix + "reply", role: .assistant,
                               text: "Heavy history landmark \(group).\n\n" + text, timestamp: date)]
            }
        } else if ProcessInfo.processInfo.arguments.contains("--mixed-history-performance-demo") {
            let toolOutput = "**Sample work output**\n\n" + String(repeating: "Checked a **local sample**. No action was performed.\n\n", count: 64)
            chats[Data("scout".utf8)]?.messages = (0..<50).flatMap { group -> [ChatMessage] in
                let prefix = "mixed-\(group)-"
                let date = now.addingTimeInterval(Double(group * 8))
                let wrapper = "[Cronjob \"Routine sample check\" output — scheduled job, not the user. Review it, act on anything that needs action, and summarize for the chat.]\n\n"
                return [
                    .init(id: prefix + "question", role: .user, text: "Review the sample updates for item \(group).", timestamp: date),
                    .init(id: prefix + "tool-1", role: .tool, text: toolOutput, timestamp: date),
                    .init(id: prefix + "tool-2", role: .tool, text: "Compared local sample records.", timestamp: date),
                    .init(id: prefix + "tool-3", role: .tool, text: "Prepared a sample summary.", timestamp: date),
                    .init(id: prefix + "scheduled", role: .user, text: wrapper + "The sample service is healthy.", timestamp: date,
                          displayKind: "internal_notification"),
                    .init(id: prefix + "reply", role: .assistant,
                          text: "Mixed history landmark \(group).\n\n" + (group.isMultiple(of: 5) ? paragraphs : "The sample updates are ready.\n\n**Next step:** inspect the [sample source](https://example.com). No changes were made."), timestamp: date),
                    .init(id: prefix + "raw", role: .user, text: wrapper + "A reference-only sample result.\n\nNo user action is requested.", timestamp: date),
                    .init(id: prefix + "summary", role: .assistant, text: "Sample check \(group) complete. No action is needed.", timestamp: date)
                ]
            }
        } else {
            chats[Data("scout".utf8)]?.messages = (0..<400).map { index in
                ChatMessage(id: "performance-\(index)", role: index.isMultiple(of: 4) ? .user : .assistant,
                            text: "History landmark \(index).\n\n" + paragraphs,
                            timestamp: now.addingTimeInterval(Double(index)))
            }
        }
        for index in 0..<200 {
            let id = "performance-bot-\(index)"
            registerSpace(id, title: "Helper \(index)")
            chats[Data(id.utf8)] = Conversation(id: "demo-" + id, storedID: id, profileID: Self.profileID,
                messages: [.init(id: "hello-" + id, role: .assistant, text: "Hello from Helper \(index).")])
        }
    }

    private func streamPerformanceReply(key: Data, source: SessionIdentity, lineage: UUID?) async {
        guard var chat = chats[key] else { return }
        performanceReplyNumber += 1
        let number = performanceReplyNumber
        let id = "performance-reply-\(number)"
        chat.messages.append(.init(id: id, role: .assistant, text: ""))
        publish(chat, source: source)
        InteractionFrameTrace.setStreamPublishing(true)
        defer { InteractionFrameTrace.setStreamPublishing(false) }
        for index in 0..<200 {
            do { try await Task.sleep(for: performanceChunkDelay) } catch { return }
            guard !Task.isCancelled, connected, var current = chats[key], current.isWorking,
                  let messageIndex = current.messages.firstIndex(where: { $0.id == id }) else { return }
            current.messages[messageIndex].text += "Word \(index). "
            InteractionFrameTrace.recordStreamPublication()
            markReplying(source: source, lineage: lineage)
            publish(current, source: source)
            if index == 19 {
                InteractionFrameTrace.setStreamPublishing(false)
                do {
                    switch PerformanceStreamGate.mode {
                    case "scroll": try await PerformanceStreamGate.waitForGesture()
                    case "typing": break
                    default: try await waitForUITestFixture("performance-stream")
                    }
                } catch { return }
                InteractionFrameTrace.setStreamPublishing(true)
            }
        }
        guard var current = chats[key], connected, !Task.isCancelled,
              let messageIndex = current.messages.firstIndex(where: { $0.id == id }) else { return }
        current.messages[messageIndex].text += "\n\nPerformance stream \(number) complete."
        completeReply(current, key: key, source: source, lineage: lineage, succeeded: true)
        if let gateDirectory {
            try? Data().write(to: gateDirectory.appendingPathComponent("performance-stream-\(number).completed"))
        }
    }
    #endif

    /// The ordinary demo includes a local showcase of rich replies and files.
    private func seedRichDemo(now: Date) {
        registerSpace("canvas", title: "Project update")
        pinned.insert("canvas")
        let pdf = Self.samplePDF()
        let notes = Data("Canvas demo\n\nDraft, review, then publish. All sample files stay on this device.\n".utf8)
        let html = Data(Self.sampleHTML.utf8)
        // Generated 96 x 64 RGB PNG: three bars, no metadata or network resources.
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAGAAAABACAIAAABqVuVZAAAAiUlEQVR42u3bsQnAIBBAUWfJFE6TJuCWlg6UJlyRwgGEcGAXHvwJXv/LE68+KggAAQIECBAgQIAECBCgpWOcyQABAgQIECBAgAABAgQI0NXuZIAAAQIECBAgQIAAAQIECBCgPaDaIxkgQIAAAQIECBAgQIAAAQIECBAgQIAAmVkECBAgQIAA/aQJU0nxj7GhRGIAAAAASUVORK5CYII=")!
        artifacts[Data("canvas".utf8)] = [
            "/demo/canvas/report.pdf": DownloadedArtifact(data: pdf, filename: "report.pdf", mimeType: "application/pdf"),
            "/demo/canvas/notes.txt": DownloadedArtifact(data: notes, filename: "notes.txt", mimeType: "text/plain"),
            "/demo/canvas/chart.png": DownloadedArtifact(data: png, filename: "chart.png", mimeType: "image/png"),
            "/demo/canvas/report.html": DownloadedArtifact(data: html, filename: "report.html", mimeType: "text/html"),
            "/demo/canvas/inline-visual-test.html": DownloadedArtifact(data: Data(Self.previewFileHTML.utf8), filename: "inline-visual-test.html", mimeType: "text/html")
        ]
        chats[Data("canvas".utf8)] = Conversation(id: "demo-canvas", storedID: "canvas", profileID: Self.profileID, messages: [
            ChatMessage(id: "canvas-request", role: .user, text: "Build a small project update with a dashboard, a diagram, and files I can keep.",
                        timestamp: now.addingTimeInterval(-60), attachments: [ChatAttachment(name: "notes.txt", path: "/demo/canvas/notes.txt", mimeType: "text/plain", byteCount: notes.count)]),
            ChatMessage(id: "canvas-rich-reply", role: .assistant, text: Self.richReply, timestamp: now)
        ])
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--attachment-deck-demo") {
            chats[Data("canvas".utf8)]?.messages.append(ChatMessage(id: "canvas-deck", role: .user, text: "Here are the files.", timestamp: now, attachments: [
                ChatAttachment(name: "report.pdf", path: "/demo/canvas/report.pdf", mimeType: "application/pdf", byteCount: pdf.count),
                ChatAttachment(name: "chart.png", path: "/demo/canvas/chart.png", mimeType: "image/png", byteCount: png.count)
            ]))
        }
        if ProcessInfo.processInfo.arguments.contains("--diagram-cache-demo") {
            chats[Data("canvas".utf8)]?.messages = (0..<24).map { index in
                let prefix = "Assistant message \(index). Here is the next part of our conversation.\n\n"
                let source = index % 4 == 0
                    ? "```mermaid\ngraph LR\nA[Start] --> B[Done]\n%% message \(index)\n```\n"
                    : String(repeating: "Plain text remains native and needs no preview renderer. ", count: 7)
                return ChatMessage(id: "m\(index)", role: .assistant, text: prefix + source,
                                   timestamp: now.addingTimeInterval(Double(index - 24)))
            }
        }
        #endif
    }

    private static let sampleHTML = """
    <!doctype html>
    <html lang="en"><meta name="viewport" content="width=device-width,initial-scale=1">
    <style>body{font:17px system-ui;padding:20px;background:#f4f6ff;color:#172554}button{font:inherit;padding:12px;border-radius:12px;border:1px solid #6366f1;background:white}strong{font-size:32px}</style>
    <h2>Launch dashboard</h2><p>Three milestones are ready for review.</p>
    <p><strong id="count">0</strong> reviews</p>
    <button onclick="document.getElementById('count').textContent=String(++window.reviews)">Add review</button>
    <script>window.reviews=0</script></html>
    """

    private static let previewFileHTML = """
    <!doctype html><html lang="en"><meta name="viewport" content="width=device-width,initial-scale=1">
    <style>body{font:17px system-ui;padding:20px;color:#172554;background:#eef2ff}h2{margin-top:0}.bar{height:20px;margin:12px 0;border-radius:6px;background:#6366f1}button{font:inherit;padding:12px;border:1px solid #6366f1;border-radius:12px;background:white}</style>
    <h2>File preview</h2><p>Three milestones, loaded from an HTML file.</p>
    <div class="bar" style="width:100%" role="img" aria-label="Draft 100 percent"></div>
    <div class="bar" style="width:75%" role="img" aria-label="Review 75 percent"></div>
    <div class="bar" style="width:50%" role="img" aria-label="Publish 50 percent"></div>
    <p id="status" aria-live="polite">Ready for review</p>
    <button onclick="document.getElementById('status').textContent='Preview updated'">Update preview</button></html>
    """

    private static let richReply = """
    Before the dashboard, here is the plan: keep the first release small and review it together. This is a local rich content demo.

    ```html
    \(sampleHTML)
    ```

    Between the dashboard and the diagram, the next step is a short review. The counter above works locally.

    ```mermaid
    flowchart LR
      Draft[Draft] --> Review[Review]
      Review --> Publish[Publish]
    ```

    Between the diagram and the illustration, here is a simple progress snapshot.

    ```svg
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 320 140" role="img" aria-label="Three completed milestones">
      <rect width="320" height="140" rx="18" fill="#eef2ff"/>
      <path d="M60 70H260" stroke="#6366f1" stroke-width="4"/>
      <g fill="#4f46e5"><circle cx="60" cy="70" r="18"/><circle cx="160" cy="70" r="18"/><circle cx="260" cy="70" r="18"/></g>
      <g fill="#172554" font-family="sans-serif" font-size="14" text-anchor="middle"><text x="60" y="112">Draft</text><text x="160" y="112">Review</text><text x="260" y="112">Publish</text></g>
    </svg>
    ```

    After the illustration, this ordinary code stays readable as source.

    ```swift
    let milestones = ["Draft", "Review", "Publish"]
    print(milestones.joined(separator: " → "))
    ```

    After the code, keep the originals:

    [Project report](file:///demo/canvas/report.pdf)

    [Review notes](file:///demo/canvas/notes.txt)

    [Dashboard HTML](file:///demo/canvas/report.html)

    MEDIA:/demo/canvas/chart.png

    After the files, everything above is a demo. Save or share a copy to inspect the original bytes.

    A file-based visual works here too:

    ::preview{file="/demo/canvas/inline-visual-test.html" height="360"}
    """

    /// A small valid PDF with fixed object offsets, independent of time and locale.
    private static func samplePDF() -> Data {
        let stream = "BT /F1 24 Tf 50 730 Td (Canvas demo) Tj 0 -40 Td /F1 14 Tf (Draft, review, then publish.) Tj ET\n"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)endstream"
        ]
        var pdf = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = pdf.utf8.count
        pdf += "xref\n0 6\n0000000000 65535 f \n"
        for offset in offsets { pdf += String(format: "%010d 00000 n \n", offset) }
        pdf += "trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(pdf.utf8)
    }

}
