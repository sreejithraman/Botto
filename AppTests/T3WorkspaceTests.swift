import Foundation
import Testing
@testable import Botto
@testable import BottoCore

@MainActor @Suite(.timeLimit(.minutes(1))) struct T3WorkspaceTests {
    @Test func mountsTheBotAndOpensTheExactStoredChannel() async throws {
        let service = T3WorkspaceService()
        let configuration = t3Configuration()
        let storage = MemoryConnectionStorage(saved: configuration)
        defer { LocalHistory.remove(for: configuration.id) }
        let store = AppStore(service: service, persistence: storage.persistence)

        await store.start()

        #expect(store.isT3Workspace)
        #expect(store.serverName == "Studio")
        #expect(store.primaryT3Bot?.id == "bot-project")
        #expect(store.t3Channels.map(\.title) == ["#general", "Release"])
        // Spaces never show a "#", and the main space is the anchor.
        #expect(store.t3Channels.map(\.displayTitle) == ["general", "Release"])
        #expect(T3ChatShelf.spaces(store.t3Channels).main?.id == "general")
        #expect(T3ChatShelf.spaces(store.t3Channels).spaces.map(\.id) == ["release"])
        // Release is waiting, so launch goes there before the main space.
        #expect(T3ChatShelf.initialSpace(store.t3Channels)?.id == "release")
        let release = try #require(store.t3Channels.last)
        #expect(await store.openT3Channel(release))
        #expect(store.selectedBotID == "bot-project")
        #expect(store.selectedT3ChannelTitle == "Release")
        #expect(store.selectedT3Channel?.id == "release")
        #expect(store.conversation(for: "bot-project")?.messages.map(\.text) == ["Chat in release"])

        let general = try #require(store.t3Channels.first)
        #expect(await store.openT3Channel(general))
        #expect(store.selectedT3ChannelTitle == "general")
        #expect(service.openedStoredThreads == ["release", "general"])

        try #require(store.flush())
        let restored = AppStore(service: T3WorkspaceService(), persistence: storage.persistence)
        #expect(restored.link == .connecting)
        #expect(restored.t3Channels.map(\.title) == ["#general", "Release"])
        #expect(restored.t3Channels.map(\.isMain) == [true, false])
        #expect(await restored.openT3Channel(release))
        #expect(restored.conversation(for: "bot-project")?.messages.map(\.text) == ["Chat in release"])
    }

    @Test func failedT3ReplacementKeepsTheSavedWorkspaceAndLiveService() async throws {
        let original = ConnectionConfiguration(serverURL: URL(string: "https://studio.example")!, username: "original")
        let candidate = t3Configuration()
        defer {
            LocalHistory.remove(for: original.id)
            LocalHistory.remove(for: candidate.id)
        }
        let storage = MemoryConnectionStorage(saved: original)
        let originalService = try WorkspaceTestService()
        let candidateService = T3WorkspaceService()
        candidateService.connectError = T3ServiceError.differentEnvironment
        let store = AppStore(persistence: storage.persistence, makeService: { configuration in
            if configuration?.t3 != nil { return candidateService }
            return originalService
        })
        await store.start()
        await store.testEdit("Keep this draft", for: "milo")
        let workspace = store.chats

        #expect(!(await store.connect(candidate)))

        #expect(candidateService.disconnects == 1)
        #expect(store.configuration == original)
        #expect(storage.saved == original)
        #expect(store.chats === workspace)
        #expect(store.isConnected)
        #expect(!store.isT3Workspace)
        #expect(store.draft(for: "milo") == "Keep this draft")
        await store.open(try #require(store.bot(withID: "milo")))
        #expect(originalService.opens.last?.profile.text == "milo")
        #expect(store.chats.screen(profile: originalService.profile)?.canAct == true)
    }

    @Test func foregroundReconnectKeepsDraftAndReattachmentWarning() async throws {
        var configuration = t3Configuration()
        configuration.t3?.workspaceRoot = "/host/.botto/bots/main"
        defer { LocalHistory.remove(for: configuration.id) }
        let storage = MemoryConnectionStorage(saved: configuration)
        let store = AppStore(persistence: storage.persistence, makeService: { _ in T3WorkspaceService() })
        await store.start()
        let channel = try #require(store.t3Channels.first)
        #expect(await store.openT3Channel(channel))
        let workspace = store.chats
        let profile = try ExactID("bot-project")
        let original = try #require(workspace.screen(profile: profile))
        workspace.editDraft("Keep this with its file", owner: original.owner)
        let target = try #require(workspace.captureImport(original.owner))
        await workspace.upload(Data([1]), filename: "plan.txt", mimeType: "text/plain", to: target)
        #expect(workspace.screen(profile: profile)?.attachments.map(\.name) == ["plan.txt"])

        await store.setActive(false)
        await store.setActive(true)

        #expect(store.chats === workspace)
        let recovered = try #require(store.chats.screen(profile: profile))
        #expect(recovered.needsReattachment)
        #expect(recovered.attachments.map(\.name) == ["plan.txt"])
        #expect(workspace.draft(recovered.owner) == "Keep this with its file")
        #expect(workspace.captureSend(recovered.owner) == nil)
    }

    @Test func explicitPairingOfTheSameVerifiedProjectPreservesCachedConversationAndDraft() async throws {
        var previous = t3Configuration()
        previous.t3?.workspaceRoot = "/host/.botto/bots/main"
        let previousID = previous.id
        let resolved = try #require(previous.t3)
        let next = ConnectionConfiguration(serverURL: previous.serverURL,
            t3: .init(environmentID: resolved.environmentID, accessToken: "new-fixture-token"))
        defer { LocalHistory.remove(for: previousID); LocalHistory.remove(for: next.id) }
        let original = T3WorkspaceService()
        let replacement = T3WorkspaceService()
        replacement.resolvedPairing = next.t3.map {
            var bound = $0
            bound.projectID = resolved.projectID
            bound.workspaceRoot = resolved.workspaceRoot
            return bound
        }
        let storage = MemoryConnectionStorage(saved: previous)
        let store = AppStore(persistence: storage.persistence, makeService: {
            $0?.id == next.id ? replacement : original
        })
        await store.start()
        let bot = try #require(store.primaryT3Bot)
        await store.open(bot)
        #expect(store.selectedT3ChannelID == "release")
        await store.testEdit("Keep the typed draft", for: bot.id)
        try #require(store.flush())
        let workspace = store.chats

        #expect(await store.connect(next))
        #expect(store.chats !== workspace)
        #expect(storage.saved?.id == next.id)
        #expect(storage.saved?.t3?.projectID == resolved.projectID)
        #expect(storage.saved?.t3?.accessToken == "new-fixture-token")
        #expect(store.draft(for: bot.id) == "Keep the typed draft")
        #expect(store.conversation(for: bot.id)?.messages.map(\.text) == ["Chat in release"])
    }

    @Test func loadsAndSavesBotBrainThroughTheMountedService() async throws {
        let configuration = t3Configuration()
        defer { LocalHistory.remove(for: configuration.id) }
        let service = T3WorkspaceService()
        let store = AppStore(service: service, persistence: MemoryConnectionStorage(saved: configuration).persistence)
        await store.start()

        let original = try await store.loadT3BotBrain()
        #expect(original.soulMarkdown == "# Soul")
        #expect(original.memoryMarkdown == "# Memory")
        #expect(original.workspaceRoot == "/host/.botto/bots/main")
        #expect(original.skills == ["skills/check"])
        let model = try #require(try await store.availableT3Models().first)
        #expect(model.modelID == "claude-test")
        #expect(try await store.readT3ProjectFile(relativePath: "skills/check/SKILL.md") == "# Check")

        var manifest = original.manifest
        manifest.displayName = "Builder"
        manifest.description = "Tracks releases."
        manifest.providerInstanceID = model.providerInstanceID
        manifest.model = model.modelID
        try await store.saveT3Soul("# Be curious", replacing: original.soulMarkdown)
        try await store.saveT3Memory("# Release checklist", replacing: original.memoryMarkdown)
        try await store.saveT3Manifest(manifest)

        let saved = try await store.loadT3BotBrain()
        #expect(saved.soulMarkdown == "# Be curious")
        #expect(saved.memoryMarkdown == "# Release checklist")
        #expect(saved.manifest == manifest)
        #expect(store.primaryT3Bot?.name == "Builder")
    }

    @Test func cacheScopesDistinguishBackendsEnvironmentsAndProjectsOnTheSameAddress() {
        let t3 = t3Configuration()
        var hermes = t3
        hermes.t3 = nil
        var otherEnvironment = t3
        otherEnvironment.t3?.environmentID = "other-environment"
        var otherProject = t3
        otherProject.t3?.projectID = "other-project"
        var rotatedToken = t3
        rotatedToken.t3?.accessToken = "replacement"

        #expect(Set([hermes, t3, otherEnvironment, otherProject].map(AppStore.artifactScope)).count == 4)
        #expect(Set([hermes, t3, otherEnvironment, otherProject].map(AppStore.richReplyAccount)).count == 4)
        #expect(AppStore.artifactScope(rotatedToken) == AppStore.artifactScope(t3))
        #expect(AppStore.richReplyAccount(rotatedToken) == AppStore.richReplyAccount(t3))
    }

    @Test func loadsTheBackendForSavedSetupWithoutAnInjectedService() {
        let t3 = t3Configuration()
        let store = AppStore(persistence: MemoryConnectionStorage(saved: t3).persistence)
        #expect(store.t3BrainService is T3BotService)
        var hermes = t3
        hermes.t3 = nil
        let prior = AppStore(persistence: MemoryConnectionStorage(saved: hermes).persistence)
        #expect(!prior.isT3Workspace)
        #expect(prior.t3BrainService == nil)
    }

    @Test func passesOutputsThroughTheMountedService() async throws {
        let configuration = t3Configuration()
        defer { LocalHistory.remove(for: configuration.id) }
        let service = T3WorkspaceService()
        let store = AppStore(service: service, persistence: MemoryConnectionStorage(saved: configuration).persistence)
        await store.start()

        let outputs = try await store.listT3Outputs()
        #expect(outputs.map(\.relativePath) == ["outputs/report.md", "outputs/charts/plot.png"])
        let report = try #require(outputs.first)
        let downloaded = try await store.downloadT3Output(report)
        #expect(downloaded == DownloadedArtifact(data: Data("# Report".utf8), filename: "report.md", mimeType: "text/markdown"))
        #expect(service.downloadedOutputs == ["outputs/report.md"])
        await #expect(throws: T3ServiceError.invalidPath) {
            try await store.downloadT3Output(T3OutputFile(name: "secret", relativePath: "SOUL.md", mimeType: "text/plain"))
        }
    }

    @Test func switchesChannelModelsAndMarksChannelsVisited() async throws {
        let configuration = t3Configuration()
        defer { LocalHistory.remove(for: configuration.id) }
        let service = T3WorkspaceService()
        let store = AppStore(service: service, persistence: MemoryConnectionStorage(saved: configuration).persistence)
        await store.start()

        let model = try #require(try await store.availableT3Models().first)
        try await store.setT3ChannelModel(threadID: "release", providerInstanceID: model.providerInstanceID, model: model.modelID)
        #expect(service.channelModels == ["release": "claude/claude-test"])
        try await store.markT3ChannelVisited(threadID: "release")
        #expect(service.visitedThreads == ["release"])

        let release = try #require(store.t3Channels.last)
        #expect(await store.openT3Channel(release))
        #expect(store.selectedT3ChannelID == "release")
    }

    @Test func t3PassthroughsRefuseHermesAndDisconnectedWorkspaces() async throws {
        let hermes = ConnectionConfiguration(serverURL: URL(string: "https://studio.example")!, username: "hermes")
        defer { LocalHistory.remove(for: hermes.id) }
        let store = AppStore(service: try WorkspaceTestService(), persistence: MemoryConnectionStorage(saved: hermes).persistence)
        await store.start()
        #expect(!store.isT3Workspace)
        await #expect(throws: T3ServiceError.unsupported) { try await store.listT3Outputs() }
        await #expect(throws: T3ServiceError.unsupported) { try await store.listT3Routines() }
        await #expect(throws: T3ServiceError.unsupported) {
            try await store.setT3ChannelModel(threadID: "general", providerInstanceID: "claude", model: "claude-test")
        }
        await #expect(throws: T3ServiceError.unsupported) { try await store.markT3ChannelVisited(threadID: "general") }

        let configuration = t3Configuration()
        defer { LocalHistory.remove(for: configuration.id) }
        let offline = AppStore(service: T3WorkspaceService(), persistence: MemoryConnectionStorage(saved: configuration).persistence)
        #expect(!offline.isConnected)
        await #expect(throws: T3ServiceError.disconnected) { try await offline.listT3Outputs() }
        await #expect(throws: T3ServiceError.disconnected) { try await offline.deleteT3Routine(id: "any") }
    }

    @Test func newSpacePageStartsAnAutoNamedSpaceAndSendsTheFirstMessage() async throws {
        let configuration = t3Configuration()
        defer { LocalHistory.remove(for: configuration.id) }
        let service = T3WorkspaceService()
        let store = AppStore(service: service, persistence: MemoryConnectionStorage(saved: configuration).persistence)
        await store.start()
        let model = try #require(try await store.availableT3Models().first)

        try await store.startT3Space(with: "Plan the Kyoto days", model: model)

        #expect(service.createdTitles == [nil])
        let created = try #require(service.createdThreads.first)
        #expect(service.channelModels == [created: "claude/claude-test"])
        #expect(store.selectedT3ChannelID == created)
        #expect(store.selectedT3ChannelTitle == "New space")
        #expect(service.sent == [created: ["Plan the Kyoto days"]])
        #expect(store.draft(for: "bot-project").isEmpty)

        // Attaching first opens a new space and keeps the typed words as its draft, unsent.
        try await store.startT3Space(with: "Here is the itinerary", send: false)
        let second = try #require(service.createdThreads.last)
        #expect(store.selectedT3ChannelID == second)
        #expect(service.sent[second] == nil)
        #expect(store.draft(for: "bot-project") == "Here is the itinerary")
    }

    @Test func newSpacePageKeepsTheNameTheUserChose() async throws {
        let configuration = t3Configuration()
        defer { LocalHistory.remove(for: configuration.id) }
        let service = T3WorkspaceService()
        let store = AppStore(service: service, persistence: MemoryConnectionStorage(saved: configuration).persistence)
        await store.start()

        try await store.startT3Space(named: "  Kyoto trip ", with: "Five slow days")
        #expect(service.createdTitles == ["Kyoto trip"])
        #expect(store.selectedT3ChannelTitle == "Kyoto trip")
        let kyoto = try #require(service.createdThreads.last)
        #expect(service.sent[kyoto] == ["Five slow days"])

        // A name alone makes a space, ready and silent.
        try await store.startT3Space(named: "Garden", with: "", send: false)
        #expect(service.createdTitles == ["Kyoto trip", "Garden"])
        #expect(store.selectedT3ChannelTitle == "Garden")
        #expect(service.sent.count == 1)
    }

    @Test func newSpaceStartFailsBeforeASpaceOpensWhenOffline() async throws {
        let configuration = t3Configuration()
        defer { LocalHistory.remove(for: configuration.id) }
        let offline = AppStore(service: T3WorkspaceService(), persistence: MemoryConnectionStorage(saved: configuration).persistence)
        await #expect(throws: T3ServiceError.disconnected) { try await offline.startT3Space(with: "Hello") }
        #expect(offline.selectedT3ChannelID == nil)
    }

    @Test func newSpaceDoesNotReportSuccessAfterAFailedAttachment() async throws {
        let configuration = t3Configuration()
        defer { LocalHistory.remove(for: configuration.id) }
        let service = T3WorkspaceService()
        let store = AppStore(service: service, persistence: MemoryConnectionStorage(saved: configuration).persistence)
        await store.start()
        let release = try #require(store.t3Channels.first { $0.id == "release" })
        #expect(await store.openT3Channel(release))
        service.openError = .missingChannel
        var created: SessionIdentity?

        await #expect(throws: T3ServiceError.missingChannel) {
            try await store.startT3Space(with: "Keep the draft", onCreated: { created = $0 })
        }
        #expect(service.createdThreads.count == 1)
        #expect(service.sent.isEmpty)
        #expect(store.selectedT3ChannelID == release.id)

        service.openError = nil
        let identity = try #require(created)
        let opened = try await store.startT3Space(with: "Keep the draft", resuming: identity)
        #expect(opened == identity)
        #expect(service.createdThreads.count == 1)
        #expect(service.sent[opened.stored.text] == ["Keep the draft"])
    }

    @Test func newSpaceDoesNotSendWhenTheChosenModelIsRejected() async throws {
        let configuration = t3Configuration()
        defer { LocalHistory.remove(for: configuration.id) }
        let service = T3WorkspaceService()
        let store = AppStore(service: service, persistence: MemoryConnectionStorage(saved: configuration).persistence)
        await store.start()
        let model = try #require(try await store.availableT3Models().first)
        service.modelError = .missingModel

        await #expect(throws: T3ServiceError.missingModel) {
            try await store.startT3Space(with: "Use the chosen provider", model: model)
        }
        #expect(service.createdThreads.count == 1)
        #expect(service.sent.isEmpty)
    }

    @Test func lateNewSpaceDoesNotTakeOverANewerSelection() async throws {
        let configuration = t3Configuration()
        defer { LocalHistory.remove(for: configuration.id) }
        let service = T3WorkspaceService()
        let store = AppStore(service: service, persistence: MemoryConnectionStorage(saved: configuration).persistence)
        await store.start()
        let gate = WorkspaceGate()
        service.createGate = gate
        let starting = Task { try await store.startT3Space(with: "Leave this unsent") }
        await gate.entered()
        defer { gate.release() }
        let release = try #require(store.t3Channels.first { $0.id == "release" })
        #expect(await store.openT3Channel(release))
        gate.release()

        await #expect(throws: HermesServiceError.staleConversation) { try await starting.value }
        #expect(store.selectedT3ChannelID == release.id)
        #expect(service.createdThreads.count == 1)
        #expect(service.sent.isEmpty)
    }

    @Test func modelChipNamesEachSpacesModel() async throws {
        let configuration = t3Configuration()
        defer { LocalHistory.remove(for: configuration.id) }
        let service = T3WorkspaceService()
        let store = AppStore(service: service, persistence: MemoryConnectionStorage(saved: configuration).persistence)
        await store.start()
        #expect(store.t3ModelLabel(provider: "claude", model: "claude-test") == "claude-test")
        await store.loadT3ModelsIfNeeded()
        #expect(store.t3Models.map(\.modelID) == ["claude-test"])
        #expect(store.t3ModelLabel(provider: "claude", model: "claude-test") == "Claude Test")
        #expect(store.t3ModelLabel(provider: "other", model: "gpt-x") == "gpt-x")
        #expect(store.t3ModelLabel(provider: nil, model: nil) == nil)
        let release = try #require(store.t3Channels.first { $0.id == "release" })
        #expect(release.model == "claude-test")

        try await store.setT3DefaultModel(store.t3Models.first)
        #expect(try await store.loadT3BotBrain().manifest.model == "claude-test")
        try await store.setT3DefaultModel(nil)
        #expect(try await store.loadT3BotBrain().manifest.model == nil)
        try await store.renameT3Bot("Kit")
        #expect(store.primaryT3Bot?.name == "Kit")
    }

    private func t3Configuration() -> ConnectionConfiguration {
        .init(serverURL: URL(string: "https://studio.example")!, installID: "studio-id",
              t3: .init(environmentID: "studio-id", label: "Studio", accessToken: "fixture-only", projectID: "bot-project"))
    }
}

