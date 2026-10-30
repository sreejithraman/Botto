import Foundation
import Testing
@testable import BottoCore

@MainActor @Test func explicitStoredOpeningKeepsRootTipAndRevokesOldAttachment() async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let profile = try ExactID(host.bot.id)
    let a = try await service.openChat(.canonical(profile: profile, expectedRoot: nil))
    let identity = try SessionIdentity(profile: profile, root: ExactID("root-B"), stored: ExactID("tip-B"), aliases: [ExactID("root-B"), ExactID("tip-B")])
    host.snapshot["session_id"] = .string("runtime-B")
    host.snapshot["stored_session_id"] = .string("tip-B")
    host.snapshot["subscription_id"] = .string("subscription-B")
    host.storedRows = [.object(["id": .string("tip-B"), "_lineage_root_id": .string("root-B"),
        "_lineage_ids": .array([.string("root-B"), .string("tip-B")])])]
    let b = try await service.openChat(.stored(identity))
    #expect(b.identity.root.text == "root-B")
    #expect(b.snapshot.id == "runtime-B")
    #expect(b.snapshot.storedID == "tip-B")
    await #expect(throws: HermesServiceError.staleConversation) {
        _ = try await service.send(text: "stale", attachments: [], access: a.access, operationID: UUID())
    }
    let receipt = try await service.stop(access: b.access, operationID: UUID())
    #expect(receipt.source == identity)
    let frames = host.sockets[0].sent
    #expect(frames.contains { $0["method"].text == "session.detach" && $0["params"]["subscription_id"].text == "subscription-1" })
    #expect(!frames.contains { ["session.close", "prompt.submit"].contains($0["method"].text ?? "") })
}

@MainActor @Test func directoryUsesFixedOffsetsDeduplicatesPinsAndCanonicalAliasesWithoutRepeatingFullReads() async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    let original = host.transport.handler
    var offsets: [Int] = []
    host.transport.handler = { request in
        guard isFullDirectoryRead(request) else { return try original?(request) ?? .object([:]) }
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.contains { $0.name == "profile" && $0.value == host.bot.id })
        #expect(query.contains { $0.name == "min_messages" && $0.value == "0" })
        let offset = Int(query.first { $0.name == "offset" }!.value!)!
        offsets.append(offset)
        var rows = (offset..<min(offset + 100, 201)).map { index -> HermesJSON in
            if index == 0 {
                return .object(["id": .string("canonical-tip"), "_lineage_root_id": .string(host.root),
                    "_lineage_ids": .array([.string(host.root), .string("canonical-tip")])])
            }
            return .object(["id": .string("ordinary-\(index)"), "title": .string("Chat \(index)")])
        }
        rows.append(.object(["id": .string("pinned"), "pinned": .bool(true)]))
        rows.append(.object(["id": .string("archived-pin"), "pinned": .bool(true), "archived": .bool(true)]))
        return .object(["sessions": .array(rows), "total": .number(201), "limit": .number(100), "offset": .number(Double(offset))])
    }
    _ = try await service.connect(configuration: host.configuration)
    let directory = try await service.conversations(profile: ExactID(host.bot.id))
    #expect(directory.isComplete)
    #expect(offsets == [0, 100, 200])
    #expect(directory.summaries.count == 202)
    #expect(directory.summaries.first?.isCanonical == true)
    #expect(directory.summaries.first?.identity.root.text == host.root)
    #expect(directory.summaries.first?.identity.stored.text == "canonical-tip")
    #expect(directory.summaries.filter { $0.identity.root.text == "pinned" }.count == 1)
    _ = try await service.bots(); _ = try await service.bots()
    #expect(offsets == [0, 100, 200])
}

@MainActor @Test(arguments: [false, true]) func freshEmptySidecarHistory404RequiresServiceProvenance(forged: Bool) async throws {
    let host = try HermesTestHost(authority: false), service = host.service()
    defer { service.disconnect() }
    host.snapshot["message_count"] = .number(0)
    host.snapshot["running"] = .bool(false)
    host.snapshot["messages"] = .array([])
    host.snapshot["info"]["profile_name"] = .string(host.bot.id)
    host.methodOverride = { frame, socket in
        if frame["method"].text == "session.create" { return host.snapshot }
        return host.defaultReply(frame, socket: socket)
    }
    let original = host.transport.handler
    var missing = true
    host.transport.handler = { request in
        if request.url?.path.hasSuffix("/messages") == true, missing { throw HermesServiceError.rejected(404) }
        return try original?(request) ?? .object([:])
    }
    _ = try await service.connect(configuration: host.configuration)
    let identity: SessionIdentity
    if forged {
        identity = try SessionIdentity(profile: ExactID(host.bot.id), root: ExactID(host.root), stored: ExactID(host.root), aliases: [ExactID(host.root)])
        await #expect(throws: HermesServiceError.rejected(404)) { try await service.openChat(.stored(identity)) }
        missing = false
    } else {
        let operation = UUID()
        let created = try await service.createConversation(profile: ExactID(host.bot.id), operationID: operation)
        #expect(created.operationID == operation)
        identity = created.summary.identity
        #expect(created.summary.persistence == .liveOnly)
        let create = try #require(host.sockets[0].sent.first { $0["method"].text == "session.create" })
        #expect(create["params"]["title"] == .null)
        #expect(create["params"]["hidden"] == .null)
        #expect(create["params"]["close_on_disconnect"].flag == false)
    }
    let opened = try await service.openChat(.stored(identity))
    #expect(opened.snapshot.messages.isEmpty)
    let receipt = try await service.send(text: "first actual message", attachments: [], access: opened.access, operationID: UUID())
    #expect(receipt.source == identity)
    #expect(!host.sockets[0].sent.contains { ["session.close", "session.interrupt"].contains($0["method"].text ?? "") })
}

