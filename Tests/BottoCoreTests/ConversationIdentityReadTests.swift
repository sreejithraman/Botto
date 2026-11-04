import Foundation
import Testing
@testable import BottoCore

@MainActor @Test(arguments: ["authority-snapshot", "authority-rest", "sidecar-rest"])
func exhaustiveSingleResponseChecksRawIdentitiesBeforeCertifyingProjectedRows(path: String) async throws {
    let host = try HermesTestHost(authority: path != "sidecar-rest"), service = host.service()
    defer { service.disconnect() }
    if path == "authority-rest" { host.snapshot["messages_omitted"] = .bool(true) }
    host.snapshot["messages"] = .array([identityReadRow(1, text: "Checked reply"),
        identityReadRow(2, text: "Hidden carrier", kind: "hidden"), identityReadRow(3, text: "Another checked reply")])
    _ = try await service.connect(configuration: host.configuration)
    let identity = try #require(try await service.conversations(profile: ExactID(host.bot.id)).summaries.first).identity
    let opened = try await service.openChat(.stored(identity))
    let proof = try #require(opened.identityRead)
    #expect(opened.readEvidence == nil)
    #expect(proof.matches(identity))
    #expect(proof.messageIDs == Set([Data((host.root + ":row:1").utf8), Data((host.root + ":row:3").utf8)]))
    #expect(opened.snapshot.messages.map(\.text) == ["Checked reply", "Another checked reply"])
}

private func identityReadRow(_ id: Int, text: String, kind: String? = nil) -> HermesJSON {
    var fields: [String: HermesJSON] = ["id": .number(Double(id)), "role": .string("assistant"), "text": .string(text)]
    if let kind { fields["display_kind"] = .string(kind) }
    return .object(fields)
}

@MainActor @Test(arguments: ["authority-snapshot", "authority-rest", "sidecar-rest"], ["hidden-duplicate", "missing-id", "negative-id"])
func ambiguousRawHistoryCannotCertifyAnOtherwiseUniqueVisibleRow(path: String, condition: String) async throws {
    let host = try HermesTestHost(authority: path != "sidecar-rest"), service = host.service()
    defer { service.disconnect() }
    if path == "authority-rest" { host.snapshot["messages_omitted"] = .bool(true) }
    var unsafe = identityReadRow(condition == "negative-id" ? -1 : 1, text: "Hidden ambiguity", kind: "hidden")
    if condition == "missing-id" { unsafe["id"] = .null }
    host.snapshot["messages"] = .array([unsafe, identityReadRow(1, text: "Unique visible candidate")])
    _ = try await service.connect(configuration: host.configuration)
    let identity = try #require(try await service.conversations(profile: ExactID(host.bot.id)).summaries.first).identity
    let opened = try await service.openChat(.stored(identity))
    #expect(opened.snapshot.messages.map(\.text) == ["Unique visible candidate"])
    #expect(opened.identityRead == nil)
}

@MainActor @Test(arguments: [true, false])
func paginatedHistoryCannotResolveIdentityAfterDeletionSkipsAHiddenDuplicate(authority: Bool) async throws {
    let host = try HermesTestHost(authority: authority), service = host.service()
    defer { service.disconnect() }
    host.snapshot["messages_omitted"] = .bool(true)
    host.storedRows = [.object(["id": .string(host.root), "message_count": .number(200), "preview": .string("First user")])]
    var sourceRows = (1...99).map { identityReadRow($0, text: "Older reply") }
        + [identityReadRow(150, text: "Hidden duplicate", kind: "hidden")]
        + (101...200).map { identityReadRow($0, text: "Recent reply") }
    let original = host.transport.handler
    var offsets: [Int] = []
    host.transport.handler = { request in
        if request.url?.path.hasSuffix("/messages") == true {
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let offset = Int(query.first { $0.name == "offset" }!.value!)!
            offsets.append(offset)
            let batch = Array(sourceRows.dropLast(offset).suffix(100))
            // Removing an unrelated newest row moves the hidden duplicate past the next offset.
            if offset == 0 { sourceRows.removeLast() }
            return .object(["session_id": .string(host.root), "profile": .string(host.bot.id), "messages": .array(batch),
                "pagination": .object(["limit": .number(100), "offset": .number(Double(offset)),
                    "order": .string("latest"), "returned": .number(Double(batch.count))])])
        }
        return try original?(request) ?? .object([:])
    }
    _ = try await service.connect(configuration: host.configuration)
    let summary = try #require(try await service.conversations(profile: ExactID(host.bot.id)).summaries.first)
    let opened = try await service.openChat(.stored(summary.identity))
    #expect(offsets == [0, 100])
    #expect(opened.snapshot.messages.count == 199)
    #expect(opened.snapshot.unavailableMessageIDs == nil)
    #expect(opened.snapshot.messages.contains { $0.id == host.root + ":row:150" })
    #expect(!opened.snapshot.hasEarlierMessages)
    #expect(opened.readEvidence?.summaryObservedBeforeRead == summary)
    #expect(opened.identityRead == nil)
}

