import Foundation
import Testing
@testable import BottoCore

@MainActor @Test func authorityHandshakeResumeAndFencedActions() async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    let info = try await service.connect(configuration: host.configuration)
    #expect(info.installID == "fixture-install")
    let bots = try await service.bots()
    #expect(bots.map(\.id) == ["inbox-triage"])
    let chat = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    #expect(chat.snapshot.id == "stored-1")
    _ = try await service.send(text: "hello", attachments: [], access: chat.access, operationID: UUID())
    _ = try await service.stop(access: chat.access, operationID: UUID())
    let socket = try #require(host.sockets.first)
    #expect(socket.sent.first?["method"].text == "client.capabilities")
    #expect(socket.sent.first?["params"]["server_requests"].flag == true)
    let resume = try #require(socket.sent.first { $0["method"].text == "session.resume" })
    #expect(resume["params"]["close_on_disconnect"] == .null)
    let replay = try #require(socket.sent.first { $0["method"].text == "session.events.since" })
    #expect(replay["params"]["replay_epoch"].text == "session-epoch")
    #expect(replay["params"]["last_sequence"].integer == 0)
    let submit = try #require(socket.sent.first { $0["method"].text == "prompt.submit" })
    #expect(submit["params"]["queued"].flag == true)
    #expect(UUID(uuidString: submit["params"]["submission_id"].text ?? "") != nil)
    #expect(submit["params"]["profile"].text == "inbox-triage")
    let stop = try #require(socket.sent.first { $0["method"].text == "session.interrupt" })
    #expect(stop["params"]["execution_generation"].integer == 7)
    #expect(host.upgrades.first?.value(forHTTPHeaderField: "Sec-WebSocket-Protocol") == "hermes-gateway-v1, hermes-gateway-ticket.test-ticket")
    #expect(host.upgrades.first?.url?.absoluteString == "wss://hermes.example/api/ws")
    #expect(host.sockets.count == 1)
}

@MainActor @Test func sidecarCapturedTurnDeduplicatesReplayAndFinalText() async throws {
    let host = try HermesTestHost(authority: false), service = host.service()
    defer { service.disconnect() }
    var views: [Conversation] = []
    service.onEvent = { if case .conversation(let publication) = $0 { let value = publication.snapshot; views.append(value) } }
    _ = try await service.connect(configuration: host.configuration)
    let chat = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    #expect(chat.snapshot.storedID != chat.snapshot.id)
    let socket = try #require(host.sockets.last)
    let resume = try #require(socket.sent.first { $0["method"].text == "session.resume" })
    #expect(resume["params"]["close_on_disconnect"].flag == false)
    let frames = try #require(try fixture("turn-frames").list)
    host.snapshot = try fixture("session-resume")
    host.replay["latest_seq"] = .number(10)
    host.replay["events"] = .array(frames.map { $0["params"] })
    for frame in frames { socket.push(frame); socket.push(frame) }
    try await eventually { views.last?.messages.count == 2 && views.last?.messages.last?.id.hasSuffix("row:79") == true }
    #expect(views.last?.messages.map(\.text) == ["Reply with exactly: ok. Do not use tools.", "ok"])
    #expect(views.allSatisfy { $0.messages.filter { $0.role == .assistant && $0.text == "ok" }.count <= 1 })
    #expect(views.last?.lastSequence == 10)
    #expect(views.last?.isWorking == false)
}