@MainActor @Test func catalogKeepsByteDistinctUnicodeIdentitiesAndReportsPartialFailure() async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    let original = host.transport.handler
    var failing = false
    host.transport.handler = { request in
        guard request.url?.path == "/api/sessions" else { return try original?(request) ?? .object([:]) }
        if failing { throw HermesServiceError.rejected(503) }
        return .object(["sessions": .array([.object(["id": .string("é")]), .object(["id": .string("e\u{301}")])]),
            "total": .number(2), "offset": .number(0), "limit": .number(100)])
    }
    _ = try await service.connect(configuration: host.configuration)
    let directory = try await service.conversations(profile: ExactID(host.bot.id))
    #expect(directory.summaries.count == 3)
    #expect(Set(directory.summaries.map(\.identity.root)).count == 3)
    failing = true
    let partial = try await service.conversations(profile: ExactID(host.bot.id))
    #expect(!partial.isComplete)
    #expect(partial.warning != nil)
    #expect(Set(partial.summaries.map(\.identity.root)) == Set(directory.summaries.map(\.identity.root)))
}

@MainActor @Test func sidecarAmbiguousActivityUsesAllKnownProfileAliases() async throws {
    let host = try HermesTestHost(authority: false), service = host.service()
    defer { service.disconnect() }
    let original = host.transport.handler
    host.profiles = .object(["profiles": .array([
        .object(["name": .string(host.bot.id), "canonical_session": .object(["id": .string(host.root)])]),
        .object(["name": .string("other"), "canonical_session": .object(["id": .string("shared-alias")])])])])
    host.transport.handler = { request in
        if request.url?.path == "/api/sessions" {
            return .object(["sessions": .array([.object(["id": .string("shared-alias")])]), "total": .number(1), "offset": .number(0), "limit": .number(100)])
        }
        return try original?(request) ?? .object([:])
    }
    host.methodOverride = { frame, socket in
        if frame["method"].text == "session.active_list" {
            return .object(["sessions": .array([.object(["id": .string("unseen-runtime"), "session_key": .string("shared-alias"), "status": .string("waiting")])])])
        }
        return host.defaultReply(frame, socket: socket)
    }
    _ = try await service.connect(configuration: host.configuration)
    _ = try await service.bots() // Learns the other profile's alias without fetching its full catalog.
    let directory = try await service.conversations(profile: ExactID(host.bot.id))
    let ordinary = try #require(directory.summaries.first { !$0.isCanonical })
    if case .unknown = directory.activity[ordinary.identity] {} else { Issue.record("A cross-profile collision cannot become known activity") }
    #expect(directory.warning != nil)
    // An exact attachment supplies positive profile/runtime ownership despite that alias collision.
    host.snapshot["session_id"] = .string("unseen-runtime")
    host.snapshot["session_key"] = .string("shared-alias")
    host.snapshot["messages"] = .array([])
    host.transport.handler = { request in
        if request.url?.path == "/api/sessions/shared-alias/messages" {
            return .object(["session_id": .string("shared-alias"), "profile": .string(host.bot.id), "messages": .array([])])
        }
        return try original?(request) ?? .object([:])
    }
    _ = try await service.openChat(.stored(ordinary.identity))
    host.transport.handler = { request in
        if request.url?.path == "/api/sessions" {
            return .object(["sessions": .array([.object(["id": .string("shared-alias")])]), "total": .number(1), "offset": .number(0), "limit": .number(100)])
        }
        return try original?(request) ?? .object([:])
    }
    let verified = try await service.conversations(profile: ExactID(host.bot.id))
    if case .known(.waiting, _) = verified.activity[ordinary.identity] {} else { Issue.record("Verified runtime ownership should join its waiting row") }
}

