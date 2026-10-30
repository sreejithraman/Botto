import Foundation
import Testing
@testable import BottoCore

@Test func conversationDecodesEarlierCacheWithoutLosingTranscript() throws {
    let data = Data(#"{"id":"runtime","storedID":"stored","profileID":"inbox","messages":[{"id":"row:1","role":"user","text":"Keep this","attachments":[]}],"pendingRequests":[],"isWorking":true,"lastSequence":42}"#.utf8)
    let conversation = try JSONDecoder().decode(Conversation.self, from: data)
    #expect(conversation.messages.map(\.text) == ["Keep this"])
    #expect(conversation.isWorking && conversation.lastSequence == 42)
    #expect(conversation.queuedMessages.isEmpty)
    var updated = conversation
    updated.queuedMessages = [QueuedMessage(id: "admission", text: "Later", canEdit: true, submissionID: "input")]
    #expect(try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(updated)) == updated)
}

@MainActor @Test func authorityQueuePreservesHostOrderAndAdvertisedEditCapability() async throws {
    let host = try HermesTestHost()
    host.snapshot["pending"] = .array([
        queuedRow("second", text: "First in host order", input: "input-2", controls: ["replace"]),
        queuedRow("first", text: "Read only"),
        queuedRow("transfer", text: "Steering", controls: ["replace"], status: "started", steering: true),
        queuedRow("image", text: "Image", controls: ["steer"]),
        queuedRow("running", text: "Already started", controls: ["replace"], status: "started")])
    let service = host.service(); defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let chat = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    #expect(chat.snapshot.queuedMessages == [
        QueuedMessage(id: "second", text: "First in host order", canEdit: true, submissionID: "input-2"),
        QueuedMessage(id: "first", text: "Read only"),
        QueuedMessage(id: "transfer", text: "Steering", isSteering: true),
        QueuedMessage(id: "image", text: "Image")])
    #expect(!chat.snapshot.messages.contains { $0.id.hasPrefix("queue:") })
}

private func queuedRow(_ id: String, text: String, input: String? = nil, controls: [String]? = nil,
                       status: String = "queued", steering: Bool = false) -> HermesJSON {
    var row: HermesJSON = .object(["admission_id": .string(id), "text": .string(text),
        "status": .string(status), "steering": .bool(steering)])
    if let input { row["input_id"] = .string(input) }
    if let controls { row["controls"] = .array(controls.map(HermesJSON.string)) }
    return row
}

@MainActor @Test func queuedReplacementUsesStableIdentityExactTextAndMovesToTail() async throws {
    let host = try HermesTestHost()
    host.snapshot["pending"] = .array([
        queuedRow("old", text: "Original", input: "original-input", controls: ["replace"]),
        queuedRow("next", text: "Second", controls: ["replace"])])
    let service: any BotService = host.service(); defer { service.disconnect() }
    var current: OpenedConversation?
    service.onEvent = { if case .conversation(let value) = $0 { current = value } }
    _ = try await service.connect(configuration: host.configuration)
    let chat = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    let original = try #require(chat.snapshot.queuedMessages.first)
    let operation = UUID(), edit = "  Revised\n\n  Keep indentation\n"
    host.methodOverride = { frame, socket in
        if frame["method"].text == "prompt.replace_queued" { return queuedReceipt(host, admission: "new") }
        return host.defaultReply(frame, socket: socket)
    }
    let receipt = try await service.replaceQueuedMessage(original, text: edit, access: chat.access, operationID: operation)
    #expect(receipt.operationID == operation && receipt.admissionID == "new")
    let writes = host.sockets[0].sent.filter { $0["method"].text == "prompt.replace_queued" }
    #expect(writes.count == 1)
    #expect(writes.first?["params"] == .object(["profile": .string("inbox-triage"), "session_id": .string(host.runtime),
        "admission_id": .string("old"), "submission_id": .string(operation.uuidString), "text": .string(edit)]))
    #expect(current?.snapshot.queuedMessages == [QueuedMessage(id: "next", text: "Second", canEdit: true),
        QueuedMessage(id: "new", text: edit, submissionID: operation.uuidString)])
    #expect(!host.sockets[0].sent.contains { ["prompt.submit", "session.steer"].contains($0["method"].text ?? "") })
    await #expect(throws: HermesServiceError.staleConversation) {
        _ = try await service.replaceQueuedMessage(original, text: edit, access: chat.access, operationID: operation)
    }
    #expect(host.sockets[0].sent.filter { $0["method"].text == "prompt.replace_queued" }.count == 1)
}

@MainActor private func queuedReceipt(_ host: HermesTestHost, admission: String, status: String = "queued") -> HermesJSON {
    .object(["admission_id": .string(admission), "ref": .object(["session_id": .string(host.runtime),
        "profile_id": .string("/profiles/inbox-triage")]), "sequence": .number(2), "status": .string(status),
        "authority_epoch": .number(2), "execution_generation": .number(7)])
}

