import Foundation
import Testing
import BottoCore
@testable import Botto

@MainActor struct ConversationStorePersistenceTests {
    @Test(arguments: [false, true])
    func unreadableCacheKeepsSavedConnectionUsableAndNeverAutosavesOrPrunes(future: Bool) async throws {
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://saved.invalid")!, username: "alice", installID: "test-install")
        let replacement = ConnectionConfiguration(serverURL: configuration.serverURL, username: "alice")
        let url = try LocalHistory.file(for: configuration.id)
        let raw = Data((future ? "{\"version\":999,\"keep\":\"original\"}" : "{broken cache bytes").utf8)
        try raw.write(to: url)
        defer { LocalHistory.remove(for: configuration.id); LocalHistory.remove(for: replacement.id) }
        let storage = MemoryConnectionStorage(saved: configuration), service = StoreTestService()
        service.profiles = [.init(id: "milo", name: "Milo")]
        var cleanups: [UUID?] = []
        let store = AppStore(service: service, persistence: storage.persistence, cleanupHistory: { cleanups.append($0) })
        #expect(store.cacheLoadFailed && !store.savedSetupLoadFailed)
        #expect(store.configuration?.id == configuration.id && store.notice != nil)
        #expect(await store.connect(configuration))
        await store.open(service.profiles[0])
        await store.testEdit("new live text", for: "milo")
        store.flush()
        #expect(try Data(contentsOf: url) == raw)
        #expect(cleanups.isEmpty && service.connectCount == 1)
        #expect(!(await store.connect(replacement)))
        #expect(storage.saved?.id == configuration.id && store.configuration?.id == configuration.id)
        #expect(try Data(contentsOf: url) == raw)
    }

    @Test func verifiedReauthenticationMovesAllChatUUIDsAndPreferencesBeforeKeychainCommit() async throws {
        let old = ConnectionConfiguration(serverURL: URL(string: "https://saved.invalid")!, username: "alice", installID: "test-install")
        let candidate = ConnectionConfiguration(serverURL: old.serverURL, username: "alice", password: "new")
        defer { LocalHistory.remove(for: old.id); LocalHistory.remove(for: candidate.id) }
        let profile = try ExactID("milo")
        var history = LocalHistory()
        history.bots = [.init(id: profile.text, name: "Milo")]
        let aIdentity = SessionIdentity(profile: profile, root: try ExactID("A-root"), stored: try ExactID("A-tip"), aliases: [])
        let bIdentity = SessionIdentity(profile: profile, root: try ExactID("B-root"), stored: try ExactID("B-tip"), aliases: [])
        let a = history.book.merge(.init(identity: aIdentity, title: "Bot Chat", isCanonical: true, persistence: .durable))
        let b = history.book.merge(.init(identity: bIdentity, title: "B", isCanonical: false, persistence: .durable))
        history.book.update(a) { $0.draft = .init(text: " A draft \n", revision: UUID()) }
        history.book.update(b) { $0.draft = .init(text: " B draft \t", revision: UUID()) }
        history.book.updatePreference(profile) { $0.preferred = b; $0.lastSelected = a }
        history.book.cache(.init(id: "A-runtime", storedID: "A-tip", profileID: profile.text,
            messages: [.init(id: "A-message", role: .assistant, text: "A transcript")]), for: a)
        history.book.cache(.init(id: "B-runtime", storedID: "B-tip", profileID: profile.text,
            messages: [.init(id: "B-message", role: .assistant, text: "B transcript")]), for: b)
        try history.save(for: old.id)
        let storage = MemoryConnectionStorage(saved: old)
        let service = StoreTestService()
        var checkedBeforeKeychain = false
        storage.beforeSave = { saved in
            guard saved.id == candidate.id else { return }
            let fresh = try? LocalHistory.load(for: saved.id)
            #expect(Set(fresh?.book.records.map(\.id) ?? []) == [a, b])
            #expect(fresh?.book.preference(profile)?.preferred == b)
            checkedBeforeKeychain = true
        }
        let store = AppStore(service: service, persistence: storage.persistence)
        #expect(await store.connect(candidate))
        #expect(checkedBeforeKeychain)
        let fresh = try LocalHistory.load(for: candidate.id)
        #expect(Set(fresh.book.records.map(\.id)) == [a, b])
        #expect(fresh.book.record(a)?.draft.text == " A draft \n" && fresh.book.record(b)?.draft.text == " B draft \t")
        #expect(fresh.book.record(a)?.transcript?.messages.first?.text == "A transcript")
        #expect(fresh.book.record(b)?.transcript?.messages.first?.text == "B transcript")
        let reopened = AppStore(service: StoreTestService(), persistence: storage.persistence)
        #expect(reopened.chats.persisted().preference(profile)?.preferred == b)
        #expect(Set(reopened.chats.persisted().records.map(\.id)) == [a, b])
    }
}