@MainActor @Test(arguments: ["nonempty", "running", "different-runtime", "previously-submitted"])
func createdSidecarHistory404RequiresFreshMatchingEmptyLiveProof(_ condition: String) async throws {
    let host = try HermesTestHost(authority: false), service = host.service()
    defer { service.disconnect() }
    host.snapshot["message_count"] = .number(0)
    host.snapshot["running"] = .bool(false)
    host.snapshot["messages"] = .array([])
    let emptySnapshot = host.snapshot
    host.methodOverride = { frame, socket in
        if frame["method"].text == "session.create" { return emptySnapshot }
        return host.defaultReply(frame, socket: socket)
    }
    let original = host.transport.handler
    var missing = false
    host.transport.handler = { request in
        if missing, request.url?.path.hasSuffix("/messages") == true { throw HermesServiceError.rejected(404) }
        return try original?(request) ?? .object([:])
    }
    _ = try await service.connect(configuration: host.configuration)
    let created = try await service.createConversation(profile: ExactID(host.bot.id), operationID: UUID())
    switch condition {
    case "nonempty": host.snapshot["message_count"] = .number(1)
    case "running": host.snapshot["running"] = .bool(true)
    case "different-runtime": host.snapshot["session_id"] = .string("different-runtime")
    default:
        let opened = try await service.openChat(.stored(created.summary.identity))
        _ = try await service.send(text: "actually sent", attachments: [], access: opened.access, operationID: UUID())
    }
    missing = true
    await #expect(throws: HermesServiceError.rejected(404)) { try await service.openChat(.stored(created.summary.identity)) }
    missing = false; host.snapshot = emptySnapshot
    let current = try await service.openChat(.stored(created.summary.identity))
    _ = try await service.send(text: "verified current", attachments: [], access: current.access, operationID: UUID())
}

@MainActor @Test func locallyRetainedCreationNeverOverwritesFreshStoredSummary() async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    let original = host.transport.handler
    host.methodOverride = { frame, socket in
        if frame["method"].text == "session.create" {
            return .object(["session_id": .string("created"), "stored_session_id": .string("created")])
        }
        return host.defaultReply(frame, socket: socket)
    }
    host.transport.handler = { request in
        if request.url?.path == "/api/sessions" {
            return .object(["sessions": .array([.object(["id": .string("created"), "title": .string("Fresh title"),
                "preview": .string("Fresh transcript"), "message_count": .number(6)])]), "total": .number(1), "offset": .number(0), "limit": .number(100)])
        }
        return try original?(request) ?? .object([:])
    }
    _ = try await service.connect(configuration: host.configuration)
    let created = try await service.createConversation(profile: ExactID(host.bot.id), operationID: UUID())
    let directory = try await service.conversations(profile: ExactID(host.bot.id))
    let summary = try #require(directory.summaries.first { $0.identity.root == created.summary.identity.root })
    #expect(summary.title == "Fresh title")
    #expect(summary.preview == "Fresh transcript")
    #expect(summary.messageCount == 6)
}

@MainActor @Test func concurrentDirectoryReadsCoalesceAndRetiredConnectionCannotPublishTheirCatalog() async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    let original = host.transport.handler
    var gate: CheckedContinuation<HermesJSON, Error>?
    var reads = 0
    host.transport.asyncHandler = { request in
        if request.url?.path == "/api/sessions" {
            reads += 1
            return try await withCheckedThrowingContinuation { gate = $0 }
        }
        return try original?(request) ?? .object([:])
    }
    let configuration = host.configuration
    _ = try await service.connect(configuration: configuration)
    let profile = try ExactID(host.bot.id)
    let first = Task { try await service.conversations(profile: profile) }
    try await eventually { gate != nil }
    let joined = Task { try await service.conversations(profile: profile) }
    await Task.yield()
    #expect(reads == 1)
    service.disconnect()
    let reply: HermesJSON = .object(["sessions": .array([.object(["id": .string("retired-row")])]),
        "total": .number(1), "offset": .number(0), "limit": .number(100)])
    gate?.resume(returning: reply); gate = nil
    await #expect(throws: HermesServiceError.disconnected) { try await first.value }
    await #expect(throws: HermesServiceError.disconnected) { try await joined.value }
    host.transport.asyncHandler = nil
    host.transport.handler = { request in
        if request.url?.path == "/api/sessions" {
            return .object(["sessions": .array([.object(["id": .string("current-row")])]), "total": .number(1), "offset": .number(0), "limit": .number(100)])
        }
        return try original?(request) ?? .object([:])
    }
    _ = try await service.connect(configuration: configuration)
    let current = try await service.conversations(profile: profile)
    #expect(current.isComplete)
    #expect(current.summaries.contains { $0.identity.root.text == "current-row" })
    #expect(!current.summaries.contains { $0.identity.root.text == "retired-row" })
}
