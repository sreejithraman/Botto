import Foundation
import CryptoKit
import Testing
@testable import BottoCore

private let generatedCat = #"{"version":1,"id":"cat","name":"Cat","body":{"path":"M18 34 L18 12 Q18 8 23 12 L35 24 Q50 20 65 24 L77 12 Q82 8 82 12 L82 34 Q90 40 88 62 Q88 86 50 88 Q12 86 12 62 Q10 40 18 34 Z"},"eyes":{"x":50,"y":48,"spacing":16,"scale":1}}"#
private let canonicalInvalidAvatar = #"{"version":1,"id":"tiny","name":"Tiny","body":{"path":"M0 0 L1 0 L1 1 L0 1 Z"},"eyes":{"x":50,"y":50,"spacing":16,"scale":1}}"#

@MainActor @Test func avatarGenerationRecoversTheSameResultWithoutAnotherModelRequest() async throws {
    let host = try HermesTestHost()
    let worker = AvatarOperationFaultWorker(operation: .prepare, failures: 1)
    let engine = BotAvatarEngine(validator: worker, factory: { _ in worker })
    let service = host.service(avatarEngine: engine); defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let opened = try await service.openChat(.canonical(profile: ExactID(host.bot.id), expectedRoot: nil))
    let before = host.sockets[0].sent.count
    host.methodOverride = { frame, socket in
        if frame["method"].text == "llm.oneshot" { return .object(["text": .string(generatedCat)]) }
        return host.defaultReply(frame, socket: socket)
    }
    let expected = try await BotAvatarEngine.shared.validate(BotAvatarGeometry(json: generatedCat))
    let result = try await service.generateAvatar(description: "A sleepy cat", for: host.bot)
    #expect(result == expected)
    #expect(await worker.preparations == 2)
    #expect(host.sockets[0].sent.dropFirst(before).compactMap { $0["method"].text } == ["llm.oneshot"])
    _ = try await service.send(text: "The same chat remains usable", attachments: [], access: opened.access, operationID: UUID())
    #expect(host.sockets[0].sent.last?["method"].text == "prompt.submit")
}

@MainActor @Test(arguments: [false, true])
func avatarGenerationLocalRendererFailureStaysOperational(validation: Bool) async throws {
    let host = try HermesTestHost()
    let worker = AvatarOperationFaultWorker(operation: validation ? .validate : .prepare,
        failures: .max, failure: .unavailable)
    let service = host.service(avatarEngine: BotAvatarEngine(validator: worker, factory: { _ in worker }))
    defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    _ = try await service.openChat(.canonical(profile: ExactID(host.bot.id), expectedRoot: nil))
    host.methodOverride = { frame, socket in
        if frame["method"].text == "llm.oneshot" { return .object(["text": .string(generatedCat)]) }
        return host.defaultReply(frame, socket: socket)
    }
    await #expect(throws: BotAvatarEngineError.unavailable) {
        _ = try await service.generateAvatar(description: "A cat", for: host.bot)
    }
    #expect(validation ? await worker.validations == 3 : await worker.preparations == 3)
    #expect(host.sockets[0].sent.filter { $0["method"].text == "llm.oneshot" }.count == 1)
    #expect(!host.sockets[0].sent.contains { ["profiles.configure", "profiles.set_asset"].contains($0["method"].text ?? "") })
}

@MainActor @Test(arguments: ["save", "create"])
func avatarValidationRendererFailureNeverWritesOrBecomesInvalidInput(operation: String) async throws {
    let host = try HermesTestHost()
    let worker = AvatarOperationFaultWorker(operation: .validate, failures: .max)
    let service = host.service(avatarEngine: BotAvatarEngine(validator: worker, factory: { _ in worker }))
    defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let choice = BotAvatarChoice.geometry(try BotAvatarGeometry(json: generatedCat))
    await #expect(throws: BotAvatarEngineError.invalidFrame) {
        if operation == "save" { _ = try await service.setAvatar(choice, for: host.bot) }
        else { _ = try await service.createBot(BotDraft(name: "New Character", avatar: choice)) }
    }
    #expect(await worker.validations == 3)
    #expect(!host.sockets[0].sent.contains { ["profiles.create", "profiles.configure", "profiles.set_asset", "llm.oneshot"].contains($0["method"].text ?? "") })
}

