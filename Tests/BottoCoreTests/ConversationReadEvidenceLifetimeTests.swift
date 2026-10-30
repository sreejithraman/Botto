import Foundation
import Testing
@testable import BottoCore

@MainActor @Test(arguments: [true, false], ["reopen", "completion", "recovery", "gap"])
func completeAutomaticAndExplicitReadsIssueFreshEvidence(authority: Bool, path: String) async throws {
    let host = try HermesTestHost(authority: authority), service = host.service()
    defer { service.disconnect() }
    host.storedRows = [evidenceLifetimeRow(host, count: 4)]
    _ = try await service.connect(configuration: host.configuration)
    let identity = try #require(try await service.conversations(profile: ExactID(host.bot.id)).summaries.first).identity
    let original = try await service.openChat(.stored(identity))
    #expect(original.readEvidence?.summaryObservedBeforeRead.messageCount == 4)
    host.storedRows = [evidenceLifetimeRow(host, count: 5)]
    _ = try await service.conversations(profile: ExactID(host.bot.id))
    host.snapshot["messages"] = .array([.object(["row_id": .number(5), "role": .string("assistant"), "text": .string("Fresh full read")])])
    var publications: [OpenedConversation] = []
    service.onEvent = { if case .conversation(let opened) = $0 { publications.append(opened) } }
    switch path {
    case "reopen": _ = try await service.openChat(.stored(identity))
    case "recovery": host.sockets[0].close()
    case "completion":
        host.snapshot["last_sequence"] = .number(1)
        host.sockets[0].push(host.event("message.complete", seq: 1, payload: ["text": .string("Transient completion")]))
    default: host.sockets[0].push(host.event("message.delta", seq: 2, payload: ["text": .string("Gap")]))
    }
    try await eventually { publications.last?.readEvidence?.summaryObservedBeforeRead.messageCount == 5 }
    let current = try #require(publications.last)
    #expect(current.access != original.access)
    #expect(current.snapshot.messages.last?.text == "Fresh full read")
    if path == "completion" { #expect(publications.first?.readEvidence == nil) }
    _ = try await service.bots()
    #expect(host.transport.requests.filter(isFullDirectoryRead).count == 2)
}

@MainActor @Test(arguments: ["delta", "optimistic"])
func incrementalAndOptimisticPublicationsCannotMintReadEvidence(path: String) async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    host.storedRows = [evidenceLifetimeRow(host, count: 4)]
    _ = try await service.connect(configuration: host.configuration)
    let identity = try #require(try await service.conversations(profile: ExactID(host.bot.id)).summaries.first).identity
    let original = try await service.openChat(.stored(identity))
    #expect(original.readEvidence != nil)
    host.storedRows = [evidenceLifetimeRow(host, count: 9)]
    _ = try await service.conversations(profile: ExactID(host.bot.id))
    var publications: [OpenedConversation] = []
    service.onEvent = { if case .conversation(let opened) = $0 { publications.append(opened) } }
    if path == "delta" {
        host.sockets[0].push(host.event("message.delta", seq: 1, payload: ["text": .string("Incremental text")]))
        try await eventually { !publications.isEmpty }
    } else {
        _ = try await service.send(text: "Optimistic text", attachments: [], access: original.access, operationID: UUID())
    }
    #expect(!publications.isEmpty)
    #expect(publications.allSatisfy { $0.readEvidence == nil })
    #expect(host.transport.requests.filter { $0.url?.path == "/api/sessions" }.count == 2)
}

