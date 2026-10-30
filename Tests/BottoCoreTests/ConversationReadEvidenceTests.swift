import Foundation
import Testing
@testable import BottoCore

@MainActor @Test(arguments: [true, false], [true, false])
func completeReadAttestsInventoryWithoutInventingProjectedCounts(authority: Bool, compacted: Bool) async throws {
    let host = try HermesTestHost(authority: authority), service = host.service()
    defer { service.disconnect() }
    // Exact database outputs from both pinned implementations, preserved without edits.
    let url = try #require(Bundle.module.url(forResource: authority ? "authority" : "sidecar",
        withExtension: "json", subdirectory: "Fixtures/ReadEvidence"))
    let proof = try HermesJSON.decode(Data(contentsOf: url))
    let fixture = compacted ? proof["compacted"] : proof
    let rows = try #require(fixture["rest_rows"].list)
    let inventoryCount = compacted ? 3 : 4
    #expect(fixture["row"]["message_count"].integer == inventoryCount)
    host.snapshot["messages"] = .array(rows)
    host.snapshot["message_count"] = .number(Double(inventoryCount))
    host.storedRows = [.object(["id": .string(host.root), "preview": .string("  e\u{301} first user…\n"),
        "message_count": .number(Double(inventoryCount)), "last_active": .number(103)])]
    _ = try await service.connect(configuration: host.configuration)
    let directory = try await service.conversations(profile: ExactID(host.bot.id))
    let expected = try #require(directory.summaries.first)
    let opened = try await service.openChat(.stored(expected.identity))
    #expect(opened.snapshot.messages.count == (compacted ? 11 : 3))
    let evidence = try #require(opened.readEvidence)
    #expect(evidence.summaryObservedBeforeRead == expected)
    #expect(evidence.summaryObservedBeforeRead.messageCount == inventoryCount)
    #expect(Data(evidence.summaryObservedBeforeRead.preview.utf8) == Data("  e\u{301} first user…\n".utf8))
    #expect(host.transport.requests.filter { $0.url?.path == "/api/sessions" }.count == 1)
}

@MainActor @Test(arguments: [true, false])
func readEvidenceKeepsBeforeReadCatalogWhenLaterSameTipMetadataArrives(authority: Bool) async throws {
    let host = try HermesTestHost(authority: authority), service = host.service()
    defer { service.disconnect() }
    host.storedRows = [readEvidenceRow(host, preview: "e\u{301}", count: 7)]
    host.snapshot["messages_omitted"] = .bool(true)
    _ = try await service.connect(configuration: host.configuration)
    let before = try #require(try await service.conversations(profile: ExactID(host.bot.id)).summaries.first)
    let original = host.transport.handler
    var history: CheckedContinuation<HermesJSON, Error>?
    host.transport.asyncHandler = { request in
        if request.url?.path.hasSuffix("/messages") == true {
            return try await withCheckedThrowingContinuation { history = $0 }
        }
        return try original?(request) ?? .object([:])
    }
    let opening = Task { try await service.openChat(.stored(before.identity)) }
    try await eventually { history != nil }
    // Swift String equality treats these as equal. The captured preview must keep its bytes.
    host.storedRows = [readEvidenceRow(host, preview: "é", count: 8)]
    let later = try #require(try await service.conversations(profile: ExactID(host.bot.id)).summaries.first)
    history?.resume(returning: readEvidencePage(host)); history = nil
    let opened = try await opening.value
    let captured = try #require(opened.readEvidence?.summaryObservedBeforeRead)
    #expect(captured.messageCount == 7)
    #expect(Data(captured.preview.utf8) == Data("e\u{301}".utf8))
    #expect(Data(captured.preview.utf8) != Data(later.preview.utf8))
    #expect(host.transport.requests.filter { $0.url?.path == "/api/sessions" }.count == 2)
}

