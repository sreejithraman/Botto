import Foundation
import Testing
@testable import BottoCore

@Test func conversationPreviewKeepsLastReadableMessageAcrossQuietTurns() {
    let at = Date(timeIntervalSince1970: 123)
    let messages: [ChatMessage] = [
        .init(id: "user", role: .user, text: "Check the report"),
        .init(id: "answer", role: .assistant, text: "The report is **ready**.", timestamp: at),
        .init(id: "process", role: .user, text: "Raw process output", displayKind: "process_complete"),
        .init(id: "quiet", role: .assistant, text: "[SILENT]")
    ]
    let preview = ConversationPreview.latest(in: messages)
    #expect(preview?.messageID == "answer")
    #expect(preview?.text == "The report is ready.")
    #expect(preview?.timestamp == at)
    #expect(messages.last?.text == "[SILENT]")
}

@Test func conversationPreviewPreservesErrorsAndAttachmentsWithoutControlText() {
    let photo = ChatAttachment(name: "result.png", path: "/private/result.png", mimeType: "image/png")
    #expect(ConversationPreview(message: .init(id: "partial", role: .assistant, text: "[SI", isSilent: true)) == nil)
    #expect(ConversationPreview(message: .init(id: "photo", role: .assistant, text: "[SILENT]", attachments: [photo]))?.text == "Shared a photo")
    #expect(ConversationPreview(message: .init(id: "error", role: .assistant, text: "[SILENT]", displayKind: "failed_turn"))?.text == "Reply failed")
    #expect(ConversationPreview(message: .init(id: "empty-error", role: .assistant, text: "", displayKind: "failed_turn"))?.text == "Reply failed")
    #expect(ConversationPreview(message: .init(id: "file", role: .user, text: "", attachments: [.init(name: "report.pdf", path: "/private/report.pdf")]))?.text == "Shared a file")
}

@MainActor @Test(arguments: ["", "Please inspect this photo."])
func conversationPreviewUsesTheUserAttachmentDisplay(caption: String) async throws {
    let reference = HermesAttachment.imageReference("/private/attachments/photo.png")
    let raw = caption.isEmpty ? reference : caption + "\n\n" + reference
    let message = ChatMessage(id: "photo", role: .user, text: raw)
    let expected = caption.isEmpty ? "Shared a photo" : caption
    #expect(ConversationPreview(message: message)?.text == expected)
    #expect(message.text == raw && message.attachments.isEmpty)

    let host = try HermesTestHost(authority: false), service = host.service()
    defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let identity = try #require(try await service.conversations(profile: ExactID(host.bot.id)).summaries.first).identity
    let original = host.transport.handler
    host.transport.handler = { request in
        if request.url?.path.hasSuffix("/messages") == true {
            return previewPage(host: host, offset: 0, rows: [.object([
                "id": .number(1), "role": .string("user"), "content": .string(raw)])])
        }
        return try original?(request) ?? .object([:])
    }
    let read = try await service.recentConversationHistory(identity)
    #expect(read != nil && read?.preview?.text == expected)
    #expect(read?.messages.first?.text == raw)
}

@Test func conversationPreviewUsesAttributedContentAndSafeFailureTitles() throws {
    let dm = ChatMessage(id: "dm", role: .user, text: "Message from 🤖 Gustavo (@hermes): The service is healthy.", displayKind: "internal_notification")
    #expect(ConversationPreview(message: dm)?.text == "The service is healthy.")
    for kind in ["internal_notification", "process_complete", "async_delegation_complete"] {
        let routine = ChatMessage(id: "routine", role: .user, text: "Internal diagnostic payload", displayKind: kind)
        #expect(ConversationPreview(message: routine) == nil)
    }
    let process = ChatMessage(id: "failure", role: .user, text: "Command and diagnostic dump", displayKind: "process_complete", displayText: "Background process failed\nDetails: /private/output")
    #expect(ConversationPreview(message: process)?.text == "Background process failed")
    let agent = ChatMessage(id: "agent-failure", role: .user, text: "Internal task payload", displayKind: "async_delegation_complete", displayText: "Subagent task failed: report")
    #expect(ConversationPreview(message: agent)?.text == "Subagent task failed: report")
    let reply = ChatMessage(id: "summary", role: .assistant, text: "Scheduled result: the service needs attention.")
    let preview = try #require(ConversationPreview(message: reply))
    #expect(preview.text == reply.text)
    #expect(try JSONDecoder().decode(ConversationPreview.self, from: JSONEncoder().encode(preview)) == preview)
}

