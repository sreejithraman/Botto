import Testing
import Foundation
import BottoCore
@testable import Botto

@MainActor struct AppStoreHistoryTests {
    @Test func saveRecoveryKeepsUnrelatedNoticeAndPersistsTheLatestDraft() async throws {
        let connection = ConnectionConfiguration(serverURL: URL(string: "https://history-notice.example")!)
        let storage = MemoryConnectionStorage(saved: connection)
        let store = AppStore(service: StoreTestService(), persistence: storage.persistence)
        #expect(await store.connect(connection))
        await store.testEdit("Latest draft", for: "milo")
        let cache = try blockHistoryCache(for: connection.id)
        defer { try? FileManager.default.removeItem(at: cache); LocalHistory.remove(for: connection.id) }
        #expect(!store.flush())
        store.notice = "Another operation needs attention."
        try FileManager.default.removeItem(at: cache)

        #expect(store.flush())

        #expect(store.notice == "Another operation needs attention.")
        #expect(try LocalHistory.load(for: connection.id).fixtureRecord("milo")?.draft.text == "Latest draft")
        store.notice = nil
        #expect(store.notice == nil)
    }

    @Test func forgettingConnectionRemovesItsHistoryWarning() async throws {
        let connection = ConnectionConfiguration(serverURL: URL(string: "https://history-forget.example")!)
        let storage = MemoryConnectionStorage(saved: connection)
        let store = AppStore(service: StoreTestService(), persistence: storage.persistence)
        #expect(await store.connect(connection))
        let cache = try blockHistoryCache(for: connection.id)
        defer { try? FileManager.default.removeItem(at: cache); LocalHistory.remove(for: connection.id) }
        #expect(!store.flush())
        #expect(store.notice != nil)

        store.forgetConnection()

        #expect(store.configuration == nil && storage.saved == nil)
        #expect(store.notice == nil)
    }

    @Test func foregroundRetriesHistorySavingEvenWhenReconnectFails() async throws {
        let connection = ConnectionConfiguration(serverURL: URL(string: "https://history-foreground.example")!)
        let storage = MemoryConnectionStorage(saved: connection), service = StoreTestService()
        let store = AppStore(service: service, persistence: storage.persistence)
        await store.start()
        await store.testEdit("Keep this while reconnecting", for: "milo")
        let cache = try blockHistoryCache(for: connection.id)
        defer { try? FileManager.default.removeItem(at: cache); LocalHistory.remove(for: connection.id) }
        await store.setActive(false)
        #expect(store.notice != nil)
        try FileManager.default.removeItem(at: cache)
        service.connectError = HermesServiceError.disconnected

        await store.setActive(true)

        #expect(!store.isConnected && store.connectionError != nil)
        #expect(store.notice == nil, "Local saving can recover independently of the network.")
        #expect(try LocalHistory.load(for: connection.id).fixtureRecord("milo")?.draft.text == "Keep this while reconnecting")
    }

    @Test func encodingFailureDoesNotReportADeviceWriteFailure() async throws {
        let connection = ConnectionConfiguration(serverURL: URL(string: "https://history-encoding.example")!)
        let storage = MemoryConnectionStorage(saved: connection), service = StoreTestService()
        service.profiles = [.init(id: "milo", name: "Milo")]
        let store = AppStore(service: service, persistence: storage.persistence)
        defer { LocalHistory.remove(for: connection.id) }
        #expect(await store.connect(connection))
        await store.testEdit("Keep this draft", for: "milo")
        #expect(store.flush())
        let url = try LocalHistory.file(for: connection.id), original = try Data(contentsOf: url)

        service.profiles[0].updatedAt = Date(timeIntervalSince1970: .infinity)
        await store.refresh()

        #expect(!store.flush())
        #expect(store.notice == "Botto couldn’t prepare your offline history for saving. Your current chat is still available.")
        #expect(store.isConnected && store.draft(for: "milo") == "Keep this draft")
        #expect(try Data(contentsOf: url) == original)
        service.profiles[0].updatedAt = nil
        await store.refresh()
        #expect(store.flush())
        #expect(store.notice == nil)
        #expect(try LocalHistory.load(for: connection.id).fixtureRecord("milo")?.draft.text == "Keep this draft")
    }