@MainActor @Test(arguments: ["receipt", "before-receipt", "after-receipt"])
func idleSendAdmissionDoesNotFlashAsQueuedBeforeStarting(projection: String) async throws {
    let host = try HermesTestHost(), service = host.service()
    host.snapshot["running"] = .bool(false)
    defer { service.disconnect() }
    var views: [Conversation] = []
    service.onEvent = { if case .conversation(let value) = $0 { views.append(value.snapshot) } }
    _ = try await service.connect(configuration: host.configuration)
    let chat = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    host.methodOverride = { frame, socket in
        if frame["method"].text == "prompt.submit" {
            if projection == "before-receipt" {
                socket.push(host.event("session.info", seq: 1, payload: ["running": .bool(false), "pending": .array([
                    queuedRow("starting", text: "Start a reply", input: frame["params"]["submission_id"].text, controls: ["replace"])
                ])]))
            }
            return queuedReceipt(host, admission: "starting")
        }
        return host.defaultReply(frame, socket: socket)
    }

    let operation = UUID()
    _ = try await service.send(text: "Start a reply", attachments: [], access: chat.access, operationID: operation)
    if projection == "after-receipt" {
        host.sockets[0].push(host.event("session.info", seq: 1, payload: ["running": .bool(false), "pending": .array([
            queuedRow("starting", text: "Start a reply", input: operation.uuidString, controls: ["replace"])
        ])]))
        try await eventually { views.last?.lastSequence == 1 }
    }
    #expect(views.allSatisfy { $0.queuedMessages.isEmpty })
    #expect(views.last?.messages.filter { $0.id == "submission:" + operation.uuidString }.map(\.text) == ["Start a reply"])

    var start = host.event("message.start", seq: projection == "receipt" ? 1 : 2)
    start["params"]["admission_id"] = .string("starting")
    host.sockets[0].push(start)
    try await eventually { views.last?.isWorking == true }
    #expect(views.allSatisfy { $0.queuedMessages.isEmpty })
}

@MainActor @Test func queuedSendReceiptShowsReadOnlyQueueUntilHostAdvertisesControls() async throws {
    let host = try HermesTestHost(), service = host.service()
    host.snapshot["running"] = .bool(true)
    defer { service.disconnect() }
    var current: OpenedConversation?
    service.onEvent = { if case .conversation(let value) = $0 { current = value } }
    _ = try await service.connect(configuration: host.configuration)
    let chat = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    host.methodOverride = { frame, socket in
        if frame["method"].text == "prompt.submit" { return queuedReceipt(host, admission: "queued-send") }
        return host.defaultReply(frame, socket: socket)
    }
    let operation = UUID()
    _ = try await service.send(text: "Next turn", attachments: [], access: chat.access, operationID: operation)
    #expect(current?.snapshot.queuedMessages == [QueuedMessage(id: "queued-send", text: "Next turn", submissionID: operation.uuidString)])
    host.sockets[0].push(host.event("session.info", seq: 1, payload: ["pending": .array([
        queuedRow("queued-send", text: "Next turn", input: operation.uuidString, controls: ["replace"])])]))
    try await eventually { current?.snapshot.queuedMessages.first?.canEdit == true }
    #expect(current?.snapshot.queuedMessages.count == 1)
}

@MainActor @Test func idleSendStillShowsQueueWhenHostReportsOtherWork() async throws {
    let host = try HermesTestHost(), service = host.service()
    host.snapshot["running"] = .bool(false)
    defer { service.disconnect() }
    var current: OpenedConversation?
    service.onEvent = { if case .conversation(let value) = $0 { current = value } }
    _ = try await service.connect(configuration: host.configuration)
    let chat = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    let operation = UUID()
    host.methodOverride = { frame, socket in
        if frame["method"].text == "prompt.submit" { return queuedReceipt(host, admission: "waiting") }
        return host.defaultReply(frame, socket: socket)
    }
    _ = try await service.send(text: "Wait behind the other client", attachments: [], access: chat.access, operationID: operation)
    host.sockets[0].push(host.event("session.info", seq: 1, payload: ["running": .bool(true), "pending": .array([
        queuedRow("waiting", text: "Wait behind the other client", input: operation.uuidString, controls: ["replace"])
    ])]))
    try await eventually { current?.snapshot.lastSequence == 1 }
    #expect(current?.snapshot.queuedMessages == [QueuedMessage(id: "waiting", text: "Wait behind the other client",
        canEdit: true, submissionID: operation.uuidString)])
    host.sockets[0].push(host.event("session.info", seq: 2, payload: ["running": .bool(false), "pending": .array([
        queuedRow("waiting", text: "Wait behind the other client", input: operation.uuidString, controls: ["replace"])
    ])]))
    try await eventually { current?.snapshot.lastSequence == 2 }
    #expect(current?.snapshot.queuedMessages.map(\.id) == ["waiting"])
}

