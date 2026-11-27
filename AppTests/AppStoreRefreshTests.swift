import Testing
import Foundation
import BottoCore
@testable import Botto

@MainActor struct AppStoreRefreshTests {
    @Test func advisoryBurstsPublishPeriodicallyWithoutMovingTheirDeadline() async throws {
        let intervals = RefreshIntervals()
        let fixture = RefreshFixture(waitForBotInvalidationInterval: intervals.wait)
        defer { fixture.cleanUp(); intervals.releaseAll() }
        let store = fixture.store, service = fixture.service
        try #require(await store.connect(fixture.configuration))
        service.profiles.append(.init(id: "scout", name: "Scout"))
        service.onEvent?(.botsChanged)
        try await eventually { service.readCount == 2 && intervals.count == 1 }
        #expect(store.bots.contains { $0.id == "scout" })

        for (index, name) in ["Orbit", "Pip"].enumerated() {
            service.profiles.append(.init(id: name.lowercased(), name: name))
            for _ in 0..<100 { service.onEvent?(.botsChanged) }
            #expect(intervals.count == index + 1, "New hints must not restart a trailing deadline.")
            #expect(service.readCount == index + 2)
            intervals.release(index)
            try await eventually { service.readCount == index + 3 && intervals.count == index + 2 }
            #expect(store.bots.contains { $0.name == name }, "Each fixed interval publishes progress despite continuing hints.")
        }
        #expect(service.readCount == 4, "Connection plus one leading read and two periodic reads.")
    }

    @Test func explicitRefreshDoesNotWaitForTheAdvisoryInterval() async throws {
        let intervals = RefreshIntervals()
        let fixture = RefreshFixture(waitForBotInvalidationInterval: intervals.wait)
        defer { fixture.cleanUp(); intervals.releaseAll() }
        let store = fixture.store, service = fixture.service
        try #require(await store.connect(fixture.configuration))
        service.onEvent?(.botsChanged)
        try await eventually { service.readCount == 2 && intervals.count == 1 }
        service.profiles.append(.init(id: "orbit", name: "Orbit"))
        let heldRead = service.holdNextRead()
        let explicit = RefreshCall { await store.refresh() }
        try await eventually { heldRead.entered }
        #expect(service.readCount == 3)
        #expect(!explicit.finished)
        #expect(intervals.count == 1)
        heldRead.release()
        try await eventually { explicit.finished }
        #expect(store.bots.contains { $0.id == "orbit" })
        #expect(intervals.returned.isEmpty, "The explicit caller finishes while the advisory clock is still held.")
    }

    @Test func queuedAdvisoryCannotAcquireRecoveredConnectionAuthority() async throws {
        let intervals = RefreshIntervals()
        let fixture = RefreshFixture(waitForBotInvalidationInterval: intervals.wait)
        defer { fixture.cleanUp(); intervals.releaseAll() }
        let store = fixture.store, service = fixture.service
        try #require(await store.connect(fixture.configuration))
        service.onEvent?(.botsChanged)
        service.onEvent?(.disconnected("Connection lost before queued hint starts"))
        service.profiles = [.init(id: "clover", name: "Clover")]
        service.onEvent?(.connected(.init(version: "recovered", installID: "refresh-install")))
        await store.refresh()
        #expect(store.bots.map(\.id) == ["clover"])
        #expect(service.readCount == 2)
        #expect(intervals.count == 0, "The old advisory task must not become a worker on recovered authority.")
    }