    @Test func failedHistorySaveKeepsWorkspaceAndDraftUntilDemoCanSafelyOpen() async throws {
        let connection = ConnectionConfiguration(serverURL: URL(string: "https://history-save.example")!)
        var saved: ConnectionConfiguration? = connection
        let persistence = ConnectionPersistence(load: { saved }, save: { saved = $0 }, remove: { saved = nil })
        let store = AppStore(service: DemoBotService(), persistence: persistence)
        #expect(await store.connect(connection))
        let bot = try #require(store.bots.first { $0.id == "milo" })
        await store.open(bot)
        let avatar = try #require(store.avatarDestination(for: bot))
        let owner = store.connectionGeneration
        await store.testEdit("Keep this unsaved thought", for: bot.id)
        let workspace = store.chats
        let screen = try #require(workspace.screen(profile: ExactID(bot.id)))
        let conversation = try #require(screen.snapshot)
        let cache = try blockHistoryCache(for: connection.id)
        defer { try? FileManager.default.removeItem(at: cache); LocalHistory.remove(for: connection.id) }

        await store.enterDemo()

        #expect(!store.isDemo)
        #expect(store.configuration?.id == connection.id)
        #expect(store.isConnected)
        #expect(store.selectedBotID == bot.id)
        #expect(store.connectionGeneration == owner)
        #expect(avatar.isCurrent(in: store))
        #expect(store.chats === workspace)
        let retained = try #require(store.chats.screen(profile: ExactID(bot.id)))
        #expect(retained.owner == screen.owner)
        #expect(retained.snapshot == conversation)
        #expect(workspace.draft(retained.owner) == "Keep this unsaved thought")
        #expect(store.notice == "Your offline history couldn’t be saved on this device. Your current chat is still available.")
        #expect(saved?.id == connection.id)

        try FileManager.default.removeItem(at: cache)
        await store.enterDemo()
        #expect(store.isDemo)
        #expect(saved?.id == connection.id)
        let savedHistory = try LocalHistory.load(for: connection.id)
        #expect(savedHistory.book.record(screen.selectedChatID)?.draft.text == "Keep this unsaved thought")
        store.leaveDemo()
        #expect(store.configuration?.id == connection.id)
        #expect(store.chats.persisted().record(screen.selectedChatID)?.draft.text == "Keep this unsaved thought")
    }

    @Test func replacementWaitsUntilCurrentHistoryCanBeSaved() async throws {
        let original = ConnectionConfiguration(serverURL: URL(string: "https://old-history.example")!)
        let candidate = ConnectionConfiguration(serverURL: URL(string: "https://new-history.example")!)
        var saved: ConnectionConfiguration? = original
        let persistence = ConnectionPersistence(load: { saved }, save: { saved = $0 }, remove: { saved = nil })
        let store = AppStore(service: DemoBotService(), persistence: persistence)
        #expect(await store.connect(original))
        await store.testEdit("Keep the original workspace", for: "milo")
        let workspace = store.chats
        let screen = try #require(workspace.screen(profile: ExactID("milo")))
        let cache = try blockHistoryCache(for: original.id)
        defer {
            try? FileManager.default.removeItem(at: cache)
            LocalHistory.remove(for: original.id); LocalHistory.remove(for: candidate.id)
        }

        #expect(!(await store.connect(candidate)))
        #expect(saved?.id == original.id)
        #expect(store.configuration?.id == original.id)
        #expect(store.chats === workspace)
        #expect(workspace.draft(screen.owner) == "Keep the original workspace")
        #expect(store.connectionError != nil)

        try FileManager.default.removeItem(at: cache)
        #expect(store.flush())
        let restarted = AppStore(service: DemoBotService(), persistence: persistence)
        #expect(restarted.chats.persisted().record(screen.selectedChatID)?.draft.text == "Keep the original workspace")
        #expect(await store.connect(candidate))
        #expect(saved?.id == candidate.id)
        #expect(store.chats !== workspace)
        #expect(store.chats.persisted().records.allSatisfy { $0.draft.text.isEmpty },
                "Another workspace must not inherit the old draft.")
    }

    @Test func backgroundSaveFailureKeepsDraftThroughRecovery() async throws {
        let connection = ConnectionConfiguration(serverURL: URL(string: "https://recover-history.example")!)
        var saved: ConnectionConfiguration? = connection
        let persistence = ConnectionPersistence(load: { saved }, save: { saved = $0 }, remove: { saved = nil })
        let store = AppStore(service: DemoBotService(), persistence: persistence)
        await store.start()
        await store.testEdit("Keep this while offline", for: "milo")
        let screen = try #require(store.chats.screen(profile: ExactID("milo")))
        let cache = try blockHistoryCache(for: connection.id)
        defer { try? FileManager.default.removeItem(at: cache); LocalHistory.remove(for: connection.id) }

        await store.setActive(false)
        #expect(!store.isConnected)
        #expect(store.chats.persisted().record(screen.selectedChatID)?.draft.text == "Keep this while offline")
        #expect(store.notice == "Your offline history couldn’t be saved on this device. Your current chat is still available.")

        try FileManager.default.removeItem(at: cache)
        await store.setActive(true)
        #expect(store.isConnected)
        #expect(store.chats.persisted().record(screen.selectedChatID)?.draft.text == "Keep this while offline")
        #expect(store.flush())
        #expect(store.notice == nil, "A successful save must clear the earlier history warning.")
        let restarted = AppStore(service: DemoBotService(), persistence: persistence)
        #expect(restarted.chats.persisted().record(screen.selectedChatID)?.draft.text == "Keep this while offline")
    }

    private func blockHistoryCache(for id: UUID) throws -> URL {
        let cache = try LocalHistory.file(for: id)
        if FileManager.default.fileExists(atPath: cache.path) { try FileManager.default.removeItem(at: cache) }
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        return cache
    }
}
