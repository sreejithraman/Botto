import Foundation
import Testing
@testable import BottoCore

@MainActor @Test func replayRejectsCanonicallyEquivalentButByteDifferentRuntime() async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    host.snapshot["session_id"] = .string("é")
    host.replay["latest_seq"] = .number(1)
    host.replay["events"] = .array([host.event("message.delta", seq: 1, payload: ["text": .string("foreign")], session: "e\u{301}")["params"]])
    _ = try await service.connect(configuration: host.configuration)
    await #expect(throws: HermesServiceError.wrongConversation) {
        try await service.openChat(.canonical(profile: ExactID(host.bot.id), expectedRoot: nil))
    }
    host.replay["events"] = .array([host.event("message.delta", seq: 1, payload: ["text": .string("owned")], session: "é")["params"]])
    let current = try await service.openChat(.canonical(profile: ExactID(host.bot.id), expectedRoot: nil))
    #expect(current.snapshot.messages.contains { $0.text == "owned" })
    _ = try await service.send(text: "current owner", attachments: [], access: current.access, operationID: UUID())
}

@MainActor @Test func repeatedRequestEnvelopeRotatesAccessEvenWhenItsPayloadRepeats() async throws {
    let host = try HermesTestHost(authority: false), service = host.service()
    defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let opened = try await service.openChat(.canonical(profile: ExactID(host.bot.id), expectedRoot: nil))
    var current = opened
    service.onEvent = { if case .conversation(let value) = $0 { current = value } }
    let frame: HermesJSON = .object(["id": .string("same-envelope"), "method": .string("approval"), "params": .object([
        "session_id": .string(host.runtime), "request_id": .string("same-queue"), "command": .string("echo harmless")])])
    host.sockets[0].push(frame)
    try await eventually { !current.snapshot.pendingRequests.isEmpty }
    let first = current
    let request = try #require(first.snapshot.pendingRequests.first)
    host.sockets[0].push(frame)
    try await eventually { current.access != first.access }
    await #expect(throws: HermesServiceError.staleConversation) {
        _ = try await service.respond(to: request, response: .choice("once"), access: first.access, operationID: UUID())
    }
    let receipt = try await service.respond(to: request, response: .choice("once"), access: current.access, operationID: UUID())
    #expect(receipt.source == opened.identity)
    #expect(host.sockets[0].sent.filter { $0["method"].text == "approval.respond" }.count == 1)
}

@MainActor @Test func storedResumeAcceptsOnlyServerVerifiedCompressionAlias() async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    host.snapshot["session_id"] = .string("new-runtime")
    host.snapshot["stored_session_id"] = .string("new-tip")
    let original = host.transport.handler
    var verified = false
    host.transport.handler = { request in
        if request.url?.path == "/api/sessions" {
            let row: HermesJSON = verified ? .object(["id": .string("new-tip"), "_lineage_root_id": .string("old-root"),
                "_lineage_ids": .array([.string("old-root"), .string("old-tip"), .string("new-tip")])]) : .object(["id": .string("unrelated")])
            return .object(["sessions": .array([row]), "total": .number(1), "offset": .number(0), "limit": .number(100)])
        }
        return try original?(request) ?? .object([:])
    }
    _ = try await service.connect(configuration: host.configuration)
    let prior = try SessionIdentity(profile: ExactID(host.bot.id), root: ExactID("old-root"), stored: ExactID("old-tip"), aliases: [ExactID("old-root"), ExactID("old-tip")])
    await #expect(throws: HermesServiceError.wrongConversation) { try await service.openChat(.stored(prior)) }
    verified = true
    let current = try await service.openChat(.stored(prior))
    #expect(current.identity.root == prior.root)
    #expect(current.identity.stored.text == "new-tip")
    #expect(current.identity.aliases.contains(try ExactID("old-tip")))
    _ = try await service.send(text: "current proven lineage", attachments: [], access: current.access, operationID: UUID())
}

@MainActor @Test func repeatedRequestIDsAcrossAtoBtoARequireCurrentAttachmentAndExactPayload() async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    host.snapshot["prompts"] = .array([.object(["kind": .string("approval"), "prompt_id": .string("repeat"),
        "execution_generation": .number(7), "command": .string("é"), "choices": .array([.string("once"), .string("deny")])])])
    let aSnapshot = host.snapshot
    _ = try await service.connect(configuration: host.configuration)
    let a = try await service.openChat(.canonical(profile: ExactID(host.bot.id), expectedRoot: nil))
    let aRequest = try #require(a.snapshot.pendingRequests.first)
    host.snapshot["session_id"] = .string("runtime-B"); host.snapshot["stored_session_id"] = .string("stored-B")
    let identity = try SessionIdentity(profile: ExactID(host.bot.id), root: ExactID("stored-B"), stored: ExactID("stored-B"), aliases: [ExactID("stored-B")])
    host.storedRows = [.object(["id": .string("stored-B")])]
    let b = try await service.openChat(.stored(identity))
    await #expect(throws: HermesServiceError.staleConversation) {
        _ = try await service.respond(to: aRequest, response: .choice("once"), access: a.access, operationID: UUID())
    }
    _ = try await service.respond(to: b.snapshot.pendingRequests[0], response: .choice("once"), access: b.access, operationID: UUID())
    host.snapshot = aSnapshot
    let again = try await service.openChat(.stored(a.identity))
    await #expect(throws: HermesServiceError.staleConversation) {
        _ = try await service.respond(to: aRequest, response: .choice("once"), access: a.access, operationID: UUID())
    }
    var forged = aRequest; forged.detail = "e\u{301}"
    await #expect(throws: HermesServiceError.staleConversation) {
        _ = try await service.respond(to: forged, response: .choice("once"), access: again.access, operationID: UUID())
    }
    _ = try await service.respond(to: aRequest, response: .choice("once"), access: again.access, operationID: UUID())
    #expect(host.sockets[0].sent.filter { $0["method"].text == "approval.respond" }.count == 2)
}