@MainActor @Test func authorityPendingPromptsUseExactGenerationAndUnknownStayVisible() async throws {
    let host = try HermesTestHost()
    host.snapshot["running"] = .bool(true)
    host.snapshot["prompts"] = .array([
        .object(["kind": .string("approval"), "prompt_id": .string("approval-1"), "execution_generation": .number(7),
                 "choices": .array([.string("once"), .string("deny")]), "command": .string("rm example")]),
        .object(["kind": .string("clarify"), "prompt_id": .string("question-1"), "execution_generation": .number(7),
                 "choices": .array([.string("Small")]), "question": .string("Which scope?")]),
        .object(["kind": .string("future-kind"), "prompt_id": .string("unsupported-1"), "execution_generation": .number(7)])])
    let service = host.service(); defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let chat = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    var current = chat
    service.onEvent = { if case .conversation(let opened) = $0 { current = opened } }
    #expect(chat.snapshot.pendingRequests.count == 3)
    let approval = try #require(chat.snapshot.pendingRequests.first { $0.id == "approval-1" })
    #expect(approval.choices.map(\.id) == ["once", "deny"])
    await #expect(throws: HermesServiceError.invalidResponse) {
        _ = try await service.respond(to: approval, response: .choice("always"), access: current.access, operationID: UUID())
    }
    _ = try await service.respond(to: approval, response: .choice("once"), access: current.access, operationID: UUID())
    let question = try #require(chat.snapshot.pendingRequests.first { $0.id == "question-1" })
    _ = try await service.respond(to: question, response: .choice("0"), access: current.access, operationID: UUID())
    let unknown = try #require(chat.snapshot.pendingRequests.first { $0.kind == .unsupported })
    await #expect(throws: HermesServiceError.unsupportedRequest) {
        _ = try await service.respond(to: unknown, response: .text("yes"), access: current.access, operationID: UUID())
    }
    let frames = host.sockets[0].sent
    let answer = try #require(frames.first { $0["method"].text == "approval.respond" })
    #expect(answer["params"]["prompt_id"].text == "approval-1")
    #expect(answer["params"]["request_id"] == .null)
    #expect(answer["params"]["execution_generation"].integer == 7)
    #expect(frames.first { $0["method"].text == "clarify.respond" }?["params"]["answer"].text == "Small")
    #expect(frames.filter { $0["method"].text == "request.answer" }.isEmpty)
}

@MainActor @Test func oversizedQuestionAnswerIsRejectedBeforeWriteAndCorrectedAnswerCanBeSubmitted() async throws {
    let host = try HermesTestHost()
    host.snapshot["prompts"] = .array([
        .object(["kind": .string("clarify"), "prompt_id": .string("question-1"),
                 "execution_generation": .number(7), "question": .string("Which scope?")])])
    let service = host.service(); defer { service.disconnect() }
    var last: OpenedConversation?
    service.onEvent = { if case .conversation(let value) = $0 { last = value } }
    _ = try await service.connect(configuration: host.configuration)
    let chat = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    let question = try #require(chat.snapshot.pendingRequests.first)
    let framesBeforeAnswer = host.sockets[0].sent

    let rejectedOperation = UUID()
    do {
        _ = try await service.respond(to: question, response: .text(String(repeating: "a", count: 16_385)), access: chat.access, operationID: rejectedOperation)
        Issue.record("An oversized answer must be rejected before sending")
    } catch {
        #expect(error as? HermesServiceError == .responseTooLong)
        #expect(error.localizedDescription == "This answer is too long. Use 16,384 UTF-8 bytes or fewer, then submit again. Some characters use more than one byte. Nothing was sent.")
    }
    #expect(host.sockets[0].sent == framesBeforeAnswer)
    #expect(last?.snapshot.pendingRequests == [question])

    let corrected = String(repeating: "a", count: 16_384)
    // Validation consumed the first operation. Only a fresh deliberate attempt may submit.
    await #expect(throws: HermesServiceError.staleConversation) {
        _ = try await service.respond(to: question, response: .text(corrected), access: chat.access, operationID: rejectedOperation)
    }
    #expect(host.sockets[0].sent == framesBeforeAnswer)
    let correctedOperation = UUID()
    let receipt = try await service.respond(to: question, response: .text(corrected), access: chat.access, operationID: correctedOperation)
    #expect(receipt.operationID == correctedOperation)
    #expect(receipt.source == chat.identity)
    let answers = host.sockets[0].sent.filter { $0["method"].text == "clarify.respond" }
    #expect(answers.count == 1)
    #expect(answers.first?["params"]["answer"].text == corrected)
    #expect(answers.first?["params"]["prompt_id"].text == "question-1")
    #expect(answers.first?["params"]["execution_generation"].integer == 7)
    #expect(last?.snapshot.pendingRequests.isEmpty == true)
}

