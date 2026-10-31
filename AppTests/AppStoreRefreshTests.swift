import Testing
import Foundation
import BottoCore
@testable import Botto

@MainActor struct AppStoreRefreshTests {
    @Test func inboxPreviewKeepsTheLastReadableMessageAfterSilentAutomation() async throws {
        let service = try WorkspaceTestService(), identity = service.summaries[0].identity
        let replyAt = Date(timeIntervalSince1970: 100)
        let messages: [ChatMessage] = [
            .init(id: "question", role: .user, text: "How is the service?"),
            .init(id: "reply", role: .assistant, text: "The service is healthy.", timestamp: replyAt),
            .init(id: "process", role: .user, text: "[IMPORTANT: Background process proc_example completed normally.]",
                  displayKind: "process_complete"),
            .init(id: "quiet", role: .assistant, text: "[SILENT]", isSilent: true)
        ]
        service.snapshots[identity.root]?.messages = messages
        service.summaries[0] = .init(identity: identity, title: "Bot Chat", isCanonical: true, persistence: .durable,
            preview: "[SILENT]", updatedAt: Date(timeIntervalSince1970: 200), messageCount: messages.count)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://inbox-preview.invalid")!)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        try #require(await store.connect(configuration))
        await store.open(try #require(store.bots.first))
        let bot = try #require(store.inbox.first?.bot)
        #expect(bot.preview == "The service is healthy.")
        #expect(bot.updatedAt == replyAt)
        #expect(store.conversation(for: bot.id)?.messages == messages)
        #expect(store.chats.persisted().records.allSatisfy { $0.seen == nil })
    }

    @Test func inboxUnreadFollowsSelectedChatWithoutClearingUnreadSiblings() async throws {
        let service = try WorkspaceTestService()
        service.summaries = service.summaries.map {
            .init(identity: $0.identity, title: $0.title, isCanonical: $0.isCanonical,
                  persistence: .durable, messageCount: 1)
        }
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://selected-chat-unread.invalid")!)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        let bot = try #require(store.bots.first)
        await store.open(bot)
        let main = try #require(store.chats.screen(profile: service.profile))
        await store.chats.refreshDirectory(main.owner)
        store.chats.displayed(main.owner)
        let other = try #require(store.chats.cards(profile: service.profile).first { !$0.isMain })
        try #require(other.unread)
        #expect(!store.isUnread(bot), "Unread sibling chats must not light the selected chat's inbox dot")

        await store.chats.select(try #require(store.chats.captureSelection(other.id, owner: main.owner)))
        #expect(store.isUnread(bot), "Selecting an unread chat lights the dot before its content is displayed")
        let selected = try #require(store.chats.screen(profile: service.profile))
        store.chats.displayed(selected.owner)
        #expect(!store.isUnread(bot))
        var reply = try #require(service.snapshots[service.summaries[0].identity.root])
        reply.messages.append(.init(id: "unseen-main-reply", role: .assistant, text: "New Main reply"))
        service.snapshots[service.summaries[0].identity.root] = reply
        service.summaries[0] = .init(identity: service.summaries[0].identity, title: "Main", isCanonical: true,
            persistence: .durable, messageCount: 2)
        await store.chats.refreshDirectory(selected.owner)
        #expect(store.chats.cards(profile: service.profile).first { $0.isMain }?.unread == true)
        #expect(!store.isUnread(bot), "New activity in Main must not light the dot while the read sibling is selected")
        store.chats.preferOpening(main.selectedChatID, owner: selected.owner)
        #expect(!store.isUnread(bot), "The open chat takes precedence over a different saved opening choice")
        await store.setActive(false)
        #expect(!store.isUnread(bot), "The selected chat's dot keeps the same meaning offline")
        let restored = ConversationWorkspace(scope: .init(cacheID: configuration.id, exactAccount: [], incarnation: UUID()),
            book: store.chats.persisted(), service: service, onDirty: {})
        #expect(restored.aggregate(profile: service.profile).selectedChatIsUnread,
                "Without an open chat, the dot follows the saved opening choice")
    }

    @Test func lookupKeepsCanonicallyEquivalentProfileIDsDistinct() async throws {
        let fixture = RefreshFixture()
        defer { fixture.cleanUp() }
        fixture.service.profiles = [.init(id: "é", name: "Composed"),
                                    .init(id: "e\u{301}", name: "Decomposed", status: .working)]
        #expect(await fixture.store.connect(fixture.configuration))
        #expect(fixture.store.bot(withID: "é")?.name == "Composed")
        #expect(fixture.store.bot(withID: "e\u{301}")?.name == "Decomposed")
    }

    @Test func inboxOrdersAttentionBeforeRecencyAndRefreshUpdatesLookup() async throws {
        let fixture = RefreshFixture()
        defer { fixture.cleanUp() }
        let store = fixture.store, service = fixture.service
        let older = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 200)
        var history = LocalHistory()
        try history.fixtureConversation(.init(id: "cached", storedID: "cached", profileID: "unread",
            messages: [.init(id: "answer", role: .assistant, text: "Unread answer")]), profile: "unread")
        try history.save(for: fixture.configuration.id)
        service.profiles = [
            .init(id: "ten", name: "Bot 10"),
            .init(id: "recent", name: "Recent", updatedAt: newer),
            .init(id: "working", name: "Working", updatedAt: newer, status: .working),
            .init(id: "unread", name: "Unread", updatedAt: older),
            .init(id: "two", name: "Bot 2"),
            .init(id: "older", name: "Older", updatedAt: older),
            .init(id: "waiting", name: "Waiting", updatedAt: older, status: .waiting)
        ]
        #expect(await store.connect(fixture.configuration))
        #expect(store.bots.map(\.id) == ["waiting", "working", "unread", "recent", "older", "two", "ten"])
        #expect(store.needsYou.map(\.id) == ["waiting"])
        #expect(store.isUnread(try #require(store.bot(withID: "unread"))))
        try expectProjectionParity(store)

        service.profiles = [
            .init(id: "recent", name: "Renamed", preview: "Fresh preview", updatedAt: newer, status: .waiting),
            .init(id: "unread", name: "Unread", updatedAt: older),
            .init(id: "waiting", name: "Finished", updatedAt: older)
        ]
        service.previewMessages["recent"] = [.init(id: "fresh", role: .assistant, text: "Fresh preview", timestamp: newer)]
        let profile = try ExactID("recent"), root = try ExactID("recent-main")
        let identity = SessionIdentity(profile: profile, root: root, stored: root, aliases: [])
        service.directories[profile] = .init(summaries: [
            .init(identity: identity, title: "Bot Chat", isCanonical: true, persistence: .durable,
                  preview: "Fresh preview", updatedAt: newer, messageCount: 1)
        ], activity: [:], isComplete: false)
        await store.refresh()
        await store.chats.refreshInboxPreviews(profiles: [profile])
        #expect(store.bots.map(\.id) == ["recent", "unread", "waiting"])
        let updated = try #require(store.bot(withID: "recent"))
        #expect(updated.name == "Renamed" && updated.preview == "Fresh preview" && updated.status == .waiting)
        #expect(store.bot(withID: "working") == nil)
        #expect(store.bot(withID: "missing") == nil)
        try expectProjectionParity(store)
    }