@MainActor @Test func idleSendUsesCurrentHostActivityWithUnchangedAccess() async throws {
    let host = try HermesTestHost(), service = host.service()
    host.snapshot["running"] = .bool(true)
    defer { service.disconnect() }
    var current: OpenedConversation?
    var views: [Conversation] = []
    service.onEvent = { if case .conversation(let value) = $0 { current = value; views.append(value.snapshot) } }
    _ = try await service.connect(configuration: host.configuration)
    let chat = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    host.sockets[0].push(host.event("session.info", seq: 1, payload: ["running": .bool(false), "pending": .array([])]))
    try await eventually { current?.snapshot.isWorking == false }
    #expect(current?.access == chat.access)
    host.methodOverride = { frame, socket in
        if frame["method"].text == "prompt.submit" { return queuedReceipt(host, admission: "next") }
        return host.defaultReply(frame, socket: socket)
    }

    _ = try await service.send(text: "Start the next reply", attachments: [], access: try #require(current?.access), operationID: UUID())

    #expect(views.allSatisfy { $0.queuedMessages.isEmpty })
    #expect(current?.snapshot.messages.last?.text == "Start the next reply")
}

@MainActor @Test(arguments: ["before-send", "before-receipt", "after-receipt"])
func competingIdleAdmissionKeepsLocalFollowupInQueue(projection: String) async throws {
    let host = try HermesTestHost(), service = host.service()
    host.snapshot["running"] = .bool(false)
    defer { service.disconnect() }
    var current: OpenedConversation?
    service.onEvent = { if case .conversation(let value) = $0 { current = value } }
    _ = try await service.connect(configuration: host.configuration)
    let chat = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    let operation = UUID()
    let remote = queuedRow("remote", text: "Earlier input", input: "remote-input", controls: ["replace"])
    let local = queuedRow("local", text: "Local followup", input: operation.uuidString, controls: ["replace"])
    if projection == "before-send" {
        host.sockets[0].push(host.event("session.info", seq: 1, payload: ["running": .bool(false), "pending": .array([remote])]))
        try await eventually { current?.snapshot.lastSequence == 1 }
        #expect(current?.access == chat.access)
    }
    host.methodOverride = { frame, socket in
        if frame["method"].text == "prompt.submit" {
            if projection == "before-receipt" {
                socket.push(host.event("session.info", seq: 1, payload: ["running": .bool(false), "pending": .array([remote, local])]))
            }
            return queuedReceipt(host, admission: "local")
        }
        return host.defaultReply(frame, socket: socket)
    }
    _ = try await service.send(text: "Local followup", attachments: [], access: try #require(current?.access), operationID: operation)
    if projection == "after-receipt" {
        host.sockets[0].push(host.event("session.info", seq: 1, payload: ["running": .bool(false), "pending": .array([remote, local])]))
        try await eventually { current?.snapshot.lastSequence == 1 }
    }
    #expect(current?.snapshot.queuedMessages.map(\.id) == ["remote", "local"])
    if projection != "before-send" { #expect(current?.snapshot.queuedMessages.last?.canEdit == true) }
}

@MainActor @Test(arguments: ["departed", "changed", "controls", "steering"])
func queuedReplacementRefusesStalePresentedItemBeforeAnyWrite(_ change: String) async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    host.snapshot["pending"] = .array([queuedRow("old", text: "Original", controls: ["replace"])])
    var current: OpenedConversation?
    service.onEvent = { if case .conversation(let value) = $0 { current = value } }
    _ = try await service.connect(configuration: host.configuration)
    let chat = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    let original = try #require(chat.snapshot.queuedMessages.first)
    let pending: [HermesJSON]
    switch change {
    case "changed": pending = [queuedRow("old", text: "Different text", controls: ["replace"])]
    case "controls": pending = [queuedRow("old", text: "Original")]
    case "steering": pending = [queuedRow("old", text: "Original", status: "started", steering: true)]
    default: pending = []
    }
    host.sockets[0].push(host.event("session.info", seq: 1, payload: ["pending": .array(pending)]))
    try await eventually { current?.snapshot.lastSequence == 1 }
    let frames = host.sockets[0].sent
    await #expect(throws: HermesServiceError.queuedMessageUnavailable) {
        _ = try await service.replaceQueuedMessage(original, text: "Revised", access: chat.access, operationID: UUID())
    }
    #expect(host.sockets[0].sent == frames)
}

@MainActor @Test func queuedReplacementServerStartedRefusalNeverFallsBack() async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    host.snapshot["pending"] = .array([queuedRow("old", text: "Original", controls: ["replace"])])
    _ = try await service.connect(configuration: host.configuration)
    let chat = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    let original = try #require(chat.snapshot.queuedMessages.first)
    host.methodOverride = { frame, socket in
        if frame["method"].text == "prompt.replace_queued" {
            socket.push(.object(["jsonrpc": .string("2.0"), "id": frame["id"], "error": .object([
                "code": .number(4001), "message": .string("admission_started"),
                "data": .object(["reason": .string("admission_started")])])]))
            return nil
        }
        return host.defaultReply(frame, socket: socket)
    }
    await #expect(throws: HermesServiceError.queuedMessageUnavailable) {
        _ = try await service.replaceQueuedMessage(original, text: "Revised", access: chat.access, operationID: UUID())
    }
    let methods = host.sockets[0].sent.compactMap { $0["method"].text }
    #expect(methods.filter { $0 == "prompt.replace_queued" }.count == 1)
    #expect(!methods.contains("prompt.submit") && !methods.contains("session.steer"))
}

