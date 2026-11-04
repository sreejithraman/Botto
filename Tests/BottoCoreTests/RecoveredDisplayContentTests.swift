import Foundation
import Testing
@testable import BottoCore

// Source-backed wire fixtures, not captured traffic. Hermes 4a0eaf79
// hermes_cli/web_routers/sessions.py:_project_for_display keeps physical rows in `content` and
// adds `display_content`; tests/hermes_cli/test_sessions_rest_scaffold_notices.py pins that shape.
// ca678285 emits the compaction case only.
private let summary = "[CONTEXT COMPACTION — REFERENCE ONLY] Earlier turns were compacted."
private let recoveredAsk = "Can you check the parser?"
private let compactionCarrier = "[PRIOR CONTEXT — for reference only; not a new message]\n\(recoveredAsk)\n\n"
    + "[END OF PRIOR CONTEXT — COMPACTION SUMMARY BELOW]\n\(summary)"
private let steerWords = "focus on the parser bug"
private let steerCarrier = "[OUT-OF-BAND USER MESSAGE]\n\(steerWords)\n[/OUT-OF-BAND USER MESSAGE]"
private let image = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGBgAAAABQABpfZFQAAAAABJRU5ErkJggg=="
private let imagePart: HermesJSON = .object(["type": .string("image_url"), "image_url": .object(["url": .string(image)])])

private func row(_ id: Int, _ role: String, _ content: HermesJSON, display: HermesJSON? = nil,
                 kind: String? = nil, extra: [String: HermesJSON] = [:]) -> HermesJSON {
    var fields = extra
    fields["id"] = .number(Double(id)); fields["role"] = .string(role); fields["content"] = content
    if let display { fields["display_content"] = display }
    if let kind { fields["display_kind"] = .string(kind) }
    return .object(fields)
}

private func message(_ row: HermesJSON) throws -> ChatMessage {
    try #require(HermesConversationState.messages([row], stored: "chat").first)
}

@Test func recoveredDisplayReplacesScaffoldingWhereverTheMessageIsRead() throws {
    let ask = try message(row(1, "user", .string(compactionCarrier), display: .string(recoveredAsk)))
    #expect(ask.text == recoveredAsk)
    #expect(ask.role == .user && ask.isOutgoingUserMessage && ask.isVisible)
    #expect(AttachmentPresentation.display(ask).text == recoveredAsk)
    #expect(ConversationPreview(message: ask)?.text == recoveredAsk)

    let steer = try message(row(2, "user", .string(steerCarrier), display: .string(steerWords), kind: "steer"))
    #expect(steer.text == steerWords)
    #expect(steer.displayKind == "steer")

    let reply = try message(row(3, "assistant", .string(compactionCarrier), display: .string(recoveredAsk)))
    #expect(ReplyContent(message: reply).canonicalText == recoveredAsk)
}

@Test func ordinaryRowsKeepTheirCanonicalTextAndMetadata() throws {
    #expect(try message(row(1, "user", .string("Plain words"))).text == "Plain words")
    #expect(try message(row(2, "assistant", .string("From content"), extra: ["text": .string("From text")])).text == "From text")
    #expect(try message(row(3, "assistant", .array([.object(["type": .string("text"), "text": .string("Part")])]))).text == "Part")
    // `display_text` titles a notification; it stays separate from the row's visible text.
    let notice = try message(row(4, "user", .string("Raw job output"), kind: "process_complete",
        extra: ["display_metadata": .object(["display_text": .string("Background process finished")])]))
    #expect(notice.text == "Raw job output")
    #expect(notice.displayText == "Background process finished")
    let ask = try message(row(5, "user", .string(compactionCarrier), display: .string(recoveredAsk)))
    #expect(ask.displayText == nil)
}

