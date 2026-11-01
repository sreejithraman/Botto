import Foundation
import Testing
import BottoCore

/// Opt-in only: creates a disposable bot on a local deterministic Hermes host.
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["BOTTO_TEST_HERMES_LIBRARY_URL"] != nil))
func disposableHostLibraryReadsPreserveSelectedSiblingAccess() async throws {
    let environment = ProcessInfo.processInfo.environment
    let address = try #require(environment["BOTTO_TEST_HERMES_LIBRARY_URL"])
    let url = try #require(URL(string: address))
    let service = HermesBotService()
    defer { service.disconnect() }
    var latest: OpenedConversation?
    var publications = 0
    service.onEvent = { event in
        if case .conversation(let opened) = event {
            latest = opened
            publications += 1
        }
    }
    let server = try await service.connect(configuration: ConnectionConfiguration(serverURL: url,
        username: environment["BOTTO_TEST_HERMES_USER"] ?? "botto-test",
        password: environment["BOTTO_TEST_HERMES_PASSWORD"] ?? "botto-test"))
    let bot = try await service.createBot(BotDraft(name: "Library probe " + String(UUID().uuidString.prefix(8)),
        instructions: "A disposable local library interoperability probe. Reply briefly."))
    let profile = try ExactID(bot.id)
    let main = try await service.openChat(.canonical(profile: profile, expectedRoot: nil))
    let expectedBytes = Data("Library original bytes\n".utf8)
    let file = try await service.upload(data: expectedBytes, filename: "library-probe.txt",
                                       mimeType: "text/plain", access: main.access)
    let mainPrompt = "Library main evidence. Confirm the attached file."
    _ = try await service.send(text: mainPrompt, attachments: [file], access: main.access, operationID: UUID())
    try await waitForLibraryLive {
        latest?.identity.root == main.identity.root && latest?.snapshot.isWorking == false &&
            latest?.snapshot.messages.contains { $0.role == .assistant && !$0.text.isEmpty } == true
    }
    let mainDirectory = try await service.conversations(profile: profile)
    let mainSource = try #require(mainDirectory.summaries.first { $0.identity.root == main.identity.root })
    let created = try await service.createConversation(profile: profile, operationID: UUID())
    let sibling = try await service.openChat(.stored(created.summary.identity))
    let beforeReads = publications

    let history = try await service.conversationHistory(mainSource.identity, offset: 0)
    #expect(history.isComplete)
    #expect(history.nextOffset == nil)
    #expect(history.messages.contains { $0.role == .user && $0.text.contains(mainPrompt) })
    #expect(history.messages.contains { $0.role == .assistant && !$0.text.isEmpty })
    let downloaded = try await service.downloadArtifact(file, in: mainSource.identity)
    #expect(downloaded.data == expectedBytes)
    #expect(downloaded.filename.hasSuffix("library-probe.txt"))
    #expect(publications == beforeReads)
    #expect(latest?.identity.root == sibling.identity.root)

    let siblingPrompt = "Library sibling evidence. Reply with one short greeting."
    let sent = try await service.send(text: siblingPrompt, attachments: [], access: sibling.access, operationID: UUID())
    #expect(sent.source.root == sibling.identity.root)
    try await waitForLibraryLive {
        latest?.identity.root == sibling.identity.root && latest?.snapshot.isWorking == false &&
            latest?.snapshot.messages.contains { $0.role == .user && $0.text.contains(siblingPrompt) } == true &&
            latest?.snapshot.messages.contains { $0.role == .assistant && !$0.text.isEmpty } == true
    }
    let mainAfter = try await service.conversationHistory(mainSource.identity, offset: 0)
    #expect(!mainAfter.messages.contains { $0.text.contains(siblingPrompt) })
    print("BOTTO_LIBRARY_LIVE version=\(server.version) profile=\(bot.id) history=main-only download=original-bytes sibling-access=preserved")
}

@MainActor private func waitForLibraryLive(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(60)
    while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
    try #require(predicate())
}
