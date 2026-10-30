import Foundation
import Testing
@testable import BottoCore

@MainActor @Test func storedTargetCannotRelabelIndependentBAsRootAThroughCallerAliases() async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    let original = host.transport.handler
    host.transport.handler = { request in
        if request.url?.path == "/api/sessions" {
            return .object(["sessions": .array([.object(["id": .string("A")]), .object(["id": .string("B")])]),
                "total": .number(2), "limit": .number(100), "offset": .number(0)])
        }
        return try original?(request) ?? .object([:])
    }
    host.snapshot["session_id"] = .string("runtime-B")
    host.snapshot["stored_session_id"] = .string("B")
    _ = try await service.connect(configuration: host.configuration)
    let profile = try ExactID(host.bot.id), a = try ExactID("A"), b = try ExactID("B")
    let forged = SessionIdentity(profile: profile, root: a, stored: b, aliases: [a, b])
    do {
        let opened = try await service.openChat(.stored(forged))
        let receipt = try await service.send(text: "must never reach B under A", attachments: [], access: opened.access, operationID: UUID())
        Issue.record("Caller aliases relabeled B: wire runtime=\(opened.snapshot.id), receipt root=\(receipt.source.root.text)")
    } catch HermesServiceError.wrongConversation {}
    #expect(!host.sockets[0].sent.contains { $0["method"].text == "prompt.submit" })
    let current = try await service.openChat(.stored(SessionIdentity(profile: profile, root: b, stored: b, aliases: [b])))
    let receipt = try await service.send(text: "proved B", attachments: [], access: current.access, operationID: UUID())
    #expect(receipt.source.root == b)
    #expect(host.sockets[0].sent.filter { $0["method"].text == "prompt.submit" }.count == 1)
    #expect(host.sockets[0].sent.last?["params"]["session_id"].text == "runtime-B")
}

@MainActor @Test func coldStoredCompressionUsesServerProofAndNeverAdmitsExtraCallerAliases() async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    host.snapshot["session_id"] = .string("runtime-tip")
    host.snapshot["stored_session_id"] = .string("tip")
    host.storedRows = [.object(["id": .string("tip"), "_lineage_root_id": .string("root"),
        "_lineage_ids": .array([.string("root"), .string("old-tip"), .string("tip")])])]
    _ = try await service.connect(configuration: host.configuration)
    let profile = try ExactID(host.bot.id), root = try ExactID("root"), tip = try ExactID("tip")
    let cached = SessionIdentity(profile: profile, root: root, stored: tip, aliases: [root, tip])
    let current = try await service.openChat(.stored(cached))
    #expect(current.identity.root == root)
    #expect(current.identity.aliases.contains(try ExactID("old-tip")))
    let receipt = try await service.send(text: "cold proved chat", attachments: [], access: current.access, operationID: UUID())
    #expect(receipt.source == current.identity)
    let before = host.transport.requests.filter(isFullDirectoryRead).count
    _ = try await service.bots(); _ = try await service.bots()
    #expect(host.transport.requests.filter(isFullDirectoryRead).count == before)
    let forged = try SessionIdentity(profile: profile, root: root, stored: tip, aliases: [root, tip, ExactID("unrelated")])
    await #expect(throws: HermesServiceError.wrongConversation) { try await service.openChat(.stored(forged)) }
    #expect(host.sockets[0].sent.filter { $0["method"].text == "prompt.submit" }.count == 1)
    let again = try await service.openChat(.stored(cached))
    _ = try await service.send(text: "current proved owner", attachments: [], access: again.access, operationID: UUID())
    #expect(host.sockets[0].sent.filter { $0["method"].text == "prompt.submit" }.count == 2)
}