@MainActor @Test(arguments: ["send", "replace"], ["queued", "started", "departed", "start-event"])
func queueFramesBeforeAcknowledgmentOwnMembershipAndControls(_ mutation: String, _ phase: String) async throws {
    let host = try HermesTestHost(), service = host.service(requestTimeout: .seconds(5))
    defer { service.disconnect() }
    host.snapshot["pending"] = .array([queuedRow("old", text: "Original", controls: ["replace"])])
    var current: OpenedConversation?
    service.onEvent = { if case .conversation(let value) = $0 { current = value } }
    _ = try await service.connect(configuration: host.configuration)
    let chat = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    let original = try #require(chat.snapshot.queuedMessages.first)
    let method = mutation == "send" ? "prompt.submit" : "prompt.replace_queued"
    var held: HermesJSON?
    host.methodOverride = { frame, socket in
        if frame["method"].text == method { held = frame; return nil }
        return host.defaultReply(frame, socket: socket)
    }
    let operation = UUID()
    let write = Task {
        if mutation == "send" {
            return try await service.send(text: "Revised", attachments: [], access: chat.access, operationID: operation)
        }
        return try await service.replaceQueuedMessage(original, text: "Revised", access: chat.access, operationID: operation)
    }
    try await eventually { held != nil }
    let pending = phase == "departed" ? [] : [queuedRow("new", text: "Revised", input: operation.uuidString,
        controls: ["replace"], status: phase == "started" ? "started" : "queued")]
    host.sockets[0].push(host.event("session.info", seq: 1, payload: ["pending": .array(pending)]))
    try await eventually { current?.snapshot.lastSequence == 1 }
    if phase == "start-event" {
        var start = host.event("message.start", seq: 2)
        start["params"]["admission_id"] = .string("new")
        host.sockets[0].push(start)
        try await eventually { current?.snapshot.lastSequence == 2 }
    }
    let beforeACK = current?.snapshot.queuedMessages
    let request = try #require(held)
    host.sockets[0].push(.object(["jsonrpc": .string("2.0"), "id": request["id"],
        "result": queuedReceipt(host, admission: "new")]))
    _ = try await write.value
    #expect(current?.snapshot.queuedMessages == beforeACK)
    if phase == "queued" {
        #expect(current?.snapshot.queuedMessages == [QueuedMessage(id: "new", text: "Revised", canEdit: true, submissionID: operation.uuidString)])
    } else {
        #expect(current?.snapshot.queuedMessages.isEmpty == true)
    }
    if phase == "start-event" {
        #expect(current?.snapshot.messages.filter { $0.id == "submission:" + operation.uuidString }.map(\.text) == ["Revised"])
    }
}

@MainActor @Test func sidecarQueueProjectionIsReadOnlyAndSurvivesUnrelatedStart() async throws {
    let host = try HermesTestHost(authority: false), service = host.service()
    defer { service.disconnect() }
    host.snapshot["queued"] = .object(["user": .string("Waiting on sidecar")])
    var current: OpenedConversation?
    service.onEvent = { if case .conversation(let value) = $0 { current = value } }
    _ = try await service.connect(configuration: host.configuration)
    let chat = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    let queue = try #require(chat.snapshot.queuedMessages.first)
    #expect(queue.text == "Waiting on sidecar" && !queue.canEdit && queue.submissionID == nil)
    await #expect(throws: HermesServiceError.queuedMessageUnavailable) {
        _ = try await service.replaceQueuedMessage(queue, text: "Cannot edit", access: chat.access, operationID: UUID())
    }
    host.sockets[0].push(host.event("message.start", seq: 1))
    try await eventually { current?.snapshot.lastSequence == 1 }
    #expect(current?.snapshot.queuedMessages == [queue])
    host.sockets[0].push(host.event("session.info", seq: 2, payload: ["queued": .null]))
    try await eventually { current?.snapshot.lastSequence == 2 }
    #expect(current?.snapshot.queuedMessages.isEmpty == true)
    #expect(!host.sockets[0].sent.contains { $0["method"].text == "prompt.replace_queued" })
}

@MainActor @Test func sidecarQueuedSendReceiptShowsOnlyReadOnlyLocalIdentity() async throws {
    let host = try HermesTestHost(authority: false), service = host.service()
    defer { service.disconnect() }
    var current: OpenedConversation?
    service.onEvent = { if case .conversation(let value) = $0 { current = value } }
    _ = try await service.connect(configuration: host.configuration)
    let chat = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    host.methodOverride = { frame, socket in
        if frame["method"].text == "prompt.submit" { return .object(["status": .string("queued")]) }
        return host.defaultReply(frame, socket: socket)
    }
    let operation = UUID()
    let receipt = try await service.send(text: "Sidecar follow-up", attachments: [], access: chat.access, operationID: operation)
    #expect(receipt.admissionID == nil)
    let queue = try #require(current?.snapshot.queuedMessages.first)
    #expect(queue.text == "Sidecar follow-up" && !queue.canEdit && !queue.isSteering)
    #expect(queue.submissionID == operation.uuidString)
    host.sockets[0].push(host.event("message.start", seq: 1))
    try await eventually { current?.snapshot.lastSequence == 1 }
    #expect(current?.snapshot.queuedMessages == [queue])
}

