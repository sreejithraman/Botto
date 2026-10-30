import Foundation
import Testing
@testable import BottoCore

@MainActor @Test func compactSidecarResumeReadsRawImageHistoryAfterReplayAndKeepsHeldEventsFenced() async throws {
    let host = try HermesTestHost(authority: false), service = host.service()
    defer { service.disconnect() }
    let dataURL = "data:image/png;base64," + attachmentPNG.base64EncodedString()
    // Source-backed ca678285 wire shapes: resume's _history_to_messages flattens
    // content, while REST /messages preserves nested image_url.url parts.
    let imageRow: HermesJSON = .object(["id": .number(7), "role": .string("user"), "content": .array([
        .object(["type": .string("image_url"), "image_url": .object(["url": .string(dataURL)])])])])
    host.snapshot["messages_omitted"] = .bool(false)
    host.snapshot["messages"] = .array([.object(["row_id": .number(7), "role": .string("user"), "text": .string("\n" + dataURL)])])
    host.snapshot["running"] = .bool(true)
    host.snapshot["inflight"] = .object(["assistant": .string("Hello")])
    host.snapshot["open_requests"] = .array([.object(["id": .string("stale-approval"), "method": .string("approval"),
        "params": .object(["session_id": .string(host.runtime), "approval_id": .string("queue-1"), "command": .string("echo hello")])])])
    host.replay["events"] = .array([host.event("message.delta", seq: 1, payload: ["text": .string("He")])["params"]])
    host.replay["latest_seq"] = .number(1)
    let original = host.transport.handler
    var historyReads = 0
    host.transport.asyncHandler = { request in
        guard request.url?.path == "/api/sessions/\(host.root)/messages" else { return try original?(request) ?? .object([:]) }
        historyReads += 1
        let socket = try #require(host.sockets.last)
        #expect(socket.sent.contains { $0["method"].text == "session.events.since" })
        #expect(socket.sent.filter { $0["method"].text == "session.resume" }.count == 2)
        socket.push(host.event("message.delta", seq: 2, payload: ["text": .string("llo")]))
        socket.push(host.event("request.cancel", seq: 3, payload: ["id": .string("stale-approval")]))
        try await eventually { socket.waiter != nil && socket.queue.isEmpty }
        return .object(["session_id": .string(host.root), "profile": .string(host.bot.id), "messages": .array([imageRow])])
    }
    var latest: Conversation?
    var recovered = false
    service.onEvent = {
        if case .conversation(let publication) = $0 { let chat = publication.snapshot; latest = chat }
        if case .connected = $0 { recovered = true }
    }
    _ = try await service.connect(configuration: host.configuration)
    let chat = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    #expect(chat.snapshot.messages.first?.text.isEmpty == true)
    #expect(chat.snapshot.messages.first?.attachments.first?.mimeType == "image/png")
    #expect(chat.snapshot.messages.filter { $0.role == .assistant }.map(\.text) == ["Hello"])
    #expect(chat.snapshot.pendingRequests.isEmpty)
    #expect(historyReads == 1)

    host.sockets[0].close()
    try await eventually { recovered }
    #expect(host.sockets.count == 2)
    #expect(historyReads == 2)
    #expect(latest?.messages.first?.attachments.first?.mimeType == "image/png")
    #expect(latest?.messages.filter { $0.role == .assistant }.map(\.text) == ["Hello"])
    #expect(latest?.pendingRequests.isEmpty == true)
}
