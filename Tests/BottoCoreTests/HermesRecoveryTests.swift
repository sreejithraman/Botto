import Foundation
import Testing
@testable import BottoCore

@MainActor @Test(arguments: [true, false], [true, false])
func interruptedDirectoryDoesNotPoisonAutomaticRecovery(authority: Bool, finishOldFirst: Bool) async throws {
    let host = try HermesTestHost(authority: authority), service = host.service()
    var held: CheckedContinuation<HermesJSON, Error>?
    defer { held?.resume(throwing: HermesServiceError.disconnected); service.disconnect() }
    let original = host.transport.handler
    var reads = 0
    host.transport.asyncHandler = { request in
        if request.url?.path == "/api/sessions" {
            reads += 1
            if reads == 1 { return try await withCheckedThrowingContinuation { held = $0 } }
        }
        return try original?(request) ?? .object([:])
    }
    _ = try await service.connect(configuration: host.configuration)
    let profile = try ExactID(host.bot.id)
    let old = Task { try await service.conversations(profile: profile) }
    try await eventually { held != nil }
    var recovered = false
    service.onEvent = { if case .connected = $0 { recovered = true } }
    host.sockets[0].close()
    try await eventually { recovered }
    host.storedRows = [.object(["id": .string("current-chat")])]
    let empty: HermesJSON = .object(["sessions": .array([]), "total": .number(0),
        "offset": .number(0), "limit": .number(100)])
    if finishOldFirst {
        held?.resume(returning: empty); held = nil
        await #expect(throws: HermesServiceError.disconnected) { try await old.value }
    }
    let current = Task { try await service.conversations(profile: profile) }
    await Task.yield()
    if !finishOldFirst {
        held?.resume(returning: empty); held = nil
        await #expect(throws: HermesServiceError.disconnected) { try await old.value }
    }
    let directory = try await current.value
    #expect(directory.isComplete)
    #expect(directory.summaries.contains { $0.identity.root.text == "current-chat" })
    #expect(reads == 2)
}

@MainActor @Test func terminalRecoveryAttachFailureClosesGatewayAndExplicitConnectStartsNewHandshake() async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    let configuration = host.configuration
    var disconnections = 0
    service.onEvent = { if case .disconnected = $0 { disconnections += 1 } }
    _ = try await service.connect(configuration: configuration)
    _ = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    host.snapshot["stored_session_id"] = .string("wrong-canonical-chat")
    host.sockets[0].close()
    try await eventually { disconnections >= 2 }

    #expect(host.sockets.count == 2)
    #expect(host.sockets[1].closed)
    await #expect(throws: HermesServiceError.disconnected) { _ = try await service.bots() }

    host.snapshot["stored_session_id"] = .string(host.root)
    _ = try await service.connect(configuration: configuration)
    #expect(host.sockets.count == 3)
    #expect(host.transport.requests.filter { $0.url?.path == "/api/auth/ws-ticket" }.count == 3)
    let chat = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    _ = try await service.send(text: "New handshake works", attachments: [], access: chat.access, operationID: UUID())
    #expect(host.sockets.last?.sent.contains { $0["method"].text == "prompt.submit" } == true)
}
