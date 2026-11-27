import AppKit
import Foundation
import SwiftUI
import Testing
@testable import BottoCore
@testable import BottoMac

@MainActor struct MacFirstRunTests {
    @Test func firstRunNamesTheBotAndItsMainSpaceAndSavesTheFace() async throws {
        let host = FirstRunHost()
        let store = try await connected(to: host)
        #expect(store.needsBotSetup)
        #expect(store.channels.map(\.displayTitle) == ["Botto"])

        // A failed rename keeps the page up to try again, through a reconnection too. The choices are already safe.
        host.failsRename = true
        await #expect(throws: ConversationServiceError.uncertain) {
            try await store.setUpBot(name: "Miso", face: BotFace(shape: .drop, color: "#38bdf8"))
        }
        #expect(host.manifest.displayName == "Miso")
        #expect(store.needsBotSetup)
        store.disconnect()
        await store.connect(origin: origin) { _ in configuration }
        #expect(store.bot?.name == "Miso")
        #expect(store.needsBotSetup)

        host.failsRename = false
        try await store.setUpBot(name: "  Miso ", face: BotFace(shape: .drop, color: "#38bdf8"))
        #expect(!store.needsBotSetup)
        #expect(store.bot?.name == "Miso")
        #expect(store.bot?.appearance?.shape == .drop)
        #expect(store.channels.first(where: \.isMain)?.displayTitle == "Miso")
        // What bot.json holds.
        let saved = try JSONDecoder().decode(T3BotManifest.self, from: Data(T3BotBootstrap.manifestJSON(host.manifest).utf8))
        #expect(saved.displayName == "Miso")
        #expect(saved.avatar?.shape == .drop)
        #expect(saved.avatar?.color == BotAvatarColors.preset(for: "#38bdf8")?.shared)
        #expect(saved.mainThreadID == "main-space")

