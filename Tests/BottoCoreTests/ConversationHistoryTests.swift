import Foundation
import Testing
@testable import BottoCore

@MainActor @Test(arguments: [true, false])
func attachmentWithholdsSourceProofAfterAnOverlappingCatalogTipChange(authority: Bool) async throws {
    let host = try HermesTestHost(authority: authority), service = host.service()
    defer { service.disconnect() }
    let profile = try ExactID(host.bot.id), root = try ExactID(host.root)
    let successor = SessionIdentity(profile: profile, root: root, stored: try ExactID("successor-tip"), aliases: [root])
    host.methodOverride = { frame, socket in
        if frame["method"].text == "session.events.since" {
            service.catalogs[profile] = .init(summaries: [.init(identity: successor, title: "Main", isCanonical: true,
                persistence: .durable)], activity: [:], isComplete: true)
        }
        return host.defaultReply(frame, socket: socket)
    }
    _ = try await service.connect(configuration: host.configuration)
    let opened = try await service.openChat(.canonical(profile: profile, expectedRoot: nil))
    #expect(opened.historyReadStartedAt != nil)
    #expect(opened.identity.stored == root)
    #expect(opened.observedSource == nil && opened.readEvidence == nil)
}

@MainActor @Test(arguments: [true, false])
func attachmentPublicationsOnlyCarryReadStartForFreshReads(authority: Bool) async throws {
    let host = try HermesTestHost(authority: authority), service = host.service()
    defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let before = ContinuousClock.now
    let opened = try await service.openChat(.canonical(profile: ExactID(host.bot.id), expectedRoot: nil))
    let started = try #require(opened.historyReadStartedAt)
    #expect(opened.observedSource == opened.identity)
    #expect(started >= before && started <= .now)
    var incremental: OpenedConversation?
    service.onEvent = { if case .conversation(let value) = $0 { incremental = value } }
    service.emitConversation()
    #expect(incremental?.historyReadStartedAt == nil)
    #expect(incremental?.observedSource == nil)
    #expect(incremental?.snapshot == opened.snapshot)
}

@MainActor @Test(arguments: [true, false], [true, false])
func attachmentKeepsUnstableRowsVisibleButUnreferenceable(authority: Bool, negative: Bool) async throws {
    let host = try HermesTestHost(authority: authority), service = host.service()
    defer { service.disconnect() }
    var row = historyRow(negative ? -1 : 7, text: "MEDIA:/unstable.html")
    if !negative { row["id"] = .null }
    host.snapshot["messages"] = .array([row])
    _ = try await service.connect(configuration: host.configuration)
    let opened = try await service.openChat(.canonical(profile: ExactID(host.bot.id), expectedRoot: nil))
    let message = try #require(opened.snapshot.messages.first)
    #expect(message.text == "MEDIA:/unstable.html")
    #expect(!ChatMessage.isStableID(Data(message.id.utf8), storedID: opened.identity.stored.text))
    #expect(opened.snapshot.unavailableMessageIDs?.contains(Data(message.id.utf8)) == true)
    let restored = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(opened.snapshot))
    #expect(restored.unavailableMessageIDs == opened.snapshot.unavailableMessageIDs)
}

@MainActor @Test(arguments: [true, false])
func libraryHistoryPreservesDuplicateIdentityEvidence(hidden: Bool) async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let identity = try #require(try await service.conversations(profile: ExactID(host.bot.id)).summaries.first).identity
    let original = host.transport.handler
    host.transport.handler = { request in
        if request.url?.path.hasSuffix("/messages") == true {
            var duplicate = historyRow(7, text: "Second occurrence")
            if hidden { duplicate["display_kind"] = .string("hidden") }
            return historyPage(identity: identity, offset: 0, rows: [historyRow(7, text: "MEDIA:/disputed.html"), duplicate, historyRow(8, text: "Retained")])
        }
        return try original?(request) ?? .object([:])
    }
    let page = try await service.conversationHistory(identity, offset: 0)
    #expect(!page.isComplete)
    #expect(page.unavailableMessageIDs == [Data((identity.stored.text + ":row:7").utf8)])
    #expect(page.messages.contains { $0.text == "Retained" })
}

