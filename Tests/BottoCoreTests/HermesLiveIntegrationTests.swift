import Foundation
import Testing
@testable import BottoCore

/// Explicit opt-in only: creates one named profile on the caller's disposable host.
/// Normal swift test never contacts a server or consumes a model token.
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["BOTTO_TEST_HERMES_URL"] != nil))
func disposableAuthorityHostThroughPublicService() async throws {
    let env = ProcessInfo.processInfo.environment
    let address = try #require(env["BOTTO_TEST_HERMES_URL"]), url = try #require(URL(string: address))
    let capture = LiveCapture()
    let service = HermesBotService(transportFactory: { LiveObservedTransport(capture: capture) })
    defer { service.disconnect() }
    var snapshots: [Conversation] = []
    var disconnections: [String] = []
    service.onEvent = { event in
        switch event {
        case .conversation(let value): snapshots.append(value.snapshot)
        case .disconnected(let message): disconnections.append(message)
        default: break
        }
    }
    let configuration = ConnectionConfiguration(serverURL: url,
        username: env["BOTTO_TEST_HERMES_USER"] ?? "botto-test", password: env["BOTTO_TEST_HERMES_PASSWORD"] ?? "botto-test")
    let server = try await service.connect(configuration: configuration)
    #expect(server.installID?.isEmpty == false)
    let unique = "Botto Core Probe " + String(UUID().uuidString.prefix(8)).lowercased()
    let bot = try await service.createBot(BotDraft(name: unique, instructions: "You are a disposable client interoperability probe. Reply briefly.",
        avatar: .face(.init(shape: .cloud, color: "#14b8a6"))))
    #expect(bot.name == unique)
    #expect(bot.face == BotFace(shape: .cloud, color: "hsl(180 68% 58%)"))
    let updated = try await service.setAvatar(.face(.init(shape: .drop, color: "#22c55e")), for: bot)
    #expect(updated.face == BotFace(shape: .drop, color: "hsl(120 68% 58%)"))
    #expect(try await service.bots().first { $0.id == bot.id }?.face == updated.face)
    let chat = try await service.openChat(.canonical(profile: try ExactID(bot.id), expectedRoot: nil))
    _ = try await service.send(text: "Reply with one brief greeting.", attachments: [], access: chat.access, operationID: UUID())
    let until = ContinuousClock.now + .seconds(60)
    while ContinuousClock.now < until {
        if let last = snapshots.last, !last.isWorking, last.messages.contains(where: { $0.role == .assistant && !$0.text.isEmpty }) { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    let final = try #require(snapshots.last)
    #expect(final.messages.contains { $0.role == .assistant && !$0.text.isEmpty })
    #expect(disconnections.isEmpty)
    service.disconnect()
    _ = try await service.connect(configuration: configuration)
    let reopened = try await service.openChat(.canonical(profile: try ExactID(bot.id), expectedRoot: nil))
    #expect(reopened.snapshot.storedID == chat.snapshot.storedID)
    #expect(reopened.snapshot.messages.contains { $0.role == .user && $0.text.contains("brief greeting") })
    #expect(reopened.snapshot.messages.contains { $0.role == .assistant && !$0.text.isEmpty })
    _ = try await service.send(text: "BOTTO_APPROVAL", attachments: [], access: reopened.access, operationID: UUID())
    try await waitForLive { snapshots.last?.pendingRequests.contains { $0.kind == .approval } == true }
    let pending = try #require(snapshots.last?.pendingRequests.first { $0.kind == .approval })
    service.disconnect()
    _ = try await service.connect(configuration: configuration)
    // Inbox discovery must find a waiting Bot Chat before any selected-chat override.
    #expect(try await service.bots().first { $0.id == bot.id }?.status == .waiting)
    let waiting = try await service.openChat(.canonical(profile: try ExactID(bot.id), expectedRoot: nil))
    let recovered = try #require(waiting.snapshot.pendingRequests.first { $0.id == pending.id })
    _ = try await service.respond(to: recovered, response: .choice("once"), access: waiting.access, operationID: UUID())
    try await waitForLive {
        snapshots.last?.isWorking == false && snapshots.last?.messages.contains {
            $0.role == .assistant && $0.text.contains("BOTTO_TOOL_DONE") && $0.text.contains("BOTTO_APPROVAL_OK")
        } == true
    }
    let settled = try await service.openChat(.canonical(profile: try ExactID(bot.id), expectedRoot: nil))
    #expect(settled.snapshot.pendingRequests.isEmpty)
    #expect(Set(settled.snapshot.messages.map(\.id)).count == settled.snapshot.messages.count)
    let file = try await service.upload(data: Data("Local integration evidence".utf8), filename: "probe.txt", mimeType: "text/plain", access: settled.access)
    #expect(file.path.hasPrefix("/"))
    let downloadedFile = try await service.downloadArtifact(file, access: settled.access)
    #expect(downloadedFile.data == Data("Local integration evidence".utf8))
    #expect(downloadedFile.filename.hasSuffix("probe.txt"))
    #expect(downloadedFile.mimeType.hasPrefix("text/plain"))
    let picture = try await service.upload(data: attachmentPNG, filename: "pixel.png", mimeType: "image/png", access: settled.access)
    let downloadedPicture = try await service.downloadArtifact(picture, access: settled.access)
    // Upload prepares native images with ImageIO. Download must preserve the
    // resulting host bytes, including that encoding's color/EXIF metadata.
    let preparedPicture = try HermesAttachment.prepare(data: attachmentPNG, filename: "pixel.png", mime: "image/png")
    #expect(downloadedPicture.data == preparedPicture.data)
    #expect(downloadedPicture.mimeType == "image/png")
    _ = try await service.send(text: "Confirm attached evidence.", attachments: [file, picture], access: settled.access, operationID: UUID())
    let priorAssistantCount = settled.snapshot.messages.filter { $0.role == .assistant }.count
    try await waitForLive {
        snapshots.last?.isWorking == false && (snapshots.last?.messages.filter { $0.role == .assistant }.count ?? 0) > priorAssistantCount
    }
    let withAttachments = try await service.openChat(.canonical(profile: try ExactID(bot.id), expectedRoot: nil))
    #expect(withAttachments.snapshot.messages.contains { $0.role == .user && $0.text.contains("Confirm attached evidence.") })
    #expect(Set(withAttachments.snapshot.messages.map(\.id)).count == withAttachments.snapshot.messages.count)
    #expect(disconnections.isEmpty)
    if let destination = env["BOTTO_TEST_CAPTURE_PATH"] {
        let report: HermesJSON = .object(["source_commit": .string("4a0eaf7989b6804319ddb94fa5d96c5a716080a1"),
            "profile": .string(bot.id), "frames": .array(capture.frames)])
        try report.data.write(to: URL(fileURLWithPath: destination), options: .atomic)
    }
    print("BOTTO_LIVE_EVIDENCE profile=\(bot.id) version=\(server.version) messages=\(withAttachments.snapshot.messages.count) stored=\(settled.snapshot.storedID) file=sent-and-downloaded image=sent-and-downloaded approval=recovered-and-resolved")
}

@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["BOTTO_TEST_HERMES_URL"] != nil))
func disposableHostDiscoversChatsCreatedByAnotherClient() async throws {
    let env = ProcessInfo.processInfo.environment
    let address = try #require(env["BOTTO_TEST_HERMES_URL"]), url = try #require(URL(string: address))
    let configuration = ConnectionConfiguration(serverURL: url,
        username: env["BOTTO_TEST_HERMES_USER"] ?? "botto-test", password: env["BOTTO_TEST_HERMES_PASSWORD"] ?? "botto-test")
    let observer = HermesBotService(), otherClient = HermesBotService()
    defer { observer.disconnect(); otherClient.disconnect() }
    _ = try await observer.connect(configuration: configuration)
    _ = try await otherClient.connect(configuration: configuration)
    let bot = try await otherClient.createBot(.init(name: "Discovery probe " + String(UUID().uuidString.prefix(8)),
        instructions: "A disposable local activity discovery probe.", avatar: .face(.init(shape: .cloud, color: "#14b8a6"))))
    let profile = try ExactID(bot.id)
    _ = try await observer.bots()
    let initial = try await observer.conversations(profile: profile)
    var changes: [ExactID] = [], activity: [SessionIdentity: ObservedActivity] = [:]
    observer.onEvent = {
        if case .conversationDirectoryChanged(let changed) = $0 { changes.append(changed) }
        for update in $0.activityUpdates where update.profile == profile { activity = update.observations }
    }
    let created = try await otherClient.createConversation(profile: profile, operationID: UUID())
    _ = try await observer.bots()
    #expect(changes.contains(profile))
    let refreshed = try await observer.conversations(profile: profile)
    let discovered = try #require(refreshed.summaries.first { $0.identity.root == created.summary.identity.root })
    #expect(refreshed.summaries.count > initial.summaries.count)
    if case .known(.idle, _) = refreshed.activity[discovered.identity] {} else { Issue.record("The idle remote chat was not discovered") }
    var current: OpenedConversation?
    otherClient.onEvent = { if case .conversation(let value) = $0 { current = value } }
    let opened = try await otherClient.openChat(.stored(created.summary.identity))
    _ = try await otherClient.send(text: "BOTTO_APPROVAL", attachments: [], access: opened.access, operationID: UUID())
    try await waitForLive { current?.snapshot.pendingRequests.contains { $0.kind == .approval } == true }
    _ = try await observer.bots()
    if case .known(.waiting, _) = activity[discovered.identity] {} else { Issue.record("The observer missed the remote approval") }
    let waiting = try #require(current), request = try #require(waiting.snapshot.pendingRequests.first { $0.kind == .approval })
    _ = try await otherClient.respond(to: request, response: .choice("once"), access: waiting.access, operationID: UUID())
    try await waitForLive { current?.snapshot.isWorking == false && current?.snapshot.pendingRequests.isEmpty == true }
    _ = try await observer.bots()
    if case .known(.idle, _) = activity[discovered.identity] {} else { Issue.record("The observer retained stale waiting activity") }
    print("BOTTO_DISCOVERY_LIVE profile=\(bot.id) clients=2 idle-chat=discovered approval=observed-and-cleared")
}