        // Launching again finds it all done.
        store.disconnect()
        #expect(!store.needsBotSetup)
        await store.connect(origin: origin) { _ in configuration }
        #expect(store.isConnected)
        #expect(!store.needsBotSetup)
    }

    @Test func keepingTheOfferedNameStillFinishesSetup() async throws {
        let host = FirstRunHost()
        let store = try await connected(to: host)
        try await store.setUpBot(name: "Botto", face: BotFace(shape: .circle, color: "#22c55e"))
        // The rename, even to the same title, is what tells other connected devices.
        #expect(host.renames == ["main-space": "Botto"])
        #expect(!store.needsBotSetup)
    }

    @Test func firstRunEndsInAMainSpaceMadeAfterConnecting() async throws {
        let host = FirstRunHost(mainSpace: false)
        let store = try await connected(to: host)
        #expect(store.needsBotSetup)
        #expect(store.selectedChannelID == nil)
        try await store.setUpBot(name: "Miso", face: BotFace(shape: .drop, color: "#38bdf8"))
        #expect(store.selectedChannelID == "main-space")
        #expect(store.selectedChannel?.displayTitle == "Miso")
    }

    @Test func missingProvidersAreExplainedUntilOneWorks() async throws {
        let host = FirstRunHost(mainSpace: false)
        host.found = [.init(id: "codex", driver: "codex", state: .notInstalled),
                      .init(id: "claudeAgent", driver: "claudeAgent", state: .needsSignIn)]
        let store = try await connected(to: host)
        await store.loadProviders()
        #expect(store.providersNeedingSetup.map(\.guide) == [.codex, .claude])
        #expect(store.showsProviderGuide)
        #expect(!store.canStartSpace)
        // The bot can be named before anything can answer.
        #expect(store.needsBotSetup)
        try await store.setUpBot(name: "Miso", face: BotFace(shape: .drop, color: "#38bdf8"))
        #expect(!store.needsBotSetup)
        #expect(store.channels.isEmpty)

        // Signing in and coming back clears the page and opens the main space, already named.
        host.found[1] = .init(id: "claudeAgent", driver: "claudeAgent", state: .ready)
        await store.loadProviders()
        #expect(store.providersNeedingSetup.isEmpty)
        #expect(store.canStartSpace)
        #expect(store.channels.map(\.displayTitle) == ["Miso"])
        #expect(store.selectedChannelID == "main-space")
        #expect(store.models.map(\.modelID) == ["claude-test"])
    }

    @Test func aFailedLookForProvidersIsTriedAgain() async throws {
        let host = FirstRunHost(mainSpace: false)
        host.found = [.init(id: "claudeAgent", driver: "claudeAgent", state: .needsSignIn)]
        host.failsProviders = true
        let store = try await connected(to: host)
        #expect(store.providers == nil)
        #expect(!store.showsProviderGuide)
        // Coming back to the window looks again.
        #expect(store.wantsProviderCheck)
        host.failsProviders = false
        await store.loadProviders()
        #expect(store.showsProviderGuide)
        #expect(store.wantsProviderCheck)

        host.found[0] = .init(id: "claudeAgent", driver: "claudeAgent", state: .ready)
        host.onEvent?(.disconnected("Lost"))
        host.onEvent?(.connected(.init(version: "fixture", installID: "mac")))
        try await settled { store.canStartSpace && !store.models.isEmpty }
        #expect(!store.wantsProviderCheck)
    }

    @Test func signingInLeavesANewSpaceBeingWritten() async throws {
        let host = FirstRunHost(preview: "See you Tuesday")
        host.found = [.init(id: "claudeAgent", driver: "claudeAgent", state: .needsSignIn)]
        let store = try await connected(to: host)
        store.showFreshPage()
        #expect(store.selectedChannelID == nil)
        host.found[0] = .init(id: "claudeAgent", driver: "claudeAgent", state: .ready)
        await store.loadProviders()
        #expect(store.models.map(\.modelID) == ["claude-test"])
        #expect(store.selectedChannelID == nil)
    }

    /// The first send belongs to the new-space page from the moment it starts, before its space exists.
    @Test func aProviderBecomingReadyLeavesAFirstSendAlone() async throws {
        let host = FirstRunHost(mainSpace: false)
        host.found = [.init(id: "claudeAgent", driver: "claudeAgent", state: .needsSignIn)]
        host.failsProviders = true
        let store = try await connected(to: host)
        store.fresh.text = "Hello"
        let replied = AsyncStream<Void>.makeStream()
        host.createReply = replied.stream
        let sending = Task { await store.startSpace() }
        try await settled { host.isCreating }

        // A look that finds nothing doesn't put the guide over it, and one that finds a provider doesn't open the main space.
        host.failsProviders = false
        await store.loadProviders()
        #expect(!store.providersNeedingSetup.isEmpty)
        #expect(!store.showsProviderGuide)
        host.found[0] = .init(id: "claudeAgent", driver: "claudeAgent", state: .ready)
        await store.loadProviders()
        #expect(store.channels.map(\.id) == ["main-space"])
        #expect(store.selectedChannelID == nil)

        replied.continuation.finish()
        await sending.value
        #expect(host.sent == ["new-space": "Hello"])
        #expect(store.selectedChannelID == "new-space")
        #expect(store.fresh.text.isEmpty)
    }

    @Test func providerHelpNeverReplacesAConversation() async throws {
        let host = FirstRunHost(preview: "See you Tuesday")
        host.found = [.init(id: "claudeAgent", driver: "claudeAgent", state: .needsSignIn)]
        let store = try await connected(to: host)
        await store.loadProviders()
        #expect(!store.needsBotSetup)
        #expect(!store.showsProviderGuide)
        #expect(store.canStartSpace)
        #expect(!store.providersNeedingSetup.isEmpty)
    }

    @Test func providerCopyStaysPlain() {
        let providers: [T3ProviderStatus] = [
            .init(id: "codex", driver: "codex", state: .notInstalled),
            .init(id: "work", driver: "claudeAgent", state: .notInstalled),
            .init(id: "home", driver: "claudeAgent", state: .needsSignIn),
        ]
        let cards = MacProviderCopy.cards(providers)
        #expect(cards.map(\.guide) == [.claude, .codex])
        #expect(cards.map(\.state) == [.needsSignIn, .notInstalled])
        #expect(MacProviderCopy.summary(providers, botName: "Miso") == "Miso can’t think until you sign in to Claude or Codex.")
        let states: [T3ProviderStatus.State] = [.ready, .needsSignIn, .notInstalled, .notWorking, .off]
        for text in states.map(MacProviderCopy.status) + states.map(MacProviderCopy.step) {
            for jargon in ["CLI", "PATH", "provider", "auth", "LLM", "binary", "T3"] { #expect(!text.contains(jargon)) }
        }
    }

    private let origin = URL(string: "http://127.0.0.1:3774")!
    private var configuration: ConnectionConfiguration {
        .init(serverURL: origin, t3: T3Connection(environmentID: "mac", accessToken: "fixture-only", projectID: "bot-project"))
    }

    private func connected(to host: FirstRunHost) async throws -> MacBottoStore {
        let suite = "botto.mac.first-run-tests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MacBottoStore(session: MacSessionPersistence(slot: MacSessionPersistenceTests.MemorySlot(), defaults: defaults),
                                  service: host)
        await store.connect(origin: origin) { _ in configuration }
        try #require(store.isConnected)
        // The store's own first look happens in the background; let it finish before steering it.
        try await settled { host.looks > 0 && !store.isCheckingProviders }
        return store
    }

    private func settled(_ done: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !done(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(done(), "The store never settled")
    }
}

