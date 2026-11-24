import Foundation
import Testing
@testable import BottoCore

@MainActor @Suite(.timeLimit(.minutes(1))) struct T3LiveSmokeTests {
    @Test func pairsBootstrapsAndRunsChannelsAgainstLiveT3Server() async throws {
        guard let pairingInput = ProcessInfo.processInfo.environment["BOTTO_TEST_T3_PAIRING_URL"],
              !pairingInput.isEmpty else {
            return
        }
        let parsed = try T3PairingExchange.parse(pairingInput)
        let exchange = T3PairingExchange()
        var paired = try await exchange.exchangePairingCredential(
            origin: parsed.origin, credential: parsed.credential, clientLabel: "Botto Live Smoke"
        ).configuration
        if let customRoot = ProcessInfo.processInfo.environment["BOTTO_TEST_T3_WORKSPACE_ROOT"], !customRoot.isEmpty {
            paired.t3?.workspaceRoot = customRoot
        }

        let service = T3BotService()
        defer { service.disconnect() }
        let info = try await service.connect(configuration: paired)
        #expect(!info.version.isEmpty)
        #expect(info.installID == paired.t3?.environmentID)

        let bots = try await service.bots()
        let bot = try #require(bots.first)
        #expect(bots.count == 1)
        #expect(bot.name == "Botto")

        let brain = try await service.loadBotBrain()
        #expect(brain.soulMarkdown == T3BotBootstrap.soulMarkdown)
        #expect(brain.memoryMarkdown == T3BotBootstrap.memoryMarkdown)
        #expect(try await service.readProjectFile(relativePath: "AGENTS.md").contains("SOUL.md"))
        #expect(try await service.readProjectFile(relativePath: "CLAUDE.md").contains("MEMORY.md"))

        try await service.saveSoul("# Live Soul\n\nVerified against real t3 serve.\n")
        try await service.saveMemory("# Live Memory\n\nChannel test succeeded.\n")
        let updatedBrain = try await service.loadBotBrain()
        #expect(updatedBrain.soulMarkdown.contains("Verified against real t3 serve."))
        #expect(updatedBrain.memoryMarkdown.contains("Channel test succeeded."))

        let models = try await service.availableModels()
        if !models.isEmpty {
            let main = try #require(service.currentT3Channels.first { $0.isMain })
            #expect(!main.isArchived)
            let created = try await service.createChat(title: "smoke-space")
            let threadID = created.summary.identity.stored.text
            let opened = try await service.openChat(.stored(created.summary.identity))
            #expect(opened.identity.stored.text == threadID)
            try await service.renameChannel(threadID: threadID, title: "smoke-renamed")
            try await service.setChannelPinned(threadID: threadID, pinned: true)
            try await service.archiveChannel(threadID: threadID, archived: true)
        }
    }
}