    @Test func liveConversationProjectionUpdatesInboxAndLookupAndPreservesUnreadOffline() async throws {
        let fixture = RefreshFixture()
        defer { fixture.cleanUp() }
        let store = fixture.store, service = fixture.service
        service.profiles = [.init(id: "other", name: "Other", updatedAt: .distantFuture),
                            .init(id: "milo", name: "Milo")]
        #expect(await store.connect(fixture.configuration))
        await store.open(try #require(store.bot(withID: "milo")))
        var conversation = try #require(store.conversation(for: "milo"))
        conversation.isWorking = true
        service.onEvent?(.conversation(try service.authority.opened(conversation)))
        #expect(store.bots.map(\.id) == ["milo", "other"])
        #expect(store.bot(withID: "milo")?.status == .working)
        #expect(store.history.bots.first { $0.id == "milo" }?.status == .idle)
        try expectProjectionParity(store)

        conversation.pendingRequests = [.init(id: "approval", kind: .approval, title: "Continue?")]
        conversation.messages = [.init(id: "answer", role: .assistant, text: "Ready for review")]
        service.onEvent?(.conversation(try service.authority.opened(conversation)))
        let waiting = try #require(store.inbox.first)
        #expect(waiting.bot.id == "milo" && waiting.bot.status == .waiting)
        #expect(waiting.needsAttention && waiting.aggregate?.attentionChat != nil)
        #expect(waiting.aggregate?.unreadCount == 1)
        try expectProjectionParity(store)

        await store.setActive(false)
        #expect(store.link == .connecting)
        #expect(store.bots.map(\.id) == ["milo", "other"])
        #expect(store.bots.allSatisfy { $0.status == .idle })
        #expect(store.needsYou.isEmpty)
        let offline = try #require(store.inbox.first)
        #expect(!offline.needsAttention && offline.aggregate?.unreadCount == 1)
        #expect(store.isUnread(offline.bot))
        try expectProjectionParity(store)
    }

    @Test func invalidProfileIDRetainsRosterStatusAndMissingLookupStaysNil() async throws {
        let fixture = RefreshFixture()
        defer { fixture.cleanUp() }
        let store = fixture.store
        fixture.service.profiles = [.init(id: "valid", name: "Valid", status: .working),
                                    .init(id: "", name: "Invalid", status: .waiting)]
        #expect(await store.connect(fixture.configuration))
        #expect(store.bots.map(\.id) == ["", "valid"])
        #expect(store.bot(withID: "")?.status == .waiting)
        #expect(store.needsYou.isEmpty)
        #expect(!store.isUnread(try #require(store.bot(withID: ""))))
        #expect(store.bot(withID: "missing") == nil)
        try expectProjectionParity(store)

        await store.setActive(false)
        #expect(store.bot(withID: "")?.status == .waiting)
        #expect(store.bot(withID: "valid")?.status == .idle)
        #expect(store.needsYou.isEmpty)
        try expectProjectionParity(store)
    }

    private func expectProjectionParity(_ store: AppStore) throws {
        let inbox = store.inbox
        #expect(inbox.map(\.bot) == store.bots)
        for entry in inbox {
            #expect(store.bot(withID: entry.bot.id) == entry.bot)
            guard let profile = try? ExactID(entry.bot.id) else {
                #expect(entry.aggregate == nil)
                continue
            }
            let snapshot = try #require(entry.aggregate)
            let single = store.chats.aggregate(profile: profile)
            #expect(snapshot.count == single.count)
            #expect(snapshot.unreadCount == single.unreadCount)
            #expect(snapshot.selectedChatIsUnread == single.selectedChatIsUnread)
            #expect(entry.isUnread == store.isUnread(entry.bot))
            #expect(snapshot.status == single.status)
            #expect(snapshot.directoryComplete == single.directoryComplete)
            #expect(snapshot.attentionChat == single.attentionChat)
            #expect(snapshot.hasUnknownActivity == single.hasUnknownActivity)
        }
    }

    @Test(arguments: [false, true])
    func creationWaitsForPublicationAfterAnOlderInboxRead(oldReadFails: Bool) async throws {
        let fixture = RefreshFixture()
        defer { fixture.cleanUp() }
        let store = fixture.store, service = fixture.service
        #expect(await store.connect(fixture.configuration))
        let existing = try #require(store.bots.first)
        await store.testEdit("Keep this thought", for: existing.id)
        store.togglePin(existing)

        service.readError = oldReadFails ? HermesServiceError.timeout : nil
        let oldRead = service.holdNextRead()
        let inbox = RefreshCall { await store.refresh() }
        try await eventually { oldRead.entered }
        service.readError = nil
        let freshRead = service.holdNextRead()
        let creation = RefreshCall { await store.create(.init(name: "Orbit")) }
        try await eventually { service.createdDrafts.count == 1 }
        let invalidation = RefreshCall { await store.refresh() }
        try await eventually { invalidation.started }
        // Give an incorrectly early return a chance to reach the public caller.
        try await Task.sleep(for: .milliseconds(20))
        #expect(!creation.finished)
        #expect(!invalidation.finished)
        #expect(store.bots.map(\.id) == [existing.id])
        if creation.finished, let premature = await creation.value() {
            await store.open(premature)
            #expect(store.selectedBot?.id == premature.id)
        }

        oldRead.release()
        try await eventually { freshRead.entered }
        #expect(!creation.finished)
        #expect(store.isRefreshing)
        freshRead.release()
        try await eventually { creation.finished && inbox.finished && invalidation.finished }
        let bot = try #require(await creation.value())
        #expect(bot.id == "orbit")
        #expect(store.bots.contains { $0.id == bot.id })
        #expect(store.history.bots.contains { $0.id == bot.id })
        await store.open(bot)
        #expect(store.selectedBot?.id == bot.id)
        #expect(store.conversation(for: bot.id)?.profileID == bot.id)
        #expect(store.draft(for: existing.id) == "Keep this thought")
        #expect(store.isPinned(existing))
        #expect(!store.isRefreshing)
        #expect(service.createdDrafts.map(\.name) == ["Orbit"])
        // The stale response has drained before success; no older read can erase it.
        #expect(service.finishedReads == service.readCount)
        store.flush()
        #expect(try LocalHistory.load(for: fixture.configuration.id).bots.contains { $0.id == bot.id })
    }

    @Test(arguments: [false, true], [false, true])
    func creationDoesNotReportNavigableSuccessWithoutPublishedMembership(readFails: Bool, overlapping: Bool) async throws {
        let fixture = RefreshFixture()
        defer { fixture.cleanUp() }
        let store = fixture.store, service = fixture.service
        #expect(await store.connect(fixture.configuration))
        let oldRead = overlapping ? service.holdNextRead() : nil
        let inbox = overlapping ? RefreshCall { await store.refresh() } : nil
        if let oldRead { try await eventually { oldRead.entered } }
        service.readError = readFails ? HermesServiceError.timeout : nil
        service.omitsCreatedProfile = !readFails

        let creation = RefreshCall { await store.create(.init(name: "Orbit")) }
        try await eventually { service.createdDrafts.count == 1 }
        oldRead?.release()
        try await eventually { creation.finished && inbox?.finished != false }
        let result = await creation.value()

        #expect(result == nil)
        #expect(!store.history.bots.contains { $0.id == "orbit" })
        #expect(store.notice?.contains("was created") == true)
        #expect(store.notice?.contains("Refresh the inbox") == true)
        #expect(store.selectedBot == nil)
        #expect(service.createdDrafts.map(\.name) == ["Orbit"])
        #expect(!store.isRefreshing)

        service.readError = nil
        service.omitsCreatedProfile = false
        await store.refresh()
        let recovered = try #require(store.bots.first { $0.id == "orbit" })
        await store.open(recovered)
        #expect(store.selectedBot?.id == "orbit")
        #expect(service.createdDrafts.count == 1)
    }

    @Test(arguments: [false, true])
    func cancellationReleasesOneCallerWithoutCancelingOtherRefreshes(cancelActive: Bool) async throws {
        let fixture = RefreshFixture()
        defer { fixture.cleanUp() }
        let store = fixture.store, service = fixture.service
        #expect(await store.connect(fixture.configuration))
        let heldRead = service.holdNextRead()
        let active = RefreshCall { await store.refresh() }
        try await eventually { heldRead.entered }
        service.profiles = [.init(id: "scout", name: "Scout")]
        let pending = RefreshCall { await store.refresh() }
        try await eventually { pending.started }
        let canceled = cancelActive ? active : pending
        let remaining = cancelActive ? pending : active
        canceled.cancel()

        try await eventually { canceled.finished }
        #expect(!remaining.finished)
        #expect(store.isRefreshing)
        #expect(store.bots.map(\.id) == ["milo"])
        #expect(store.notice == nil)

        heldRead.release()
        try await eventually { remaining.finished && !store.isRefreshing }
        #expect(store.bots.map(\.id) == (cancelActive ? ["scout"] : ["milo"]))
        // Canceling a queued-only request does not cause an unnecessary replay.
        #expect(service.readCount == (cancelActive ? 3 : 2))
    }

    @Test func cancelingCreationReleasesItsWaitWithoutRetryingTheMutation() async throws {
        let fixture = RefreshFixture()
        defer { fixture.cleanUp() }
        let store = fixture.store, service = fixture.service
        #expect(await store.connect(fixture.configuration))
        let heldRead = service.holdNextRead()
        let inbox = RefreshCall { await store.refresh() }
        try await eventually { heldRead.entered }
        let creation = RefreshCall { await store.create(.init(name: "Orbit")) }
        try await eventually { service.createdDrafts.count == 1 }
        creation.cancel()

        try await eventually { creation.finished }
        #expect(await creation.value() == nil)
        #expect(!inbox.finished)
        #expect(store.notice == nil)
        #expect(store.selectedBot == nil)
        heldRead.release()
        try await eventually { inbox.finished && !store.isRefreshing }
        // The independent botsChanged invalidation still publishes the server's creation.
        #expect(store.bots.contains { $0.id == "orbit" })
        #expect(service.createdDrafts.map(\.name) == ["Orbit"])
    }

    @Test func futureInvalidationsCoalesceWithoutDelayingEarlierPublicationWaiters() async throws {
        let fixture = RefreshFixture()
        defer { fixture.cleanUp() }
        let store = fixture.store, service = fixture.service
        #expect(await store.connect(fixture.configuration))
        let oldRead = service.holdNextRead()
        let inbox = RefreshCall { await store.refresh() }
        try await eventually { oldRead.entered }
        let createdRead = service.holdNextRead()
        let creation = RefreshCall { await store.create(.init(name: "Orbit")) }
        try await eventually { service.createdDrafts.count == 1 }
        oldRead.release()
        try await eventually { createdRead.entered && inbox.finished }

        service.profiles.append(.init(id: "scout", name: "Scout"))
        let futureRead = service.holdNextRead()
        let callers = (0..<20).map { _ in RefreshCall { await store.refresh() } }
        try await eventually { callers.allSatisfy(\.started) }
        createdRead.release()
        try await eventually { futureRead.entered && creation.finished }
        let created = try #require(await creation.value())
        await store.open(created)
        #expect(store.selectedBot?.id == "orbit")
        #expect(!store.bots.contains { $0.id == "scout" })
        #expect(callers.allSatisfy { !$0.finished })
        #expect(store.isRefreshing)

        // Another wave arrives before the current read finishes. Earlier waiters
        // must still finish at their own publication, even if this keeps happening.
        service.profiles.append(.init(id: "pip", name: "Pip"))
        let lastRead = service.holdNextRead()
        let last = RefreshCall { await store.refresh() }
        try await eventually { last.started }
        futureRead.release()
        try await eventually { lastRead.entered && callers.allSatisfy(\.finished) }
        #expect(!last.finished)
        #expect(store.bots.contains { $0.id == "scout" })
        #expect(!store.bots.contains { $0.id == "pip" })
        #expect(store.selectedBot?.id == "orbit")
        lastRead.release()
        try await eventually { last.finished && !store.isRefreshing }
        #expect(store.bots.contains { $0.id == "pip" })
        #expect(service.readCount == 5) // Connection, old, created, and two later waves.
        #expect(service.createdDrafts.count == 1)
    }

    @Test(arguments: [false, true])
    func retirementReleasesWaitersBeforeTheOldReadFinishes(background: Bool) async throws {
        let fixture = RefreshFixture()
        defer { fixture.cleanUp() }
        let store = fixture.store, service = fixture.service
        #expect(await store.connect(fixture.configuration))
        let oldRead = service.holdNextRead()
        let inbox = RefreshCall { await store.refresh() }
        try await eventually { oldRead.entered }
        let creation = RefreshCall { await store.create(.init(name: "Orbit")) }
        try await eventually { service.createdDrafts.count == 1 }
        let pending = RefreshCall { await store.refresh() }
        try await eventually { pending.started }

        if background { await store.setActive(false) }
        else { store.forgetConnection() }
        try await eventually { inbox.finished && creation.finished && pending.finished }
        #expect(await creation.value() == nil)
        #expect(!store.isRefreshing)
        #expect(store.link == (background ? .connecting : .unconfigured))
        await store.refresh() // A disconnected caller must also finish without a read.
        #expect(service.readCount == 2)
        oldRead.release()
        try await eventually { service.finishedReads == 2 }
        #expect(store.bots.map(\.id) == (background ? ["milo"] : []))
        #expect(store.selectedBot == nil)
        #expect(store.notice == nil)
        #expect(!store.isRefreshing)
        #expect(service.createdDrafts.count == 1)
    }

    @Test(arguments: [false, true], [false, true])
    func retiredReadCannotPublishOrClearAReplacementRefresh(socketRecovery: Bool, oldReadFails: Bool) async throws {
        let fixture = RefreshFixture()
        let replacement = ConnectionConfiguration(serverURL: URL(string: "https://replacement.example")!)
        defer { fixture.cleanUp(); LocalHistory.remove(for: replacement.id) }
        let store = fixture.store, service = fixture.service
        #expect(await store.connect(fixture.configuration))
        service.readError = oldReadFails ? HermesServiceError.timeout : nil
        let oldRead = service.holdNextRead()
        let inbox = RefreshCall { await store.refresh() }
        try await eventually { oldRead.entered }
        let creation = RefreshCall { await store.create(.init(name: "Orbit")) }
        try await eventually { service.createdDrafts.count == 1 }

        service.profiles = [.init(id: "clover", name: "Clover")]
        service.readError = nil
        let newRead = service.holdNextRead()
        let connection = RefreshCall {
            if socketRecovery {
                service.onEvent?(.disconnected("Connection lost"))
                #expect(!store.isRefreshing)
                await store.refresh()
                service.onEvent?(.connected(.init(version: "recovered", installID: "refresh-install")))
                return true
            }
            return await store.connect(replacement)
        }
        try await eventually { newRead.entered && inbox.finished && creation.finished }
        #expect(await creation.value() == nil)
        let notice = store.notice
        oldRead.release()
        try await eventually { service.finishedReads == 2 }
        #expect(store.isRefreshing)
        #expect(store.bots.map(\.id) == (socketRecovery ? ["milo"] : []))
        #expect(store.notice == notice)

        newRead.release()
        try await eventually { connection.finished && !store.isRefreshing }
        #expect(await connection.value())
        #expect(store.link == .online)
        #expect(store.bots.map(\.id) == ["clover"])
        #expect(store.configuration?.id == (socketRecovery ? fixture.configuration.id : replacement.id))
        #expect(store.selectedBot == nil)
        #expect(service.createdDrafts.count == 1)
    }

    @Test func ordinaryCreationPublishesBeforeOpeningAndPrecancelledCreationDoesNotMutate() async throws {
        let fixture = RefreshFixture()
        defer { fixture.cleanUp() }
        let store = fixture.store, service = fixture.service
        #expect(await store.connect(fixture.configuration))
        let canceled = RefreshCall { await store.create(.init(name: "Canceled")) }
        canceled.cancel()
        #expect(await canceled.value() == nil)
        #expect(service.createdDrafts.isEmpty)
        let created = try #require(await store.create(.init(name: "Orbit")))
        #expect(store.history.bots.contains { $0.id == created.id })
        await store.open(created)
        #expect(store.selectedBot?.name == "Orbit")
        #expect(store.conversation(for: created.id)?.profileID == created.id)
        #expect(service.createdDrafts.map(\.name) == ["Orbit"])
        #expect(!store.isRefreshing)
    }
}

@MainActor private final class RefreshFixture {
    let configuration = ConnectionConfiguration(serverURL: URL(string: "https://refresh.example")!)
    let service = RefreshService()
    let store: AppStore