@MainActor @Test(arguments: [true, false])
func recentHistoryReadsNewestWindowWithoutChangingTheLiveAttachment(authority: Bool) async throws {
    let host = try HermesTestHost(authority: authority), service = host.service()
    defer { service.disconnect() }
    let profile = try ExactID(host.bot.id)
    _ = try await service.connect(configuration: host.configuration)
    let directory = try await service.conversations(profile: profile)
    let identity = try #require(directory.summaries.first { $0.isCanonical }?.identity)
    let opened = try await service.openChat(.stored(identity))
    let original = host.transport.handler
    var offsets: [Int] = []
    host.transport.handler = { request in
        if request.url?.path == "/api/sessions/\(host.root)/messages" {
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            #expect(query.contains { $0.name == "order" && $0.value == "latest" })
            #expect(query.contains { $0.name == "inline_images" && $0.value == "false" })
            #expect(query.contains { $0.name == "include_compacted" && $0.value == "true" })
            let offset = Int(query.first { $0.name == "offset" }!.value!)!
            offsets.append(offset)
            let rows: [HermesJSON] = [previewRow(1, text: "The report is **ready**.", timestamp: 123)]
                + (101...200).map { previewRow($0, text: "[SILENT]") }
            return previewPage(host: host, offset: offset, rows: rows)
        }
        return try original?(request) ?? .object([:])
    }
    let methods = host.sockets.flatMap(\.sent).map { $0["method"].text }
    var publications = 0
    service.onEvent = { if case .conversation = $0 { publications += 1 } }
    let result = try await service.recentConversationHistory(identity)
    #expect(result?.preview?.text == "The report is ready.")
    #expect(result?.preview?.timestamp == Date(timeIntervalSince1970: 123))
    #expect(result?.messages.count == 101)
    #expect(result?.messages.first?.text == "The report is **ready**.")
    #expect(result?.messages.first?.id == host.root + ":row:1")
    #expect(result?.messages.last?.id == host.root + ":row:200")
    #expect(result?.messages.dropFirst().allSatisfy { $0.text == "[SILENT]" } == true)
    #expect(result?.hasEarlierMessages == false)
    let proof = try #require(result?.identityRead)
    #expect(proof.matches(identity))
    #expect(proof.messageIDs == Set(try #require(result).messages.map { Data($0.id.utf8) }))
    #expect(offsets == [0])
    #expect(host.sockets.flatMap(\.sent).map { $0["method"].text } == methods)
    #expect(publications == 0)
    try service.validate(opened.access)
}

@MainActor @Test(arguments: ["budget", "exhausted", "omitted", "truncated"])
func conversationPreviewDistinguishesBoundedUnknownFromKnownAbsence(condition: String) async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let identity = try #require(try await service.conversations(profile: ExactID(host.bot.id)).summaries.first).identity
    let original = host.transport.handler
    var offsets: [Int] = []
    host.transport.handler = { request in
        if request.url?.path.hasSuffix("/messages") == true {
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let offset = Int(query.first { $0.name == "offset" }!.value!)!
            offsets.append(offset)
            let rows = condition == "budget" ? (1...300).map { previewRow(offset + $0, text: "[SILENT]") }
                : [previewRow(1, text: condition == "exhausted" ? "[SILENT]" : "An incomplete reply")]
            var page = previewPage(host: host, offset: offset, rows: rows)
            if condition == "omitted" { page["messages_omitted"] = .bool(true) }
            if condition == "truncated" {
                var row = rows[0]; row["archived_truncated"] = .bool(true); page["messages"] = .array([row])
            }
            return page
        }
        return try original?(request) ?? .object([:])
    }
    let result = try await service.recentConversationHistory(identity)
    #expect(result?.preview == nil)
    #expect((result != nil) == (condition == "exhausted"))
    #expect(offsets == [0])
}