/// The real card in a window of the test host, pressed the way VoiceOver presses it.
@MainActor struct MacRequestCardTests {
    @Test func alwaysAllowAsksFirstAndCancelSendsNothing() async throws {
        let host = FirstRunHost(preview: "Hi")
        let store = try await connected(to: host)
        let request = PendingRequest(id: "run-tests", kind: .approval, title: "Run the test suite?",
                                     detail: "`swift test` in the bot's folder.",
                                     choices: [.init(id: "once", label: "Allow once"),
                                               .init(id: "always", label: "Always allow"),
                                               .init(id: "deny", label: "Deny")])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 220), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MacRuntimeRequestCard(request: request, store: store).padding(20))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        // What VoiceOver sets on the app; until something does, SwiftUI keeps no accessibility tree.
        let enhance = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        NSApp.perform(enhance, with: true, with: "AXEnhancedUserInterface")
        defer { NSApp.perform(enhance, with: false, with: "AXEnhancedUserInterface") }
        try await settled { button("Always allow", in: window) != nil }
        record(window, named: "request-card")

        // Any other choice still answers on one click.
        try press("Allow once", in: window)
        try await settled { host.responses == [.choice("once")] }
        #expect(window.attachedSheet == nil)

        try await settled { !store.respondingRequestIDs.contains(request.id) }
        try press("Always allow", in: window)
        try await settled { window.attachedSheet != nil }
        let sheet = try #require(window.attachedSheet)
        try await settled { button("Cancel", in: sheet) != nil }
        record(sheet, named: "allow-future-actions")
        #expect(host.responses == [.choice("once")])

        try press("Cancel", in: sheet)
        try await settled { window.attachedSheet == nil }
        try await Task.sleep(for: .milliseconds(200))
        #expect(host.responses == [.choice("once")])

        try press("Always allow", in: window)
        try await settled { window.attachedSheet != nil }
        try press("Always allow", in: try #require(window.attachedSheet))
        try await settled { host.responses == [.choice("once"), .choice("always")] }
    }

    private func connected(to host: FirstRunHost) async throws -> MacBottoStore {
        let suite = "botto.mac.request-card-tests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MacBottoStore(session: MacSessionPersistence(slot: MacSessionPersistenceTests.MemorySlot(), defaults: defaults),
                                  service: host)
        let origin = URL(string: "http://127.0.0.1:3774")!
        await store.connect(origin: origin) { _ in
            .init(serverURL: origin, t3: T3Connection(environmentID: "mac", accessToken: "fixture-only", projectID: "bot-project"))
        }
        try await settled { store.openedConversation != nil }
        return store
    }

    private func settled(_ done: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !done(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(done(), "The card never settled", sourceLocation: sourceLocation)
    }

    private func press(_ title: String, in window: NSWindow) throws {
        let button = try #require(button(title, in: window), "No \(title) button")
        // The alert's own buttons act but answer false, so what a press did is checked by its effect.
        _ = button.accessibilityPerformPress?()
    }

    private func button(_ title: String, in window: NSWindow) -> AnyObject? {
        func find(_ element: Any) -> AnyObject? {
            let node = element as AnyObject
            let name = (node.accessibilityLabel?() ?? nil) ?? (node.accessibilityTitle?() ?? nil)
            if node.accessibilityRole?() == .button, name == title, node.isAccessibilityEnabled?() == true { return node }
            return (node.accessibilityChildren?() ?? []).lazy.compactMap(find).first
        }
        return window.contentView.flatMap(find)
    }

    /// Kept with the test's results, for seeing what a person sees.
    private func record(_ window: NSWindow, named name: String) {
        guard let view = window.contentView?.superview ?? window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        Attachment.record(png, named: name + ".png")
    }
}