@MainActor @Test func queuedReplacementAcknowledgmentSurvivesCancellationAndSourceSwitch() async throws {
    let host = try HermesTestHost(), service = host.service(requestTimeout: .seconds(5))
    defer { service.disconnect() }
    host.snapshot["pending"] = .array([queuedRow("old", text: "Original", controls: ["replace"])])
    _ = try await service.connect(configuration: host.configuration)
    let a = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    let original = try #require(a.snapshot.queuedMessages.first)
    var held: HermesJSON?
    let acknowledgment = queuedReceipt(host, admission: "replacement-A")
    host.methodOverride = { frame, socket in
        if frame["method"].text == "prompt.replace_queued" { held = frame; return nil }
        return host.defaultReply(frame, socket: socket)
    }
    let operation = UUID()
    let write = Task { try await service.replaceQueuedMessage(original, text: "Edited in A", access: a.access, operationID: operation) }
    try await eventually { held != nil }
    await #expect(throws: HermesServiceError.staleConversation) {
        _ = try await service.replaceQueuedMessage(original, text: "Edited in A", access: a.access, operationID: operation)
    }
    write.cancel()
    host.snapshot["session_id"] = .string("runtime-B")
    host.snapshot["stored_session_id"] = .string("stored-B")
    host.snapshot["subscription_id"] = .string("subscription-B")
    host.snapshot["execution_generation"] = .number(22)
    host.snapshot["pending"] = .array([queuedRow("queue-B", text: "Only B", controls: ["replace"])])
    let identity = try SessionIdentity(profile: ExactID(host.bot.id), root: ExactID("root-B"), stored: ExactID("stored-B"),
        aliases: [ExactID("root-B"), ExactID("stored-B")])
    host.storedRows = [.object(["id": .string("stored-B"), "_lineage_root_id": .string("root-B"),
        "_lineage_ids": .array([.string("root-B"), .string("stored-B")])])]
    let b = try await service.openChat(.stored(identity))
    var current = b
    service.onEvent = { if case .conversation(let value) = $0 { current = value } }
    let request = try #require(held), socket = host.sockets[0]
    socket.push(.object(["jsonrpc": .string("2.0"), "id": request["id"], "result": acknowledgment]))
    let receipt = try await write.value
    #expect(receipt.source == a.identity && receipt.operationID == operation && receipt.admissionID == "replacement-A")
    #expect(current.snapshot == b.snapshot)
    #expect(!socket.closed)
    #expect(socket.sent.filter { $0["method"].text == "prompt.replace_queued" }.count == 1)
}

@MainActor @Test(arguments: ["before-write", "after-ACK"])
func queuedReplacementHonorsJournalDurability(_ failure: String) async throws {
    let host = try HermesTestHost()
    host.snapshot["pending"] = .array([queuedRow("old", text: "Original", controls: ["replace"])])
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let service = HermesBotService(transportFactory: { host.transport }, journal: HermesSubmissionJournal(directory: directory))
    defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let chat = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    let original = try #require(chat.snapshot.queuedMessages.first)
    let operation = UUID()
    if failure == "before-write" { try Data("occupied".utf8).write(to: directory) }
    host.methodOverride = { frame, socket in
        if frame["method"].text == "prompt.replace_queued" {
            let saved = try String(contentsOf: directory.appendingPathComponent("identities.json"), encoding: .utf8)
            #expect(saved.contains(operation.uuidString))
            #expect(!saved.contains("Private revised text"))
            try FileManager.default.removeItem(at: directory)
            try Data("occupied".utf8).write(to: directory)
            return queuedReceipt(host, admission: "new")
        }
        return host.defaultReply(frame, socket: socket)
    }
    if failure == "before-write" {
        await #expect(throws: HermesServiceError.submissionStorage) {
            _ = try await service.replaceQueuedMessage(original, text: "Private revised text", access: chat.access, operationID: operation)
        }
        #expect(!host.sockets[0].sent.contains { $0["method"].text == "prompt.replace_queued" })
    } else {
        let receipt = try await service.replaceQueuedMessage(original, text: "Private revised text", access: chat.access, operationID: operation)
        #expect(receipt.admissionID == "new")
        if case .needsLocalRepair = receipt.journal {} else { Issue.record("Confirmed replacement must report local journal repair") }
        #expect(host.sockets[0].sent.filter { $0["method"].text == "prompt.replace_queued" }.count == 1)
    }
}

@MainActor @Test(arguments: ["session", "profile", "status", "same-admission", "unknown"])
func queuedReplacementRejectsUnconfirmedReceiptWithoutSubmittingAgain(_ invalid: String) async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    host.snapshot["pending"] = .array([queuedRow("old", text: "Original", controls: ["replace"])])
    _ = try await service.connect(configuration: host.configuration)
    let chat = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    let original = try #require(chat.snapshot.queuedMessages.first)
    host.methodOverride = { frame, socket in
        if frame["method"].text == "prompt.replace_queued" {
            var reply = queuedReceipt(host, admission: "new")
            switch invalid {
            case "session": reply["ref"]["session_id"] = .string("different-session")
            case "profile": reply["ref"]["profile_id"] = .string("different-profile")
            case "status": reply["status"] = .string("maybe")
            case "same-admission": reply["admission_id"] = .string("old")
            default: reply["status"] = .string("unknown")
            }
            return reply
        }
        return host.defaultReply(frame, socket: socket)
    }
    let operation = UUID()
    await #expect(throws: HermesServiceError.uncertain) {
        _ = try await service.replaceQueuedMessage(original, text: "Revised", access: chat.access, operationID: operation)
    }
    await #expect(throws: HermesServiceError.staleConversation) {
        _ = try await service.replaceQueuedMessage(original, text: "Revised", access: chat.access, operationID: operation)
    }
    let methods = host.sockets[0].sent.compactMap { $0["method"].text }
    #expect(methods.filter { $0 == "prompt.replace_queued" }.count == 1)
    #expect(!methods.contains("prompt.submit") && !methods.contains("session.steer"))
}