@MainActor @Test(arguments: [true, false], [true, false])
func activeAttachmentRetainsRawDuplicateEvidence(authority: Bool, hidden: Bool) async throws {
    let host = try HermesTestHost(authority: authority), service = host.service()
    defer { service.disconnect() }
    let first = historyRow(7, text: "MEDIA:/disputed.html")
    var second = historyRow(7, text: "Second occurrence")
    if hidden { second["display_kind"] = .string("hidden") }
    host.snapshot["messages"] = .array([first, second])
    _ = try await service.connect(configuration: host.configuration)
    let opened = try await service.openChat(.canonical(profile: ExactID(host.bot.id), expectedRoot: nil))
    let id = Data((opened.identity.stored.text + ":row:7").utf8)
    #expect(opened.snapshot.unavailableMessageIDs?.contains(id) == true)
    #expect(opened.snapshot.messages.count == (hidden ? 1 : 2))
    #expect(opened.readEvidence == nil)
    let restored = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(opened.snapshot))
    #expect(restored.unavailableMessageIDs?.contains(id) == true)
}

@MainActor @Test(arguments: [true, false])
func directorySummaryPreservesMissingVersusEmptyPreview(provided: Bool) async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    var row: [String: HermesJSON] = ["id": .string("preview-evidence")]
    if provided { row["preview"] = .string("") }
    host.storedRows = [.object(row)]
    _ = try await service.connect(configuration: host.configuration)
    let summary = try #require(try await service.conversations(profile: ExactID(host.bot.id))
        .summaries.first { $0.identity.stored.text == "preview-evidence" })
    #expect(summary.preview.isEmpty)
    #expect(summary.hasPreview == provided)
    let encoded = try JSONEncoder().encode(summary)
    #expect(try JSONDecoder().decode(SessionSummary.self, from: encoded).hasPreview == provided)
    var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    legacy.removeValue(forKey: "hasPreview")
    let decoded = try JSONDecoder().decode(SessionSummary.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(decoded.preview.isEmpty)
    #expect(decoded.hasPreview != true)
}

@MainActor @Test(arguments: [true, false])
func conversationHistoryReadsAnotherChatWithoutReplacingLiveAccess(authority: Bool) async throws {
    let host = try HermesTestHost(authority: authority), service = host.service()
    defer { service.disconnect() }
    host.storedRows = [.object(["id": .string("other-chat")])]
    _ = try await service.connect(configuration: host.configuration)
    let directory = try await service.conversations(profile: ExactID(host.bot.id))
    let other = try #require(directory.summaries.first { $0.identity.stored.text == "other-chat" }).identity
    let opened = try await service.openChat(.canonical(profile: ExactID(host.bot.id), expectedRoot: nil))
    let original = host.transport.handler
    host.transport.handler = { request in
        if request.url?.path == "/api/sessions/other-chat/messages" {
            return historyPage(identity: other, offset: 0, rows: [historyRow(1, text: "Other chat result")])
        }
        return try original?(request) ?? .object([:])
    }
    let methods = host.sockets.flatMap(\.sent).map { $0["method"].text }
    var publications = 0
    service.onEvent = { if case .conversation = $0 { publications += 1 } }
    let result = try await service.conversationHistory(other, offset: 0)
    #expect(result.messages.map(\.text) == ["Other chat result"])
    #expect(result.nextOffset == nil && result.isComplete)
    #expect(host.sockets.flatMap(\.sent).map { $0["method"].text } == methods)
    #expect(publications == 0)
    try service.validate(opened.access)
}

@MainActor @Test func conversationHistoryPagesOlderRowsAndUsesDisplayContent() async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let identity = try #require(try await service.conversations(profile: ExactID(host.bot.id)).summaries.first).identity
    let original = host.transport.handler
    host.transport.handler = { request in
        if request.url?.path.hasSuffix("/messages") == true {
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            #expect(query.contains { $0.name == "profile" && $0.value == identity.profile.text })
            #expect(query.contains { $0.name == "include_compacted" && $0.value == "true" })
            #expect(query.contains { $0.name == "inline_images" && $0.value == "false" })
            let offset = Int(query.first { $0.name == "offset" }!.value!)!
            if offset == 0 {
                return historyPage(identity: identity, offset: offset, rows: (101...200).map { historyRow($0, text: "New \($0)") })
            }
            var row = historyRow(1, text: "Provider scaffolding")
            row["display_content"] = .string("Older visible reply")
            var hidden = historyRow(2, text: "Hidden carrier")
            hidden["display_kind"] = .string("hidden")
            return historyPage(identity: identity, offset: offset, rows: [row, hidden])
        }
        return try original?(request) ?? .object([:])
    }
    let newest = try await service.conversationHistory(identity, offset: 0)
    #expect(newest.messages.first?.text == "New 101")
    #expect(newest.messages.last?.text == "New 200")
    #expect(newest.nextOffset == 100 && newest.isComplete)
    let oldest = try await service.conversationHistory(identity, offset: 100)
    #expect(oldest.messages.map(\.text) == ["Older visible reply"])
    #expect(oldest.messages.first?.id == identity.stored.text + ":row:1")
    #expect(oldest.nextOffset == nil && oldest.isComplete)
}

