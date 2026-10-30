import Foundation
import Testing
@testable import BottoCore

@MainActor @Test(arguments: [false, true]) func capturedCompletionRetiresTransientAccessThenPublishesUsableRefreshedOwner(explicitReopen: Bool) async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let opened = try await service.openChat(.canonical(profile: ExactID(host.bot.id), expectedRoot: nil))
    let url = try #require(Bundle.module.url(forResource: "turn-events", withExtension: "json", subdirectory: "Fixtures/AuthorityCaptured"))
    let events = try HermesJSON.decode(Data(contentsOf: url))
    var complete = try #require(events.list?.first { $0["type"].text == "message.complete" })
    complete["session_id"] = .string(host.runtime); complete["replay_epoch"] = .string("session-epoch")
    complete["execution_generation"] = .number(7); complete["seq"] = .number(1)
    host.snapshot["last_sequence"] = .number(1)
    host.snapshot["messages"] = .array([.object(["role": .string("assistant"), "row_id": .number(2), "text": complete["payload"]["text"]])])
    var publications: [OpenedConversation] = []
    service.onEvent = { if case .conversation(let value) = $0 { publications.append(value) } }
    let socket = host.sockets[0]
    socket.push(.object(["method": .string("event"), "params": complete]))
    try await eventually { !publications.isEmpty }
    let transient = try #require(publications.first)
    #expect(transient.snapshot.messages.contains { $0.text.contains("HOT_LOCAL_ACK") })
    #expect(transient.access == opened.access)
    let file = ChatAttachment(name: "proof.txt", path: "/host/proof.txt")
    await #expect(throws: HermesServiceError.staleConversation) { try await service.downloadArtifact(file, access: transient.access) }
    #expect(!host.transport.requests.contains { $0.url?.path == "/api/fs/download" })
    if explicitReopen { _ = try await service.openChat(.stored(transient.identity)) }
    try await eventually { publications.last?.access != transient.access }
    let refreshed = try #require(publications.last)
    #expect(refreshed.identity == transient.identity)
    #expect(refreshed.snapshot.messages.contains { $0.text.contains("HOT_LOCAL_ACK") })
    _ = try await service.downloadArtifact(file, access: refreshed.access)
    #expect(host.transport.requests.filter { $0.url?.path == "/api/fs/download" }.count == 1)
}