    init() {
        store = AppStore(service: service, persistence: .init(load: { nil }, save: { _ in }, remove: {}))
    }

    func cleanUp() {
        service.releaseReads()
        store.forgetConnection()
        LocalHistory.remove(for: configuration.id)
    }
}

/// Captures the host roster before suspension, including when cancellation is ignored.
@MainActor private final class RefreshService: BotService {
    let authority = TestConversationAuthority()

    func conversations(profile: ExactID) async throws -> ConversationDirectory {
        directories[profile] ?? authority.directory(profile)
    }
    func conversationPreview(_ identity: SessionIdentity) async throws -> ConversationPreviewRead {
        guard let messages = previewMessages[identity.profile.text] else { return .init(preview: nil, isComplete: false) }
        return .init(preview: ConversationPreview.latest(in: messages), isComplete: true)
    }
    func createConversation(profile: ExactID, operationID: UUID) async throws -> CreatedSession { throw HermesServiceError.rejected(-32601) }
    func downloadArtifact(_ attachment: ChatAttachment, access: ConversationAccess) async throws -> DownloadedArtifact { throw HermesServiceError.rejected(-32601) }

    var onEvent: ((BotServiceEvent) -> Void)?
    var profiles = [BotProfile(id: "milo", name: "Milo")]
    var previewMessages: [String: [ChatMessage]] = [:]
    var directories: [ExactID: ConversationDirectory] = [:]
    var createdDrafts: [BotDraft] = []
    var readError: (any Error)?
    var omitsCreatedProfile = false
    private var gates: [RefreshGate] = []
    private var pendingGates: [RefreshGate] = []
    private(set) var readCount = 0
    private(set) var finishedReads = 0