@MainActor @Test(arguments: [String(repeating: "é", count: 8_192), String(repeating: "🙂", count: 4_096)])
func sidecarQuestionAnswerLimitCountsUTF8Bytes(boundaryAnswer: String) async throws {
    let host = try HermesTestHost(authority: false)
    host.snapshot["open_requests"] = .array([
        .object(["id": .string("question-1"), "method": .string("clarify"),
                 "params": .object(["session_id": .string(host.runtime), "question": .string("Which scope?")])])])
    let service = host.service(); defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let chat = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    let question = try #require(chat.snapshot.pendingRequests.first)
    let framesBeforeAnswer = host.sockets[0].sent
    await #expect(throws: HermesServiceError.responseTooLong) {
        _ = try await service.respond(to: question, response: .text(boundaryAnswer + "a"), access: chat.access, operationID: UUID())
    }
    #expect(host.sockets[0].sent == framesBeforeAnswer)
    _ = try await service.respond(to: question, response: .text(boundaryAnswer), access: chat.access, operationID: UUID())
    let answers = host.sockets[0].sent.filter { $0["method"].text == "request.answer" }
    #expect(answers.count == 1)
    #expect(answers.first?["params"]["id"].text == "question-1")
    #expect(answers.first?["params"]["result"]["answer"].text == boundaryAnswer)
}

@MainActor @Test func questionLengthErrorPreservesEmptyAndOfferedChoiceValidation() async throws {
    let host = try HermesTestHost()
    let offered = String(repeating: "a", count: 16_385)
    host.snapshot["prompts"] = .array([
        .object(["kind": .string("clarify"), "prompt_id": .string("question-1"),
                 "execution_generation": .number(7), "question": .string("Which scope?"),
                 "choices": .array([.string(offered)])]),
        .object(["kind": .string("approval"), "prompt_id": .string("approval-1"),
                 "execution_generation": .number(7), "choices": .array([.string("once")])])])
    let service = host.service(); defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let chat = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    let question = try #require(chat.snapshot.pendingRequests.first { $0.kind == .question })
    let approval = try #require(chat.snapshot.pendingRequests.first { $0.kind == .approval })
    let framesBeforeAnswer = host.sockets[0].sent
    for empty in ["", " \t\n", String(repeating: " ", count: 16_385)] {
        await #expect(throws: HermesServiceError.invalidResponse) {
            _ = try await service.respond(to: question, response: .text(empty), access: chat.access, operationID: UUID())
        }
    }
    await #expect(throws: HermesServiceError.invalidResponse) {
        _ = try await service.respond(to: question, response: .choice("unoffered"), access: chat.access, operationID: UUID())
    }
    await #expect(throws: HermesServiceError.invalidResponse) {
        _ = try await service.respond(to: approval, response: .text(offered), access: chat.access, operationID: UUID())
    }
    #expect(host.sockets[0].sent == framesBeforeAnswer)
    _ = try await service.respond(to: question, response: .choice("0"), access: chat.access, operationID: UUID())
    let answers = host.sockets[0].sent.filter { $0["method"].text == "clarify.respond" }
    #expect(answers.count == 1)
    #expect(answers.first?["params"]["answer"].text == offered)
}

@MainActor @Test func lostQuestionAnswerAcknowledgmentReconnectsWithoutResubmitting() async throws {
    let host = try HermesTestHost()
    host.snapshot["prompts"] = .array([
        .object(["kind": .string("clarify"), "prompt_id": .string("question-1"),
                 "execution_generation": .number(7), "question": .string("Which scope?")])])
    host.methodOverride = { [weak host] frame, socket in
        guard let host else { return nil }
        if frame["method"].text == "clarify.respond" { return nil }
        return host.defaultReply(frame, socket: socket)
    }
    let service = host.service(requestTimeout: .milliseconds(50)); defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let chat = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    let question = try #require(chat.snapshot.pendingRequests.first)
    var recovered = false
    service.onEvent = { if case .connected = $0 { recovered = true } }
    await #expect(throws: HermesServiceError.uncertain) {
        _ = try await service.respond(to: question, response: .text("Small"), access: chat.access, operationID: UUID())
    }
    try await eventually { recovered }
    #expect(host.sockets.count == 2)
    #expect(host.sockets[1].sent.contains { $0["method"].text == "session.resume" })
    let answers = host.sockets.flatMap(\.sent).filter { $0["method"].text == "clarify.respond" }
    #expect(answers.count == 1)
    #expect(answers.first?["params"]["answer"].text == "Small")
}

