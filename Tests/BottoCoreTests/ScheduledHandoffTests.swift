import Foundation
import Testing
@testable import BottoCore

struct ScheduledHandoffTests {
    static let wrapper = "[Cronjob \"Mac service incident diagnosis\" output — scheduled job, not the user. Review it, act on anything that needs action, and summarize for the chat.]\n\n"

    @Test func verifiedHandoffKeepsRawPayloadAndChronology() throws {
        let payload = Self.wrapper + String(repeating: "{\"diagnostic\":\"service health\",\"ack\":\"inspect-only\"}\n", count: 5000)
        let rows: [HermesJSON] = [
            .object(["row_id": .number(7), "role": .string("user"), "content": .string(payload),
                     "display_kind": .string("internal_notification"), "timestamp": .number(100)]),
            .object(["row_id": .number(8), "role": .string("assistant"), "content": .string("The service recovered. No action is needed."), "timestamp": .number(105)])
        ]
        let messages = HermesConversationState.messages(rows, stored: "bot-a")
        #expect(messages.count == 2)
        #expect(messages[0].scheduledJobName == "Mac service incident diagnosis")
        #expect(!messages[0].requiresAttention)
        #expect(messages[0].text == payload)
        #expect(messages[0].timestamp == Date(timeIntervalSince1970: 100))
        #expect(messages[1].requiresAttention)
        #expect(messages[1].isVisible)
        #expect(messages.map(\.id) == ["bot-a:row:7", "bot-a:row:8"])
        #expect(try JSONDecoder().decode([ChatMessage].self, from: JSONEncoder().encode(messages)) == messages)
    }
    @Test(arguments: [nil, "user", "cron", "unknown"] as [String?])
    func humanPasteNeverEstablishesProvenance(_ kind: String?) {
        let message = ChatMessage(id: "human", role: .user, text: Self.wrapper + "{\"cron\":true}", displayKind: kind)
        #expect(message.scheduledJobName == nil)
        #expect(message.requiresAttention && message.isVisible)
    }

    static let unknownWrappers: [String] = ["Let's discuss cron and scheduled jobs: {}", "> " + wrapper + "payload",
        "```\n" + wrapper + "payload\n```", " " + wrapper + "payload", wrapper,
        wrapper.replacingOccurrences(of: "Cronjob", with: "Cron task") + "payload",
        wrapper.replacingOccurrences(of: "\n\n", with: "\n") + "payload",
        wrapper.replacingOccurrences(of: "Mac service incident diagnosis", with: "") + "payload",
        wrapper.replacingOccurrences(of: "Mac service incident diagnosis", with: "one\ntwo") + "payload"]

    @Test(arguments: unknownWrappers)
    func unknownAndMalformedWrappersStayVisible(_ text: String) {
        let message = ChatMessage(id: "unknown", role: .user, text: text, displayKind: "internal_notification")
        #expect(message.scheduledJobName == nil)
        #expect(message.requiresAttention)
    }

    @Test(arguments: ["[SILENT]", " no_reply ", "NO REPLY", "**[SILENT]**", "静默。", "[沉默]"])
    func successfulInternalSilenceIsRetainedWithoutBubble(_ marker: String) {
        let rows: [HermesJSON] = [
            .object(["role": .string("user"), "content": .string(Self.wrapper + "Routine check"), "display_kind": .string("internal_notification")]),
            .object(["role": .string("assistant"), "content": .string(marker)])]
        let messages = HermesConversationState.messages(rows, stored: "bot")
        #expect(messages.count == 2)
        #expect(messages[1].text == marker)
        #expect(!messages[1].isVisible && !messages[1].requiresAttention)
    }

    @Test(arguments: ["The marker [SILENT] means no reply.", "NO_REPLY is a control token.", "[SILENT] Service failed", "[SILENT", "", "Silent retry succeeded"])
    func ordinaryProseAndMalformedSilenceRemainVisible(_ text: String) {
        let rows: [HermesJSON] = [
            .object(["role": .string("user"), "content": .string(Self.wrapper + "Check"), "display_kind": .string("internal_notification")]),
            .object(["role": .string("assistant"), "content": .string(text)])]
        #expect(HermesConversationState.messages(rows, stored: "bot").last?.isVisible == true)
    }