    @Test(arguments: [false, true])
    func retiredAdvisoryIntervalCannotReplaceANewOwner(socketRecovery: Bool) async throws {
        let intervals = RefreshIntervals()
        let fixture = RefreshFixture(waitForBotInvalidationInterval: intervals.wait)
        let replacement = ConnectionConfiguration(serverURL: URL(string: "https://replacement.example")!)
        defer { fixture.cleanUp(); intervals.releaseAll(); LocalHistory.remove(for: replacement.id) }
        let store = fixture.store, service = fixture.service
        try #require(await store.connect(fixture.configuration))
        service.onEvent?(.botsChanged)
        try await eventually { service.readCount == 2 && intervals.count == 1 }
        service.profiles = [.init(id: "clover", name: "Clover")]
        if socketRecovery {
            service.onEvent?(.disconnected("Connection lost during advisory interval"))
            service.onEvent?(.connected(.init(version: "recovered", installID: "refresh-install")))
            await store.refresh()
        } else { try #require(await store.connect(replacement)) }
        try await eventually { service.readCount == 3 && !store.isRefreshing }
        service.onEvent?(.botsChanged)
        try await eventually { service.readCount == 4 && intervals.count == 2 }

        intervals.release(0)
        try await eventually { intervals.returned.contains(0) }
        service.profiles.append(.init(id: "orbit", name: "Orbit"))
        for _ in 0..<100 { service.onEvent?(.botsChanged) }
        #expect(service.readCount == 4)
        #expect(intervals.count == 2)
        intervals.release(1)
        try await eventually { service.readCount == 5 && intervals.count == 3 }
        #expect(store.bots.map(\.id).sorted() == ["clover", "orbit"])
        #expect(store.configuration?.id == (socketRecovery ? fixture.configuration.id : replacement.id))
    }

    @Test func inboxPreviewKeepsTheNewestNonEmptyMessage() async throws {
        let service = try WorkspaceTestService(), identity = service.summaries[0].identity
        let replyAt = Date(timeIntervalSince1970: 100)
        let messages: [ChatMessage] = [
            .init(id: "question", role: .user, text: "How is the service?"),
            .init(id: "reply", role: .assistant, text: "The service is healthy.", timestamp: replyAt),
            .init(id: "check", role: .tool, text: "uptime\nup 3 days", toolName: "Command"),
            .init(id: "empty", role: .assistant, text: "")
        ]
        service.snapshots[identity.root]?.messages = messages
        service.summaries[0] = .init(identity: identity, title: "Bot Chat", isCanonical: true, persistence: .durable,
            preview: "", updatedAt: Date(timeIntervalSince1970: 200), messageCount: messages.count)
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
        #expect(store.inbox.filter(\.needsAttention).map(\.id) == ["waiting"])
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
        ], activity: [:])
        store.chats.invalidateActivityDirectory(profile)
        await store.refresh()
        await store.chats.refreshInboxHistory(profiles: [profile])
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
        #expect(!store.inbox.contains { $0.needsAttention })
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
        #expect(!store.inbox.contains { $0.needsAttention })
        #expect(!store.isUnread(try #require(store.bot(withID: ""))))
        #expect(store.bot(withID: "missing") == nil)
        try expectProjectionParity(store)

        await store.setActive(false)
        #expect(store.bot(withID: "")?.status == .waiting)
        #expect(store.bot(withID: "valid")?.status == .idle)
        #expect(!store.inbox.contains { $0.needsAttention })
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

    @Test func futureInvalidationsCoalesceWithoutDelayingEarlierPublicationWaiters() async throws {
        let fixture = RefreshFixture()
        defer { fixture.cleanUp() }
        let store = fixture.store, service = fixture.service
        #expect(await store.connect(fixture.configuration))
        let oldRead = service.holdNextRead()
        let inbox = RefreshCall { await store.refresh() }
        try await eventually { oldRead.entered }
        let createdRead = service.holdNextRead()
        let queued = RefreshCall { await store.refresh() }
        try await eventually { queued.started }
        oldRead.release()
        try await eventually { createdRead.entered && inbox.finished }

        service.profiles.append(.init(id: "scout", name: "Scout"))
        let futureRead = service.holdNextRead()
        let callers = (0..<20).map { _ in RefreshCall { await store.refresh() } }
        try await eventually { callers.allSatisfy(\.started) }
        createdRead.release()
        try await eventually { futureRead.entered && queued.finished }
        await queued.value()
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
        lastRead.release()
        try await eventually { last.finished && !store.isRefreshing }
        #expect(store.bots.contains { $0.id == "pip" })
        #expect(service.readCount == 5) // Connection, old, created, and two later waves.
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
        let queued = RefreshCall { await store.refresh() }
        try await eventually { queued.started }
        let pending = RefreshCall { await store.refresh() }
        try await eventually { pending.started }

        if background { await store.setActive(false) }
        else { store.forgetConnection() }
        try await eventually { inbox.finished && queued.finished && pending.finished }
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
    }

