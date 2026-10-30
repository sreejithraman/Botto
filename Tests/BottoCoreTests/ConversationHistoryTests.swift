import Foundation
import Testing
@testable import BottoCore

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

@MainActor @Test(arguments: ["profile", "session", "offset", "limit", "order", "returned", "oversized", "duplicate", "missing-id"])
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
            case "duplicate":
                page = historyPage(identity: identity, offset: 0, rows: [historyRow(1, text: "One"), historyRow(1, text: "Conflicting row")])
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