@MainActor @Test(arguments: ["profile", "session", "paging", "oversized", "negativeID", "missingID"])
func conversationPreviewRejectsMismatchedOrMalformedHistory(condition: String) async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let identity = try #require(try await service.conversations(profile: ExactID(host.bot.id)).summaries.first).identity
    let original = host.transport.handler
    host.transport.handler = { request in
        if request.url?.path.hasSuffix("/messages") == true {
            var page = previewPage(host: host, offset: 0, rows: [previewRow(1, text: "Wrong response must not win")])
            switch condition {
            case "profile": page["profile"] = .string("foreign-profile")
            case "session": page["session_id"] = .string("foreign-session")
            case "paging": page["pagination"]["offset"] = .number(100)
            case "oversized": page["messages"] = .array((1...301).map { previewRow($0, text: "Unexpected surplus") })
            case "negativeID": page["messages"] = .array([previewRow(-1, text: "Invalid identity")])
            case "missingID":
                var row = previewRow(1, text: "Missing identity"); row["id"] = .null
                page["messages"] = .array([row])
            default: break
            }
            return page
        }
        return try original?(request) ?? .object([:])
    }
    do {
        _ = try await service.recentConversationHistory(identity)
        Issue.record("A malformed response must be rejected")
    } catch {
        #expect(error is HermesServiceError, "Unknown shapes prove nothing about cached identities: \(error)")
    }
}

@MainActor @Test func conversationPreviewUsesExistingHistoryDisplayProjection() async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let identity = try #require(try await service.conversations(profile: ExactID(host.bot.id)).summaries.first).identity
    let original = host.transport.handler
    host.transport.handler = { request in
        if request.url?.path.hasSuffix("/messages") == true {
            var modelOnly = previewRow(3, text: "Model-only carrier")
            modelOnly["display_metadata"] = .object(["model_only": .bool(true)])
            var visible = previewRow(1, text: "Provider compaction scaffolding")
            visible["display_content"] = .string("The visible reply")
            return previewPage(host: host, offset: 0, rows: [visible,
                previewRow(2, text: "Hidden carrier", kind: "hidden"), modelOnly,
                .object(["id": .number(4), "role": .string("tool"), "content": .string("Tool diagnostics")]),
                .object(["id": .number(5), "role": .string("user"), "content": .string("Cron scaffolding"), "display_kind": .string("internal_notification")]),
                previewRow(6, text: "[SILENT]")])
        }
        return try original?(request) ?? .object([:])
    }
    let result = try await service.recentConversationHistory(identity)
    #expect(result?.preview?.text == "The visible reply")
    #expect(result != nil)
}

@MainActor @Test func conversationPreviewDoesNotClaimAbsenceBeyondSidecarCompressionTip() async throws {
    let host = try HermesTestHost(authority: false), service = host.service()
    defer { service.disconnect() }
    host.methodOverride = { frame, socket in
        if frame["method"].text == "session.list" {
            return .object(["sessions": .array([.object(["id": .string(host.root), "resolved_id": .string("compressed-tip")])])])
        }
        return host.defaultReply(frame, socket: socket)
    }
    let original = host.transport.handler
    host.transport.handler = { request in
        if request.url?.path == "/api/sessions/compressed-tip/messages" {
            return .object(["session_id": .string("compressed-tip"), "profile": .string(host.bot.id), "messages": .array([])])
        }
        return try original?(request) ?? .object([:])
    }
    _ = try await service.connect(configuration: host.configuration)
    let identity = try #require(try await service.conversations(profile: ExactID(host.bot.id)).summaries.first).identity
    let result = try await service.recentConversationHistory(identity)
    #expect(result?.preview == nil)
    #expect(result == nil)
}

@MainActor @Test(arguments: ["cancel", "connection", "tip"])
func conversationPreviewRejectsResultsAfterItsReadLifetimeEnds(retirement: String) async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let identity = try #require(try await service.conversations(profile: ExactID(host.bot.id)).summaries.first).identity
    let original = host.transport.handler
    var gate: CheckedContinuation<HermesJSON, Error>?
    defer { gate?.resume(throwing: HermesServiceError.disconnected) }
    host.transport.asyncHandler = { request in
        if request.url?.path.hasSuffix("/messages") == true {
            return try await withCheckedThrowingContinuation { gate = $0 }
        }
        return try original?(request) ?? .object([:])
    }
    let read = Task { try await service.recentConversationHistory(identity) }
    try await eventually { gate != nil }
    switch retirement {
    case "cancel": read.cancel()
    case "connection": service.disconnect()
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
    pending?.resume(returning: previewPage(host: host, offset: 0, rows: [previewRow(1, text: "Stale reply"),
        previewRow(1, text: "A stale conflicting reply")]))
    do {
        _ = try await read.value
        Issue.record("A retired read must not return history")
    } catch {
        #expect(!(error is ConversationHistoryPage.Failure), "A retired read proves nothing: \(error)")
    }
}