@MainActor @Test func conversationHistoryKeepsPagingPastHiddenRows() async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let identity = try #require(try await service.conversations(profile: ExactID(host.bot.id)).summaries.first).identity
    let original = host.transport.handler
    host.transport.handler = { request in
        if request.url?.path.hasSuffix("/messages") == true {
            let rows = (1...100).map { id -> HermesJSON in
                var row = historyRow(id, text: "Hidden scaffolding")
                row["display_kind"] = .string("hidden")
                return row
            }
            return historyPage(identity: identity, offset: 0, rows: rows)
        }
        return try original?(request) ?? .object([:])
    }
    let page = try await service.conversationHistory(identity, offset: 0)
    #expect(page.messages.isEmpty)
    #expect(page.nextOffset == 100 && page.isComplete)
    #expect(page.sourceIDs?.count == 100)
    #expect(page.sourceIDs?.contains(Data((identity.stored.text + ":row:100").utf8)) == true)
}

@MainActor @Test(arguments: ["omitted", "truncated", "sidecar"])
func conversationHistoryReportsMissingContent(condition: String) async throws {
    let host = try HermesTestHost(authority: condition != "sidecar"), service = host.service()
    defer { service.disconnect() }
    if condition == "sidecar" {
        host.methodOverride = { frame, socket in
            if frame["method"].text == "session.list" {
                return .object(["sessions": .array([.object(["id": .string(host.root), "resolved_id": .string("compressed-tip")])])])
            }
            return host.defaultReply(frame, socket: socket)
        }
    }
    _ = try await service.connect(configuration: host.configuration)
    let identity = try #require(try await service.conversations(profile: ExactID(host.bot.id)).summaries.first).identity
    let original = host.transport.handler
    host.transport.handler = { request in
        if request.url?.path.hasSuffix("/messages") == true {
            var page = historyPage(identity: identity, offset: 0, rows: [historyRow(1, text: "Available content")])
            if condition == "omitted" { page["messages_omitted"] = .bool(true) }
            if condition == "truncated" {
                var row = historyRow(1, text: "Available content")
                row["archived_truncated"] = .bool(true)
                page["messages"] = .array([row])
            }
            return page
        }
        return try original?(request) ?? .object([:])
    }
    let read = try await service.conversationHistory(identity, offset: 0)
    #expect(!read.isComplete && read.nextOffset == nil)
    #expect(read.messages.map(\.text) == ["Available content"])
}

@MainActor @Test(arguments: ["profile", "session", "offset", "limit", "order", "returned", "oversized", "missing-id"])
func conversationHistoryRejectsMalformedOrForeignPages(condition: String) async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let identity = try #require(try await service.conversations(profile: ExactID(host.bot.id)).summaries.first).identity
    let original = host.transport.handler
    host.transport.handler = { request in
        if request.url?.path.hasSuffix("/messages") == true {
            var page = historyPage(identity: identity, offset: 0, rows: [historyRow(1, text: "Must not enter library")])
            switch condition {
            case "profile": page["profile"] = .string("foreign-profile")
            case "session": page["session_id"] = .string("foreign-session")
            case "offset": page["pagination"]["offset"] = .number(100)
            case "limit": page["pagination"]["limit"] = .number(200)
            case "order": page["pagination"]["order"] = .string("oldest")
            case "returned": page["pagination"]["returned"] = .number(0)
            case "oversized": page["messages"] = .array((1...101).map { historyRow($0, text: "Surplus") })
            default: page["messages"] = .array([.object(["role": .string("assistant"), "content": .string("Missing identity")])])
            }
            return page
        }
        return try original?(request) ?? .object([:])
    }
    await #expect(throws: HermesServiceError.self) { try await service.conversationHistory(identity, offset: 0) }
}

@MainActor @Test(arguments: [-1, 1, 101, 100_100, Int.max])
func conversationHistoryRejectsInvalidOffsetsBeforeRequest(offset: Int) async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let identity = try #require(try await service.conversations(profile: ExactID(host.bot.id)).summaries.first).identity
    let count = host.transport.requests.count
    await #expect(throws: HermesServiceError.incompatible) { try await service.conversationHistory(identity, offset: offset) }
    #expect(host.transport.requests.count == count)
}

