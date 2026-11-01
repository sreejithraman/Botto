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

@MainActor @Test func liveToolIdentitySurvivesTheAutomaticDurableCompletionRefresh() async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    _ = try await service.openChat(.canonical(profile: ExactID(host.bot.id), expectedRoot: nil))
    let url = try #require(Bundle.module.url(forResource: "final-snapshot", withExtension: "json", subdirectory: "Fixtures/AuthorityCaptured"))
    let captured = try HermesJSON.decode(Data(contentsOf: url))
    let tool = try #require(captured["messages"].list?.first { $0["role"].text == "tool" })
    let call = try #require(tool["tool_call_id"].text)
    var publications: [OpenedConversation] = []
    service.onEvent = { if case .conversation(let value) = $0 { publications.append(value) } }
    func event(_ type: String, sequence: Int, payload: [String: HermesJSON]) -> HermesJSON {
        var event = host.event(type, seq: sequence, payload: payload)
        event["params"]["admission_id"] = .string("tool-identity-turn")
        return event
    }
    let start = event("message.start", sequence: 1, payload: [:])
    let toolStart = event("tool.start", sequence: 2, payload: ["tool_id": .string(call), "name": .string("terminal")])
    host.sockets[0].push(start); host.sockets[0].push(toolStart)
    try await eventually { publications.last?.snapshot.messages.contains { $0.role == .tool } == true }
    let live = try #require(publications.last)
    let liveTool = try #require(live.snapshot.messages.first { $0.role == .tool })
    let toolComplete = event("tool.complete", sequence: 3, payload: ["tool_id": .string(call), "name": .string("terminal"), "result": tool["content"]])
    let complete = event("message.complete", sequence: 4, payload: ["text": .string("Done"), "status": .string("complete"), "outcome": .string("completed")])
    host.snapshot["last_sequence"] = .number(4)
    host.snapshot["running"] = .bool(false)
    host.snapshot["messages"] = .array([tool, .object(["role": .string("assistant"), "row_id": .number(6), "text": .string("Done")])])
    host.replay["latest_seq"] = .number(4)
    host.replay["events"] = .array([start, toolStart, toolComplete, complete].map { $0["params"] })
    host.sockets[0].push(toolComplete); host.sockets[0].push(complete)
    try await eventually { publications.last?.access != live.access && publications.last?.snapshot.messages.count == 2 }
    let refreshed = try #require(publications.last?.snapshot.messages.first { $0.role == .tool })
    #expect(refreshed.id == "stored-1:row:5")
    #expect(refreshed.workDetailsID == (liveTool.workDetailsID ?? liveTool.id))
    #expect(refreshed.hasStableIdentity(storedID: "stored-1"))
    #expect(refreshed.transientID == nil)
    #expect(refreshed.toolName == "terminal")
    #expect(refreshed.text == tool["content"].text)
}