@MainActor @Test func queuedReplacementConnectionLossIsUncertainAndNeverResent() async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    host.snapshot["pending"] = .array([queuedRow("old", text: "Original", controls: ["replace"])])
    _ = try await service.connect(configuration: host.configuration)
    let chat = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    let original = try #require(chat.snapshot.queuedMessages.first)
    host.methodOverride = { frame, socket in
        if frame["method"].text == "prompt.replace_queued" { socket.close(); return nil }
        return host.defaultReply(frame, socket: socket)
    }
    let operation = UUID()
    await #expect(throws: HermesServiceError.uncertain) {
        _ = try await service.replaceQueuedMessage(original, text: "Revised", access: chat.access, operationID: operation)
    }
    var recovered: OpenedConversation?
    service.onEvent = { if case .conversation(let value) = $0 { recovered = value } }
    try await eventually { recovered != nil }
    let current = try #require(recovered)
    await #expect(throws: HermesServiceError.staleConversation) {
        _ = try await service.replaceQueuedMessage(original, text: "Revised", access: current.access, operationID: operation)
    }
    let methods = host.sockets.flatMap(\.sent).compactMap { $0["method"].text }
    #expect(methods.filter { $0 == "prompt.replace_queued" }.count == 1)
    #expect(!methods.contains("prompt.submit") && !methods.contains("session.steer"))
}

@MainActor @Test func retiringReplacedQueueItemDoesNotFinishTheRunningTurn() async throws {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    host.snapshot["running"] = .bool(true)
    host.snapshot["pending"] = .array([queuedRow("old", text: "Original", controls: ["replace"])])
    var current: OpenedConversation?
    service.onEvent = { if case .conversation(let value) = $0 { current = value } }
    _ = try await service.connect(configuration: host.configuration)
    _ = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    host.sockets[0].push(host.event("message.delta", seq: 1, payload: ["text": .string("Still running")]))
    try await eventually { current?.snapshot.lastSequence == 1 }
    // session_queued_controls retires the old admission without an execution generation.
    var retired = host.event("message.complete", seq: 2, payload: ["text": .string(""),
        "content": .string(""), "admission_id": .string("old"), "outcome": .string("cancelled")])
    retired["params"]["execution_generation"] = .null
    retired["params"]["admission_id"] = .string("old")
    host.sockets[0].push(retired)
    try await eventually { current?.snapshot.lastSequence == 2 }
    #expect(current?.snapshot.isWorking == true)
    #expect(current?.snapshot.messages.last?.text == "Still running")
    #expect(current?.snapshot.queuedMessages.isEmpty == true)
}

@MainActor @Test func editedQueueMessageBecomesTheUserTurnWhenItStarts() async throws {
    let host = try HermesTestHost(), service = host.service()
    host.snapshot["running"] = .bool(true)
    defer { service.disconnect() }
    var current: OpenedConversation?
    service.onEvent = { if case .conversation(let value) = $0 { current = value } }
    _ = try await service.connect(configuration: host.configuration)
    let chat = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    let originalOperation = UUID()
    host.methodOverride = { frame, socket in
        if frame["method"].text == "prompt.submit" { return queuedReceipt(host, admission: "old") }
        if frame["method"].text == "prompt.replace_queued" { return queuedReceipt(host, admission: "new") }
        return host.defaultReply(frame, socket: socket)
    }
    _ = try await service.send(text: "Original", attachments: [], access: chat.access, operationID: originalOperation)
    host.sockets[0].push(host.event("session.info", seq: 1, payload: ["pending": .array([
        queuedRow("old", text: "Original", input: originalOperation.uuidString, controls: ["replace"])])]))
    try await eventually { current?.snapshot.lastSequence == 1 }
    let original = try #require(current?.snapshot.queuedMessages.first)
    let editOperation = UUID(), edit = "Revised\n  exactly"
    _ = try await service.replaceQueuedMessage(original, text: edit, access: chat.access, operationID: editOperation)
    var start = host.event("message.start", seq: 2)
    start["params"]["admission_id"] = .string("new")
    host.sockets[0].push(start)
    try await eventually { current?.snapshot.lastSequence == 2 }
    #expect(current?.snapshot.queuedMessages.isEmpty == true)
    #expect(current?.snapshot.messages.filter { $0.role == .user }.map(\.text) == [edit])
    #expect(current?.snapshot.messages.contains { $0.id == "submission:" + editOperation.uuidString } == true)
}

