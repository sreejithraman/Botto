import Foundation
import Testing
import BottoCore
@testable import Botto

@MainActor struct AvatarGenerationStoreTests {
    private let cat = #"{"version":1,"id":"cat","name":"Cat","body":{"path":"M18 30 L18 14 Q18 10 24 14 L34 24 L66 24 L76 14 Q82 10 82 18 L82 72 Q82 86 68 86 L32 86 Q18 86 18 72 Z"},"eyes":{"x":50,"y":48,"spacing":16,"scale":1}}"#

    @Test func generationReturnsAnUnsavedCandidateAndRejectsWorkspaceRetirement() async throws {
        let service = StoreTestService()
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://avatar-generation.example")!)
        let original = BotProfile(id: "milo", name: "Milo", appearance: .init(shape: .cloud))
        let geometry = try BotAvatarGeometry(json: cat)
        service.profiles = [original]
        let store = AppStore(service: service, persistence: MemoryConnectionStorage().persistence)
        defer { store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        #expect(await store.connect(configuration))
        let destination = try #require(store.avatarDestination(for: original))
        service.avatarGenerator = { prompt, bot in
            #expect(prompt == "A cat" && bot.id == original.id)
            return geometry
        }
        #expect(try await store.generateAvatar(description: "A cat", for: destination) == geometry)
        #expect(store.bot(withID: original.id)?.appearance == original.appearance)

        let barrier = StoreTestBarrier()
        service.avatarGenerator = { _, _ in await barrier.wait(); return geometry }
        let pending = Task { try await store.generateAvatar(description: "A dragon", for: destination) }
        #expect(await barrier.waitUntilEntered(timeout: .seconds(2)))
        store.forgetConnection()
        barrier.release()
        await #expect(throws: HermesServiceError.disconnected) { try await pending.value }
        #expect(store.bots.isEmpty)
    }

    @Test func cachedCustomGeometryRestoresInANewOfflineWorkspace() async throws {
        let geometry = try BotAvatarGeometry(json: cat)
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://avatar-cache.example")!)
        defer { LocalHistory.remove(for: configuration.id) }
        let bot = BotProfile(id: "milo", name: "Milo",
            appearance: BotAvatarChoice.geometry(geometry).applying(to: .init(color: "#14b3a5")))
        var history = LocalHistory()
        history.bots = [bot]
        try history.save(for: configuration.id)
        let service = StoreTestService()
        service.connectError = HermesServiceError.disconnected
        let store = AppStore(service: service, persistence: MemoryConnectionStorage(saved: configuration).persistence)
        await store.start()
        #expect(!store.isConnected)
        let restored = try #require(store.bots.first)
        #expect(restored.appearance?.rawShape == geometry.recipe)
        #expect(restored.appearance?.geometry == geometry)
        #expect(restored.appearance?.color == "#14b3a5")
    }
}