@Test func displayContentKeepsAttachmentsAndIdentityFromTheCanonicalRow() throws {
    let content: HermesJSON = .array([.object(["type": .string("text"), "text": .string(steerCarrier)]), imagePart])
    let canonical = try message(row(7, "user", content))
    let projected = try message(row(7, "user", content, display: .string(steerWords), kind: "steer"))
    #expect(projected.id == "chat:row:7")
    #expect(projected.id == canonical.id)
    #expect(projected.text == steerWords)
    #expect(projected.attachments.count == 1)
    #expect(projected.attachments == canonical.attachments)
    #expect(projected.attachments.first?.path == "chat:row:7:image:1")
}

@Test func structuredDisplayContentOmitsItsImageParts() throws {
    // ca678285 has no inline_images projection, so a merged carrier's display view keeps its list shape.
    let content: HermesJSON = .array([imagePart, .object(["type": .string("text"), "text": .string(compactionCarrier)])])
    let display: HermesJSON = .array([imagePart, .object(["type": .string("text"), "text": .string(recoveredAsk)])])
    let projected = try message(row(7, "user", content, display: display))
    #expect(projected.text == recoveredAsk)
    #expect(projected.attachments.first?.path == "chat:row:7:image:0")
}

@Test func toolResultsStayCanonicalBecauseHermesProjectsOnlyChatRows() throws {
    // 4a0eaf79 Desktop hydration reads stored tool rows before it considers display_content.
    let result = try message(row(4, "tool", .string("{\"ok\":true}"), display: .string("Summary")))
    #expect(result.text == "{\"ok\":true}")
}

@Test func displayContentNeverRevealsAHiddenOrModelOnlyRow() {
    let hidden = row(1, "user", .string(summary), display: .string("Hidden words"), kind: "hidden")
    let modelOnly = row(2, "user", .string(summary), display: .string("Merged words"),
                        extra: ["display_metadata": .object(["model_only": .bool(true)])])
    #expect(HermesConversationState.messages([hidden, modelOnly], stored: "chat").isEmpty)
}

@Test func emptyDisplayContentIsHonoredRatherThanFallingBackToScaffolding() throws {
    let toolCall = row(1, "assistant", .string(summary), display: .string(""), extra: ["tool_calls": .array([])])
    #expect(HermesConversationState.messages([toolCall], stored: "chat").isEmpty)
    let empty = try message(row(2, "assistant", .string(summary), display: .string("")))
    #expect(empty.text.isEmpty)
    let photo = try message(row(3, "user", .array([imagePart]), display: .string("")))
    #expect(photo.text.isEmpty && photo.attachments.count == 1)
}

@Test func replyClassificationFollowsTheVisibleText() throws {
    let silent = try message(row(1, "assistant", .string("Provider commentary"), display: .string("[SILENT]")))
    #expect(silent.isSilent == true && !silent.isVisible)
    let spoken = try message(row(2, "assistant", .string("[SILENT]"), display: .string("Visible reply")))
    #expect(spoken.isSilent == false && spoken.isVisible)
    let failed = try message(row(3, "assistant", .string(summary), display: .string("Partial reply"),
                                 extra: ["status": .string("failed")]))
    #expect(failed.displayKind == "failed_turn" && failed.text == "Partial reply")
}

@Test func canonicalTextIsWhatTheRowReadsAsWithoutItsProjection() throws {
    let caption = "\(steerCarrier)\n\n[Image attached at: /home/u/scan.png]"
    let contents: [(HermesJSON, [String: HermesJSON])] = [
        (.string(compactionCarrier), [:]),
        (.string("Ignored content"), ["text": .string(compactionCarrier)]),
        (.array([.object(["type": .string("text"), "text": .string(caption)]), imagePart]), [:]),
        (.array([.object(["type": .string("text"), "text": .string("One")]), .object(["type": .string("text"), "text": .string("Two")])]), [:]),
        (.array([imagePart]), [:])]
    for (content, extra) in contents {
        let unprojected = try message(row(7, "user", content, extra: extra))
        let projected = try message(row(7, "user", content, display: .string("Shown"), extra: extra))
        #expect(projected.text == "Shown")
        #expect(projected.canonicalText?.utf8.elementsEqual(unprojected.text.utf8) == true)
        #expect(unprojected.canonicalText == nil)
        #expect(projected.attachments == unprojected.attachments)
        #expect(projected.id == unprojected.id)
    }
}