    @Test func humanInputStillAllowsControlRepliesWhileFailedTurnsStayVisible() {
        let human: [HermesJSON] = [
            .object(["role": .string("user"), "content": .string(Self.wrapper + "Pasted by human")]),
            .object(["role": .string("assistant"), "content": .string("[SILENT]")])]
        #expect(HermesConversationState.messages(human, stored: "bot").map(\.isVisible) == [true, false])
        var failed = human
        failed[0]["display_kind"] = .string("internal_notification")
        failed[1]["display_kind"] = .string("failed_turn")
        #expect(HermesConversationState.messages(failed, stored: "bot").last?.isVisible == true)
        failed[1]["display_kind"] = .null
        failed[1]["display_metadata"] = .object(["error": .string("provider failure")])
        #expect(HermesConversationState.messages(failed, stored: "bot").last?.isVisible == true)
        failed[1]["display_metadata"] = .null
        failed[1]["status"] = .string("error")
        #expect(HermesConversationState.messages(failed, stored: "bot").last?.isVisible == true)
    }

    @Test func liveSilentCandidateDivergesToProseAndFailureRemainsVisible() {
        var state = HermesConversationState(profile: "bot", root: "stored", stored: "stored", runtime: "runtime", epoch: "epoch")
        func event(_ type: String, _ payload: [String: HermesJSON]) -> HermesJSON {
            .object(["type": .string(type), "payload": .object(payload)])
        }
        state.reduce(event("message.start", ["display_kind": .string("internal_notification")]), authority: true)
        state.reduce(event("message.delta", ["text": .string("NO")]), authority: true)
        #expect(state.conversation.visibleMessages.last?.text == "NO")
        state.reduce(event("message.delta", ["text": .string("_REPLY means intentional silence.")]), authority: true)
        #expect(state.conversation.visibleMessages.last?.text == "NO_REPLY means intentional silence.")
        state.reduce(event("message.complete", ["text": .string("[SILENT]"), "status": .string("error")]), authority: true)
        #expect(state.conversation.messages.contains { $0.text == "[SILENT]" && $0.isVisible })
        #expect(state.conversation.messages.contains { $0.role == .system && $0.requiresAttention })
        state.reduce(event("approval.request", ["prompt_id": .string("approval"), "kind": .string("approval"), "command": .string("restart service")]), authority: true)
        #expect(state.conversation.pendingRequests.first?.kind == .approval)
    }

    @Test(arguments: [false, true])
    func queuedHandoffRetainsHostProvenanceWhenItStarts(existingEcho: Bool) {
        var state = HermesConversationState(profile: "bot", root: "stored", stored: "stored", runtime: "runtime", epoch: "epoch")
        let prior = ChatMessage(id: "prior", role: .assistant, text: "Earlier reply")
        state.conversation.messages = [prior]
        let text = Self.wrapper + "Routine check"
        if existingEcho { state.addSubmittedText(text, submission: "automation-input") }
        state.applyPending(.array([.object([
            "admission_id": .string("automation-admission"), "input_id": .string("automation-input"),
            "status": .string("queued"), "text": .string(text)
        ])]))
        state.reduce(.object(["type": .string("message.start"), "admission_id": .string("automation-admission"),
            "payload": .object(["display_kind": .string("internal_notification")])]), authority: true)
        let promoted = state.conversation.messages.last
        #expect(promoted?.id == "submission:automation-input")
        #expect(promoted?.text == text)
        #expect(promoted?.scheduledJobName == "Mac service incident diagnosis")
        #expect(state.conversation.attentionMessages == [prior])
        #expect(state.conversation.queuedMessages.isEmpty)
        state.reduce(.object(["type": .string("message.complete"), "payload": .object([
            "text": .string("[SILENT]"), "status": .string("complete"),
            "persisted_turn": .object(["submission_id": .string("automation-input"), "user_row_id": .number(7)])
        ])]), authority: true)
        #expect(state.conversation.visibleMessages.count == 2)
        #expect(state.conversation.visibleMessages.last?.scheduledJobName == "Mac service incident diagnosis")
        #expect(state.conversation.attentionMessages == [prior])
    }

}