@MainActor @Test(arguments: ["cancel", "selection", "connection"])
func retiredFullReadNeverPublishesOldEvidence(retirement: String) async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    host.snapshot["messages_omitted"] = .bool(true)
    host.storedRows = [evidenceLifetimeRow(host, count: 4)]
    let configuration = host.configuration
    _ = try await service.connect(configuration: configuration)
    let identity = try #require(try await service.conversations(profile: ExactID(host.bot.id)).summaries.first).identity
    let original = host.transport.handler
    var gate: CheckedContinuation<HermesJSON, Error>?
    host.transport.asyncHandler = { request in
        if request.url?.path.hasSuffix("/messages") == true {
            return try await withCheckedThrowingContinuation { gate = $0 }
        }
        return try original?(request) ?? .object([:])
    }
    var publications: [OpenedConversation] = []
    service.onEvent = { if case .conversation(let opened) = $0 { publications.append(opened) } }
    let opening = Task { try await service.openChat(.stored(identity)) }
    try await eventually { gate != nil }
    let oldPage: HermesJSON = .object(["session_id": .string(host.root), "profile": .string(host.bot.id), "messages": .array([])])
    switch retirement {
    case "cancel": opening.cancel()
    case "connection":
        service.disconnect()
        host.transport.asyncHandler = nil
        _ = try await service.connect(configuration: configuration)
    default:
        host.root = "replacement"
        host.snapshot["session_id"] = .string("replacement")
        host.snapshot["stored_session_id"] = .string("replacement")
        host.snapshot["messages_omitted"] = .bool(false)
        _ = try await service.openChat(.canonical(profile: ExactID(host.bot.id), expectedRoot: nil))
    }
    let publishedBeforeOldCompletion = publications.count
    gate?.resume(returning: oldPage); gate = nil
    do { _ = try await opening.value; Issue.record("Retired read must fail") } catch {}
    #expect(publications.count == publishedBeforeOldCompletion)
    host.transport.asyncHandler = nil
    host.storedRows = [evidenceLifetimeRow(host, count: 6)]
    let currentIdentity = try #require(try await service.conversations(profile: ExactID(host.bot.id)).summaries.first).identity
    let current = try await service.openChat(.stored(currentIdentity))
    #expect(current.readEvidence?.summaryObservedBeforeRead.messageCount == 6)
}

@MainActor @Test func idleAuthoritySnapshotAttestsReadAfterReplayRingRollsOver() async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    host.storedRows = [evidenceLifetimeRow(host, count: 149)]
    host.replay["truncated"] = .bool(true)
    host.replay["snapshot_required"] = .bool(true)
    host.replay["latest_seq"] = .number(700)
    host.snapshot["last_sequence"] = .number(700)
    host.snapshot["running"] = .bool(false)
    _ = try await service.connect(configuration: host.configuration)
    let summary = try #require(try await service.conversations(profile: ExactID(host.bot.id)).summaries.first)
    let opened = try await service.openChat(.stored(summary.identity))
    #expect(!opened.snapshot.isWorking)
    #expect(opened.readEvidence?.summaryObservedBeforeRead == summary,
        "A complete idle snapshot covers the replay head even after old ring entries expire")
}

@MainActor @Test(arguments: ["truncated-working", "truncated-stale-snapshot", "truncated-sidecar", "truncated-missing-running", "epoch", "snapshot-hydrating", "history-truncated", "bad-pagination"])
func incompleteReadNeverIssuesEvidence(condition: String) async throws {
    let host = try HermesTestHost(authority: condition != "truncated-sidecar"), service = host.service()
    defer { service.disconnect() }
    host.storedRows = [evidenceLifetimeRow(host, count: 4)]
    host.replay["truncated"] = .bool(true)
    _ = try await service.connect(configuration: host.configuration)
    let identity = try #require(try await service.conversations(profile: ExactID(host.bot.id)).summaries.first).identity
    switch condition {
    case "truncated-working":
        host.snapshot["running"] = .bool(true)
    case "truncated-stale-snapshot":
        host.replay["latest_seq"] = .number(1)
        host.snapshot["last_sequence"] = .number(0)
    case "truncated-sidecar": break
    case "truncated-missing-running": host.snapshot["running"] = .null
    case "epoch": host.replay["replay_epoch"] = .string("unknown-epoch")
    case "snapshot-hydrating": host.snapshot["hydrating"] = .bool(true)
    default:
        host.snapshot["messages_omitted"] = .bool(true)
        let original = host.transport.handler
        host.transport.handler = { request in
            if request.url?.path.hasSuffix("/messages") == true {
                return .object(["session_id": .string(host.root), "profile": .string(host.bot.id),
                    "messages": .array(condition == "history-truncated" ? [.object(["role": .string("assistant"),
                        "text": .string("Incomplete"), "archived_truncated": .bool(true)])] : []),
                    "pagination": .object(["offset": .number(condition == "bad-pagination" ? 100 : 0),
                        "limit": .number(100), "order": .string("latest"),
                        "returned": .number(condition == "history-truncated" ? 1 : 0)])])
            }
            return try original?(request) ?? .object([:])
        }
    }
    let opened = try await service.openChat(.stored(identity))
    #expect(opened.readEvidence == nil)
}