@Test func canonicalTextKeepsAnExplicitlyEmptyProjectionDistinctFromNoProjection() throws {
    let empty = try message(row(1, "assistant", .string(summary), display: .string("")))
    #expect(empty.text.isEmpty && empty.canonicalText == summary)
    let emptyCanonical = try message(row(2, "assistant", .string(""), display: .string("Shown")))
    #expect(emptyCanonical.text == "Shown" && emptyCanonical.canonicalText == "")
    let cleared = try message(row(3, "assistant", .string(""), display: .string("")))
    #expect(cleared.text.isEmpty && cleared.canonicalText == nil)
}

@Test func canonicalTextIsOmittedOnlyWhenBytesMatch() throws {
    #expect(try message(row(1, "user", .string(recoveredAsk), display: .string(recoveredAsk))).canonicalText == nil)
    // Swift String equality would treat these as the same text.
    let composed = "caf\u{E9}", decomposed = "cafe\u{301}"
    let projected = try message(row(2, "user", .string(decomposed), display: .string(composed)))
    #expect(projected.text.utf8.elementsEqual(composed.utf8))
    #expect(projected.canonicalText?.utf8.elementsEqual(decomposed.utf8) == true)
}

@Test func toolAndLiveRowsCarryNoCanonicalCopy() throws {
    #expect(try message(row(1, "tool", .string("{}"), display: .string("Summary"))).canonicalText == nil)
    var state = HermesConversationState(profile: "bot", root: "stored", stored: "stored", runtime: "runtime", epoch: "epoch")
    state.setStream("Live")
    #expect(state.conversation.messages.map(\.canonicalText) == [nil])
}

@Test func canonicalTextSurvivesCodableAndDistinguishesRevisions() throws {
    let projected = try message(row(1, "user", .string(compactionCarrier), display: .string(""),
        extra: ["display_metadata": .object(["display_text": .string("Title")])]))
    let restored = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(projected))
    #expect(restored == projected)
    #expect(restored.text.isEmpty && restored.canonicalText == compactionCarrier && restored.displayText == "Title")

    var changed = projected
    changed.canonicalText = "Different scaffolding"
    #expect(changed != projected)
}

@Test func ordinaryMessagesEncodeExactlyAsBeforeAndLegacyCachesDecode() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let ordinary = try message(row(1, "assistant", .string("Plain")))
    #expect(String(decoding: try encoder.encode(ordinary), as: UTF8.self)
        == #"{"attachments":[],"id":"chat:row:1","isSilent":false,"role":"assistant","text":"Plain"}"#)

    let legacy = Data(#"{"id":"old","role":"user","text":"Saved words","attachments":[],"displayText":"Title"}"#.utf8)
    let decoded = try JSONDecoder().decode(ChatMessage.self, from: legacy)
    #expect(decoded.canonicalText == nil)
    #expect(decoded.text == "Saved words" && decoded.displayText == "Title")
}