@MainActor @Test func capturedSidecarApprovalKeepsQueueIdentityAndRestoresUnknownRequests() async throws {
    let host = try HermesTestHost(authority: false)
    var approval = try #require(try fixture("turn-tool-approval-frames")["frames"].list?.first { $0["method"].text == "approval" })
    approval["params"]["session_id"] = .string(host.runtime)
    let unknown: HermesJSON = .object(["id": .string("future-request"), "method": .string("future.action"),
        "params": .object(["session_id": .string(host.runtime)])])
    host.snapshot["open_requests"] = .array([approval, unknown])
    let service = host.service(); defer { service.disconnect() }
    var last: Conversation?
    service.onEvent = { if case .conversation(let publication) = $0 { let value = publication.snapshot; last = value } }
    _ = try await service.connect(configuration: host.configuration)
    let chat = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    #expect(chat.snapshot.pendingRequests.count == 2)
    let card = try #require(chat.snapshot.pendingRequests.first { $0.kind == .approval })
    #expect(card.id == "srq-627297cd2bb0")
    #expect(card.queueID == "850a0a9d32c448c2b4b9bc34503f5812")
    _ = try await service.respond(to: card, response: .choice("deny"), access: chat.access, operationID: UUID())
    #expect(host.sockets[0].sent.last?["params"]["request_id"].text == card.queueID)
    host.sockets[0].push(host.event("request.cancel", seq: 1, payload: ["id": .string("future-request")]))
    try await eventually { last?.pendingRequests.isEmpty == true }
    #expect(host.sockets[0].sent.filter { $0["method"].text == "request.answer" }.isEmpty)
}

@MainActor @Test func lostSubmitAcknowledgmentReconnectsWithoutResendingMutation() async throws {
    let host = try HermesTestHost()
    host.methodOverride = { [weak host] frame, socket in
        guard let host else { return nil }
        if frame["method"].text == "prompt.submit" { return nil }
        return host.defaultReply(frame, socket: socket)
    }
    let service = host.service(requestTimeout: .milliseconds(50)); defer { service.disconnect() }
    var recovered = false
    service.onEvent = { if case .connected = $0 { recovered = true } }
    _ = try await service.connect(configuration: host.configuration)
    let chat = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    await #expect(throws: HermesServiceError.uncertain) { try await service.send(text: "Do it once", attachments: [], access: chat.access, operationID: UUID()) }
    try await eventually { recovered }
    #expect(host.sockets.count == 2)
    let sentFrames = host.sockets.flatMap(\.sent)
    let submissions = sentFrames.filter { $0["method"].text == "prompt.submit" }
    #expect(submissions.count == 1)
    #expect(host.transport.requests.filter { $0.url?.path == "/api/auth/ws-ticket" }.count == 2)
    #expect(host.sockets[1].sent.contains { $0["method"].text == "session.resume" })
}

@MainActor @Test func authorityGapRebuildsSnapshotAndFiltersOtherSessions() async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    var last: Conversation?
    service.onEvent = { if case .conversation(let publication) = $0 { let value = publication.snapshot; last = value } }
    _ = try await service.connect(configuration: host.configuration)
    _ = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    let socket = host.sockets[0]
    socket.push(host.event("message.delta", seq: 1, payload: ["text": .string("WRONG")], session: "other-bot"))
    host.snapshot["messages"] = .array([.object(["role": .string("assistant"), "row_id": .number(9), "content": .string("Recovered")])])
    host.snapshot["last_sequence"] = .number(3)
    host.replay["snapshot_required"] = .bool(true)
    host.replay["truncated"] = .bool(true)
    host.replay["latest_seq"] = .number(3)
    socket.push(host.event("message.delta", seq: 3, payload: ["text": .string("gap")]))
    try await eventually { last?.messages.last?.text == "Recovered" }
    #expect(last?.lastSequence == 3)
    #expect(last?.messages.count == 1)
    #expect(host.sockets.count == 1)
}

@MainActor @Test func unknownAuthorityServerRequestsRemainVisibleAfterRecoveryUntilCanceled() async throws {
    let host = try HermesTestHost(), service = host.service(); defer { service.disconnect() }
    var last: Conversation?
    service.onEvent = { if case .conversation(let publication) = $0 { let value = publication.snapshot; last = value } }
    _ = try await service.connect(configuration: host.configuration)
    _ = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    let socket = host.sockets[0]
    socket.push(.object(["jsonrpc": .string("2.0"), "id": .string("srq-unknown"), "method": .string("future.secret"),
                        "params": .object(["session_id": .string(host.runtime)])]))
    try await eventually { last?.pendingRequests.first?.id == "srq-unknown" }
    host.snapshot["last_sequence"] = .number(3)
    host.replay["latest_seq"] = .number(3)
    host.replay["snapshot_required"] = .bool(true)
    socket.push(host.event("message.delta", seq: 3, payload: ["text": .string("gap")]))
    try await eventually { last?.lastSequence == 3 }
    #expect(last?.pendingRequests.first?.kind == .unsupported)
    socket.push(host.event("request.cancel", seq: 4, payload: ["id": .string("srq-unknown")]))
    try await eventually { last?.pendingRequests.isEmpty == true }
    #expect(!socket.sent.contains { ["request.answer", "approval.respond", "clarify.lock"].contains($0["method"].text ?? "") })
}