    @Test(arguments: [false, true], [false, true])
    func retiredReadCannotPublishOrClearAReplacementRefresh(socketRecovery: Bool, oldReadFails: Bool) async throws {
        let fixture = RefreshFixture()
        let replacement = ConnectionConfiguration(serverURL: URL(string: "https://replacement.example")!)
        defer { fixture.cleanUp(); LocalHistory.remove(for: replacement.id) }
        let store = fixture.store, service = fixture.service
        #expect(await store.connect(fixture.configuration))
        service.readError = oldReadFails ? ConversationServiceError.timeout : nil
        let oldRead = service.holdNextRead()
        let inbox = RefreshCall { await store.refresh() }
        try await eventually { oldRead.entered }
        let queued = RefreshCall { await store.refresh() }
        try await eventually { queued.started }

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
        try await eventually { newRead.entered && inbox.finished && queued.finished }
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
    }

}

@MainActor private final class RefreshFixture {
    let configuration = ConnectionConfiguration(serverURL: URL(string: "https://refresh.example")!)
    let service = RefreshService()
    let store: AppStore

    init(waitForBotInvalidationInterval: (@MainActor () async throws -> Void)? = nil) {
        let persistence = ConnectionPersistence(load: { nil }, save: { _ in }, remove: {})
        if let waitForBotInvalidationInterval {
            store = AppStore(service: service, persistence: persistence,
                waitForBotInvalidationInterval: waitForBotInvalidationInterval)
        } else { store = AppStore(service: service, persistence: persistence) }
    }

    func cleanUp() {
        service.releaseReads()
        store.forgetConnection()
        LocalHistory.remove(for: configuration.id)
    }
}

/// Captures the host roster before suspension, including when cancellation is ignored.
@MainActor private final class RefreshService: ConversationTestService {
    let authority = TestConversationAuthority()

    func conversations(profile: ExactID) async throws -> ConversationDirectory {
        directories[profile] ?? authority.directory(profile)
    }
    func recentConversationHistory(_ identity: SessionIdentity) async throws -> ConversationHistoryWindow? {
        guard let messages = previewMessages[identity.profile.text] else { return nil }
        return .init(messages: messages, hasEarlierMessages: false)
    }
    func downloadArtifact(_ attachment: ChatAttachment, access: ConversationAccess) async throws -> DownloadedArtifact { throw ConversationServiceError.rejected(-32601) }

    var onEvent: ((BotServiceEvent) -> Void)?
    var profiles = [BotProfile(id: "milo", name: "Milo")]
    var previewMessages: [String: [ChatMessage]] = [:]
    var directories: [ExactID: ConversationDirectory] = [:]
    var readError: (any Error)?
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
        let snapshot = profiles
        let error = readError
        readCount += 1
        defer { finishedReads += 1 }
        if !pendingGates.isEmpty { await pendingGates.removeFirst().wait() }
        if let error { throw error }
        return snapshot
    }
    func markVisited(through mark: VisitMark, access: ConversationAccess) async throws {}
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

@MainActor private final class RefreshIntervals {
    private var gates: [RefreshGate] = []
    private(set) var returned = Set<Int>()
    var count: Int { gates.count }

    func wait() async {
        let index = gates.count, gate = RefreshGate()
        gates.append(gate)
        await gate.wait()
        returned.insert(index)
    }

    func release(_ index: Int) { gates[index].release() }
    func releaseAll() { gates.forEach { $0.release() } }
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
    await waitWhile(fileID: sourceLocation.fileID, line: sourceLocation.line) { !condition() }
    try #require(condition(), sourceLocation: sourceLocation)
}