@MainActor @Test(arguments: ["profile", "root", "stored", "alias"])
func libraryReadsRequireServiceObservedIdentity(component: String) async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let known = try #require(try await service.conversations(profile: ExactID(host.bot.id)).summaries.first).identity
    let other = try ExactID("unobserved")
    let identity = SessionIdentity(profile: component == "profile" ? other : known.profile,
        root: component == "root" ? other : known.root, stored: component == "stored" ? other : known.stored,
        aliases: component == "alias" ? known.aliases.union([other]) : known.aliases)
    let count = host.transport.requests.count
    await #expect(throws: HermesServiceError.wrongConversation) { try await service.conversationHistory(identity, offset: 0) }
    await #expect(throws: HermesServiceError.wrongConversation) {
        try await service.downloadArtifact(.init(name: "report.txt", path: "/host/report.txt"), in: identity)
    }
    #expect(host.transport.requests.count == count)
}

@MainActor @Test(arguments: [true, false])
func libraryDownloadUsesOriginalChatWithoutReplacingLiveAccess(authority: Bool) async throws {
    let host = try HermesTestHost(authority: authority), service = host.service()
    defer { service.disconnect() }
    host.storedRows = [.object(["id": .string("other-chat")])]
    _ = try await service.connect(configuration: host.configuration)
    let directory = try await service.conversations(profile: ExactID(host.bot.id))
    let other = try #require(directory.summaries.first { $0.identity.stored.text == "other-chat" }).identity
    let opened = try await service.openChat(.canonical(profile: ExactID(host.bot.id), expectedRoot: nil))
    let methods = host.sockets.flatMap(\.sent).map { $0["method"].text }
    let artifact = try await service.downloadArtifact(.init(name: "report.txt", path: "./report+draft.txt"), in: other)
    let request = try #require(host.transport.requests.last)
    #expect(request.url?.path == "/api/fs/download")
    #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems == [
        URLQueryItem(name: "path", value: "./report+draft.txt"), URLQueryItem(name: "profile", value: other.profile.text),
        URLQueryItem(name: "session_id", value: "other-chat")])
    #expect(request.url?.absoluteString.contains("%2B") == true)
    #expect(artifact.data == Data(#"{"ok":true}"#.utf8))
    #expect(host.sockets.flatMap(\.sent).map { $0["method"].text } == methods)
    try service.validate(opened.access)
}

@MainActor @Test(arguments: ["history", "download"], ["cancel", "reconnect", "tip"])
func libraryReadsRejectResultsAfterTheirSourceChanges(operation: String, retirement: String) async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let identity = try #require(try await service.conversations(profile: ExactID(host.bot.id)).summaries.first).identity
    let original = host.transport.handler
    var gate: CheckedContinuation<HermesJSON, Error>?
    defer { gate?.resume(throwing: HermesServiceError.disconnected) }
    host.transport.asyncHandler = { request in
        if request.url?.path.hasSuffix("/messages") == true || request.url?.path == "/api/fs/download" {
            return try await withCheckedThrowingContinuation { gate = $0 }
        }
        return try original?(request) ?? .object([:])
    }
    let read = Task {
        if operation == "history" { _ = try await service.conversationHistory(identity, offset: 0) }
        else { _ = try await service.downloadArtifact(.init(name: "report.txt", path: "/host/report.txt"), in: identity) }
    }
    try await eventually { gate != nil }
    switch retirement {
    case "cancel": read.cancel()
    case "reconnect":
        service.disconnect()
        _ = try await service.connect(configuration: host.configuration)
        _ = try await service.conversations(profile: identity.profile)
    default:
        host.methodOverride = { frame, socket in
            if frame["method"].text == "session.list" {
                return .object(["sessions": .array([.object(["id": .string(host.root), "resolved_id": .string("new-tip")])])])
            }
            return host.defaultReply(frame, socket: socket)
        }
        _ = try await service.conversations(profile: identity.profile)
    }
    let pending = gate; gate = nil
    pending?.resume(returning: historyPage(identity: identity, offset: 0, rows: [historyRow(1, text: "Stale result")]))
    await #expect(throws: Error.self) { try await read.value }
}

private func historyRow(_ id: Int, text: String) -> HermesJSON {
    .object(["id": .number(Double(id)), "role": .string("assistant"), "content": .string(text)])
}

private func historyPage(identity: SessionIdentity, offset: Int, rows: [HermesJSON]) -> HermesJSON {
    .object(["session_id": .string(identity.stored.text), "profile": .string(identity.profile.text), "messages": .array(rows),
        "pagination": .object(["limit": .number(100), "offset": .number(Double(offset)), "order": .string("latest"),
            "returned": .number(Double(rows.count))])])
}