@MainActor @Test func uploadedFilesStayInTheirConversationAndUseServerReference() async throws {
    let host = try HermesTestHost(), service = host.service(); defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let chat = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    let attachment = try await service.upload(data: Data("hello".utf8), filename: "notes.txt", mimeType: "text/plain", access: chat.access)
    let wrong = try ConversationIssuer<String>().issue("foreign")
    await #expect(throws: HermesServiceError.staleConversation) { try await service.send(text: "read", attachments: [attachment], access: wrong, operationID: UUID()) }
    var forged = attachment; forged.path = "/etc/passwd"
    await #expect(throws: HermesServiceError.invalidAttachment) { try await service.send(text: "read", attachments: [forged], access: chat.access, operationID: UUID()) }
    _ = try await service.send(text: "Read these", attachments: [attachment], access: chat.access, operationID: UUID())
    #expect(host.sockets[0].sent.last?["params"]["text"].text == "Read these\n\n@file:/host/file.txt")
    #expect(host.sockets[0].sent.filter { $0["method"].text == "prompt.submit" }.count == 1)
    await #expect(throws: HermesServiceError.attachmentLimit) {
        try await service.upload(data: Data(repeating: 0, count: 25 * 1024 * 1024 + 1), filename: "large.txt", mimeType: "text/plain", access: chat.access)
    }
}

// One opaque red pixel, encoded as a valid PNG; generated locally, no external artwork.
let attachmentPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==")!

@MainActor @Test func authorityImagesAreExplicitPerSubmissionAndNeverUseTheSharedQueue() async throws {
    let host = try HermesTestHost(), service = host.service(); defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let chat = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    let attachment = try await service.upload(data: attachmentPNG, filename: "pixel.png", mimeType: "image/png", access: chat.access)
    _ = try await service.send(text: "Inspect", attachments: [attachment], access: chat.access, operationID: UUID())
    let requests = host.sockets[0].sent
    let upload = try #require(requests.first { $0["method"].text == "image.attach_bytes" })
    #expect(upload["params"]["profile"].text == chat.snapshot.profileID)
    #expect(upload["params"]["session_id"].text == chat.snapshot.id)
    let submit = try #require(requests.first { $0["method"].text == "prompt.submit" })
    #expect(submit["params"]["attachments"].list == [.object(["path": .string(attachment.path), "mime": .string(attachment.mimeType)])])
    #expect(submit["params"]["text"].text == "Inspect")
    #expect(!host.transport.requests.contains { $0.url?.path == "/api/chat/image-upload" })
    await #expect(throws: HermesServiceError.invalidAttachment) {
        _ = try await service.send(text: "Inspect again", attachments: [attachment], access: chat.access, operationID: UUID())
    }
}

@MainActor @Test func canonicalIdentityMismatchIsRejectedBeforeSend() async throws {
    let host = try HermesTestHost(), service = host.service(); defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    host.snapshot["stored_session_id"] = .string("other-stored-session")
    await #expect(throws: HermesServiceError.wrongConversation) { try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil)) }
    #expect(!host.sockets[0].sent.contains { $0["method"].text == "prompt.submit" })
}

@Test func sidecarCompletionAlreadyInHistoryNeverDuplicatesTheAnswer() throws {
    let snapshot = try fixture("session-resume")
    let runtime = try #require(snapshot["session_id"].text), stored = try #require(snapshot["session_key"].text)
    var state = HermesConversationState(profile: "inbox-triage", root: stored, stored: stored, runtime: runtime, epoch: "gateway-epoch")
    try state.restore(snapshot, history: snapshot["messages"].list ?? [], authority: false)
    let frames = try #require(try fixture("turn-frames").list)
    let complete = try #require(frames.first { $0["params"]["type"].text == "message.complete" })
    // A completion held during REST history loading follows a snapshot that already
    // contains its durable final row. Even a partial stream must not duplicate it.
    state.appendStream("o")
    state.reduce(complete["params"], authority: false)
    #expect(state.conversation.messages.map(\.text) == ["Reply with exactly: ok. Do not use tools.", "ok"])
    #expect(Set(state.conversation.messages.map(\.id)).count == state.conversation.messages.count)
}