@MainActor @Test(arguments: [false, true])
func scheduledDeliveryRefreshReconnectAndDuplicateEvents(authority: Bool) async throws {
    let host = try HermesTestHost(authority: authority), service = host.service()
    defer { service.disconnect() }
    host.snapshot["messages"] = .array([])
    host.snapshot["running"] = .bool(false)
    host.snapshot["info"]["profile_name"] = .string(host.bot.id)
    var publications: [OpenedConversation] = []
    service.onEvent = { if case .conversation(let value) = $0 { publications.append(value) } }
    _ = try await service.connect(configuration: host.configuration)
    let opened = try await service.openChat(.canonical(profile: ExactID(host.bot.id), expectedRoot: nil))
    let body = ScheduledHandoffTests.wrapper + String(repeating: "{\"diagnosis\":\"healthy\"}\n", count: 3000)
    let rows: [HermesJSON] = [
        .object(["role": .string("user"), "row_id": .number(71), "content": .string(body), "display_kind": .string("internal_notification"), "timestamp": .number(100)]),
        .object(["role": .string("assistant"), "row_id": .number(72), "content": .string("The service is healthy."), "timestamp": .number(105)])]
    host.snapshot["messages"] = .array(rows)
    host.snapshot["last_sequence"] = .number(3)
    host.replay["latest_seq"] = .number(3)
    let socket = host.sockets[0]
    socket.push(host.event("message.start", seq: 1, session: "another-bot-runtime"))
    socket.push(host.event("message.start", seq: 1))
    socket.push(host.event("message.delta", seq: 2, payload: ["text": .string("The service is healthy.")]))
    socket.push(host.event("message.delta", seq: 2, payload: ["text": .string("DUPLICATE")]))
    socket.push(host.event("message.complete", seq: 3, payload: ["text": .string("The service is healthy."), "status": .string("complete"),
        "persisted_turn": .object(["user_row_id": .number(71), "final_assistant_row_id": .number(72)])]))
    try await eventually { publications.last?.snapshot.messages.first?.scheduledJobName != nil }
    let delivered = try #require(publications.last)
    #expect(delivered.snapshot.messages.count == 2)
    #expect(delivered.snapshot.messages[0].text == body)
    #expect(delivered.snapshot.messages[1].text == "The service is healthy.")
    #expect(!publications.contains { $0.snapshot.messages.contains { $0.text.contains("DUPLICATE") } })
    let reloaded = try await service.openChat(.stored(opened.identity))
    #expect(reloaded.snapshot.messages == delivered.snapshot.messages)
    let count = publications.count
    host.sockets.last?.close()
    try await eventually { host.sockets.count >= 2 && publications.count > count }
    #expect(publications.last?.snapshot.messages == delivered.snapshot.messages)
}

@Test func reconnectKeepsHumanInputAndHidesItsAssistantControlReply() throws {
    var state = HermesConversationState(profile: "bot", root: "stored", stored: "stored", runtime: "runtime", epoch: "epoch")
    let history: [HermesJSON] = [
        .object(["row_id": .number(1), "role": .string("user"), "content": .string(ScheduledHandoffTests.wrapper + "check"),
                 "display_kind": .string("internal_notification"), "timestamp": .number(100)]),
        .object(["row_id": .number(2), "role": .string("assistant"), "content": .string("Earlier answer"), "timestamp": .number(105)])]
    let snapshot: HermesJSON = .object(["session_id": .string("runtime"), "session_key": .string("stored"), "running": .bool(true),
        "inflight": .object(["user": .string("A new human question"), "assistant": .string("[SILENT]"), "started_at": .number(200)])])
    try state.restore(snapshot, history: history, authority: false)
    #expect(state.conversation.messages.last?.text == "[SILENT]")
    #expect(state.conversation.messages.last?.isVisible == false)
    #expect(state.conversation.messages.first { $0.id == "inflight-user" }?.requiresAttention == true)
}