@MainActor @Test(arguments: [false, true])
func avatarGenerationStopsLocalRecoveryOnCancellationOrDisconnect(disconnect: Bool) async throws {
    let host = try HermesTestHost()
    let worker = AvatarOperationFaultWorker(operation: .prepare, failures: .max)
    let service = host.service(avatarEngine: BotAvatarEngine(validator: worker, factory: { _ in worker }))
    defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    _ = try await service.openChat(.canonical(profile: ExactID(host.bot.id), expectedRoot: nil))
    host.methodOverride = { frame, socket in
        if frame["method"].text == "llm.oneshot" { return .object(["text": .string(generatedCat)]) }
        return host.defaultReply(frame, socket: socket)
    }
    let pending = Task { try await service.generateAvatar(description: "A cat", for: host.bot) }
    await worker.firstFailure()
    if disconnect { service.disconnect() } else { pending.cancel() }
    do {
        _ = try await pending.value
        Issue.record("Retired generation must not finish local preparation.")
    } catch {
        if disconnect { #expect(error as? HermesServiceError == .disconnected) }
        else { #expect(error is CancellationError) }
    }
    #expect(await worker.preparations == 1)
    #expect(host.sockets[0].sent.filter { $0["method"].text == "llm.oneshot" }.count == 1)
}

@MainActor @Test func avatarGenerationUsesSelectedBotRoutingWithoutWritingChatOrProfile() async throws {
    let host = try HermesTestHost()
    let service = host.service(); defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let opened = try await service.openChat(.canonical(profile: ExactID(host.bot.id), expectedRoot: nil))
    let before = host.sockets[0].sent.count
    host.methodOverride = { frame, socket in
        if frame["method"].text == "llm.oneshot" {
            #expect(frame["params"]["profile"].text == host.bot.id)
            #expect(frame["params"]["session_id"].text == host.runtime)
            #expect(frame["params"]["task"].text == "botto_avatar")
            #expect(frame["params"]["input"].text == "A sleepy cat")
            #expect(frame["params"]["instructions"].text?.hasPrefix("Botto avatar geometry\n\n# Avatar geometry designer") == true)
            #expect(frame["params"]["instructions"].text?.contains(#""id":"slug""#) == true)
            #expect(frame["params"]["instructions"].text?.contains("# Avatar geometry designer") == true)
            #expect(frame["params"]["instructions"].text?.contains("## Reference examples") == true)
            #expect(frame["params"]["instructions"].text?.contains("M L H V C S Q T A Z") == true)
            #expect(frame["params"]["instructions"].text?.contains("Botto native generation profile") == false)
            if let instructions = frame["params"]["instructions"].text {
                let canonical = instructions.dropFirst("Botto avatar geometry\n\n".count)
                let digest = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
                // Exact canonical prompt bytes at Open Bot Avatar commit 3a511987.
                #expect(digest == "e8b4a0dae22617ab81a4371b83dcdabe59104248a18bf3241aa032208a4ae7cb")
            }
            return .object(["text": .string(generatedCat)])
        }
        return host.defaultReply(frame, socket: socket)
    }
    let avatar = try await service.generateAvatar(description: "A sleepy cat", for: host.bot)
    #expect(avatar.id == "cat" && avatar.name == "Cat")
    #expect(host.sockets[0].sent.dropFirst(before).compactMap { $0["method"].text } == ["llm.oneshot"])
    _ = try await service.send(text: "Chat access still works", attachments: [], access: opened.access, operationID: UUID())
    #expect(host.sockets[0].sent.last?["method"].text == "prompt.submit")
}

private actor AvatarOperationFaultWorker: AvatarEngineWorker {
    enum Operation { case validate, prepare }
    let executedOnMainThread = false
    private let operation: Operation
    private var failures: Int
    private let failure: BotAvatarEngineError
    private let failureEvents: AsyncStream<Void>
    private let failureSignal: AsyncStream<Void>.Continuation
    private let delegate = JavaScriptAvatarWorker()
    private(set) var preparations = 0
    private(set) var validations = 0

    init(operation: Operation, failures: Int, failure: BotAvatarEngineError = .invalidFrame) {
        self.operation = operation
        self.failures = failures
        self.failure = failure
        (failureEvents, failureSignal) = AsyncStream.makeStream(of: Void.self)
    }
    func validate(_ geometry: BotAvatarGeometry) async throws -> BotAvatarGeometry {
        validations += 1
        try failIfNeeded(.validate)
        return try await delegate.validate(geometry)
    }
    func prepare(_ geometry: BotAvatarGeometry, depth: Double) async throws -> BotAvatarDrawingAsset {
        preparations += 1
        try failIfNeeded(.prepare)
        return try await delegate.prepare(geometry, depth: depth)
    }
    func frame(_ geometry: BotAvatarGeometry, options: BotAvatarFrameOptions) async throws -> BotAvatarRenderFrame {
        try await delegate.frame(geometry, options: options)
    }
    func release(instanceID: String) async { await delegate.release(instanceID: instanceID) }
    func firstFailure() async {
        var iterator = failureEvents.makeAsyncIterator()
        _ = await iterator.next()
    }
    private func failIfNeeded(_ operation: Operation) throws {
        if self.operation == operation, failures > 0 {
            failures -= 1
            failureSignal.yield(())
            throw failure
        }
    }
}

@MainActor @Test func avatarGenerationResolvesAnotherBotsCanonicalRootWithoutChangingSelectedChat() async throws {
    let host = try HermesTestHost()
    let service = host.service(); defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let opened = try await service.openChat(.canonical(profile: ExactID(host.bot.id), expectedRoot: nil))
    let before = host.sockets[0].sent.count
    host.methodOverride = { frame, socket in
        switch frame["method"].text {
        case "session.list":
            #expect(frame["params"]["profile"].text == "garden")
            return .object(["sessions": .array([.object([
                "id": .string("garden-tip"), "resolved_id": .string("garden-tip"),
                "_lineage_root_id": .string("garden-root"), "profile": .string("garden")
            ])])])
        case "llm.oneshot":
            #expect(frame["params"]["profile"].text == "garden")
            #expect(frame["params"]["session_id"].text == "garden-root")
            return .object(["text": .string(generatedCat)])
        default: return host.defaultReply(frame, socket: socket)
        }
    }
    let avatar = try await service.generateAvatar(description: "A gardening cat", for: BotProfile(id: "garden", name: "Garden"))
    #expect(avatar.name == "Cat")
    #expect(host.sockets[0].sent.dropFirst(before).compactMap { $0["method"].text } == ["session.list", "llm.oneshot"])
    _ = try await service.send(text: "Still in the original chat", attachments: [], access: opened.access, operationID: UUID())
    #expect(host.sockets[0].sent.last?["params"]["session_id"].text == host.runtime)
}

@MainActor @Test func avatarGenerationCancellationRejectsDuplicatesAndLateResultsWithoutRevokingChatAccess() async throws {
    let host = try HermesTestHost()
    let service = host.service(); defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let opened = try await service.openChat(.canonical(profile: ExactID(host.bot.id), expectedRoot: nil))
    let before = host.sockets[0].sent.count
    var pending: HermesJSON?
    var conversationEvents = 0
    service.onEvent = { if case .conversation = $0 { conversationEvents += 1 } }
    host.methodOverride = { frame, socket in
        if frame["method"].text == "llm.oneshot" { pending = frame; return nil }
        return host.defaultReply(frame, socket: socket)
    }
    let generating = Task { try await service.generateAvatar(description: "A cat", for: host.bot) }
    try await eventually { pending != nil }
    await #expect(throws: BotAvatarGenerationError.alreadyGenerating) {
        _ = try await service.generateAvatar(description: "Another cat", for: host.bot)
    }
    generating.cancel()
    await #expect(throws: CancellationError.self) { _ = try await generating.value }
    host.sockets[0].push(.object(["id": try #require(pending)["id"], "result": .object(["text": .string(generatedCat)])]))
    #expect(conversationEvents == 0)
    #expect(!host.sockets[0].closed)
    #expect(host.sockets[0].sent.dropFirst(before).compactMap { $0["method"].text } == ["llm.oneshot"])
    _ = try await service.send(text: "Original access survives cancellation", attachments: [], access: opened.access, operationID: UUID())
    #expect(host.sockets[0].sent.last?["method"].text == "prompt.submit")
    host.methodOverride = { frame, socket in
        if frame["method"].text == "llm.oneshot" { return .object(["text": .string(generatedCat)]) }
        return host.defaultReply(frame, socket: socket)
    }
    #expect(try await service.generateAvatar(description: "Try the cat again", for: host.bot).name == "Cat")
}

@MainActor @Test(arguments: ["invalid", "canonical-invalid", "oversized", "missing", "unsupported", "failed"])
func avatarGenerationFailureKeepsChatUsableAndCanBeRetried(problem: String) async throws {
    let host = try HermesTestHost()
    let service = host.service(); defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let opened = try await service.openChat(.canonical(profile: ExactID(host.bot.id), expectedRoot: nil))
    host.methodOverride = { frame, socket in
        if frame["method"].text == "llm.oneshot" {
            switch problem {
            case "invalid": return .object(["text": .string("A cat! <svg/>")])
            case "canonical-invalid": return .object(["text": .string(canonicalInvalidAvatar)])
            case "oversized": return .object(["text": .string(String(repeating: "x", count: 8_193))])
            case "missing": return .object([:])
            case "unsupported": socket.reject(frame, code: -32601); return nil
            default: socket.reject(frame, code: 5030); return nil
            }
        }
        return host.defaultReply(frame, socket: socket)
    }
    let expected: BotAvatarGenerationError = problem == "unsupported" ? .unsupportedHost : problem == "failed" ? .failed : .invalidResult
    await #expect(throws: expected) { _ = try await service.generateAvatar(description: "A cat", for: host.bot) }
    #expect(!host.sockets[0].closed)
    _ = try await service.send(text: "Failure did not change my chat", attachments: [], access: opened.access, operationID: UUID())
    #expect(host.sockets[0].sent.last?["method"].text == "prompt.submit")
    host.methodOverride = { frame, socket in
        if frame["method"].text == "llm.oneshot" { return .object(["text": .string(generatedCat)]) }
        return host.defaultReply(frame, socket: socket)
    }
    #expect(try await service.generateAvatar(description: "Try again", for: host.bot).name == "Cat")
    #expect(host.sockets[0].sent.filter { $0["method"].text == "llm.oneshot" }.count == 2)
    #expect(!host.sockets[0].sent.contains { ["profiles.configure", "profiles.set_asset", "session.create", "session.detach"].contains($0["method"].text ?? "") })
}

@MainActor @Test func avatarGenerationTimeoutSettlesOnlyGenerationAndAllowsDeliberateRetry() async throws {
    let host = try HermesTestHost()
    let service = HermesBotService(transportFactory: { host.transport }, timing: .init(
        request: .seconds(1), avatarGeneration: .milliseconds(25), heartbeat: .seconds(10),
        silence: .seconds(30), reconnectDelays: [.milliseconds(10)]), journal: HermesSubmissionJournal(directory: nil))
    defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let opened = try await service.openChat(.canonical(profile: ExactID(host.bot.id), expectedRoot: nil))
    var pending: HermesJSON?
    host.methodOverride = { frame, socket in
        if frame["method"].text == "llm.oneshot" { pending = frame; return nil }
        return host.defaultReply(frame, socket: socket)
    }
    await #expect(throws: BotAvatarGenerationError.timedOut) {
        _ = try await service.generateAvatar(description: "A cat", for: host.bot)
    }
    #expect(!host.sockets[0].closed)
    host.sockets[0].push(.object(["id": try #require(pending)["id"], "result": .object(["text": .string(generatedCat)])]))
    _ = try await service.send(text: "Original chat after generation timeout", attachments: [], access: opened.access, operationID: UUID())
    host.methodOverride = { frame, socket in
        if frame["method"].text == "llm.oneshot" { return .object(["text": .string(generatedCat)]) }
        return host.defaultReply(frame, socket: socket)
    }
    #expect(try await service.generateAvatar(description: "Try again", for: host.bot).name == "Cat")
    #expect(host.sockets.count == 1)
    #expect(host.sockets[0].sent.filter { $0["method"].text == "llm.oneshot" }.count == 2)
}

@MainActor @Test func avatarGenerationRejectsEmptyLongAndExcessiveUnicodeDescriptionsBeforeSending() async throws {
    let host = try HermesTestHost()
    let service = host.service(); defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let before = host.sockets[0].sent.count
    host.methodOverride = { frame, socket in
        if frame["method"].text == "llm.oneshot" { return .object(["text": .string(generatedCat)]) }
        return host.defaultReply(frame, socket: socket)
    }
    for description in [" \n ", String(repeating: "x", count: 1_001), "A" + String(repeating: "\u{301}", count: 5_000)] {
        await #expect(throws: BotAvatarGenerationError.invalidDescription) {
            _ = try await service.generateAvatar(description: description, for: host.bot)
        }
    }
    #expect(host.sockets[0].sent.count == before)
}

@MainActor @Test func avatarGenerationRefusesUnprovenSidecarRoutingWithoutTakingOverItsChat() async throws {
    let host = try HermesTestHost(authority: false)
    let service = host.service(); defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let opened = try await service.openChat(.canonical(profile: ExactID(host.bot.id), expectedRoot: nil))
    let before = host.sockets[0].sent.count
    await #expect(throws: BotAvatarGenerationError.unsupportedHost) {
        _ = try await service.generateAvatar(description: "A cat", for: host.bot)
    }
    #expect(host.sockets[0].sent.count == before)
    _ = try await service.send(text: "The sidecar chat still works", attachments: [], access: opened.access, operationID: UUID())
    #expect(host.sockets[0].sent.last?["method"].text == "prompt.submit")
}

@MainActor @Test(arguments: ["missing", "ambiguous", "foreign"])
func avatarGenerationRefusesUnprovenCanonicalIdentity(problem: String) async throws {
    let host = try HermesTestHost()
    let service = host.service(); defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let opened = try await service.openChat(.canonical(profile: ExactID(host.bot.id), expectedRoot: nil))
    let before = host.sockets[0].sent.count
    host.methodOverride = { frame, socket in
        if frame["method"].text == "session.list" {
            let row: HermesJSON = .object(["id": .string("garden-root"),
                "profile": .string(problem == "foreign" ? "another-bot" : "garden")])
            return .object(["sessions": .array(problem == "missing" ? [] : problem == "ambiguous" ? [row, row] : [row])])
        }
        return host.defaultReply(frame, socket: socket)
    }
    if problem == "foreign" {
        await #expect(throws: HermesServiceError.wrongConversation) {
            _ = try await service.generateAvatar(description: "A cat", for: BotProfile(id: "garden", name: "Garden"))
        }
    } else {
        await #expect(throws: BotAvatarGenerationError.missingChat) {
            _ = try await service.generateAvatar(description: "A cat", for: BotProfile(id: "garden", name: "Garden"))
        }
    }
    #expect(host.sockets[0].sent.dropFirst(before).compactMap { $0["method"].text } == ["session.list"])
    _ = try await service.send(text: "Identity rejection preserved access", attachments: [], access: opened.access, operationID: UUID())
    #expect(host.sockets[0].sent.last?["method"].text == "prompt.submit")
}

@MainActor @Test func avatarGenerationRetiresWithConnectionAndLateReplyCannotCompleteItsReplacement() async throws {
    let host = try HermesTestHost()
    let service = host.service(); defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    _ = try await service.openChat(.canonical(profile: ExactID(host.bot.id), expectedRoot: nil))
    var pending: HermesJSON?
    host.methodOverride = { frame, socket in
        if frame["method"].text == "llm.oneshot" { pending = frame; return nil }
        return host.defaultReply(frame, socket: socket)
    }
    let generating = Task { try await service.generateAvatar(description: "Old cat", for: host.bot) }
    try await eventually { pending != nil }
    service.disconnect()
    await #expect(throws: HermesServiceError.disconnected) { _ = try await generating.value }
    _ = try await service.connect(configuration: host.configuration)
    let opened = try await service.openChat(.canonical(profile: ExactID(host.bot.id), expectedRoot: nil))
    host.sockets[0].push(.object(["id": try #require(pending)["id"], "result": .object(["text": .string(generatedCat)])]))
    host.methodOverride = { frame, socket in
        if frame["method"].text == "llm.oneshot" { return .object(["text": .string(generatedCat)]) }
        return host.defaultReply(frame, socket: socket)
    }
    #expect(try await service.generateAvatar(description: "New cat", for: host.bot).name == "Cat")
    _ = try await service.send(text: "New connection works", attachments: [], access: opened.access, operationID: UUID())
    #expect(host.sockets.count == 2)
    #expect(host.sockets[1].sent.filter { $0["method"].text == "llm.oneshot" }.count == 1)
    #expect(host.sockets[1].sent.last?["method"].text == "prompt.submit")
}

@MainActor @Test func avatarGenerationPendingRequestDoesNotBlockSendingInSelectedChat() async throws {
    let host = try HermesTestHost()
    let service = host.service(); defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let opened = try await service.openChat(.canonical(profile: ExactID(host.bot.id), expectedRoot: nil))
    var pending: HermesJSON?
    host.methodOverride = { frame, socket in
        if frame["method"].text == "llm.oneshot" { pending = frame; return nil }
        return host.defaultReply(frame, socket: socket)
    }
    let generating = Task { try await service.generateAvatar(description: "A cat", for: host.bot) }
    try await eventually { pending != nil }
    _ = try await service.send(text: "Keep chatting while the character is being created", attachments: [], access: opened.access, operationID: UUID())
    #expect(host.sockets[0].sent.last?["method"].text == "prompt.submit")
    host.sockets[0].push(.object(["id": try #require(pending)["id"], "result": .object(["text": .string(generatedCat)])]))
    #expect(try await generating.value.name == "Cat")
    #expect(host.sockets[0].sent.filter { $0["method"].text == "session.resume" }.count == 1)
}

@MainActor @Test func avatarGenerationCanonicalLookupTimeoutPreservesSelectedChat() async throws {
    let host = try HermesTestHost()
    let service = host.service(requestTimeout: .milliseconds(50)); defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let opened = try await service.openChat(.canonical(profile: ExactID(host.bot.id), expectedRoot: nil))
    host.methodOverride = { frame, socket in
        if frame["method"].text == "session.list" { return nil }
        return host.defaultReply(frame, socket: socket)
    }
    await #expect(throws: BotAvatarGenerationError.timedOut) {
        _ = try await service.generateAvatar(description: "A cat", for: BotProfile(id: "garden", name: "Garden"))
    }
    #expect(!host.sockets[0].closed)
    #expect(!host.sockets[0].sent.contains { $0["method"].text == "llm.oneshot" })
    _ = try await service.send(text: "Lookup timeout did not change the chat", attachments: [], access: opened.access, operationID: UUID())
    #expect(host.sockets[0].sent.last?["method"].text == "prompt.submit")
}

@MainActor @Test func avatarSaveRejectsCanonicalInvalidGeometryBeforeMetadataOrImageWrites() async throws {
    let host = try HermesTestHost()
    host.profiles = .object(["profiles": .array([.object(["name": .string(host.bot.id),
        "has_avatar": .bool(true), "ui_meta_revisions": .object(["hermes-bots": .number(1)]),
        "ui_meta": .object(["hermes-bots": .object(["shape": .string("circle"), "custom": .bool(true)])])])])])
    host.methodOverride = { frame, socket in
        switch frame["method"].text {
        case "profiles.configure": return .object(["applied": .object(["ui_meta": .bool(true)])])
        case "profiles.set_asset": return .object(["ok": .bool(true), "asset": .string("avatar")])
        default: return host.defaultReply(frame, socket: socket)
        }
    }
    let service = host.service(); defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let bot = try #require(try await service.bots().first)
    let geometry = try BotAvatarGeometry(json: canonicalInvalidAvatar)
    await #expect(throws: HermesServiceError.invalidAvatar) {
        _ = try await service.setAvatar(.geometry(geometry), for: bot)
    }
    #expect(!host.sockets[0].sent.contains { ["profiles.configure", "profiles.set_asset"].contains($0["method"].text ?? "") })
}

@MainActor @Test func avatarCreationRejectsCanonicalInvalidGeometryBeforeCreatingAProfile() async throws {
    let host = try HermesTestHost()
    let service = host.service(); defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let geometry = try BotAvatarGeometry(json: canonicalInvalidAvatar)
    await #expect(throws: HermesServiceError.invalidAvatar) {
        _ = try await service.createBot(BotDraft(name: "New Character", avatar: .geometry(geometry)))
    }
    #expect(!host.sockets[0].sent.contains { ["profiles.create", "profiles.configure", "profiles.set_asset"].contains($0["method"].text ?? "") })
}

private let fullAvatarPaths: [(source: String, normalized: String)] = [
    ("M20 15 H80 A5 5 0 0 1 85 20 V80 A5 5 0 0 1 80 85 H20 A5 5 0 0 1 15 80 V20 A5 5 0 0 1 20 15 Z",
     "M20 15L80 15A5 5 0 0 1 85 20L85 80A5 5 0 0 1 80 85L20 85A5 5 0 0 1 15 80L15 20A5 5 0 0 1 20 15Z"),
    ("m20 15 h60 q5 0 5 5 v60 q0 5 -5 5 h-60 q-5 0 -5 -5 v-60 q0 -5 5 -5 z",
     "M20 15L80 15Q85 15 85 20L85 80Q85 85 80 85L20 85Q15 85 15 80L15 20Q15 15 20 15Z"),
    ("M20 15 H80 Q85 15 85 20 T85 25 V75 C85 80 85 85 80 85 S75 85 70 85 H20 Q15 85 15 80 V20 Q15 15 20 15 Z",
     "M20 15L80 15Q85 15 85 20Q85 25 85 25L85 75C85 80 85 85 80 85C75 85 75 85 70 85L20 85Q15 85 15 80L15 20Q15 15 20 15Z")
]

@MainActor @Test(arguments: fullAvatarPaths)
func avatarGenerationAndSaveAcceptFullCanonicalCommandsAndRetainFreshReadback(fixture: (source: String, normalized: String)) async throws {
    let wire: [String: Any] = ["version": 1, "id": "full-commands", "name": "Commands", "body": ["path": fixture.source],
        "eyes": ["x": 50, "y": 50, "spacing": 16, "scale": 1]]
    let json = String(decoding: try JSONSerialization.data(withJSONObject: wire), as: UTF8.self)
    let host = try HermesTestHost()
    host.profiles = .object(["profiles": .array([.object(["name": .string(host.bot.id),
        "has_avatar": .bool(false), "ui_meta_revisions": .object(["hermes-bots": .number(1)]),
        "ui_meta": .object(["hermes-bots": .object(["shape": .string("circle"), "custom": .bool(true),
            "color": .string("#123456"), "future": .bool(true)])])])])])
    host.methodOverride = { frame, socket in
        switch frame["method"].text {
        case "llm.oneshot": return .object(["text": .string(json)])
        case "profiles.configure":
            #expect(frame["params"]["ui_meta_expected_revisions"]["hermes-bots"].integer == 1)
            let look = frame["params"]["ui_meta"]["hermes-bots"]
            #expect(look["future"].flag == true)
            host.profiles = .object(["profiles": .array([.object(["name": .string(host.bot.id),
                "has_avatar": .bool(false), "ui_meta_revisions": .object(["hermes-bots": .number(2)]),
                "ui_meta": .object(["hermes-bots": look])])])])
            return .object(["applied": .object(["ui_meta": .bool(true),
                "ui_meta_revisions": .object(["hermes-bots": .number(2)])])])
        case "profiles.set_asset": return .object(["ok": .bool(true), "asset": .string("avatar")])
        default: return host.defaultReply(frame, socket: socket)
        }
    }
    let service = host.service(); defer { service.disconnect() }
    _ = try await service.connect(configuration: host.configuration)
    let bot = try #require(try await service.bots().first)
    let geometry = try await service.generateAvatar(description: "A rounded character", for: bot)
    #expect(geometry.bodyPath == fixture.normalized)
    let saved = try await service.setAvatar(.geometry(geometry), for: bot)
    let fresh = try #require(try await service.bots().first)
    #expect(fresh.appearance?.geometry?.id == "full-commands")
    #expect(fresh.appearance?.geometry?.bodyPath == fixture.normalized)
    #expect(fresh.appearance?.rawShape == saved.appearance?.rawShape)
    #expect(fresh.appearance?.color == "#123456" && fresh.lookRevision == 2)
    #expect(host.sockets[0].sent.filter { $0["method"].text == "profiles.configure" }.count == 1)
    #expect(host.sockets[0].sent.filter { $0["method"].text == "profiles.set_asset" }.count == 1)
}

private struct AvatarValidationGate: Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
}

private extension BotAvatarEngine {
    // Hold only this test's actor work. The bound prevents a failed test from
    // leaving the shared engine blocked; production exposes no test hook.
    func holdValidation(for gate: AvatarValidationGate) {
        gate.entered.signal()
        _ = gate.release.wait(timeout: .now() + 10)
    }
}

@MainActor @Test func avatarSaveReconnectRetiresOldLockWithoutClearingAReplacementSave() async throws {
    let host = try HermesTestHost()
    let configuration = host.configuration
    let service = HermesBotService(transportFactory: { host.transport }, timing: .init(
        request: .seconds(3), heartbeat: .seconds(10), silence: .seconds(30), reconnectDelays: []),
        journal: HermesSubmissionJournal(directory: nil))
    defer { service.disconnect() }
    var revision = 1
    host.profiles = .object(["profiles": .array([.object(["name": .string(host.bot.id),
        "has_avatar": .bool(false), "ui_meta_revisions": .object(["hermes-bots": .number(1)]),
        "ui_meta": .object(["hermes-bots": .object(["title": .string("Original"),
            "shape": .string("circle"), "custom": .bool(true)])])])])])
    var holdAppearance = false
    var pending: (HermesJSON, ScriptedSocket)?
    host.methodOverride = { frame, socket in
        switch frame["method"].text {
        case "profiles.list" where holdAppearance && frame["params"]["profile"].text == host.bot.id:
            pending = (frame, socket)
            return nil
        case "profiles.configure":
            revision += 1
            let look = frame["params"]["ui_meta"]["hermes-bots"]
            host.profiles = .object(["profiles": .array([.object(["name": .string(host.bot.id),
                "has_avatar": .bool(false), "ui_meta_revisions": .object(["hermes-bots": .number(Double(revision))]),
                "ui_meta": .object(["hermes-bots": look])])])])
            return .object(["applied": .object(["ui_meta": .bool(true),
                "ui_meta_revisions": .object(["hermes-bots": .number(Double(revision))])])])
        default: return host.defaultReply(frame, socket: socket)
        }
    }
    _ = try await service.connect(configuration: configuration)
    let bot = try #require(try await service.bots().first)
    let geometry = try BotAvatarGeometry(json: generatedCat)
    let gate = AvatarValidationGate()
    let occupying = Task.detached { await BotAvatarEngine.shared.holdValidation(for: gate) }
    defer { gate.release.signal(); occupying.cancel() }
    let entered = await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: gate.entered.wait(timeout: .now() + 5) == .success)
        }
    }
    try #require(entered)
    let oldSave = Task { try await service.setAvatar(.geometry(geometry), for: bot) }
    defer { oldSave.cancel() }
    try await eventually { !service.savingAvatars.isEmpty }

    // Drive the same reset/re-establish path without a timer racing the test.
    service.lost(.disconnected)
    _ = try await service.connect(configuration: configuration)
    #expect(service.savingAvatars.isEmpty)
    holdAppearance = true
    let replacement = Task { try await service.setAvatar(.shape(.hexagon), for: bot) }
    defer { replacement.cancel() }
    try await eventually { pending != nil }
    let (frame, socket) = try #require(pending)

    gate.release.signal()
    await occupying.value
    await #expect(throws: HermesServiceError.disconnected) { _ = try await oldSave.value }
    await #expect(throws: HermesServiceError.avatarConflict) {
        _ = try await service.setAvatar(.automatic, for: bot)
    }
    await #expect(throws: HermesServiceError.profileConflict) {
        _ = try await service.updateProfile(.init(name: "Too early"), for: bot)
    }
    #expect(!host.sockets.flatMap(\.sent).contains { $0["method"].text == "profiles.configure" })

    holdAppearance = false
    socket.push(.object(["id": frame["id"], "result": host.profiles]))
    let saved = try await replacement.value
    #expect(saved.appearance?.shape == .hexagon)
    let edited = try await service.updateProfile(.init(name: "After Reconnect"), for: saved)
    #expect(edited.name == "After Reconnect")
    #expect(host.sockets.flatMap(\.sent).filter { $0["method"].text == "profiles.configure" }.count == 2)
}