@Test func sidecarInflightUserUsesTurnTimeInsteadOfRepeatedText() throws {
    var snapshot = try fixture("session-resume")
    let runtime = try #require(snapshot["session_id"].text), stored = try #require(snapshot["session_key"].text)
    snapshot["running"] = .bool(true)
    snapshot["inflight"] = .object(["user": .string("Repeat"), "started_at": .number(100)])
    let rows: [HermesJSON] = [
        .object(["role": .string("user"), "row_id": .number(1), "text": .string("Repeat"), "timestamp": .number(90)]),
        .object(["role": .string("user"), "row_id": .number(2), "text": .string("Repeat"), "timestamp": .number(101)])]
    var state = HermesConversationState(profile: "inbox-triage", root: stored, stored: stored, runtime: runtime, epoch: "gateway-epoch")
    try state.restore(snapshot, history: rows, authority: false)
    #expect(state.conversation.messages.count == 2)
    try state.restore(snapshot, history: [rows[0]], authority: false)
    #expect(state.conversation.messages.count == 2)
    #expect(state.conversation.messages.last?.id == "inflight-user")
}

@MainActor @Test func newerExecutionBeforeSubmitReceiptDoesNotRegressControlGeneration() async throws {
    let host = try HermesTestHost(), service = host.service(); defer { service.disconnect() }
    host.methodOverride = { frame, socket in
        if frame["method"].text == "prompt.submit" {
            var event = host.event("session.info", seq: 1, payload: ["running": .bool(true), "execution_generation": .number(8)])
            event["params"]["execution_generation"] = .number(8)
            socket.push(event)
        }
        return host.defaultReply(frame, socket: socket)
    }
    _ = try await service.connect(configuration: host.configuration)
    let chat = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    var current = chat
    service.onEvent = { if case .conversation(let opened) = $0 { current = opened } }
    _ = try await service.send(text: "Queued input", attachments: [], access: current.access, operationID: UUID())
    _ = try await service.stop(access: current.access, operationID: UUID())
    #expect(host.sockets[0].sent.last?["params"]["execution_generation"].integer == 8)
}

@Test func capturedAuthorityApprovalRestoresAndSettlesWithoutDuplicateTools() throws {
    func captured(_ name: String) throws -> HermesJSON {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/AuthorityCaptured"))
        return try HermesJSON.decode(Data(contentsOf: url))
    }
    let snapshot = try captured("approval-snapshot"), final = try captured("final-snapshot")
    let events = try #require(try captured("turn-events").list)
    let profile = try #require(snapshot["info"]["profile_name"].text), runtime = try #require(snapshot["session_id"].text)
    var state = HermesConversationState(profile: profile, root: runtime, stored: runtime, runtime: runtime, epoch: "unused-gateway-epoch")
    try state.restore(snapshot, history: snapshot["messages"].list ?? [], authority: true)
    state.restoreAuthorityStream(events, through: state.conversation.lastSequence)
    #expect(state.conversation.pendingRequests.count == 1)
    #expect(state.conversation.pendingRequests.first?.kind == .approval)
    #expect(state.conversation.messages.filter { $0.role == .tool }.count == 1)
    #expect(state.conversation.messages.filter { $0.text == "Running the disposable check." }.count == 1)
    let prompt = try #require(state.conversation.pendingRequests.first)
    #expect(state.routes[prompt.id]?.generation == 2)
    #expect(state.epoch == snapshot["replay_epoch"].text)
    let watermark = state.conversation.lastSequence
    for event in events where (event["seq"].integer ?? 0) > watermark { state.reduce(event, authority: true) }
    #expect(state.conversation.pendingRequests.isEmpty)
    #expect(state.conversation.messages.filter { $0.role == .tool }.count == 1)
    #expect(state.conversation.messages.last?.text.contains("HOT_TOOL_DONE") == true)
    #expect(Set(state.conversation.messages.map(\.id)).count == state.conversation.messages.count)
    let streamed = state.conversation.messages.filter { $0.role == .assistant }.map(\.text)
    try state.restore(final, history: final["messages"].list ?? [], authority: true)
    #expect(state.conversation.messages.filter { $0.role == .assistant }.map(\.text) == streamed)
}

