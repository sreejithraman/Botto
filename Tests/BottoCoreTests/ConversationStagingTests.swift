import Foundation
import Testing
@testable import BottoCore

@MainActor @Test func stagedFilesKeepExactCapabilityAcrossNavigationButRetireOnConnection() async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let first = try await service.openChat(.canonical(profile: ExactID(host.bot.id), expectedRoot: nil))
    let file = try await service.upload(data: Data("one".utf8), filename: "note.txt", mimeType: "text/plain", access: first.access)
    let second = try await service.upload(data: Data("two".utf8), filename: "note.txt", mimeType: "text/plain", access: first.access)
    #expect(file.path == second.path)
    #expect(file.id != second.id)
    let copied = ChatAttachment(name: file.name, path: file.path, mimeType: file.mimeType, byteCount: file.byteCount)
    await #expect(throws: HermesServiceError.invalidAttachment) {
        _ = try await service.send(text: "copied", attachments: [copied], access: first.access, operationID: UUID())
    }
    let bSnapshot = host.snapshot
    host.snapshot["session_id"] = .string("B")
    host.snapshot["stored_session_id"] = .string("B")
    let bIdentity = try SessionIdentity(profile: ExactID(host.bot.id), root: ExactID("B"), stored: ExactID("B"), aliases: [ExactID("B")])
    host.storedRows = [.object(["id": .string("B")])]
    let b = try await service.openChat(.stored(bIdentity))
    await #expect(throws: HermesServiceError.invalidAttachment) {
        _ = try await service.send(text: "wrong owner", attachments: [file], access: b.access, operationID: UUID())
    }
    host.snapshot = bSnapshot
    let again = try await service.openChat(.stored(first.identity))
    await #expect(throws: HermesServiceError.staleConversation) {
        _ = try await service.send(text: "captured old A", attachments: [file], access: first.access, operationID: UUID())
    }
    let receipt = try await service.send(text: "current owner", attachments: [file], access: again.access, operationID: UUID())
    #expect(receipt.source == first.identity)
    service.disconnect()
    _ = try await service.connect(configuration: host.configuration)
    let reconnected = try await service.openChat(.stored(first.identity))
    await #expect(throws: HermesServiceError.invalidAttachment) {
        _ = try await service.send(text: "previous nonce", attachments: [second], access: reconnected.access, operationID: UUID())
    }
    let fresh = try await service.upload(data: Data("three".utf8), filename: "note.txt", mimeType: "text/plain", access: reconnected.access)
    #expect(fresh.id != second.id)
    _ = try await service.send(text: "fresh stage", attachments: [fresh], access: reconnected.access, operationID: UUID())
}

@MainActor @Test func lateAdmissionCleansOnlyItsSubmittedStageEvenWhenServerPathRepeats() async throws {
    let host = try HermesTestHost(), service = host.service(requestTimeout: .seconds(5))
    defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let a = try await service.openChat(.canonical(profile: ExactID(host.bot.id), expectedRoot: nil))
    let old = try await service.upload(data: Data("old".utf8), filename: "same.txt", mimeType: "text/plain", access: a.access)
    var pending: HermesJSON?
    host.methodOverride = { frame, socket in
        if frame["method"].text == "prompt.submit" { pending = frame; return nil }
        return host.defaultReply(frame, socket: socket)
    }
    let write = Task { try await service.send(text: "old", attachments: [old], access: a.access, operationID: UUID()) }
    try await eventually { pending != nil }
    let current = try await service.openChat(.stored(a.identity))
    let replacement = try await service.upload(data: Data("new".utf8), filename: "same.txt", mimeType: "text/plain", access: current.access)
    #expect(replacement.path == old.path)
    #expect(replacement.id != old.id)
    let socket = host.sockets[0]
    socket.push(.object(["id": pending!["id"], "result": host.defaultReply(pending!, socket: socket)!]))
    _ = try await write.value
    host.methodOverride = nil
    _ = try await service.send(text: "replacement", attachments: [replacement], access: current.access, operationID: UUID())
}