@MainActor @Test(arguments: ["queued", "started"], ["delta", "interim", "tool", "later-stream", "tool-first"])
func replacementStartedBeforeAnyPendingFrameStillShowsItsText(_ status: String, _ output: String) async throws {
    let host = try HermesTestHost(), service = host.service(requestTimeout: .seconds(5))
    defer { service.disconnect() }
    host.snapshot["pending"] = .array([queuedRow("old", text: "Original", controls: ["replace"])])
    var current: OpenedConversation?
    service.onEvent = { if case .conversation(let value) = $0 { current = value } }
    _ = try await service.connect(configuration: host.configuration)
    let chat = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    let original = try #require(chat.snapshot.queuedMessages.first)
    var held: HermesJSON?
    host.methodOverride = { frame, socket in
        if frame["method"].text == "prompt.replace_queued" { held = frame; return nil }
        return host.defaultReply(frame, socket: socket)
    }
    let operation = UUID()
    let saving = Task { try await service.replaceQueuedMessage(original, text: "Edited\nmessage", access: chat.access, operationID: operation) }
    try await eventually { held != nil }
    var start = host.event("message.start", seq: 1)
    start["params"]["admission_id"] = .string("replacement")
    host.sockets[0].push(start)
    var sequence = 1
    if output != "tool-first" {
        sequence += 1
        host.sockets[0].push(host.event("message.delta", seq: sequence, payload: ["text": .string("Reply already streaming")]))
    }
    if output != "delta" && output != "tool-first" {
        sequence += 1
        host.sockets[0].push(host.event("message.interim", seq: sequence, payload: ["already_streamed": .bool(true)]))
    }
    if output == "tool" || output == "later-stream" || output == "tool-first" {
        sequence += 1
        host.sockets[0].push(host.event("tool.start", seq: sequence, payload: ["tool_id": .string("lookup"), "name": .string("Lookup")]))
        sequence += 1
        host.sockets[0].push(host.event("tool.complete", seq: sequence, payload: ["tool_id": .string("lookup"), "result_text": .string("Found it")]))
    }
    if output == "later-stream" {
        sequence += 1
        host.sockets[0].push(host.event("message.delta", seq: sequence, payload: ["text": .string("Later reply")]))
    }
    try await eventually { current?.snapshot.lastSequence == sequence }
    host.sockets[0].push(.object(["jsonrpc": .string("2.0"), "id": try #require(held)["id"],
                                "result": queuedReceipt(host, admission: "replacement", status: status)]))
    _ = try await saving.value
    #expect(current?.snapshot.messages.filter { $0.id == "submission:" + operation.uuidString }.map(\.text) == ["Edited\nmessage"])
    #expect(current?.snapshot.queuedMessages.isEmpty == true)
    var expected = ["Edited\nmessage"]
    if output != "tool-first" { expected.append("Reply already streaming") }
    if output == "tool" || output == "later-stream" || output == "tool-first" { expected.append("Found it") }
    if output == "later-stream" { expected.append("Later reply") }
    #expect(current?.snapshot.messages.map(\.text) == expected)
}

@Test func queuedUserEchoMovesAfterTheReplyThatFinishedAheadOfIt() {
    var state = HermesConversationState(profile: "profile", root: "root", stored: "stored", runtime: "runtime", epoch: "epoch")
    state.conversation.messages = [
        ChatMessage(id: "submission:queued-input", role: .user, text: "Next prompt"),
        ChatMessage(id: "prior-reply", role: .assistant, text: "Reply that finished first")]
    state.conversation.queuedMessages = [QueuedMessage(id: "queued-admission", text: "Next prompt", submissionID: "queued-input")]
    state.reduce(.object(["type": .string("message.start"), "admission_id": .string("queued-admission"),
                          "seq": .number(1), "payload": .object([:])]), authority: true)
    #expect(state.conversation.messages.map(\.id) == ["prior-reply", "submission:queued-input"])
    #expect(state.conversation.queuedMessages.isEmpty)
}