@MainActor @Test(arguments: ["replay", "buffer"])
func rowsAddedAfterTheDurableResponseDoNotInheritIdentityProof(path: String) async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    host.snapshot["messages_omitted"] = .bool(true)
    host.snapshot["messages"] = .array([identityReadRow(1, text: "Checked durable reply")])
    let completion = host.event("message.complete", seq: 1, payload: ["text": .string("A later completed reply"),
        "persisted_turn": .object(["final_assistant_row_id": .number(77)])])
    if path == "replay" {
        host.replay["events"] = .array([completion["params"]])
        host.replay["latest_seq"] = .number(1)
    } else {
        let original = host.transport.handler
        host.transport.asyncHandler = { request in
            if request.url?.path.hasSuffix("/messages") == true {
                let socket = host.sockets[0]
                socket.push(completion)
                try await eventually { socket.queue.isEmpty && socket.waiter != nil }
            }
            return try original?(request) ?? .object([:])
        }
    }
    _ = try await service.connect(configuration: host.configuration)
    let identity = try #require(try await service.conversations(profile: ExactID(host.bot.id)).summaries.first).identity
    let opened = try await service.openChat(.stored(identity))
    #expect(opened.snapshot.messages.last?.id == host.root + ":row:77")
    #expect(opened.snapshot.messages.last?.text == "A later completed reply")
    let proof = try #require(opened.identityRead)
    #expect(proof.messageIDs == [Data((host.root + ":row:1").utf8)])
}

@MainActor @Test(arguments: ["delta", "optimistic"])
func incrementalPublicationsDoNotCarryAnEarlierIdentityRead(path: String) async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    host.snapshot["messages"] = .array([identityReadRow(1, text: "Checked reply")])
    _ = try await service.connect(configuration: host.configuration)
    let identity = try #require(try await service.conversations(profile: ExactID(host.bot.id)).summaries.first).identity
    let opened = try await service.openChat(.stored(identity))
    #expect(opened.identityRead != nil)
    var publications: [OpenedConversation] = []
    service.onEvent = { if case .conversation(let next) = $0 { publications.append(next) } }
    if path == "delta" {
        host.sockets[0].push(host.event("message.delta", seq: 1, payload: ["text": .string("New content")]))
        try await eventually { !publications.isEmpty }
    } else {
        _ = try await service.send(text: "New content", attachments: [], access: opened.access, operationID: UUID())
    }
    #expect(!publications.isEmpty)
    #expect(publications.allSatisfy { $0.identityRead == nil })
}

@Test func historyIdentityReadMatchesOnlyItsExactProfileRootAndStoredTip() throws {
    let profile = try ExactID("profile"), root = try ExactID("root"), stored = try ExactID("stored"), other = try ExactID("other")
    let identity = SessionIdentity(profile: profile, root: root, stored: stored, aliases: [])
    let proof = ConversationIdentityRead(identity: identity, messageIDs: [])
    #expect(proof.matches(.init(profile: profile, root: root, stored: stored, aliases: [try ExactID("another-alias")])))
    #expect(!proof.matches(.init(profile: other, root: root, stored: stored, aliases: [])))
    #expect(!proof.matches(.init(profile: profile, root: other, stored: stored, aliases: [])))
    #expect(!proof.matches(.init(profile: profile, root: root, stored: other, aliases: [])))
}

@MainActor @Test(arguments: [true, false])
func exactlyFullFirstPageCannotCertifyExhaustionFromALaterEmptyPage(authority: Bool) async throws {
    let host = try HermesTestHost(authority: authority), service = host.service()
    defer { service.disconnect() }
    host.snapshot["messages_omitted"] = .bool(true)
    host.storedRows = [.object(["id": .string(host.root), "message_count": .number(100)])]
    let original = host.transport.handler
    var offsets: [Int] = []
    host.transport.handler = { request in
        if request.url?.path.hasSuffix("/messages") == true {
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let offset = Int(query.first { $0.name == "offset" }!.value!)!
            offsets.append(offset)
            let batch = offset == 0 ? (1...100).map { identityReadRow($0, text: "Available reply") } : []
            return .object(["session_id": .string(host.root), "profile": .string(host.bot.id), "messages": .array(batch)])
        }
        return try original?(request) ?? .object([:])
    }
    _ = try await service.connect(configuration: host.configuration)
    let summary = try #require(try await service.conversations(profile: ExactID(host.bot.id)).summaries.first)
    let opened = try await service.openChat(.stored(summary.identity))
    #expect(offsets == [0, 100])
    #expect(opened.snapshot.messages.count == 100)
    #expect(opened.readEvidence != nil)
    #expect(opened.identityRead == nil)
}

@MainActor @Test func changedStoredTipCannotPublishAnEarlierRawIdentityProof() async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    host.snapshot["messages_omitted"] = .bool(true)
    let original = host.transport.handler
    var gate: CheckedContinuation<HermesJSON, Error>?
    defer { gate?.resume(throwing: HermesServiceError.disconnected) }
    host.transport.asyncHandler = { request in
        if request.url?.path.hasSuffix("/messages") == true {
            return try await withCheckedThrowingContinuation { gate = $0 }
        }
        return try original?(request) ?? .object([:])
    }
    _ = try await service.connect(configuration: host.configuration)
    let identity = try #require(try await service.conversations(profile: ExactID(host.bot.id)).summaries.first).identity
    let read = Task { try await service.openChat(.stored(identity)) }
    try await eventually { gate != nil }
    host.methodOverride = { frame, socket in
        if frame["method"].text == "session.list" {
            return .object(["sessions": .array([.object(["id": .string(host.root), "resolved_id": .string("new-tip")])])])
        }
        return host.defaultReply(frame, socket: socket)
    }
    _ = try await service.conversations(profile: identity.profile)
    let pending = gate; gate = nil
    pending?.resume(returning: .object(["session_id": .string(host.root), "profile": .string(host.bot.id),
        "messages": .array([identityReadRow(1, text: "Old tip reply")])]))
    let opened = try await read.value
    #expect(opened.identityRead == nil)
}