@MainActor private final class T3WorkspaceService: T3BotBrainControlling {
    var onEvent: ((BotServiceEvent) -> Void)?
    var connectError: T3ServiceError?
    var resolvedPairing: T3Connection?
    var openError: T3ServiceError?
    var modelError: T3ServiceError?
    var createGate: WorkspaceGate?
    private(set) var disconnects = 0
    private(set) var openedStoredThreads: [String] = []
    private(set) var downloadedOutputs: [String] = []
    private(set) var channelModels: [String: String] = [:]
    private(set) var visitedThreads: [String] = []
    private(set) var createdTitles: [String?] = []
    private(set) var createdThreads: [String] = []
    private(set) var sent: [String: [String]] = [:]
    private var manifest = T3BotManifest(displayName: "Studio Bot")
    private var soul = "# Soul"
    private var memory = "# Memory"
    private let issuer = ConversationIssuer<SessionIdentity>()
    private let profile = try! ExactID("bot-project")

    let currentBotWorkspaceRoot: String? = "/host/.botto/bots/main"
    private(set) var currentT3Channels: [T3ChannelSummary] = [
        .init(id: "general", title: "#general", isMain: true, isPinned: false, isArchived: false, isUnread: false,
              status: .idle, preview: "", updatedAt: nil),
        .init(id: "release", title: "Release", isPinned: false, isArchived: false, isUnread: true,
              status: .waiting, preview: "Release notes", updatedAt: nil, providerInstanceID: "claude", model: "claude-test"),
    ]