@MainActor @Test func olderNavigationCannotReplaceTheLatestSelection() async throws {
    let host = try HermesTestHost(), service = host.service(); defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    _ = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    var heldDetach: HermesJSON?
    host.methodOverride = { frame, socket in
        if frame["method"].text == "session.detach" { heldDetach = frame; return nil }
        return host.defaultReply(frame, socket: socket)
    }
    let older = Task { try await service.openChat(.canonical(profile: try ExactID("older-selection"), expectedRoot: nil)) }
    try await eventually { heldDetach != nil }
    let current = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    let request = try #require(heldDetach)
    host.sockets[0].push(.object(["jsonrpc": .string("2.0"), "id": request["id"], "result": .object(["ok": .bool(true)])]))
    await #expect(throws: HermesServiceError.staleConversation) { _ = try await older.value }
    _ = try await service.send(text: "Still the current selection", attachments: [], access: current.access, operationID: UUID())
    #expect(host.sockets[0].sent.last?["params"]["profile"].text == host.bot.id)
    #expect(!host.sockets[0].sent.contains { $0["method"].text == "session.list" && $0["params"]["profile"].text == "older-selection" })
}

@MainActor @Test func canceledSnapshotRefreshCannotDisconnectANewerNavigation() async throws {
    let host = try HermesTestHost(), service = host.service(); defer { service.disconnect() }
    var disconnected = false
    service.onEvent = { if case .disconnected = $0 { disconnected = true } }
    _ = try await service.connect(configuration: host.configuration)
    _ = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    var heldResume: HermesJSON?
    host.methodOverride = { frame, socket in
        if frame["method"].text == "session.resume" { heldResume = frame; return nil }
        return host.defaultReply(frame, socket: socket)
    }
    host.sockets[0].push(host.event("message.delta", seq: 3, payload: ["text": .string("gap")]))
    try await eventually { heldResume != nil }
    host.methodOverride = nil
    let current = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    let request = try #require(heldResume)
    host.sockets[0].push(.object(["jsonrpc": .string("2.0"), "id": request["id"], "result": host.snapshot]))
    _ = try await service.send(text: "Current", attachments: [], access: current.access, operationID: UUID())
    #expect(!disconnected)
    #expect(host.sockets.count == 1)
}

@MainActor @Test(arguments: [true, false]) func profileCreationWaitsForGatewayServingWithoutRepeatingWrites(hasModel: Bool) async throws {
    let host = try HermesTestHost(), service = host.service(); defer { service.disconnect() }
    var created = false, chatCreated = false, statusPolls = 0
    host.transport.handler = { request in
        switch request.url!.path {
        case "/api/status":
            var status = try fixture("status")
            if created { statusPolls += 1 }
            status["gateway_shared_with"] = .array(statusPolls >= 2 ? [.string("new-bot")] : [])
            return status
        case "/api/auth/me": return .object(["provider": .string("basic"), "user_id": .string("alice")])
        case "/api/auth/ws-ticket": return .object(["ticket": .string("test-ticket")])
        default: return .object(["ok": .bool(true)])
        }
    }
    host.methodOverride = { frame, socket in
        switch frame["method"].text {
        case "profiles.create":
            #expect(frame["params"]["no_alias"].flag == true)
            #expect(frame["params"]["share_auth"].flag == true)
            created = true
            return .object(["ok": .bool(true), "soul_written": .bool(true), "mirrored": .object(["model_inherited": .bool(false)])])
        case "profiles.describe": return .object(["model": .object(["default": .string(hasModel ? "existing-server-default" : "")])])
        case "profiles.configure": return .object(["applied": .object(["ui_meta": .bool(true)])])
        case "profiles.list" where created:
            return .object(["profiles": .array([.object(["name": .string("new-bot"), "ui_meta": .object([
                "hermes-bots": .object(["title": .string("New Bot"), "shape": .string("cloud"),
                    "color": .string("#14b8a6"), "custom": .bool(true), "imageKind": .string("shape")])])])])])
        case "session.list":
            #expect(statusPolls >= 2)
            return .object(["sessions": .array(chatCreated ? [.object(["id": .string("new-chat")])] : [])])
        case "session.create":
            #expect(frame["params"]["profile"].text == "new-bot")
            #expect(frame["params"]["source"].text == "gui")
            #expect(frame["params"]["title"].text == "Bot Chat")
            #expect(frame["params"]["request_id"].text != nil)
            chatCreated = true
            return .object(["session_id": .string("new-chat")])
        default: return host.defaultReply(frame, socket: socket)
        }
    }
    _ = try await service.connect(configuration: host.configuration)
    let draft = BotDraft(name: "New Bot", instructions: "Be concise", avatar: .face(.init(shape: .cloud, color: "#14b8a6")))
    if hasModel {
        let bot = try await service.createBot(draft)
        #expect(bot.name == "New Bot" && bot.face == BotFace(shape: .cloud, color: "#14b8a6"))
    } else {
        await #expect(throws: HermesServiceError.missingModel) { _ = try await service.createBot(draft) }
    }
    #expect(host.sockets[0].sent.filter { $0["method"].text == "profiles.create" }.count == 1)
    #expect(host.sockets[0].sent.filter { $0["method"].text == "session.create" }.count == 1)
    #expect(!host.sockets[0].sent.contains { $0["method"].text == "session.title" })
    #expect(host.sockets[0].sent.contains { $0["method"].text == "profiles.describe" })
}

