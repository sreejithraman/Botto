import Foundation
import Testing
@testable import BottoCore

@MainActor @Test func capturedUnpersistedSidecarResumeWithoutRunningRequiresExactLiveEmptyProof() async throws {
    let fixture = try emptyDraftFixture()
    let host = try HermesTestHost(authority: false), service = host.service()
    defer { service.disconnect() }
    host.snapshot = fixture
    let stored = try #require(fixture["stored_session_id"].nonempty)
    let profile = try #require(fixture["info"]["profile_name"].nonempty)
    var activated = false
    host.methodOverride = { frame, socket in
        switch frame["method"].text {
        case "session.create": return fixture
        case "session.activate":
            #expect(frame["params"]["profile"].text == profile)
            #expect(frame["params"]["session_id"].text == fixture["session_id"].text)
            #expect(frame["params"]["omit_messages"].flag == true)
            activated = true
            // _live_session_payload uses session_key and can omit profile_name in lazy info.
            let proof: HermesJSON = .object(["session_id": fixture["session_id"], "session_key": .string(stored),
                "info": .object([:]), "running": .bool(false), "message_count": .number(0), "messages": .array([]),
                "messages_omitted": .bool(true), "status": .string("starting")])
            return proof
        default: return host.defaultReply(frame, socket: socket)
        }
    }
    let original = host.transport.handler
    host.transport.handler = { request in
        if request.url?.path == "/api/sessions/\(stored)/messages" { throw HermesServiceError.rejected(404) }
        return try original?(request) ?? .object([:])
    }
    _ = try await service.connect(configuration: host.configuration)
    let created = try await service.createConversation(profile: ExactID(profile), operationID: UUID())
    let opened = try await service.openChat(.stored(created.summary.identity))
    #expect(activated)
    #expect(opened.snapshot.messages.isEmpty)
    #expect(!opened.snapshot.isWorking)
    #expect(opened.identity == created.summary.identity)
    let receipt = try await service.send(text: "first real prompt", attachments: [], access: opened.access, operationID: UUID())
    #expect(receipt.source == created.summary.identity)
    #expect(host.sockets[0].sent.filter { $0["method"].text == "session.create" }.count == 1)
    #expect(!host.sockets[0].sent.contains { ["session.close", "session.interrupt"].contains($0["method"].text ?? "") })
}

private func emptyDraftFixture() throws -> HermesJSON {
    let url = Bundle.module.url(forResource: "live-unpersisted-resume", withExtension: "json", subdirectory: "Fixtures/SidecarEmptyDraft")!
    return try HermesJSON.decode(Data(contentsOf: url))
}

@MainActor @Test(arguments: ["unissued", "nonempty", "working", "inflight", "queued", "waiting", "runtime", "stored", "profile", "unknown-running", "snapshot-nonempty", "snapshot-inflight"])
func capturedEmptyDraftStillRejectsUnprovedOrActiveLiveState(_ condition: String) async throws {
    let captured = try emptyDraftFixture()
    let host = try HermesTestHost(authority: false), service = host.service()
    defer { service.disconnect() }
    host.snapshot = captured
    let profile = try ExactID(#require(captured["info"]["profile_name"].nonempty))
    let stored = try ExactID(#require(captured["stored_session_id"].nonempty))
    var hostile = true
    host.methodOverride = { frame, socket in
        if frame["method"].text == "session.create" { return captured }
        if frame["method"].text == "session.activate" {
            var proof = captured
            proof["running"] = .bool(false); proof["messages_omitted"] = .bool(true); proof["status"] = .string("idle")
            if hostile {
                switch condition {
                case "nonempty": proof["message_count"] = .number(1)
                case "working": proof["running"] = .bool(true)
                case "inflight": proof["inflight"] = .object(["assistant": .string("working")])
                case "queued": proof["queued"] = .object(["user": .string("queued")])
                case "waiting": proof["status"] = .string("waiting")
                case "runtime": proof["session_id"] = .string("foreign-runtime")
                case "stored": proof["stored_session_id"] = .string("foreign-store")
                case "profile": proof["info"]["profile_name"] = .string("foreign-profile")
                case "unknown-running": proof["running"] = .null
                default: break
                }
            }
            return proof
        }
        return host.defaultReply(frame, socket: socket)
    }
    let original = host.transport.handler
    host.transport.handler = { request in
        if request.url?.path == "/api/sessions/\(stored.text)/messages" { throw HermesServiceError.rejected(404) }
        return try original?(request) ?? .object([:])
    }
    _ = try await service.connect(configuration: host.configuration)
    let identity: SessionIdentity
    if condition == "unissued" {
        host.storedRows = [.object(["id": .string(stored.text)])]
        identity = SessionIdentity(profile: profile, root: stored, stored: stored, aliases: [stored])
    } else {
        identity = try await service.createConversation(profile: profile, operationID: UUID()).summary.identity
    }
    if condition == "snapshot-nonempty" { host.snapshot["message_count"] = .number(1) }
    if condition == "snapshot-inflight" { host.snapshot["inflight"] = .object(["user": .string("working")]) }
    await #expect(throws: HermesServiceError.rejected(404)) { try await service.openChat(.stored(identity)) }
    hostile = false; host.snapshot = captured
    if condition == "unissued" { _ = try await service.createConversation(profile: profile, operationID: UUID()) }
    let current = try await service.openChat(.stored(identity))
    let receipt = try await service.send(text: "current proved empty owner", attachments: [], access: current.access, operationID: UUID())
    #expect(receipt.source == identity)
}