    func connect(configuration: ConnectionConfiguration) async throws -> ServerInfo {
        if let connectError { throw connectError }
        if let resolvedPairing {
            var connected = configuration
            connected.t3 = resolvedPairing
            onEvent?(.configuration(connected))
        }
        return .init(version: "fixture", installID: configuration.t3?.environmentID)
    }
    func disconnect() { disconnects += 1; issuer.retireAttachment() }
    func bots() async throws -> [BotProfile] {
        [.init(id: profile.text, name: manifest.displayName, description: manifest.description, model: manifest.model)]
    }
    func conversations(profile: ExactID) async throws -> ConversationDirectory {
        let summaries = try currentT3Channels.map { channel in
            let thread = try ExactID(channel.id)
            return SessionSummary(identity: .init(profile: profile, root: thread, stored: thread, aliases: []),
                                  title: channel.displayTitle, isCanonical: false, persistence: .durable)
        }
        return .init(summaries: summaries, activity: [:], isComplete: true)
    }
    func openChat(_ target: SessionTarget) async throws -> OpenedConversation {
        if let openError { throw openError }
        guard case .stored(let identity) = target, identity.profile == profile else { throw T3ServiceError.missingChannel }
        let thread = identity.stored.text
        openedStoredThreads.append(thread)
        let snapshot = Conversation(id: thread, storedID: thread, profileID: profile.text,
                                    messages: [.init(id: "reply", role: .assistant, text: "Chat in \(thread)")])
        return .init(identity: identity, snapshot: snapshot, access: try issuer.issue(identity))
    }
    func loadBotBrain() async throws -> T3BotBrainSnapshot {
        .init(manifest: manifest, soulMarkdown: soul, memoryMarkdown: memory, skills: ["skills/check"],
              workspaceRoot: "/host/.botto/bots/main")
    }
    func saveSoul(_ markdown: String, replacing expected: String?) async throws {
        if let expected, expected != soul { throw T3ServiceError.proseChanged }
        soul = markdown
    }
    func saveMemory(_ markdown: String, replacing expected: String?) async throws {
        if let expected, expected != memory { throw T3ServiceError.proseChanged }
        memory = markdown
    }
    func saveManifest(_ manifest: T3BotManifest) async throws { self.manifest = manifest }
    func setDefaultModel(_ option: T3ModelOption?) async throws -> T3BotManifest {
        manifest.providerInstanceID = option?.providerInstanceID
        manifest.model = option?.modelID
        return manifest
    }
    func availableModels() async throws -> [T3ModelOption] {
        [.init(id: "claude-test", providerInstanceID: "claude", providerName: "Claude", modelID: "claude-test", label: "Claude Test")]
    }
    func readProjectFile(relativePath: String) async throws -> String {
        guard relativePath == "skills/check/SKILL.md" else { throw T3ServiceError.invalidPath }
        return "# Check"
    }