@MainActor @Test(arguments: [true, false])
func catalogArrivingAfterReadStartsCannotBackfillMissingEvidence(authority: Bool) async throws {
    let host = try HermesTestHost(authority: authority), service = host.service()
    defer { service.disconnect() }
    host.snapshot["messages_omitted"] = .bool(true)
    host.storedRows = [readEvidenceRow(host)]
    _ = try await service.connect(configuration: host.configuration)
    let original = host.transport.handler
    var history: CheckedContinuation<HermesJSON, Error>?
    host.transport.asyncHandler = { request in
        if request.url?.path.hasSuffix("/messages") == true {
            return try await withCheckedThrowingContinuation { history = $0 }
        }
        return try original?(request) ?? .object([:])
    }
    let opening = Task { try await service.openChat(.canonical(profile: ExactID(host.bot.id), expectedRoot: nil)) }
    try await eventually { history != nil }
    let directory = try await service.conversations(profile: ExactID(host.bot.id))
    history?.resume(returning: readEvidencePage(host)); history = nil
    let first = try await opening.value
    #expect(first.readEvidence == nil)
    host.transport.asyncHandler = nil
    let reopened = try await service.openChat(.stored(try #require(directory.summaries.first).identity))
    #expect(reopened.readEvidence?.summaryObservedBeforeRead.messageCount == 4)
}

@MainActor @Test(arguments: ["catalog", "resume"])
func changedInventoryTipCannotInheritBeforeReadEvidence(change: String) async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    host.snapshot["messages_omitted"] = .bool(true)
    host.storedRows = [readEvidenceRow(host)]
    _ = try await service.connect(configuration: host.configuration)
    let before = try #require(try await service.conversations(profile: ExactID(host.bot.id)).summaries.first)
    let original = host.transport.handler
    var history: CheckedContinuation<HermesJSON, Error>?
    if change == "catalog" {
        host.transport.asyncHandler = { request in
            if request.url?.path.hasSuffix("/messages") == true {
                return try await withCheckedThrowingContinuation { history = $0 }
            }
            return try original?(request) ?? .object([:])
        }
    } else { host.snapshot["stored_session_id"] = .string("new-tip") }
    let opening = Task { try await service.openChat(.stored(before.identity)) }
    if change == "catalog" { try await eventually { history != nil } }
    var nextRow = readEvidenceRow(host)
    nextRow["resolved_id"] = .string("new-tip")
    nextRow["_lineage_ids"] = .array([.string(host.root), .string("new-tip")])
    host.storedRows = [nextRow]
    if change == "catalog" {
        _ = try await service.conversations(profile: ExactID(host.bot.id))
        history?.resume(returning: readEvidencePage(host)); history = nil
    } else {
        host.transport.handler = { request in
            if request.url?.path == "/api/sessions/new-tip/messages" {
                return .object(["session_id": .string("new-tip"), "profile": .string(host.bot.id), "messages": .array([])])
            }
            return try original?(request) ?? .object([:])
        }
    }
    let opened = try await opening.value
    #expect(opened.readEvidence == nil)
}

@MainActor @Test(arguments: [true, false])
func firstCanonicalLookupCanWitnessItsAvailableMetadataWithoutDirectoryScan(authority: Bool) async throws {
    let host = try HermesTestHost(authority: authority), service = host.service()
    defer { service.disconnect() }
    // Source-shaped session.list title rows: both have count; only sidecar has preview.
    var row: HermesJSON = .object(["id": .string(host.root), "resolved_id": .string(host.root),
        "title": .string("Bot Chat"), "message_count": .number(4)])
    if !authority { row["preview"] = .string("  exact first user…\n") }
    let canonical = row
    host.methodOverride = { frame, socket in
        if frame["method"].text == "session.list" { return .object(["sessions": .array([canonical])]) }
        return host.defaultReply(frame, socket: socket)
    }
    _ = try await service.connect(configuration: host.configuration)
    let opened = try await service.openChat(.canonical(profile: ExactID(host.bot.id), expectedRoot: nil))
    let evidence = try #require(opened.readEvidence?.summaryObservedBeforeRead)
    #expect(evidence.identity == opened.identity)
    #expect(evidence.messageCount == 4)
    #expect(evidence.updatedAt == nil)
    #expect(Data(evidence.preview.utf8) == Data((authority ? "" : "  exact first user…\n").utf8))
    #expect(!host.transport.requests.contains { $0.url?.path == "/api/sessions" })
    #expect(host.sockets[0].sent.filter { $0["method"].text == "session.list" }.count == 1)
    // A later directory cannot enrich the already returned observation retroactively.
    host.storedRows = [canonical]
    let directory = try await service.conversations(profile: ExactID(host.bot.id))
    #expect(directory.summaries.first == evidence)
    host.storedRows = [readEvidenceRow(host, preview: "Richer REST first user", count: 4)]
    let enriched = try await service.conversations(profile: ExactID(host.bot.id))
    #expect(enriched.summaries.first?.updatedAt != evidence.updatedAt)
    #expect(opened.readEvidence?.summaryObservedBeforeRead.updatedAt == nil)
}

@MainActor @Test(arguments: [true, false])
func hiddenModelOnlyAndUnknownRowsDoNotPreventGenuineReadEvidence(authority: Bool) async throws {
    let host = try HermesTestHost(authority: authority), service = host.service()
    defer { service.disconnect() }
    host.snapshot["messages"] = .array([
        .object(["row_id": .number(1), "role": .string("user"), "text": .string("Visible question")]),
        .object(["row_id": .number(2), "role": .string("assistant"), "text": .string("Hidden"), "display_kind": .string("hidden")]),
        .object(["row_id": .number(3), "role": .string("assistant"), "text": .string("Model only"),
            "display_metadata": .object(["model_only": .bool(true)])]),
        .object(["row_id": .number(4), "role": .string("unknown"), "text": .string("Not displayed")]),
        .object(["row_id": .number(5), "role": .string("assistant"), "text": .string("Visible answer")])])
    host.storedRows = [readEvidenceRow(host, count: 5)]
    _ = try await service.connect(configuration: host.configuration)
    let directory = try await service.conversations(profile: ExactID(host.bot.id))
    let opened = try await service.openChat(.stored(try #require(directory.summaries.first).identity))
    #expect(opened.snapshot.messages.map(\.text) == ["Visible question", "Visible answer"])
    #expect(opened.readEvidence?.summaryObservedBeforeRead.messageCount == 5)
}

@MainActor private func readEvidenceRow(_ host: HermesTestHost, preview: String = "First user", count: Int = 4) -> HermesJSON {
    .object(["id": .string(host.root), "preview": .string(preview), "message_count": .number(Double(count)),
        "last_active": .number(103)])
}

@MainActor @Test(arguments: ["missing-count", "wrong-profile", "wrong-profile-name"])
func unqualifiedCanonicalLookupDoesNotIssueReadEvidence(condition: String) async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    var row = readEvidenceRow(host)
    if condition == "missing-count" { row["message_count"] = .null }
    else { row[condition == "wrong-profile" ? "profile" : "profile_name"] = .string("other-profile") }
    let canonical = row
    host.methodOverride = { frame, socket in
        if frame["method"].text == "session.list" { return .object(["sessions": .array([canonical])]) }
        return host.defaultReply(frame, socket: socket)
    }
    _ = try await service.connect(configuration: host.configuration)
    let opened = try await service.openChat(.canonical(profile: ExactID(host.bot.id), expectedRoot: nil))
    #expect(opened.readEvidence == nil)
    #expect(!host.transport.requests.contains { $0.url?.path == "/api/sessions" })
}

@MainActor @Test func fullHistoricalAliasReadCannotAttestCurrentInventoryTip() async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    var row = readEvidenceRow(host)
    row["resolved_id"] = .string("current-tip")
    row["_lineage_ids"] = .array([.string(host.root), .string("current-tip")])
    host.storedRows = [row]
    _ = try await service.connect(configuration: host.configuration)
    let current = try #require(try await service.conversations(profile: ExactID(host.bot.id)).summaries.first).identity
    let historical = SessionIdentity(profile: current.profile, root: current.root, stored: try ExactID(host.root), aliases: current.aliases)
    let opened = try await service.openChat(.stored(historical))
    #expect(opened.readEvidence == nil)
    host.snapshot["stored_session_id"] = .string("current-tip")
    let tip = try await service.openChat(.stored(current))
    #expect(tip.readEvidence?.summaryObservedBeforeRead.identity.stored == current.stored)
}

@MainActor private func readEvidencePage(_ host: HermesTestHost) -> HermesJSON {
    .object(["session_id": .string(host.root), "profile": .string(host.bot.id), "messages": host.snapshot["messages"]])
}
