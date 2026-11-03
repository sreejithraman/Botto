import Foundation
import Testing
import BottoCore

/// Opt-in integration with the disposable authority host and deterministic provider.
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["BOTTO_TEST_HERMES_AVATAR_URL"] != nil))
func disposableHostGeneratesAndPersistsACustomAvatarWithoutChangingChat() async throws {
    let environment = ProcessInfo.processInfo.environment
    let url = try #require(environment["BOTTO_TEST_HERMES_AVATAR_URL"].flatMap(URL.init(string:)))
    try #require(["127.0.0.1", "localhost"].contains(url.host ?? ""))
    let configuration = ConnectionConfiguration(serverURL: url, username: "botto-test", password: "botto-test")
    let service = HermesBotService(), observer = HermesBotService()
    defer { service.disconnect(); observer.disconnect() }
    let info = try await service.connect(configuration: configuration)
    let bot = try await service.createBot(.init(name: "Avatar probe " + UUID().uuidString.prefix(8),
        instructions: "A disposable avatar interoperability probe."))
    let opened = try await service.openChat(.canonical(profile: ExactID(bot.id), expectedRoot: nil))
    let description = "A sleepy cat with pointed ears"
    let geometry = try await service.generateAvatar(description: description, for: bot)
    #expect(geometry.name == "Cat")
    let beforeSave = try #require(try await service.bots().first { $0.id == bot.id })
    #expect(beforeSave.appearance == bot.appearance)
    let history = try await service.conversationHistory(opened.identity, offset: 0)
    #expect(!history.messages.contains { $0.text.contains(description) || $0.text.contains("Botto avatar geometry") })

    let saved = try await service.setAvatar(.geometry(geometry, color: .value("#14b3a5")), for: beforeSave)
    _ = try await observer.connect(configuration: configuration)
    let fresh = try #require(try await observer.bots().first { $0.id == bot.id })
    #expect(fresh.appearance?.rawShape == geometry.recipe)
    #expect(fresh.appearance?.geometry == geometry)
    #expect(fresh.appearance?.color == "#14b3a5" && fresh.hasAvatar == true)
    #expect(fresh.lookRevision == saved.lookRevision)
    let png = try #require(try await observer.avatarAsset(for: fresh))
    #expect(png.isStaticPreview(for: fresh.appearance))
    let created = try await observer.createBot(.init(name: "Static avatar " + UUID().uuidString.prefix(8),
        avatar: .geometry(geometry, color: .value("#123456"))))
    let createdImage = try #require(try await service.avatarAsset(for: created))
    #expect(created.hasAvatar == true && createdImage.isStaticPreview(for: created.appearance))
    #expect(created.appearance?.geometry == geometry)
    let cached = try JSONDecoder().decode(BotProfile.self, from: JSONEncoder().encode(fresh))
    #expect(cached.appearance?.geometry == geometry)

    let receipt = try await service.send(text: "Keep this chat usable after creating an avatar.", attachments: [],
                                         access: opened.access, operationID: UUID())
    #expect(receipt.source.root == opened.identity.root)
    _ = try await observer.setAvatar(.shape(.cloud), for: fresh)
    let replaced = try #require(try await service.bots().first { $0.id == bot.id })
    #expect(replaced.appearance?.shape == .cloud && replaced.appearance?.geometry == nil)

    if let path = environment["BOTTO_TEST_AVATAR_REPORT_PATH"] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(fresh).write(to: URL(fileURLWithPath: path), options: .atomic)
        try png.data.write(to: URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("png"), options: .atomic)
    }
    print("BOTTO_AVATAR_LIVE version=\(info.version) profile=\(bot.id) generation=oneshot storage=fresh-read chat-access=preserved external-replacement=passed")
}