    func listOutputs() async throws -> [T3OutputFile] {
        [.init(name: "report.md", relativePath: "outputs/report.md", mimeType: "text/markdown"),
         .init(name: "plot.png", relativePath: "outputs/charts/plot.png", mimeType: "image/png")]
    }
    func downloadOutput(_ output: T3OutputFile) async throws -> DownloadedArtifact {
        guard output.relativePath.hasPrefix("outputs/") else { throw T3ServiceError.invalidPath }
        downloadedOutputs.append(output.relativePath)
        return .init(data: Data("# Report".utf8), filename: output.name, mimeType: output.mimeType)
    }
    func setChannelModel(threadID: String, providerInstanceID: String, model: String) async throws {
        if let modelError { throw modelError }
        channelModels[threadID] = "\(providerInstanceID)/\(model)"
    }
    func markChannelVisited(threadID: String) async throws { visitedThreads.append(threadID) }

    func createBot(_ draft: BotDraft) async throws -> BotProfile { throw T3ServiceError.unsupported }
    func createChat(title: String?) async throws -> CreatedSession {
        await createGate?.wait()
        let id = "chat-\(createdThreads.count + 1)"
        createdTitles.append(title)
        createdThreads.append(id)
        currentT3Channels.insert(.init(id: id, title: title ?? T3ChannelSummary.untitledWireTitle, isPinned: false,
                                       isArchived: false, isUnread: false, status: .idle, preview: "", updatedAt: .now), at: 0)
        let thread = try ExactID(id)
        return .init(operationID: UUID(), summary: .init(identity: .init(profile: profile, root: thread, stored: thread, aliases: []),
                                                         title: "New chat", isCanonical: false, persistence: .durable))
    }
    func updateProfile(_ edit: BotProfileEdit, for bot: BotProfile) async throws -> BotProfile {
        if let name = edit.name { manifest.displayName = name }
        return try await bots()[0]
    }
    func renameChannel(threadID: String, title: String) async throws { throw T3ServiceError.unsupported }
    func setChannelPinned(threadID: String, pinned: Bool) async throws { throw T3ServiceError.unsupported }
    func archiveChannel(threadID: String, archived: Bool) async throws { throw T3ServiceError.unsupported }
    func createConversation(profile: ExactID, operationID: UUID) async throws -> CreatedSession { throw T3ServiceError.unsupported }
    func send(text: String, attachments: [ChatAttachment], delivery: MessageDelivery, access: ConversationAccess,
              operationID: UUID) async throws -> MutationReceipt {
        let identity = try issuer.resolve(access)
        sent[identity.stored.text, default: []].append(text)
        return .init(operationID: operationID, source: identity, admissionID: operationID.uuidString, journal: .saved)
    }
    func stop(access: ConversationAccess, operationID: UUID) async throws -> MutationReceipt { throw T3ServiceError.unsupported }
    func respond(to request: PendingRequest, response: RequestResponse, access: ConversationAccess,
                 operationID: UUID) async throws -> MutationReceipt { throw T3ServiceError.unsupported }
    func upload(data: Data, filename: String, mimeType: String, access: ConversationAccess) async throws -> ChatAttachment {
        _ = try issuer.resolve(access)
        return .init(name: filename, path: "staged/" + filename, mimeType: mimeType)
    }
    func downloadArtifact(_ attachment: ChatAttachment, access: ConversationAccess) async throws -> DownloadedArtifact {
        throw T3ServiceError.unsupported
    }
}