@Test func retainedTextBytesChargeEveryRetainedUTF8ByteOnce() throws {
    func bytes(_ text: String, _ canonicalText: String? = nil) -> Int {
        ChatMessage(id: "row", role: .user, text: text, canonicalText: canonicalText).retainedTextBytes
    }
    #expect(bytes("") == 0)
    #expect(bytes("four") == 4)
    #expect(bytes("four", "") == 4)
    #expect(bytes("", "four") == 4)
    #expect(bytes("four", "four") == 8)
    // Bytes, not characters: these two render alike and cost 2 and 3 bytes.
    #expect(bytes("\u{E9}") == 2)
    #expect(bytes("e\u{301}") == 3)
    #expect(bytes("\u{E9}", "e\u{301}") == 5)
    #expect(bytes("\u{1F916}", "\u{1F916}") == 8)

    let ordinary = try message(row(1, "user", .string("Plain words")))
    #expect(ordinary.retainedTextBytes == "Plain words".utf8.count)
    let cleared = try message(row(2, "user", .string(compactionCarrier), display: .string("")))
    #expect(cleared.retainedTextBytes == compactionCarrier.utf8.count)
    let projected = try message(row(3, "user", .string(compactionCarrier), display: .string(recoveredAsk)))
    #expect(projected.retainedTextBytes == recoveredAsk.utf8.count + compactionCarrier.utf8.count)
    let identical = try message(row(4, "user", .string(recoveredAsk), display: .string(recoveredAsk)))
    #expect(identical.retainedTextBytes == recoveredAsk.utf8.count)
}

@Test func presentationAndDiscoveryNeverReadCanonicalText() throws {
    let scaffolding = "MEDIA:/home/u/handoff-summary.pdf"
    let control = try message(row(1, "assistant", .string(scaffolding)))
    #expect(ArtifactDiscovery.artifacts(in: [control]).count == 1)

    let projected = try message(row(1, "assistant", .string(scaffolding), display: .string("Visible reply")))
    #expect(ArtifactDiscovery.artifacts(in: [projected]).isEmpty)
    #expect(ReplyContent(message: projected).blocks.map(\.source) == ["Visible reply"])
    #expect(AttachmentPresentation.display(projected).text == "Visible reply")
    #expect(ConversationPreview(message: projected)?.text == "Visible reply")
    #expect(projected.attributedText == "Visible reply")
    #expect(projected.notificationPresentation == nil)

    let silent = try message(row(2, "assistant", .string("Canonical words"), display: .string("[SILENT]")))
    #expect(ConversationPreview(message: silent) == nil)
}

private func recoveredRows() -> [HermesJSON] {
    [row(1, "user", .string("First words")),
     row(2, "user", .string(summary), kind: "hidden"),
     row(3, "user", .string(compactionCarrier), display: .string(recoveredAsk)),
     row(4, "user", .string(steerCarrier), display: .string(steerWords), kind: "steer"),
     row(5, "user", .string(summary), extra: ["display_metadata": .object(["model_only": .bool(true)])]),
     row(6, "assistant", .string("Latest reply"))]
}

private func expectRecoveredTranscript(_ chat: Conversation?) {
    #expect(chat?.messages.map(\.id) == [1, 3, 4, 6].map { "\(chat?.storedID ?? ""):row:\($0)" })
    #expect(chat?.messages.map(\.text) == ["First words", recoveredAsk, steerWords, "Latest reply"])
    #expect(chat?.messages.map(\.role) == [.user, .user, .user, .assistant])
    #expect(chat?.messages[2].displayKind == "steer")
    #expect(chat?.messages.map(\.canonicalText) == [nil, compactionCarrier, steerCarrier, nil])
}

@MainActor @Test(arguments: [false, true])
func restoredTranscriptUsesRestDisplayContentAcrossReconnect(authority: Bool) async throws {
    let host = try HermesTestHost(authority: authority), service = host.service()
    defer { service.disconnect() }
    // The sidecar always reads REST; authority does when its snapshot withholds rows.
    host.snapshot["messages_omitted"] = .bool(true)
    host.snapshot["messages"] = .array([])
    let original = host.transport.handler
    var historyReads = 0
    host.transport.handler = { request in
        guard request.url?.path == "/api/sessions/\(host.root)/messages" else { return try original?(request) ?? .object([:]) }
        historyReads += 1
        return .object(["session_id": .string(host.root), "profile": .string(host.bot.id), "messages": .array(recoveredRows())])
    }
    var latest: Conversation?
    var recovered = false
    service.onEvent = {
        if case .conversation(let publication) = $0 { let chat = publication.snapshot; latest = chat }
        if case .connected = $0 { recovered = true }
    }
    _ = try await service.connect(configuration: host.configuration)
    let chat = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    expectRecoveredTranscript(chat.snapshot)
    #expect(historyReads == 1)

    host.sockets[0].close()
    try await eventually { recovered && historyReads == 2 }
    try await eventually { latest?.messages.count == 4 }
    expectRecoveredTranscript(latest)
}

