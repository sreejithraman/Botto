import Foundation
import Testing
import BottoCore
@testable import Botto

@MainActor struct WorkspaceLaunchTests {
    #if targetEnvironment(simulator)
    @Test func isolatedLaunchLeavesSavedConnectionUntouchedAcrossDemo() async throws {
        let saved = ConnectionConfiguration(serverURL: URL(string: "https://saved.example")!)
        var reads = 0, writes = 0, removals = 0
        let persistence = ConnectionPersistence(load: { reads += 1; return saved },
            save: { _ in writes += 1 }, remove: { removals += 1 })
        let store = makeWorkspaceStore(arguments: ["--isolated-ui-test"], persistence: persistence)
        try #require(store.configuration == nil)
        #expect(!store.savedSetupLoadFailed)
        await store.start()
        await store.enterDemo()
        #expect(store.isDemo)
        store.leaveDemo()
        #expect(store.configuration == nil)
        #expect(reads == 0)
        #expect(writes == 0)
        #expect(removals == 0)
    }
    #endif

    @Test func ordinaryLaunchLoadsItsSavedConnection() {
        let saved = ConnectionConfiguration(serverURL: URL(string: "https://saved.example")!)
        var reads = 0
        let persistence = ConnectionPersistence(load: { reads += 1; return saved },
            save: { _ in }, remove: {})
        let store = makeWorkspaceStore(arguments: [], persistence: persistence)
        #expect(store.configuration?.id == saved.id)
        #expect(reads == 1)
    }
}