/// A host with one new bot, as a first launch finds it.
@MainActor private final class FirstRunHost: T3BotBrainControlling {
    var onEvent: ((BotServiceEvent) -> Void)?
    var failsRename = false
    var failsProviders = false
    private(set) var looks = 0
    /// Holds a new space's reply until it finishes.
    var createReply: AsyncStream<Void>?
    private(set) var isCreating = false
    private(set) var sent: [String: String] = [:]
    private(set) var responses: [RequestResponse] = []
    var found: [T3ProviderStatus] = [.init(id: "claudeAgent", driver: "claudeAgent", state: .ready)]
    private(set) var renames: [String: String] = [:]
    private(set) var manifest = T3BotManifest(displayName: "Botto")
    private(set) var currentT3Channels: [T3ChannelSummary] = []
    let currentBotWorkspaceRoot: String? = "/host/.botto/bots/main"
    private let issuer = ConversationIssuer<SessionIdentity>()
    private let profile = try! ExactID("bot-project")

    init(mainSpace: Bool = true, preview: String = "") {
        if mainSpace { makeMainSpace(preview: preview) }
    }

    private func makeMainSpace(preview: String = "") {
        manifest.mainThreadID = "main-space"
        currentT3Channels = [.init(id: "main-space", title: manifest.displayName, isMain: true, isPinned: false, isArchived: false,
                                   isUnread: false, status: .idle, preview: preview, updatedAt: nil)]
    }