// Completion immediately starts a refresh in the service. This checks that its
// source fence also protects the transcript while the replacement ACK is held.
@MainActor @Test(arguments: ["queued", "started"])
func replacementAcknowledgedDuringCompletionRefreshKeepsOneDurableUserRow(_ status: String) async throws {
    let host = try HermesTestHost(), service = host.service(requestTimeout: .seconds(5))
    defer { service.disconnect() }
    host.snapshot["pending"] = .array([queuedRow("old", text: "Original", controls: ["replace"])])
    var current: OpenedConversation?
    service.onEvent = { if case .conversation(let value) = $0 { current = value } }
    _ = try await service.connect(configuration: host.configuration)
    let chat = try await service.openChat(.canonical(profile: try ExactID(host.bot.id), expectedRoot: nil))
    let original = try #require(chat.snapshot.queuedMessages.first)
    var held: HermesJSON?
    host.methodOverride = { frame, socket in
        if frame["method"].text == "prompt.replace_queued" { held = frame; return nil }
        return host.defaultReply(frame, socket: socket)
    }
    let operation = UUID()
    let saving = Task { try await service.replaceQueuedMessage(original, text: "Edited", access: chat.access, operationID: operation) }
    try await eventually { held != nil }
    host.sockets[0].push(host.event("session.info", seq: 1, payload: ["pending": .array([
        queuedRow("replacement", text: "Edited", input: operation.uuidString, controls: ["replace"])])]))
    var start = host.event("message.start", seq: 2)
    start["params"]["admission_id"] = .string("replacement")
    host.sockets[0].push(start)
    host.sockets[0].push(host.event("message.complete", seq: 3, payload: ["text": .string("Finished"),
        "persisted_turn": .object(["submission_id": .string(operation.uuidString),
            "user_row_id": .number(101), "final_assistant_row_id": .number(102)])]))
    try await eventually { current?.snapshot.lastSequence == 3 }
    #expect(current?.snapshot.messages.map(\.id) == [chat.snapshot.storedID + ":row:101", chat.snapshot.storedID + ":row:102"])
    host.sockets[0].push(.object(["jsonrpc": .string("2.0"), "id": try #require(held)["id"],
        "result": queuedReceipt(host, admission: "replacement", status: status)]))
    _ = try await saving.value
    #expect(current?.snapshot.messages.map(\.id) == [chat.snapshot.storedID + ":row:101", chat.snapshot.storedID + ":row:102"])
    #expect(current?.snapshot.messages.map(\.text) == ["Edited", "Finished"])
    #expect(current?.snapshot.queuedMessages.isEmpty == true)
    #expect(host.sockets[0].sent.filter { $0["method"].text == "prompt.replace_queued" }.count == 1)
    #expect(!host.sockets[0].sent.contains { ["prompt.submit", "session.steer"].contains($0["method"].text ?? "") })
}

// Exercise the reducer independently of the service's completion refresh fence.
@MainActor @Test(arguments: [false, true], ["final-only", "interim-tools", "next-turn"])
func replacementIdentityAndAdmissionBoundarySurviveCompletion(_ projected: Bool, _ output: String) throws {
    let host = try HermesTestHost()
    var state = HermesConversationState(profile: "profile", root: "root", stored: "stored", runtime: host.runtime, epoch: "epoch")
    // Repeated text has no bearing on submission identity.
    state.conversation.messages = [ChatMessage(id: "stored:row:90", role: .user, text: "Edited"),
        ChatMessage(id: "stored:row:91", role: .assistant, text: "Earlier reply")]
    state.queuedReplacement = .init(submission: "replacement-input")
    if projected {
        state.applyPending(.array([queuedRow("replacement", text: "Edited", input: "replacement-input")]))
    }
    var sequence = 0
    func event(_ type: String, admission: String? = nil, payload: [String: HermesJSON] = [:]) -> HermesJSON {
        sequence += 1
        var frame = host.event(type, seq: sequence, payload: payload)["params"]
        if let admission { frame["admission_id"] = .string(admission) }
        return frame
    }
    // Another client's turn can start while the replacement receipt is held.
    state.reduce(event("message.start", admission: "unrelated"), authority: true)
    state.reduce(event("message.complete", payload: ["text": .string("Unrelated reply"),
        "persisted_turn": .object(["submission_id": .string("unrelated-input"),
            "user_row_id": .number(95), "final_assistant_row_id": .number(96)])]), authority: true)
    state.reduce(event("message.start", admission: "replacement"), authority: true)
    if output != "final-only" {
        state.reduce(event("message.delta", payload: ["text": .string("Interim reply")]), authority: true)
        state.reduce(event("message.interim", payload: ["already_streamed": .bool(true)]), authority: true)
        state.reduce(event("tool.start", payload: ["tool_id": .string("lookup")]), authority: true)
        state.reduce(event("tool.complete", payload: ["tool_id": .string("lookup"), "result_text": .string("Found it")]), authority: true)
    }
    state.reduce(event("message.complete", payload: ["text": .string("Finished"),
        "persisted_turn": .object(["submission_id": .string("replacement-input"),
            "user_row_id": .number(101), "final_assistant_row_id": .number(102)])]), authority: true)
    if output == "next-turn" {
        state.applyPending(.array([queuedRow("next", text: "Next prompt", input: "next-input")]))
        state.reduce(event("message.start", admission: "next"), authority: true)
        state.reduce(event("message.delta", payload: ["text": .string("Next reply")]), authority: true)
    }
    let boundary = try #require(state.queuedReplacement?.turn("replacement"))
    state.addSubmittedText("Edited", submission: "replacement-input", beforeMessageID: boundary.beforeMessageID)
    #expect(state.conversation.messages.filter { $0.role == .user }.map(\.id) ==
        (output == "next-turn" ? ["stored:row:90", "stored:row:101", "submission:next-input"] : ["stored:row:90", "stored:row:101"]))
    var expected = ["Edited", "Earlier reply", "Unrelated reply", "Edited"]
    if output != "final-only" { expected += ["Interim reply", "Found it"] }
    expected.append("Finished")
    if output == "next-turn" { expected += ["Next prompt", "Next reply"] }
    #expect(state.conversation.messages.map(\.text) == expected)
    #expect(!state.optimistic.contains("submission:replacement-input"))
}
