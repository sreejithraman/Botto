import Foundation
import Observation
import Testing
import BottoCore
@testable import Botto

@MainActor private final class BatchActivityObserverEntry {
    var entered = false
}

@MainActor struct ConversationActivityTests {
    @Test(arguments: [false, true])
    func activityBatchPreservesCallbackDraftAndNewerSample(newerActivity: Bool) async throws {
        let service = try WorkspaceTestService()
        let independentProfile = try ExactID("independent")
        let independentRoot = try ExactID("independent-root")
        let independent = SessionIdentity(profile: independentProfile, root: independentRoot,
                                          stored: independentRoot, aliases: [])
        var book = ConversationBook()
        for summary in service.summaries { _ = book.merge(summary) }
        let independentID = book.merge(.init(identity: independent, title: "Independent", isCanonical: true, persistence: .durable))
        var dirty = 0
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: book, service: service, onDirty: { dirty += 1 })
        workspace.setOnline(true)
        await workspace.openBot(profile: service.profile)
        let owner = try #require(workspace.screen(profile: service.profile)?.owner)
        await workspace.refreshDirectory(owner)
        let other = service.summaries[1].identity
        let sibling = try #require(workspace.cards(profile: service.profile).first { $0.id != owner.chat }?.id)
        let callback = BatchActivityObserverEntry()
        dirty = 0
        await confirmation("A guarded history callback runs before batch reduction") { changed in
            withObservationTracking { _ = workspace.persisted() } onChange: {
                MainActor.assumeIsolated {
                    guard !callback.entered else { return }
                    callback.entered = true
                    changed()
                    if newerActivity {
                        workspace.applyActivity(profile: service.profile,
                            observations: [other: .known(.waiting, .init(timeIntervalSince1970: 30))])
                    } else {
                        workspace.editDraft("Keep the callback draft", owner: owner)
                    }
                }
            }
            workspace.applyActivity([
                .init(profile: service.profile, observations: [other: .known(.working, .init(timeIntervalSince1970: 20))]),
                .init(profile: independentProfile, observations: [independent: .known(.working, .init(timeIntervalSince1970: 20))])
            ])
        }
        #expect(dirty == 2)
        #expect(workspace.persisted().record(independentID)?.lastKnownActivity == .init(status: .working, observedAt: .init(timeIntervalSince1970: 20)))
        if newerActivity {
            #expect(workspace.persisted().record(sibling)?.lastKnownActivity == .init(status: .waiting, observedAt: .init(timeIntervalSince1970: 30)))
            #expect(workspace.cards(profile: service.profile).first { $0.id == sibling }?.status == .waiting)
            #expect(workspace.avatarPresentation(profile: service.profile, scope: .profile).activity == .waiting)
        } else {
            #expect(workspace.draft(owner) == "Keep the callback draft")
            #expect(workspace.persisted().record(sibling)?.lastKnownActivity == .init(status: .working, observedAt: .init(timeIntervalSince1970: 20)))
        }
    }

    @Test func activityBatchReducesAfterCoarseObserverPublishesNewerSample() async throws {
        let service = try WorkspaceTestService()
        var book = ConversationBook()
        for summary in service.summaries { _ = book.merge(summary) }
        let identity = service.summaries[0].identity
        let id = try #require(book.opening(service.profile))
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: book, service: service, onDirty: {})
        workspace.setOnline(true)
        workspace.observeProfiles([.init(id: service.profile.text, name: "Milo", status: .waiting)])
        #expect(workspace.aggregate(profile: service.profile).status == .waiting)
        let callback = BatchActivityObserverEntry()
        let emptyProfile = try ExactID("not-yet-listed")
        await confirmation("A guarded coarse fallback callback publishes a newer sample") { changed in
            // With no rows, this aggregate observes coarse fallback without observing chat activity.
            withObservationTracking { _ = workspace.aggregate(profile: emptyProfile) } onChange: {
                MainActor.assumeIsolated {
                    guard !callback.entered else { return }
                    callback.entered = true
                    changed()
                    workspace.applyActivity(profile: service.profile,
                        observations: [identity: .known(.waiting, .init(timeIntervalSince1970: 30))])
                }
            }
            workspace.applyActivity(profile: service.profile,
                observations: [identity: .known(.working, .init(timeIntervalSince1970: 20))])
        }
        #expect(workspace.persisted().record(id)?.lastKnownActivity == .init(status: .waiting, observedAt: .init(timeIntervalSince1970: 30)))
        #expect(workspace.aggregate(profile: service.profile).status == .waiting)
        #expect(workspace.avatarPresentation(profile: service.profile, scope: .profile).activity == .waiting)
    }

    @Test(arguments: [false, true])
    func activityBatchCannotCrossCallbackRecoveryOrRetirement(retire: Bool) async throws {
        let service = try WorkspaceTestService()
        var book = ConversationBook()
        for summary in service.summaries { _ = book.merge(summary) }
        let identity = service.summaries[0].identity
        var dirty = 0
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: book, service: service, onDirty: { dirty += 1 })
        workspace.setOnline(true)
        let callback = BatchActivityObserverEntry()
        await confirmation("A guarded history callback retires the source lifetime") { changed in
            withObservationTracking { _ = workspace.persisted() } onChange: {
                MainActor.assumeIsolated {
                    guard !callback.entered else { return }
                    callback.entered = true
                    changed()
                    if retire { workspace.retireWorkspace() }
                    else { workspace.setOnline(false); workspace.setOnline(true) }
                }
            }
            workspace.applyActivity(profile: service.profile,
                observations: [identity: .known(.waiting, .init(timeIntervalSince1970: 20))])
        }
        #expect(workspace.persisted().records.allSatisfy { $0.lastKnownActivity == nil })
        #expect(workspace.aggregate(profile: service.profile).status == nil)
        #expect(workspace.avatarPresentation(profile: service.profile, scope: .profile).activity == .idle)
        #expect(dirty == 0)
    }

    @Test func authoritativeOpenStillOverridesFutureInventoryActivity() async throws {
        let service = try WorkspaceTestService()
        var book = ConversationBook()
        for summary in service.summaries { _ = book.merge(summary) }
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: book, service: service, onDirty: {})
        workspace.setOnline(true)
        let identity = service.summaries[0].identity
        workspace.applyActivity(profile: service.profile, observations: [identity: .known(.waiting, .distantFuture)])
        #expect(workspace.aggregate(profile: service.profile).status == .waiting)
        await workspace.openBot(profile: service.profile)
        let screen = try #require(workspace.screen(profile: service.profile))
        let screenCards = workspace.cards(profile: service.profile)
        #expect(screenCards.first { $0.id == screen.owner.chat }?.status == .idle)
        #expect(workspace.persisted().record(screen.owner.chat)?.lastKnownActivity?.status == .idle)
    }

    @Test func activityBatchPreservesOrderedSamplesAndPublishesOnce() throws {
        let service = try WorkspaceTestService()
        let main = service.summaries[0].identity, other = service.summaries[1].identity
        let root = try ExactID("unicode-root")
        let composed = SessionIdentity(profile: try ExactID("é"), root: root, stored: root, aliases: [])
        let decomposed = SessionIdentity(profile: try ExactID("e\u{301}"), root: root, stored: root, aliases: [])
        var book = ConversationBook(), ids: [SessionIdentity: ChatID] = [:]
        for identity in [main, other, composed, decomposed] {
            let id = book.merge(.init(identity: identity, title: "Saved", isCanonical: identity != other, persistence: .durable))
            ids[identity] = id
            let snapshot = Conversation(id: identity.root.text, storedID: identity.stored.text, profileID: identity.profile.text,
                messages: [.init(id: "saved", role: .assistant, text: "Original history")])
            book.cache(snapshot, for: id)
            book.update(id) {
                $0.draft.text = "Keep this draft"
                $0.displayed(snapshot, acknowledging: nil, at: Date(timeIntervalSince1970: 1))
            }
        }
        var dirty = 0
        let batch = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: book, service: service, onDirty: { dirty += 1 })
        let sequential = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: book, service: service, onDirty: {})
        batch.setOnline(true); sequential.setOnline(true); dirty = 0
        let newer = Date(timeIntervalSince1970: 10), older = Date(timeIntervalSince1970: 5)
        let ambiguous = SessionIdentity(profile: main.profile, root: main.root, stored: main.stored, aliases: [other.root])
        let updates: [ProfileActivityUpdate] = [
            .init(profile: main.profile, observations: [main: .known(.waiting, newer)]),
            .init(profile: main.profile, observations: [main: .known(.idle, older)]),
            .init(profile: other.profile, observations: [other: .known(.working, newer)]),
            .init(profile: other.profile, observations: [other: .unknown("Unavailable")]),
            .init(profile: other.profile, observations: [other: .known(.idle, older)]),
            .init(profile: main.profile, observations: [ambiguous: .known(.idle, .distantFuture)]),
            .init(profile: main.profile, observations: [composed: .known(.idle, .distantFuture)]),
            .init(profile: composed.profile, observations: [composed: .known(.working, newer)]),
            .init(profile: decomposed.profile, observations: [decomposed: .known(.waiting, newer)])
        ]
        batch.applyActivity(updates)
        for update in updates { sequential.applyActivity(profile: update.profile, observations: update.observations) }
        #expect(dirty == 1)
        #expect(batch.aggregate(profile: main.profile).status == .waiting)
        #expect(batch.aggregate(profile: composed.profile).status == .working)
        #expect(batch.aggregate(profile: decomposed.profile).status == .waiting)
        var expected = book
        for (identity, status, date) in [(main, BotStatus.waiting, newer), (other, .idle, older),
                                         (composed, .working, newer), (decomposed, .waiting, newer)] {
            expected.update(try #require(ids[identity])) { $0.lastKnownActivity = .init(status: status, observedAt: date) }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(batch.persisted()) == encoder.encode(expected.readOnly))
        #expect(try encoder.encode(batch.persisted()) == encoder.encode(sequential.persisted()))
    }

    @Test func activityBatchKeepsLiveContentDraftAndAccessWhileUpdatingItsSibling() async throws {
        let service = try WorkspaceTestService()
        let main = service.summaries[0].identity, other = service.summaries[1].identity
        service.snapshots[main.root]?.pendingRequests = [.init(id: "approval", kind: .approval, title: "Waiting")]
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: .init(), service: service, onDirty: {})
        workspace.setOnline(true)
        await workspace.openBot(profile: service.profile)
        let openingOwner = try #require(workspace.screen(profile: service.profile)?.owner)
        await workspace.refreshDirectory(openingOwner)
        let before = try #require(workspace.screen(profile: service.profile))
        workspace.editDraft("Keep the editor", owner: before.owner)
        workspace.displayed(before.owner)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let saved = try encoder.encode(workspace.persisted().record(before.owner.chat))
        workspace.applyActivity([.init(profile: service.profile, observations: [
            main: .known(.idle, .distantFuture), other: .known(.waiting, .distantFuture)
        ])])
        let after = try #require(workspace.screen(profile: service.profile))
        let afterCards = workspace.cards(profile: service.profile)
        #expect(after.owner == before.owner && workspace.isCurrent(before.owner))
        #expect(after.snapshot == before.snapshot && after.canAct)
        #expect(workspace.draft(before.owner) == "Keep the editor")
        #expect(try encoder.encode(workspace.persisted().record(before.owner.chat)) == saved)
        #expect(afterCards.first { $0.id == before.owner.chat }?.status == .waiting)
        #expect(afterCards.first { $0.id != before.owner.chat }?.status == .waiting)
    }

    @Test(arguments: [false, true])
    func inactiveWorkspaceIgnoresActivityBatches(retired: Bool) throws {
        let service = try WorkspaceTestService()
        var book = ConversationBook()
        let identity = service.summaries[0].identity
        _ = book.merge(service.summaries[0])
        var dirty = 0
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: book, service: service, onDirty: { dirty += 1 })
        workspace.setOnline(true)
        if retired { workspace.retireWorkspace() } else { workspace.setOnline(false) }
        dirty = 0
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(workspace.persisted())
        workspace.applyActivity([.init(profile: service.profile, observations: [identity: .known(.waiting, .now)])])
        #expect(dirty == 0)
        #expect(try encoder.encode(workspace.persisted()) == before)
    }

    @Test func individualActivityAppliesWhileAnUnrelatedRosterReadIsSuspended() async throws {
        let service = try WorkspaceTestService(), gate = WorkspaceGate()
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://activity-order.invalid")!)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        defer { gate.release(); store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        service.rosterGate = gate
        let refresh = Task { await store.refresh() }
        await gate.entered()
        let identity = service.summaries[0].identity
        service.onEvent?(.activity(profile: service.profile, observations: [identity: .known(.waiting, .now)]))
        #expect(store.chats.aggregate(profile: service.profile).status == .waiting)
        #expect(store.needsYou.map(\.id) == [service.profile.text])
        gate.release(); await refresh.value
    }

    @Test func reconnectCannotReviveRetiredRosterAttentionWhileTheNewRosterIsPendingOrFails() async throws {
        let service = try WorkspaceTestService(), gate = WorkspaceGate()
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://retired-roster.invalid")!)
        defer { LocalHistory.remove(for: configuration.id) }
        service.rosterStatus = .waiting
        for summary in service.summaries { service.directoryActivity[summary.identity] = .known(.waiting, .now) }
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        #expect(await store.connect(configuration))
        #expect(store.needsYou.count == 1)
        await store.setActive(false)
        let historical = store.chats.aggregate(profile: service.profile).activity
        service.rosterGate = gate
        service.rosterError = HermesServiceError.timeout
        let reconnecting = Task { await store.connect(configuration) }
        await gate.entered()
        #expect(store.isConnected)
        #expect(store.chats.aggregate(profile: service.profile).activity == historical)
        #expect(store.needsYou.isEmpty)
        #expect(store.inbox.allSatisfy { !$0.needsAttention && $0.bot.status == .idle })
        gate.release()
        #expect(await reconnecting.value)
        #expect(store.chats.aggregate(profile: service.profile).activity == historical)
        #expect(store.needsYou.isEmpty)
        #expect(store.inbox.allSatisfy { !$0.needsAttention && $0.bot.status == .idle })
        await store.setActive(false)
    }

    @Test func finishingInitialRefreshPreservesAChatOpenedWhileItWasPending() async throws {
        let service = try WorkspaceTestService(), gate = WorkspaceGate()
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://pending-start.invalid")!)
        defer { LocalHistory.remove(for: configuration.id) }
        service.directoryGate = gate
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        let connecting = Task { await store.connect(configuration) }
        await gate.entered()
        await store.open(try #require(store.bots.first))
        let workspace = store.chats
        let opened = try #require(workspace.screen(profile: service.profile))
        workspace.editDraft("Keep typing", owner: opened.owner)
        gate.release()
        #expect(await connecting.value)
        #expect(workspace.isCurrent(opened.owner))
        #expect(workspace.screen(profile: service.profile)?.selectedViewLifetime == opened.selectedViewLifetime)
        #expect(workspace.draft(opened.owner) == "Keep typing")
        #expect(service.opens.count == 1)
        await store.setActive(false)
    }

    @Test func delayedInitialActivityKeepsCachedContentAndDraftsQuiet() async throws {
        let service = try WorkspaceTestService(), gate = WorkspaceGate()
        let bot = BotProfile(id: service.profile.text, name: "Milo")
        var book = ConversationBook()
        for summary in service.summaries {
            let id = book.merge(summary)
            book.cache(try #require(service.snapshots[summary.identity.root]), for: id)
        }
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: book, service: service, onDirty: {})
        workspace.observeProfiles([bot])
        await workspace.openBot(profile: service.profile)
        let before = try #require(workspace.screen(profile: service.profile))
        workspace.editDraft("A saved thought\n", owner: before.owner)
        service.directoryGate = gate
        for summary in service.summaries { service.directoryActivity[summary.identity] = .known(.idle, .now) }
        workspace.setOnline(true)
        let refreshing = Task { await workspace.refreshActivityDirectories(for: [bot]) }
        await gate.entered()
        let during = try #require(workspace.screen(profile: service.profile))
        let duringCards = workspace.cards(profile: service.profile)
        #expect(during.isLoadingDirectory && !during.canAct)
        #expect(duringCards.allSatisfy { $0.activity == .unobserved && $0.activity.label == nil })
        #expect(workspace.aggregate(profile: service.profile).activity == .unobserved)
        #expect(during.snapshot?.messages.first?.text == "Bot Chat")
        #expect(workspace.draft(during.owner) == "A saved thought\n")
        gate.release(); await refreshing.value
        let after = try #require(workspace.screen(profile: service.profile))
        let afterCards = workspace.cards(profile: service.profile)
        #expect(!after.isLoadingDirectory && after.selectedChatID == before.selectedChatID)
        #expect(afterCards.allSatisfy { $0.activity == .current(.idle) })
        #expect(workspace.draft(after.owner) == "A saved thought\n")
        #expect(service.opens.isEmpty && service.sends.isEmpty)
    }

    @Test func successfulActivitySurvivesDiskRestoreAsHistoryWithoutLiveAttentionOrAccess() async throws {
        let service = try WorkspaceTestService()
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://historical-activity.invalid")!)
        defer { LocalHistory.remove(for: configuration.id) }
        let bot = BotProfile(id: service.profile.text, name: "Milo")
        let identity = service.summaries[1].identity
        let observedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let observation = ActivityObservation(status: .waiting, observedAt: observedAt)
        var book = ConversationBook()
        for summary in service.summaries {
            let id = book.merge(summary)
            book.cache(try #require(service.snapshots[summary.identity.root]), for: id)
        }
        let workspace = ConversationWorkspace(scope: .init(cacheID: configuration.id, exactAccount: [], incarnation: UUID()),
            book: book, service: service, onDirty: {})
        workspace.observeProfiles([bot]); workspace.setOnline(true)
        for summary in service.summaries { service.directoryActivity[summary.identity] = .known(.idle, observedAt) }
        await workspace.refreshActivityDirectories(for: [bot])
        workspace.applyActivity(profile: service.profile, observations: [identity: .known(.waiting, observedAt)])
        #expect(workspace.aggregate(profile: service.profile).attentionChat != nil)
        var history = LocalHistory()
        history.bots = [bot]; history.book = workspace.persisted()
        try history.save(for: configuration.id)
        let loaded = try LocalHistory.load(for: configuration.id)
        let savedID = try #require(loaded.book.matching(identity))
        #expect(loaded.book.record(savedID)?.lastKnownActivity == observation)

        let store = AppStore(service: service,
            persistence: MemoryConnectionStorage(saved: configuration).persistence)
        #expect(store.chats.aggregate(profile: service.profile).activity == .historical(observation))
        #expect(store.chats.aggregate(profile: service.profile).status == nil)
        #expect(store.chats.aggregate(profile: service.profile).attentionChat == nil)
        #expect(store.needsYou.isEmpty)
        await store.chats.openBot(profile: service.profile)
        let screen = try #require(store.chats.screen(profile: service.profile))
        let screenCards = store.chats.cards(profile: service.profile)
        let restored = try #require(screenCards.first { $0.id == savedID })
        #expect(restored.activity.label == "Previously waiting" && restored.status == nil)
        #expect(!screen.canAct && screen.requests.isEmpty)
        #expect(screen.snapshot?.messages.first?.text == "Bot Chat")
        #expect(service.opens.isEmpty && service.responses.isEmpty)
    }

    @Test func unknownSampleAndFailedReconnectPreserveHistoryUntilSuccessfulRetry() async throws {
        let service = try WorkspaceTestService()
        let bot = BotProfile(id: service.profile.text, name: "Milo")
        let identity = service.summaries[1].identity
        let observedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let observation = ActivityObservation(status: .waiting, observedAt: observedAt)
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: .init(), service: service, onDirty: {})
        workspace.observeProfiles([bot]); workspace.setOnline(true)
        for summary in service.summaries { service.directoryActivity[summary.identity] = .known(.idle, observedAt) }
        service.directoryActivity[identity] = .known(.waiting, observedAt)
        await workspace.refreshActivityDirectories(for: [bot])
        await workspace.openBot(profile: service.profile)
        let before = try #require(workspace.screen(profile: service.profile))
        workspace.editDraft("Keep this draft", owner: before.owner)
        workspace.applyActivity(profile: service.profile, observations: [identity: .unknown("Timed out")])
        #expect(workspace.aggregate(profile: service.profile).activity == .unavailable(lastKnown: observation))
        #expect(workspace.aggregate(profile: service.profile).attentionChat == nil)
        #expect(workspace.aggregate(profile: service.profile).status == nil)
        workspace.setOnline(false)
        #expect(workspace.aggregate(profile: service.profile).activity == .historical(observation))
        workspace.setOnline(true)
        service.directoryError = HermesServiceError.timeout
        await workspace.refreshActivityDirectories(for: [bot])
        let failed = try #require(workspace.screen(profile: service.profile))
        let failedCards = workspace.cards(profile: service.profile)
        #expect(failed.selectedChatID == before.selectedChatID && !failed.canAct)
        #expect(workspace.draft(failed.owner) == "Keep this draft")
        let card = try #require(failedCards.first { !$0.isMain })
        #expect(card.activity == .unavailable(lastKnown: observation))
        #expect(card.activity.label == "Previously waiting")
        #expect(workspace.persisted().record(card.id)?.lastKnownActivity == observation)

        service.directoryError = nil
        service.directoryActivity[identity] = .known(.working, observedAt.addingTimeInterval(5))
        await workspace.refreshActivityDirectories(for: [bot])
        let recovered = try #require(workspace.screen(profile: service.profile))
        let recoveredCards = workspace.cards(profile: service.profile)
        #expect(recoveredCards.first { !$0.isMain }?.activity == .current(.working))
        #expect(workspace.aggregate(profile: service.profile).activity == .current(.working))
        #expect(workspace.draft(recovered.owner) == "Keep this draft")
        #expect(recovered.selectedChatID == before.selectedChatID && !recovered.canAct)
        #expect(service.sends.isEmpty && service.responses.isEmpty)
    }

    @Test func activityFailureWithoutAnObservationIsExplicitOnlyAfterTheCheckFails() async throws {
        let service = try WorkspaceTestService()
        let bot = BotProfile(id: service.profile.text, name: "Milo")
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: .init(), service: service, onDirty: {})
        workspace.observeProfiles([bot]); workspace.setOnline(true)
        #expect(workspace.aggregate(profile: service.profile).activity == .unobserved)
        service.directoryError = HermesServiceError.timeout
        await workspace.refreshActivityDirectories(for: [bot])
        #expect(workspace.aggregate(profile: service.profile).activity == .unavailable(lastKnown: nil))
        #expect(workspace.aggregate(profile: service.profile).activity.label == "Activity unavailable")
        #expect(service.opens.isEmpty)
    }

    @Test func directoryWithoutActivityDoesNotTurnMissingObservationsIntoFailures() async throws {
        let service = try WorkspaceTestService()
        let bot = BotProfile(id: service.profile.text, name: "Milo")
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: .init(), service: service, onDirty: {})
        workspace.observeProfiles([bot]); workspace.setOnline(true)
        await workspace.refreshActivityDirectories(for: [bot])
        #expect(workspace.aggregate(profile: service.profile).activity == .unobserved)
        #expect(workspace.aggregate(profile: service.profile).activity.label == nil)
        let identity = service.summaries[1].identity
        let observedAt = Date(timeIntervalSince1970: 1_700_000_000)
        workspace.applyActivity(profile: service.profile, observations: [identity: .known(.working, observedAt)])
        workspace.invalidateActivityDirectory(service.profile)
        await workspace.refreshActivityDirectories(for: [bot])
        #expect(workspace.aggregate(profile: service.profile).activity == .historical(.init(status: .working, observedAt: observedAt)))
        #expect(workspace.aggregate(profile: service.profile).status == nil)
        #expect(service.opens.isEmpty)
    }

    @Test func cacheWithoutActivityFieldRestoresContentWithoutGuessingIdleOrFailure() throws {
        let service = try WorkspaceTestService()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = UUID()
        var history = LocalHistory()
        let id = history.book.merge(service.summaries[0])
        history.book.cache(try #require(service.snapshots[service.summaries[0].identity.root]), for: id)
        history.book.update(id) {
            $0.draft.text = "Legacy draft\n"
            $0.lastKnownActivity = .init(status: .working, observedAt: .now)
        }
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(history)) as? [String: Any])
        var book = try #require(json["book"] as? [String: Any])
        var records = try #require(book["records"] as? [[String: Any]])
        for index in records.indices { records[index].removeValue(forKey: "lastKnownActivity") }
        book["records"] = records; json["book"] = book
        try JSONSerialization.data(withJSONObject: json).write(to: LocalHistory.file(for: connection, directory: directory))
        let restored = try LocalHistory.load(for: connection, directory: directory)
        #expect(restored.book.record(id)?.lastKnownActivity == nil)
        #expect(restored.book.record(id)?.draft.text == "Legacy draft\n")
        #expect(restored.book.record(id)?.transcript?.messages.first?.text == "Bot Chat")
        let workspace = ConversationWorkspace(scope: .init(cacheID: connection, exactAccount: [], incarnation: UUID()),
            book: restored.book, service: service, onDirty: {})
        #expect(workspace.aggregate(profile: service.profile).activity == .unobserved)
    }

    @Test func remoteChatReachesInboxAttentionWithoutOpeningABot() async throws {
        let service = try WorkspaceTestService()
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://remote-discovery.invalid")!)
        defer { LocalHistory.remove(for: configuration.id) }
        for summary in service.summaries { service.directoryActivity[summary.identity] = .known(.idle, .now) }
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        #expect(await store.connect(configuration))
        #expect(store.needsYou.isEmpty && service.directoryCalls == 1)
        let root = try ExactID("remote-chat")
        let identity = SessionIdentity(profile: service.profile, root: root, stored: root, aliases: [root])
        service.summaries.append(.init(identity: identity, title: "From another client", isCanonical: false, persistence: .durable))
        service.directoryActivity[identity] = .known(.waiting, .now)
        service.rosterActivity = [identity: .known(.waiting, .now)]
        service.directoryChanges = [service.profile]
        await store.refresh()
        #expect(store.needsYou.count == 1)
        #expect(store.chats.aggregate(profile: service.profile).count == 3)
        let entry = try #require(store.inbox.first { $0.id == service.profile.text })
        #expect(entry.aggregate?.count == 3 && entry.aggregate?.directoryComplete == true)
        #expect(entry.aggregate?.status == .waiting && entry.aggregate?.attentionChat != nil)
        #expect(store.bot(withID: service.profile.text) == entry.bot)
        #expect(service.directoryCalls == 2 && service.opens.isEmpty)
        await store.setActive(false)
    }

    @Test func directoryInvalidationRetiresOldReadsAndRefreshesOnlyItsProfile() async throws {
        let service = try WorkspaceTestService(), gate = WorkspaceGate()
        let otherProfile = try ExactID("other-bot"), otherRoot = try ExactID("other-main")
        let other = SessionIdentity(profile: otherProfile, root: otherRoot, stored: otherRoot, aliases: [otherRoot])
        service.summaries.append(.init(identity: other, title: "Main", isCanonical: true, persistence: .durable))
        let bots = [BotProfile(id: service.profile.text, name: "Milo"), .init(id: otherProfile.text, name: "Other")]
        for summary in service.summaries { service.directoryActivity[summary.identity] = .known(.idle, .now) }
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: .init(), service: service, onDirty: {})
        workspace.observeProfiles(bots); workspace.setOnline(true)
        await workspace.refreshActivityDirectories(for: bots)
        #expect(service.directoryCalls == 2)
        service.directoryResult = .init(summaries: service.summaries, activity: service.directoryActivity, isComplete: true)
        service.directoryGate = gate
        workspace.invalidateActivityDirectory(service.profile)
        let old = Task { await workspace.refreshActivityDirectories(for: bots) }
        await gate.entered()
        let root = try ExactID("newer-remote")
        let identity = SessionIdentity(profile: service.profile, root: root, stored: root, aliases: [root])
        service.summaries.append(.init(identity: identity, title: "Remote", isCanonical: false, persistence: .durable))
        service.directoryActivity[identity] = .known(.waiting, .now)
        workspace.invalidateActivityDirectory(service.profile)
        service.directoryGate = nil; service.directoryResult = nil
        await workspace.refreshActivityDirectories(for: bots)
        gate.release(); await old.value
        #expect(service.directoryCalls == 4)
        #expect(workspace.aggregate(profile: service.profile).count == 3)
        #expect(workspace.aggregate(profile: service.profile).status == .waiting)
        #expect(workspace.aggregate(profile: otherProfile).count == 1)
        #expect(workspace.aggregate(profile: otherProfile).status == .idle)
    }

    @Test func restoredInboxSamplesEveryChatWithoutOpeningABot() async throws {
        let service = try WorkspaceTestService()
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://activity.invalid")!)
        defer { LocalHistory.remove(for: configuration.id) }
        var history = LocalHistory()
        history.bots = [.init(id: service.profile.text, name: "Milo")]
        for summary in service.summaries {
            let id = history.book.merge(summary)
            if let snapshot = service.snapshots[summary.identity.root] { history.book.cache(snapshot, for: id) }
            service.directoryActivity[summary.identity] = .known(.idle, .now)
        }
        try history.save(for: configuration.id)
        let store = AppStore(service: service,
            persistence: MemoryConnectionStorage(saved: configuration).persistence)
        #expect(store.chats.aggregate(profile: service.profile).hasUnknownActivity)
        #expect(await store.connect(configuration))
        #expect(!store.chats.aggregate(profile: service.profile).hasUnknownActivity)
        #expect(store.chats.aggregate(profile: service.profile).status == .idle)
        #expect(service.opens.isEmpty && service.directoryCalls == 1)
        #expect(store.selectedBot == nil)

        let sibling = service.summaries[1].identity
        service.rosterActivity = [sibling: .known(.waiting, .now.addingTimeInterval(1))]
        await store.refresh()
        #expect(store.needsYou.count == 1)
        #expect(service.directoryCalls == 1 && service.opens.isEmpty)

        service.directoryActivity[sibling] = .known(.waiting, .now.addingTimeInterval(2))
        #expect(await store.connect(configuration))
        #expect(!store.chats.aggregate(profile: service.profile).hasUnknownActivity)
        #expect(store.needsYou.count == 1)
        #expect(service.directoryCalls == 2 && service.opens.isEmpty)
        await store.setActive(false)
    }

    @Test func failedInboxDirectoryRetriesAndUnknownSamplesRemainVisible() async throws {
        let service = try WorkspaceTestService()
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://activity-failure.invalid")!)
        defer { LocalHistory.remove(for: configuration.id) }
        service.directoryError = HermesServiceError.timeout
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        #expect(await store.connect(configuration))
        #expect(store.chats.aggregate(profile: service.profile).hasUnknownActivity)
        #expect(service.directoryCalls == 1)
        service.directoryError = nil
        for summary in service.summaries { service.directoryActivity[summary.identity] = .known(.idle, .now) }
        await store.refresh()
        #expect(!store.chats.aggregate(profile: service.profile).hasUnknownActivity)
        #expect(service.directoryCalls == 2)
        service.rosterActivity = [service.summaries[1].identity: .unknown("Activity unavailable")]
        await store.refresh()
        #expect(store.chats.aggregate(profile: service.profile).hasUnknownActivity)
        #expect(service.directoryCalls == 2 && service.opens.isEmpty)
        await store.setActive(false)
    }

    @Test func retiredInboxDirectoryCannotPublishIntoAReplacementConnection() async throws {
        let service = try WorkspaceTestService(), gate = WorkspaceGate()
        let first = ConnectionConfiguration(serverURL: URL(string: "https://old-activity.invalid")!)
        let second = ConnectionConfiguration(serverURL: URL(string: "https://new-activity.invalid")!)
        defer { LocalHistory.remove(for: first.id); LocalHistory.remove(for: second.id) }
        service.directoryGate = gate
        for summary in service.summaries { service.directoryActivity[summary.identity] = .known(.waiting, .now) }
        service.directoryResult = .init(summaries: service.summaries, activity: service.directoryActivity, isComplete: true)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        let connecting = Task { await store.connect(first) }
        await gate.entered()
        let retired = store.chats
        service.directoryGate = nil; service.directoryResult = nil
        service.directoryActivity = service.directoryActivity.mapValues { _ in .known(.idle, .now) }
        #expect(await store.connect(second))
        gate.release()
        #expect(await connecting.value == false)
        #expect(store.configuration?.id == second.id)
        #expect(store.needsYou.isEmpty)
        #expect(!store.chats.aggregate(profile: service.profile).hasUnknownActivity)
        #expect(retired.aggregate(profile: service.profile).hasUnknownActivity)
        #expect(retired.persisted().records.allSatisfy { $0.lastKnownActivity == nil })
        #expect(store.chats.persisted().records.allSatisfy { $0.lastKnownActivity?.status == .idle })
        #expect(service.opens.isEmpty)
        await store.setActive(false)
        let reloaded = try LocalHistory.load(for: second.id)
        #expect(reloaded.book.records.count == service.summaries.count)
        #expect(reloaded.book.records.allSatisfy { $0.lastKnownActivity?.status == .idle })
    }

    @Test func olderInboxDirectoryCannotDisableANewlyCreatedChat() async throws {
        let service = try WorkspaceTestService(), gate = WorkspaceGate()
        let bot = BotProfile(id: service.profile.text, name: "Milo")
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: .init(), service: service, onDirty: {})
        workspace.observeProfiles([bot]); workspace.setOnline(true)
        await workspace.openBot(profile: service.profile)
        let main = try #require(workspace.screen(profile: service.profile))
        service.directoryResult = .init(summaries: service.summaries,
            activity: Dictionary(uniqueKeysWithValues: service.summaries.map { ($0.identity, .known(.idle, .now)) }),
            isComplete: true)
        service.directoryGate = gate
        let loading = Task { await workspace.refreshActivityDirectories(for: [bot]) }
        await gate.entered()
        await workspace.create(try #require(workspace.captureCreation(main.owner)))
        let created = try #require(workspace.screen(profile: service.profile))
        #expect(created.selectedChatID != main.selectedChatID && created.canAct)
        gate.release(); await loading.value
        let current = try #require(workspace.screen(profile: service.profile))
        #expect(current.selectedChatID == created.selectedChatID && current.canAct)
        #expect(current.error == nil)
        service.directoryGate = nil; service.directoryResult = nil
        for summary in service.summaries { service.directoryActivity[summary.identity] = .known(.idle, .now) }
        await workspace.refreshActivityDirectories(for: [bot])
        #expect(!workspace.aggregate(profile: service.profile).hasUnknownActivity)
        #expect(workspace.screen(profile: service.profile)?.canAct == true)
    }

    @Test(arguments: [true, false])
    func cancellingOneWaiterKeepsSharedDirectoryRead(cancelBackground: Bool) async throws {
        let service = try WorkspaceTestService(), gate = WorkspaceGate()
        let bot = BotProfile(id: service.profile.text, name: "Milo")
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: .init(), service: service, onDirty: {})
        workspace.observeProfiles([bot]); workspace.setOnline(true)
        await workspace.openBot(profile: service.profile)
        let owner = try #require(workspace.screen(profile: service.profile)?.owner)
        for summary in service.summaries { service.directoryActivity[summary.identity] = .known(.idle, .now) }
        service.directoryGate = gate
        let background = Task { await workspace.refreshActivityDirectories(for: [bot]) }
        await gate.entered()
        var foregroundStarted = false
        let foreground = Task { foregroundStarted = true; await workspace.refreshDirectory(owner) }
        while !foregroundStarted { await Task.yield() }
        if cancelBackground { background.cancel() } else { foreground.cancel() }
        gate.release(); await foreground.value; await background.value
        #expect(!workspace.aggregate(profile: service.profile).hasUnknownActivity)
        #expect(service.directoryCalls == 1)
        #expect(workspace.screen(profile: service.profile)?.canAct == true)
    }

    @Test func reappearingBotLoadsItsNewDirectoryWithoutReconnecting() async throws {
        let service = try WorkspaceTestService()
        let bot = BotProfile(id: service.profile.text, name: "Milo")
        let workspace = ConversationWorkspace(scope: .init(cacheID: UUID(), exactAccount: [], incarnation: UUID()),
            book: .init(), service: service, onDirty: {})
        workspace.observeProfiles([bot]); workspace.setOnline(true)
        await workspace.refreshActivityDirectories(for: [bot])
        await workspace.refreshActivityDirectories(for: [])
        let root = try ExactID("reappeared-chat")
        service.summaries.append(.init(identity: .init(profile: service.profile, root: root, stored: root, aliases: [root]),
            title: "New chat", isCanonical: false, persistence: .durable))
        for summary in service.summaries { service.directoryActivity[summary.identity] = .known(.idle, .now) }
        await workspace.refreshActivityDirectories(for: [bot])
        #expect(service.directoryCalls == 2)
        #expect(workspace.aggregate(profile: service.profile).count == 3)
        #expect(!workspace.aggregate(profile: service.profile).hasUnknownActivity)
        #expect(service.opens.isEmpty)
    }

    @Test func ordinaryRosterPollPublishesSiblingActivityWithoutDirectoryPagingAndOldConnectionCannotPublish() async throws {
        let service = try WorkspaceTestService(), storage = MemoryConnectionStorage()
        let first = ConnectionConfiguration(serverURL: URL(string: "https://first.invalid")!)
        let second = ConnectionConfiguration(serverURL: URL(string: "https://second.invalid")!)
        defer { LocalHistory.remove(for: first.id); LocalHistory.remove(for: second.id) }
        let identity = service.summaries[0].identity
        service.snapshots[identity.root]?.pendingRequests = [.init(id: "approval", kind: .approval, title: "Waiting")]
        service.directoryActivity[identity] = .known(.waiting, .now)
        let store = AppStore(service: service, persistence: storage.persistence)
        #expect(await store.connect(first))
        let bot = try #require(store.bots.first)
        await store.open(bot)
        var workspace = store.chats
        var a = try #require(workspace.screen(profile: service.profile))
        await workspace.refreshDirectory(a.owner)
        var b = try #require(workspace.cards(profile: service.profile).first { !$0.isMain }?.id)
        await workspace.select(try #require(workspace.captureSelection(b, owner: a.owner)))
        #expect(store.needsYou.map(\.id) == [bot.id])
        let reads = service.directoryCalls
        service.rosterActivity = [identity: .known(.idle, .now.addingTimeInterval(1))]
        await store.refresh()
        #expect(store.needsYou.isEmpty && service.directoryCalls == reads)
        let retired = try #require(service.onEvent)
        #expect(await store.connect(second))
        service.rosterActivity = [:]
        await store.open(bot)
        workspace = store.chats
        a = try #require(workspace.screen(profile: service.profile))
        await workspace.refreshDirectory(a.owner)
        b = try #require(workspace.cards(profile: service.profile).first { !$0.isMain }?.id)
        await workspace.select(try #require(workspace.captureSelection(b, owner: a.owner)))
        #expect(!store.needsYou.isEmpty)
        let seen = workspace.persisted().record(a.selectedChatID)?.seen
        retired(.activity(profile: service.profile, observations: [identity: .known(.idle, .distantFuture)]))
        #expect(!store.needsYou.isEmpty)
        service.onEvent?(.activity(profile: service.profile, observations: [identity: .known(.idle, .distantFuture)]))
        #expect(store.needsYou.isEmpty)
        #expect(workspace.persisted().record(a.selectedChatID)?.seen?.observedAt == seen?.observedAt)
    }
}
