import Foundation
import Testing
@testable import BottoCore

@MainActor @Test(arguments: ["send", "stop", "answer"])
func positiveOriginACKSurvivesSelectionAndViewCancellation(_ operation: String) async throws {
    let host = try HermesTestHost(), service = host.service(requestTimeout: .seconds(5))
    defer { service.disconnect() }
    host.snapshot["prompts"] = .array([.object(["kind": .string("approval"), "prompt_id": .string("reused"),
        "execution_generation": .number(7), "choices": .array([.string("once"), .string("deny")])])])
    _ = try await service.connect(configuration: host.configuration)
    let a = try await service.openChat(.canonical(profile: ExactID(host.bot.id), expectedRoot: nil))
    let request = try #require(a.snapshot.pendingRequests.first)
    let method = operation == "send" ? "prompt.submit" : operation == "stop" ? "session.interrupt" : "approval.respond"
    var pending: HermesJSON?, ack: HermesJSON?
    host.methodOverride = { frame, socket in
        if frame["method"].text == method {
            pending = frame; ack = host.defaultReply(frame, socket: socket); return nil
        }
        return host.defaultReply(frame, socket: socket)
    }
    let operationID = UUID()
    let write = Task { () throws -> MutationReceipt in
        switch operation {
        case "send": return try await service.send(text: "only A", attachments: [], access: a.access, operationID: operationID)
        case "stop": return try await service.stop(access: a.access, operationID: operationID)
        default: return try await service.respond(to: request, response: .choice("once"), access: a.access, operationID: operationID)
        }
    }
    try await eventually { pending != nil }
    write.cancel() // A SwiftUI task disappearing must not close the multiplexed socket.
    host.snapshot["session_id"] = .string("runtime-B")
    host.snapshot["stored_session_id"] = .string("stored-B")
    host.snapshot["subscription_id"] = .string("subscription-B")
    host.snapshot["execution_generation"] = .number(22)
    let identity = try SessionIdentity(profile: ExactID(host.bot.id), root: ExactID("root-B"), stored: ExactID("stored-B"), aliases: [ExactID("root-B"), ExactID("stored-B")])
    host.storedRows = [.object(["id": .string("stored-B"), "_lineage_root_id": .string("root-B"),
        "_lineage_ids": .array([.string("root-B"), .string("stored-B")])])]
    let b = try await service.openChat(.stored(identity))
    var latest = b
    service.onEvent = { if case .conversation(let opened) = $0 { latest = opened } }
    let socket = host.sockets[0]
    socket.push(.object(["jsonrpc": .string("2.0"), "id": pending!["id"], "result": ack!]))
    let receipt = try await write.value
    #expect(receipt.operationID == operationID)
    #expect(receipt.source == a.identity)
    #expect(latest.snapshot.id == "runtime-B")
    #expect(latest.snapshot.pendingRequests == b.snapshot.pendingRequests)
    #expect(!socket.closed)
    await #expect(throws: HermesServiceError.staleConversation) {
        _ = try await service.send(text: "duplicate operation", attachments: [], access: b.access, operationID: operationID)
    }
    host.methodOverride = nil
    let current = try await service.send(text: "current B", attachments: [], access: b.access, operationID: UUID())
    #expect(current.source == b.identity)
}

@MainActor @Test func confirmedAdmissionWithJournalWriteFailureReturnsRepairReceipt() async throws {
    let host = try HermesTestHost()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let service = HermesBotService(transportFactory: { host.transport }, journal: HermesSubmissionJournal(directory: root))
    defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let opened = try await service.openChat(.canonical(profile: ExactID(host.bot.id), expectedRoot: nil))
    host.methodOverride = { frame, socket in
        if frame["method"].text == "prompt.submit" {
            // The pre-dispatch identity is durably written. Only the post-ACK write fails.
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("identities.json").path))
            try FileManager.default.removeItem(at: root)
            try Data("occupied".utf8).write(to: root)
        }
        return host.defaultReply(frame, socket: socket)
    }
    let receipt = try await service.send(text: "once", attachments: [], access: opened.access, operationID: UUID())
    #expect(receipt.admissionID == "admission-1")
    if case .needsLocalRepair = receipt.journal {} else { Issue.record("A confirmed ACK must retain its success and report journal repair") }
    #expect(host.sockets[0].sent.filter { $0["method"].text == "prompt.submit" }.count == 1)
}