@MainActor private func waitForLive(_ predicate: () -> Bool) async throws {
    let until = ContinuousClock.now + .seconds(60)
    while !predicate(), ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(100)) }
    try #require(predicate())
}

/// Records only session RPC results and events from this disposable fixture. Never HTTP,
/// credentials, tickets, or full runtime/profile configuration. Opt-in export for provenance.
@MainActor private final class LiveCapture {
    var frames: [HermesJSON] = []
}

@MainActor private final class LiveObservedTransport: HermesTransport {
    let native = NativeHermesTransport()
    let capture: LiveCapture
    init(capture: LiveCapture) { self.capture = capture }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) { try await native.data(for: request) }
    func socket(for request: URLRequest) throws -> any HermesSocket { LiveObservedSocket(socket: try native.socket(for: request), capture: capture) }
    func invalidate() { native.invalidate() }
}

@MainActor private final class LiveObservedSocket: HermesSocket {
    let socket: any HermesSocket
    let capture: LiveCapture
    var methods: [Int: String] = [:]
    init(socket: any HermesSocket, capture: LiveCapture) { self.socket = socket; self.capture = capture }
    func send(_ data: Data) async throws {
        let frame = try HermesJSON.decode(data)
        if let id = frame["id"].integer { methods[id] = frame["method"].text }
        try await socket.send(data)
    }
    func receive() async throws -> Data {
        let data = try await socket.receive(), frame = try HermesJSON.decode(data)
        if let id = frame["id"].integer, let method = methods[id] {
            let result = frame["result"]
            let reason = frame["error"]["data"]["reason"].text ?? ""
            if !reason.isEmpty, reason.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == "_") }) { print("BOTTO_REFUSAL \(method) \(reason)") }
            print("BOTTO_RPC method=\(method) resultKeys=\((result.fields ?? [:]).keys.sorted()) error=\(frame["error"]["code"].integer ?? 0) ok=\(String(describing: result["ok"].flag)) soul=\(String(describing: result["soul_written"].flag)) ui=\(String(describing: result["applied"]["ui_meta"].flag))")
            if ["session.resume", "session.events.since", "prompt.submit", "approval.respond"].contains(method) {
                var value = result
                if let info = value["info"].fields {
                    value["info"] = .object(info.filter { ["profile_name", "profile_id", "title"].contains($0.key) })
                }
                capture.frames.append(.object(["method": .string(method), "result": value]))
            }
        } else if frame["method"].text == "event", frame["params"]["session_id"].text != nil {
            capture.frames.append(frame)
        }
        return data
    }
    func close() { socket.close() }
}