private func previewRow(_ id: Int, text: String, kind: String? = nil, timestamp: Double? = nil) -> HermesJSON {
    var fields: [String: HermesJSON] = ["id": .number(Double(id)), "role": .string("assistant"), "content": .string(text)]
    if let kind { fields["display_kind"] = .string(kind) }
    if let timestamp { fields["timestamp"] = .number(timestamp) }
    return .object(fields)
}

@MainActor private func previewPage(host: HermesTestHost, offset: Int, rows: [HermesJSON], limit: Int = 300) -> HermesJSON {
    .object(["session_id": .string(host.root), "profile": .string(host.bot.id), "messages": .array(rows),
        "pagination": .object(["limit": .number(Double(limit)), "offset": .number(Double(offset)), "order": .string("latest"),
            "returned": .number(Double(rows.count))])])
}

@MainActor @Test func recentHistoryRetainsExactMessageContentForImmediateChatDisplay() async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let identity = try #require(try await service.conversations(profile: ExactID(host.bot.id)).summaries.first).identity
    let original = host.transport.handler
    let fullReply = "The report is **ready**.\n\n```swift\nlet count = 2\n```"
    host.transport.handler = { request in
        if request.url?.path.hasSuffix("/messages") == true {
            return previewPage(host: host, offset: 0, rows: [
                .object(["id": .number(1), "role": .string("user"), "content": .array([
                    .object(["type": .string("text"), "text": .string("Review the full report")]),
                    .object(["type": .string("image_url"), "image_url": .object(["url": .string("data:image/png;base64,aGVsbG8=")])])])]),
                previewRow(2, text: fullReply),
                .object(["id": .number(3), "role": .string("tool"), "content": .string("Diagnostic details")])])
        }
        return try original?(request) ?? .object([:])
    }
    let result = try #require(try await service.recentConversationHistory(identity))
    #expect(result.messages.map(\.text) == ["Review the full report", fullReply, "Diagnostic details"])
    #expect(result.messages.map(\.id) == [host.root + ":row:1", host.root + ":row:2", host.root + ":row:3"])
    #expect(result.messages.first?.attachments == [ChatAttachment(name: "Image.png", path: host.root + ":row:1:image:1", mimeType: "image/png")])
    #expect(!result.hasEarlierMessages)
    #expect(result.preview?.messageID == host.root + ":row:2")
}

@MainActor @Test(arguments: ["visible", "hidden", "omitted", "truncated", "paging", "oversized", "invalidRow"])
func recentHistoryReportsDuplicateRawIdentitiesAsScopedEvidence(shape: String) async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let identity = try #require(try await service.conversations(profile: ExactID(host.bot.id)).summaries.first).identity
    let original = host.transport.handler
    host.transport.handler = { request in
        if request.url?.path.hasSuffix("/messages") == true {
            var rows = [previewRow(1, text: "One occurrence", kind: shape == "hidden" ? "hidden" : nil),
                previewRow(2, text: "An unrelated row"), previewRow(1, text: "A conflicting occurrence")]
            if shape == "truncated" { rows[1]["archived_truncated"] = .bool(true) }
            if shape == "invalidRow" { rows.append(previewRow(-1, text: "Invalid identity")) }
            if shape == "oversized" { rows += (3...300).map { previewRow($0, text: "Surplus") } }
            var page = previewPage(host: host, offset: 0, rows: rows)
            if shape == "omitted" { page["messages_omitted"] = .bool(true) }
            if shape == "paging" { page["pagination"]["offset"] = .number(100) }
            return page
        }
        return try original?(request) ?? .object([:])
    }
    do {
        _ = try await service.recentConversationHistory(identity)
        Issue.record("A duplicate raw identity must reject the window")
    } catch let failure as ConversationHistoryPage.Failure {
        #expect(failure.identity == identity)
        #expect(failure.unavailableMessageIDs == [Data((identity.stored.text + ":row:1").utf8)])
        #expect(failure.sourceIDs.isEmpty, "An observed dispute says nothing about the window's other rows")
        #expect(!failure.exceedsRowLimit)
    } catch {
        Issue.record("A duplicate must stay structured evidence instead of \(error)")
    }
}