    func holdNextRead() -> RefreshGate {
        let gate = RefreshGate()
        gates.append(gate)
        pendingGates.append(gate)
        return gate
    }

    func releaseReads() { gates.forEach { $0.release() } }
    func connect(configuration: ConnectionConfiguration) async throws -> ServerInfo {
        .init(version: "fixture", installID: "refresh-install")
    }
    func disconnect() {}
    func bots() async throws -> [BotProfile] {
        let snapshot = profiles.filter { !omitsCreatedProfile || $0.id != "orbit" }
        let error = readError
        readCount += 1
        defer { finishedReads += 1 }
        if !pendingGates.isEmpty { await pendingGates.removeFirst().wait() }
        if let error { throw error }
        return snapshot
    }
    func createBot(_ draft: BotDraft) async throws -> BotProfile {
        createdDrafts.append(draft)
        let bot = BotProfile(id: "orbit", name: draft.name)
        profiles.append(bot)
        onEvent?(.botsChanged)
        return bot
    }
    func openChat(_ target: SessionTarget) async throws -> OpenedConversation {
        let bot = BotProfile(id: authority.profile(target), name: "Fixture")
        return try authority.opened(.init(id: "runtime-" + bot.id, storedID: "stored-" + bot.id, profileID: bot.id))
    }
    func send(text: String, attachments: [ChatAttachment], delivery: MessageDelivery, access: ConversationAccess, operationID: UUID) async throws -> MutationReceipt { try authority.receipt(access, operationID) }
    func stop(access: ConversationAccess, operationID: UUID) async throws -> MutationReceipt { try authority.receipt(access, operationID) }
    func respond(to request: PendingRequest, response: RequestResponse, access: ConversationAccess, operationID: UUID) async throws -> MutationReceipt { try authority.receipt(access, operationID) }
    func upload(data: Data, filename: String, mimeType: String, access: ConversationAccess) async throws -> ChatAttachment {
        .init(name: filename, path: "uploads/" + filename, mimeType: mimeType)
    }
}

@MainActor private final class RefreshGate {
    private(set) var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor private final class RefreshCall<Value: Sendable> {
    private var task: Task<Value, Never>?
    private(set) var started = false
    private(set) var finished = false

    init(_ operation: @escaping @MainActor () async -> Value) {
        task = Task {
            started = true
            let value = await operation()
            finished = true
            return value
        }
    }

    func value() async -> Value { await task!.value }
    func cancel() { task?.cancel() }
}

@MainActor private func eventually(_ condition: () -> Bool,
                                    sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !condition(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(2))
    }
    try #require(condition(), sourceLocation: sourceLocation)
}