@Test(arguments: ["error", "interrupted", "cancelled", "unknown"])
func failedCompletionUnhidesMarkerWhenHistoryArrivedFirst(_ status: String) throws {
    var state = HermesConversationState(profile: "bot", root: "stored", stored: "stored", runtime: "runtime", epoch: "epoch")
    state.conversation.messages = HermesConversationState.messages([
        .object(["row_id": .number(1), "role": .string("user"), "content": .string(ScheduledHandoffTests.wrapper + "check"), "display_kind": .string("internal_notification")]),
        .object(["row_id": .number(2), "role": .string("assistant"), "content": .string("[SILENT]")])], stored: "stored")
    #expect(state.conversation.messages.last?.isVisible == false)
    state.reduce(.object(["type": .string("message.complete"), "payload": .object(["status": .string(status), "text": .string("[SILENT]"),
        "persisted_turn": .object(["final_assistant_row_id": .number(2)])])]), authority: true)
    #expect(state.conversation.messages.first { $0.id == "stored:row:2" }?.isVisible == true)
    #expect(state.conversation.messages.contains { $0.role == .system && $0.requiresAttention })
    let cached = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(state.conversation))
    #expect(cached.messages.first { $0.id == "stored:row:2" }?.requiresAttention == true)
}

@Test(arguments: ["message.interim", "message.delta"])
func markerPrefixesRemainVisibleThroughSegmentBoundaries(_ boundary: String) {
    var state = HermesConversationState(profile: "bot", root: "stored", stored: "stored", runtime: "runtime", epoch: "epoch")
    state.reduce(.object(["type": .string("message.start"), "payload": .object(["display_kind": .string("internal_notification")])]), authority: true)
    state.reduce(.object(["type": .string("message.delta"), "payload": .object(["text": .string("No")])]), authority: true)
    #expect(state.conversation.messages.last?.isVisible == true)
    state.reduce(.object(["type": .string(boundary), "payload": .object(["already_streamed": .bool(true), "text": .null])]), authority: true)
    #expect(state.conversation.messages.last?.text == "No")
    #expect(state.conversation.messages.last?.isVisible == true)
}

@Test(arguments: [false, true])
func humanGreetingControlReplyStaysQuietAcrossLiveHistoryAndOldCache(_ authority: Bool) throws {
    let rows: [HermesJSON] = [
        .object(["role": .string("user"), "content": .string("Hi")]),
        .object(["role": .string("assistant"), "content": .string("[SILENT]")])]
    let history = HermesConversationState.messages(rows, stored: "stored")
    #expect(history.map(\.text) == ["Hi", "[SILENT]"])
    #expect(history.filter(\.isVisible).map(\.text) == ["Hi"])
    var state = HermesConversationState(profile: "bot", root: "stored", stored: "stored", runtime: "runtime", epoch: "epoch")
    state.reduce(.object(["type": .string("message.start"), "payload": .object([:])]), authority: authority)
    state.reduce(.object(["type": .string("message.delta"), "payload": .object(["text": .string("[SILENT]")])]), authority: authority)
    #expect(state.conversation.visibleMessages.isEmpty)
    state.reduce(.object(["type": .string("message.complete"), "payload": .object(["text": .string("[SILENT]"), "status": .string("complete")])]), authority: authority)
    #expect(state.conversation.attentionMessages.isEmpty)
    let oldCache = Data(#"{"id":"old","role":"assistant","text":"[SILENT]","attachments":[],"isSilent":false}"#.utf8)
    let cached = try JSONDecoder().decode(ChatMessage.self, from: oldCache)
    #expect(!cached.isVisible && !cached.requiresAttention)
    let human = ChatMessage(id: "human", role: .user, text: "[SILENT]")
    #expect(human.isVisible && human.requiresAttention)
}

@Test func legacyPartialControlProjectionCannotHideRealText() throws {
    let data = Data(#"{"id":"old","role":"assistant","text":"No","attachments":[],"isSilent":true}"#.utf8)
    let message = try JSONDecoder().decode(ChatMessage.self, from: data)
    #expect(message.isVisible && message.requiresAttention)
}