    func connect(configuration: ConnectionConfiguration) async throws -> ServerInfo { .init(version: "fixture", installID: "mac") }
    func disconnect() {}
    func bots() async throws -> [BotProfile] {
        [.init(id: profile.text, name: manifest.displayName, appearance: manifest.avatar)]
    }
    func loadBotBrain() async throws -> T3BotBrainSnapshot {
        .init(manifest: manifest, soulMarkdown: "", memoryMarkdown: "", skills: [], workspaceRoot: "/host/.botto/bots/main")
    }
    func saveManifest(_ manifest: T3BotManifest) async throws {
        let main = self.manifest.mainThreadID
        self.manifest = manifest
        self.manifest.mainThreadID = main
    }
    func renameChannel(threadID: String, title: String) async throws {
        if failsRename { throw ConversationServiceError.uncertain }
        renames[threadID] = title
        currentT3Channels = currentT3Channels.map {
            .init(id: $0.id, title: $0.id == threadID ? title : $0.title, isMain: $0.isMain, isPinned: $0.isPinned, isArchived: $0.isArchived,
                  isUnread: $0.isUnread, status: $0.status, preview: $0.preview, updatedAt: $0.updatedAt)
        }
    }
    func providers() async throws -> [T3ProviderStatus] {
        looks += 1
        if failsProviders { throw T3ServiceError.disconnected }
        return found
    }
    /// Like the live service: the first usable model is what makes the main space.
    func availableModels() async throws -> [T3ModelOption] {
        guard found.contains(where: { $0.state == .ready }) else { return [] }
        if currentT3Channels.isEmpty { makeMainSpace() }
        return [.init(id: "claude-test", providerInstanceID: "claudeAgent", providerName: "Claude", modelID: "claude-test", label: "Claude Test")]
    }
    func openChat(_ target: SessionTarget) async throws -> OpenedConversation {
        // Without a main space, a host still looking for its providers can't make one.
        guard case .stored(let identity) = target else { throw T3ServiceError.missingModel }
        let thread = identity.stored.text
        return .init(identity: identity, snapshot: Conversation(id: thread, storedID: thread, profileID: profile.text, messages: []),
                     access: try issuer.issue(identity))
    }

    func conversations(profile: ExactID) async throws -> ConversationDirectory { .init(summaries: [], activity: [:]) }
    func saveSoul(_ markdown: String, replacing expected: String?) async throws {}
    func saveMemory(_ markdown: String, replacing expected: String?) async throws {}
    func setDefaultModel(_ option: T3ModelOption?) async throws -> T3BotManifest { throw T3ServiceError.unsupported }
    func createChat(title: String?) async throws -> CreatedSession {
        guard let createReply else { throw T3ServiceError.unsupported }
        isCreating = true
        for await _ in createReply {}
        currentT3Channels.append(.init(id: "new-space", title: "", isMain: false, isPinned: false, isArchived: false,
                                       isUnread: false, status: .idle, preview: "", updatedAt: nil))
        let thread = try ExactID("new-space")
        let identity = SessionIdentity(profile: profile, root: thread, stored: thread, aliases: [])
        return .init(operationID: UUID(), summary: .init(identity: identity, title: "", isCanonical: false, persistence: .durable))
    }
    func setChannelPinned(threadID: String, pinned: Bool) async throws {}
    func archiveChannel(threadID: String, archived: Bool) async throws {}
    func readProjectFile(relativePath: String) async throws -> String { throw T3ServiceError.unsupported }
    func updateProfile(_ edit: BotProfileEdit, for bot: BotProfile) async throws -> BotProfile { throw T3ServiceError.unsupported }
    func createConversation(profile: ExactID, operationID: UUID) async throws -> CreatedSession { throw T3ServiceError.unsupported }
    func send(text: String, attachments: [ChatAttachment], delivery: MessageDelivery, access: ConversationAccess,
              operationID: UUID) async throws -> MutationReceipt {
        let identity = try issuer.resolve(access)
        sent[identity.stored.text] = text
        return .init(operationID: operationID, source: identity, admissionID: nil)
    }
    func stop(access: ConversationAccess, operationID: UUID) async throws -> MutationReceipt { throw T3ServiceError.unsupported }
    func respond(to request: PendingRequest, response: RequestResponse, access: ConversationAccess,
                 operationID: UUID) async throws -> MutationReceipt {
        responses.append(response)
        return .init(operationID: operationID, source: try issuer.resolve(access), admissionID: nil)
    }
    func upload(data: Data, filename: String, mimeType: String, access: ConversationAccess) async throws -> ChatAttachment {
        throw T3ServiceError.unsupported
    }
    func downloadArtifact(_ attachment: ChatAttachment, access: ConversationAccess) async throws -> DownloadedArtifact {
        throw T3ServiceError.unsupported
    }
}