@MainActor @Test(arguments: [false, true])
func steeringUsesCorrectionRPCAndKeepsTheActiveTurn(authority: Bool) async throws {
    let host = try HermesTestHost(authority: authority), service = host.service()
    host.snapshot["running"] = .bool(true)
    host.methodOverride = { frame, socket in
        if frame["method"].text == "session.steer" {
            return .object(["status": .string("queued"), "text": frame["params"]["text"],
                            "execution_generation": .number(7)])
        }
        return host.defaultReply(frame, socket: socket)
    }
    defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let opened = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    let operation = UUID()
    let receipt = try await service.send(text: "Use the shorter version", attachments: [], delivery: .steer,
                                         access: opened.access, operationID: operation)
    let frames = try #require(host.sockets.first?.sent)
    let correction = try #require(frames.first { $0["method"].text == "session.steer" })
    #expect(correction["params"]["text"].text == "Use the shorter version")
    #expect(correction["params"]["profile"].text == host.bot.id)
    #expect(correction["params"]["session_id"].text == opened.snapshot.id)
    #expect(correction["params"]["execution_generation"] == (authority ? .number(7) : .null))
    #expect(!frames.contains { ["prompt.submit", "session.interrupt"].contains($0["method"].text ?? "") })
    #expect(receipt.operationID == operation && receipt.admissionID == nil)
}

@MainActor @Test(arguments: [false, true])
func steeringUsesLiveWorkingStateAfterAnIdleOpen(authority: Bool) async throws {
    let host = try HermesTestHost(authority: authority), service = host.service()
    host.snapshot["running"] = .bool(false)
    host.methodOverride = { frame, socket in
        if frame["method"].text == "session.steer" {
            return .object(["status": .string("queued"), "execution_generation": .number(7)])
        }
        return host.defaultReply(frame, socket: socket)
    }
    defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let opened = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    #expect(!opened.snapshot.isWorking)
    var current = opened
    service.onEvent = { if case .conversation(let publication) = $0 { current = publication } }
    let socket = try #require(host.sockets.first)
    socket.push(host.event("message.start", seq: 1))
    try await eventually { current.snapshot.isWorking }
    #expect(current.access == opened.access)

    _ = try await service.send(text: "Use the shorter version", attachments: [], delivery: .steer,
                               access: current.access, operationID: UUID())
    let correction = try #require(socket.sent.first { $0["method"].text == "session.steer" })
    #expect(correction["params"]["execution_generation"] == (authority ? .number(7) : .null))
    #expect(!socket.sent.contains { ["prompt.submit", "session.interrupt"].contains($0["method"].text ?? "") })
}

@MainActor @Test(arguments: [false, true])
func rejectedSteeringNeverFallsBackToAQueuedPrompt(authority: Bool) async throws {
    let host = try HermesTestHost(authority: authority), service = host.service()
    host.snapshot["running"] = .bool(true)
    host.methodOverride = { frame, socket in
        if frame["method"].text == "session.steer" {
            return .object(["status": .string("rejected"), "execution_generation": .number(7)])
        }
        return host.defaultReply(frame, socket: socket)
    }
    defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let opened = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    await #expect(throws: HermesServiceError.steeringUnavailable) {
        _ = try await service.send(text: "Keep my draft", attachments: [], delivery: .steer,
                                   access: opened.access, operationID: UUID())
    }
    #expect(host.sockets[0].sent.filter { $0["method"].text == "session.steer" }.count == 1)
    #expect(!host.sockets[0].sent.contains { $0["method"].text == "prompt.submit" })
}