@MainActor @Test func createdSummaryWithoutRemoteInventoryCannotManufactureReadEvidence() async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    host.methodOverride = { frame, socket in
        if frame["method"].text == "session.create" {
            var created = host.snapshot
            created["session_id"] = .string("created-runtime")
            created["stored_session_id"] = .string("created-stored")
            return created
        }
        return host.defaultReply(frame, socket: socket)
    }
    _ = try await service.connect(configuration: host.configuration)
    let created = try await service.createConversation(profile: ExactID(host.bot.id), operationID: UUID())
    _ = try await service.conversations(profile: ExactID(host.bot.id))
    host.snapshot["session_id"] = .string("created-runtime")
    host.snapshot["stored_session_id"] = .string("created-stored")
    let opened = try await service.openChat(.stored(created.summary.identity))
    #expect(opened.readEvidence == nil)
    var inventoriedRow = evidenceLifetimeRow(host, count: 4)
    inventoriedRow["id"] = .string("created-stored")
    host.storedRows = [inventoriedRow]
    _ = try await service.conversations(profile: ExactID(host.bot.id))
    let inventoried = try await service.openChat(.stored(created.summary.identity))
    #expect(inventoried.readEvidence?.summaryObservedBeforeRead.messageCount == 4)
    host.storedRows = []
    _ = try await service.conversations(profile: ExactID(host.bot.id))
    let missing = try await service.openChat(.stored(created.summary.identity))
    #expect(missing.readEvidence == nil, "The retained creation must not replace an actual inventory observation with count zero")
}

@MainActor private func evidenceLifetimeRow(_ host: HermesTestHost, count: Int) -> HermesJSON {
    .object(["id": .string(host.root), "message_count": .number(Double(count)), "preview": .string("First user"),
        "last_active": .number(103)])
}

@MainActor @Test(arguments: ["failure", "profile", "stored"])
func failedOrMismatchedHistoryCannotPublishReadEvidence(condition: String) async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    host.storedRows = [evidenceLifetimeRow(host, count: 4)]
    host.snapshot["messages_omitted"] = .bool(true)
    _ = try await service.connect(configuration: host.configuration)
    let identity = try #require(try await service.conversations(profile: ExactID(host.bot.id)).summaries.first).identity
    let original = host.transport.handler
    host.transport.handler = { request in
        if request.url?.path.hasSuffix("/messages") == true {
            if condition == "failure" { throw HermesServiceError.rejected(503) }
            return .object(["session_id": .string(condition == "stored" ? "wrong-stored" : host.root),
                "profile": .string(condition == "profile" ? "wrong-profile" : host.bot.id), "messages": .array([])])
        }
        return try original?(request) ?? .object([:])
    }
    var publications: [OpenedConversation] = []
    service.onEvent = { if case .conversation(let opened) = $0 { publications.append(opened) } }
    do { _ = try await service.openChat(.stored(identity)); Issue.record("Invalid history must fail") } catch {}
    #expect(publications.isEmpty)
    host.transport.handler = original
    let current = try await service.openChat(.stored(identity))
    #expect(current.readEvidence?.summaryObservedBeforeRead.messageCount == 4)
}