@MainActor @Test(arguments: ["beyondWindow", "foreignProfile", "foreignSession"])
func recentHistoryOffersNoDisputeWithoutBoundedAssociatedEvidence(condition: String) async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let identity = try #require(try await service.conversations(profile: ExactID(host.bot.id)).summaries.first).identity
    let original = host.transport.handler
    host.transport.handler = { request in
        if request.url?.path.hasSuffix("/messages") == true {
            var page = previewPage(host: host, offset: 0, rows: [previewRow(1, text: "One"), previewRow(1, text: "Two")])
            switch condition {
            case "beyondWindow":
                page["messages"] = .array((1...300).map { previewRow($0, text: "Inside") } + [previewRow(1, text: "Outside")])
            case "foreignProfile": page["profile"] = .string("foreign-profile")
            default: page["session_id"] = .string("foreign-session")
            }
            return page
        }
        return try original?(request) ?? .object([:])
    }
    do {
        _ = try await service.recentConversationHistory(identity)
        Issue.record("The response must be rejected")
    } catch {
        #expect(error is HermesServiceError, "Only bounded rows of this exact source can dispute it: \(error)")
    }
}

@MainActor @Test(arguments: ["authorityComplete", "authorityBounded", "sidecarComplete", "sidecarCompressed"])
func recentHistoryDistinguishesNewestWindowFromExhaustiveHistory(condition: String) async throws {
    let host = try HermesTestHost(authority: condition.hasPrefix("authority")), service = host.service()
    defer { service.disconnect() }
    if condition == "sidecarCompressed" {
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
            let count = condition == "authorityBounded" ? 300 : 1
            var page = previewPage(host: host, offset: 0, rows: (1...count).map { previewRow($0, text: "A readable reply") })
            page["session_id"] = .string(identity.stored.text)
            return page
        }
        return try original?(request) ?? .object([:])
    }
    let result = try #require(try await service.recentConversationHistory(identity))
    #expect(result.hasEarlierMessages == (condition == "authorityBounded" || condition == "sidecarCompressed"))
    if result.hasEarlierMessages { #expect(result.identityRead == nil) }
    else {
        let proof = try #require(result.identityRead)
        #expect(proof.matches(identity))
        #expect(proof.messageIDs == Set(result.messages.map { Data($0.id.utf8) }))
    }
    #expect(result.messages.last?.text == "A readable reply")
}

@MainActor @Test func recentHistoryUsesOneNewestWindowWhenOffsetPagesCouldMove() async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let identity = try #require(try await service.conversations(profile: ExactID(host.bot.id)).summaries.first).identity
    let original = host.transport.handler
    var offsets: [Int] = []
    host.transport.handler = { request in
        if request.url?.path.hasSuffix("/messages") == true {
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let requestedLimit = query.first { $0.name == "limit" }?.value
            let offset = Int(query.first { $0.name == "offset" }!.value!)!
            #expect(requestedLimit == "300")
            offsets.append(offset)
            // Deletion between offset reads would shift the older page without necessarily duplicating IDs.
            let rows = offset == 0 ? (1...300).map { previewRow($0, text: $0 == 1 ? "The retained reply" : "[SILENT]") }
                : [previewRow(301, text: "A shifted older page")]
            return previewPage(host: host, offset: offset, rows: rows, limit: 300)
        }
        return try original?(request) ?? .object([:])
    }
    let result = try #require(try await service.recentConversationHistory(identity))
    #expect(offsets == [0])
    #expect(result.messages.count == 300)
    #expect(result.messages.first?.id == host.root + ":row:1")
    #expect(result.messages.last?.id == host.root + ":row:300")
    #expect(result.preview?.text == "The retained reply")
    #expect(result.hasEarlierMessages)
}