@MainActor @Test func runningRestoreAndReplayLeaveAProjectedRowsCanonicalTextAlone() async throws {
    // ca678285 session.resume inflight fields; REST supplies the persisted row by its id.
    let host = try HermesTestHost(authority: false), service = host.service()
    defer { service.disconnect() }
    host.snapshot["messages_omitted"] = .bool(true)
    host.snapshot["messages"] = .array([])
    host.snapshot["running"] = .bool(true)
    host.snapshot["inflight"] = .object(["user": .string(recoveredAsk), "user_row_id": .number(3), "assistant": .string("He"),
        "display_metadata": .object(["display_text": .string("Host title")])])
    host.replay["events"] = .array([host.event("message.delta", seq: 1, payload: ["text": .string("He")])["params"]])
    host.replay["latest_seq"] = .number(1)
    let original = host.transport.handler
    host.transport.handler = { request in
        guard request.url?.path == "/api/sessions/\(host.root)/messages" else { return try original?(request) ?? .object([:]) }
        return .object(["session_id": .string(host.root), "profile": .string(host.bot.id),
            "messages": .array([row(3, "user", .string(compactionCarrier), display: .string(recoveredAsk))])])
    }
    var latest: Conversation?
    service.onEvent = { if case .conversation(let publication) = $0 { let chat = publication.snapshot; latest = chat } }
    _ = try await service.connect(configuration: host.configuration)
    let chat = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    let stored = chat.snapshot.storedID
    let user = try #require(chat.snapshot.messages.first { $0.role == .user })
    #expect(chat.snapshot.messages.filter { $0.role == .user }.count == 1)
    #expect(user.id == stored + ":row:3")
    #expect(user.text == recoveredAsk && user.canonicalText == compactionCarrier)
    #expect(user.displayText == "Host title")

    host.sockets[0].push(host.event("message.delta", seq: 2, payload: ["text": .string("llo")]))
    try await eventually { latest?.messages.last?.text == "Hello" }
    #expect(latest?.messages.first == user)
    #expect(latest?.messages.last?.canonicalText == nil)
}

@MainActor @Test func everyHistoryReadProjectsTheSameRowTheSameWay() async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let identity = try #require(try await service.conversations(profile: ExactID(host.bot.id)).summaries.first).identity
    let stored = identity.stored.text
    let content: HermesJSON = .array([.object(["type": .string("text"), "text": .string(steerCarrier)]), imagePart])
    let steer = row(9, "user", content, display: .string(steerWords), kind: "steer")
    let expected = try #require(HermesConversationState.messages([steer], stored: stored).first)
    #expect(expected.attachments.count == 1)
    #expect(expected.canonicalText == steerCarrier)
    let original = host.transport.handler
    host.transport.handler = { request in
        guard request.url?.path.hasSuffix("/messages") == true else { return try original?(request) ?? .object([:]) }
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        let limit = Double(query.first { $0.name == "limit" }!.value!)!
        return .object(["session_id": .string(stored), "profile": .string(identity.profile.text), "messages": .array([steer]),
            "pagination": .object(["limit": .number(limit), "offset": .number(0), "order": .string("latest"), "returned": .number(1)])])
    }
    let page = try await service.conversationHistory(identity, offset: 0)
    #expect(page.messages == [expected])
    #expect(page.identityRead?.messageIDs == [Data(expected.id.utf8)])
    let window = try await service.recentConversationHistory(identity)
    #expect(window?.messages == [expected])
    #expect(window?.identityRead?.messageIDs == [Data(expected.id.utf8)])
    #expect(window?.preview?.text == steerWords)
}
