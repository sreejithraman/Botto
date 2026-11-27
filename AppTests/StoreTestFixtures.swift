import Foundation
import Dispatch
import Testing
import XCTest
import BottoCore
@testable import Botto

@MainActor final class MemoryConnectionStorage {
    var saved: ConnectionConfiguration?
    var failLoad = false
    var failSave = false
    var beforeSave: ((ConnectionConfiguration) -> Void)?
    init(saved: ConnectionConfiguration? = nil) { self.saved = saved }
    var persistence: ConnectionPersistence {
        .init(load: {
            if self.failLoad { throw ConversationServiceError.disconnected }
            return self.saved
        }, save: {
            self.beforeSave?($0)
            if self.failSave { throw ConversationServiceError.disconnected }
            self.saved = $0
        }, remove: { self.saved = nil })
    }
}

/// A test service that exercises conversations only. Every T3 workspace member it leaves out is refused,
/// as AppStore refused them before the service contract was one protocol.
@MainActor protocol ConversationTestService: BotService {}

extension ConversationTestService {
    func updateProfile(_ edit: BotProfileEdit, for bot: BotProfile) async throws -> BotProfile { throw T3ServiceError.unsupported }
    func setAvatar(_ choice: BotAvatarChoice, for bot: BotProfile) async throws -> BotProfile { throw T3ServiceError.unsupported }
    func recentConversationHistory(_ identity: SessionIdentity) async throws -> ConversationHistoryWindow? { nil }
    func replaceQueuedMessage(_ message: QueuedMessage, text: String, access: ConversationAccess,
                              operationID: UUID) async throws -> MutationReceipt { throw T3ServiceError.unsupported }
    var currentBotWorkspaceRoot: String? { nil }
    var currentT3Channels: [T3ChannelSummary] { [] }
    func loadBotBrain() async throws -> T3BotBrainSnapshot { throw T3ServiceError.unsupported }
    func saveSoul(_ markdown: String, replacing expected: String?) async throws { throw T3ServiceError.unsupported }
    func saveMemory(_ markdown: String, replacing expected: String?) async throws { throw T3ServiceError.unsupported }
    func saveManifest(_ manifest: T3BotManifest) async throws { throw T3ServiceError.unsupported }
    func setDefaultModel(_ option: T3ModelOption?) async throws -> T3BotManifest { throw T3ServiceError.unsupported }
    func createChat(title: String?) async throws -> CreatedSession { throw T3ServiceError.unsupported }
    func renameChannel(threadID: String, title: String) async throws { throw T3ServiceError.unsupported }
    func setChannelPinned(threadID: String, pinned: Bool) async throws { throw T3ServiceError.unsupported }
    func archiveChannel(threadID: String, archived: Bool) async throws { throw T3ServiceError.unsupported }
    func markChannelVisited(threadID: String) async throws { throw T3ServiceError.unsupported }
    func setChannelModel(threadID: String, providerInstanceID: String, model: String) async throws { throw T3ServiceError.unsupported }
    func availableModels() async throws -> [T3ModelOption] { throw T3ServiceError.unsupported }
    func providers() async throws -> [T3ProviderStatus] { throw T3ServiceError.unsupported }
    func readProjectFile(relativePath: String) async throws -> String { throw T3ServiceError.unsupported }
    func listOutputs() async throws -> [T3OutputFile] { throw T3ServiceError.unsupported }
    func downloadOutput(_ output: T3OutputFile) async throws -> DownloadedArtifact { throw T3ServiceError.unsupported }
    func listRoutines() async throws -> [T3ScheduledRoutine] { throw T3ServiceError.unsupported }
    func createRoutine(name: String, prompt: String, schedule: T3RoutineSchedule,
                       threadID: String?) async throws -> T3ScheduledRoutine { throw T3ServiceError.unsupported }
    func setRoutineEnabled(id: String, enabled: Bool) async throws { throw T3ServiceError.unsupported }
    func deleteRoutine(id: String) async throws { throw T3ServiceError.unsupported }
}

@MainActor final class StoreTestService: ConversationTestService {
    let authority = TestConversationAuthority()

    func conversations(profile: ExactID) async throws -> ConversationDirectory { authority.directory(profile) }
    func downloadArtifact(_ attachment: ChatAttachment, access: ConversationAccess) async throws -> DownloadedArtifact { throw T3ServiceError.unsupported }

    var onEvent: ((BotServiceEvent) -> Void)?
    var connectError: (any Error)?
    var duringConnect: ((ConnectionConfiguration) -> Void)?
    var connectBarrier: StoreTestBarrier?
    var connectCount = 0
    var profiles: [BotProfile]
    var info = ServerInfo(version: "test", installID: "test-install")
    var chat = Conversation(id: "runtime", storedID: "stored", profileID: "milo")
    var uploadedConversations: [Conversation] = []
    var uploadBarrier: StoreTestBarrier?
    var uploadError: (any Error)?
    var uploadedByteCount: Int?
    private var recovery: Task<Void, Never>?
    private var releaseRecovery: (() -> Void)?
    private(set) var recovered = false

    init(profiles: [BotProfile] = []) { self.profiles = profiles }

    func scheduleRecovery() {
        onEvent?(.disconnected("Transient handshake failure"))
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        releaseRecovery = { continuation.yield(()); continuation.finish() }
        recovery = Task { @MainActor in
            for await _ in stream {
                guard !Task.isCancelled else { return }
                self.recovered = true
                self.onEvent?(.connected(.init(version: "candidate", installID: "candidate-install")))
                return
            }
        }
    }
    func finishRecovery() async {
        releaseRecovery?()
        await recovery?.value
    }
    func connect(configuration: ConnectionConfiguration) async throws -> ServerInfo {
        connectCount += 1
        duringConnect?(configuration)
        await connectBarrier?.wait()
        if let connectError { throw connectError }
        return info
    }
    func disconnect() { recovery?.cancel() }
    func bots() async throws -> [BotProfile] { profiles }
    func markVisited(through mark: VisitMark, access: ConversationAccess) async throws {}
    func openChat(_ target: SessionTarget) async throws -> OpenedConversation {
        let readStartedAt = ContinuousClock.now
        let bot = BotProfile(id: authority.profile(target), name: "Fixture")
        var opened = chat
        opened.profileID = bot.id
        let publication = try authority.opened(opened)
        return OpenedConversation(identity: publication.identity, snapshot: publication.snapshot, access: publication.access,
            activity: publication.activity, historyReadStartedAt: readStartedAt,
            observedSource: publication.identity)
    }
    func send(text: String, attachments: [ChatAttachment], delivery: MessageDelivery, access: ConversationAccess, operationID: UUID) async throws -> MutationReceipt { try authority.receipt(access, operationID) }
    func stop(access: ConversationAccess, operationID: UUID) async throws -> MutationReceipt { try authority.receipt(access, operationID) }
    func respond(to request: PendingRequest, response: RequestResponse, access: ConversationAccess, operationID: UUID) async throws -> MutationReceipt { try authority.receipt(access, operationID) }
    func upload(data: Data, filename: String, mimeType: String, access: ConversationAccess) async throws -> ChatAttachment {
        uploadedConversations.append(try authority.resolve(access))
        await uploadBarrier?.wait()
        if let uploadError { throw uploadError }
        return .init(name: filename, path: "uploads/\(filename)", mimeType: mimeType, byteCount: uploadedByteCount)
    }
}

/// A provider or service may finish even after its caller is cancelled.
@MainActor final class StoreTestBarrier {
    private var entered = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var completion: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            completion = continuation
            entered = true
            entryWaiter?.resume()
            entryWaiter = nil
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }

    func entersInTime(fileID: String = #fileID, line: Int = #line) async -> Bool {
        await waitWhile(fileID: fileID, line: line) { !entered }
    }

    func release() {
        completion?.resume()
        completion = nil
    }
}

/// A wait longer than this passes but leaves an attachment, so lateness stays visible.
let slowReadiness = Duration.seconds(3)

@MainActor func recordReadiness(_ text: String) {
    guard Test.current == nil else { return Attachment.record(text, named: "readiness-wait.txt") }
    // Swift Testing drops attachments recorded inside an XCTest case.
    XCTContext.runActivity(named: "readiness-wait") { activity in
        let attachment = XCTAttachment(string: text)
        attachment.name = "readiness-wait.txt"; attachment.lifetime = .keepAlways
        activity.add(attachment)
    }
}

/// Suspends while `pending` is true, for at most `limit`, and returns whether it became false.
/// It yields briefly so a ready condition returns at once, then sleeps: spinning on the main actor would
/// compete with the utility-priority work that some conditions wait for. A slow or unmet wait is attached.
@discardableResult
@MainActor func waitWhile(_ label: String? = nil, limit: Duration = readinessLimit, diagnostics: () -> String = { "" },
                          fileID: String = #fileID, line: Int = #line,
                          _ pending: () async throws -> Bool) async rethrows -> Bool {
    let started = ContinuousClock.now, deadline = started + limit
    var previousPoll = started, maximumGap = Duration.zero, polls = 0
    while true {
        let ready = try await !pending()
        let now = ContinuousClock.now, elapsed = started.duration(to: now)
        maximumGap = max(maximumGap, previousPoll.duration(to: now))
        previousPoll = now; polls += 1
        if ready || now >= deadline || Task.isCancelled {
            if !ready || elapsed > slowReadiness {
                recordReadiness("\(label ?? "") \(fileID):\(line)\nready=\(ready) cancelled=\(Task.isCancelled) elapsed=\(elapsed) polls=\(polls) maximumPollGap=\(maximumGap)\n\(diagnostics())")
            }
            return ready
        }
        if elapsed < .milliseconds(50) { await Task.yield() } else { try? await Task.sleep(for: .milliseconds(5)) }
    }
}

nonisolated final class CaptureCommitGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var armed = false
    private var entered = false
    var isEntered: Bool { lock.withLock { entered } }
    func arm() { lock.withLock { armed = true; entered = false } }
    func pause() {
        let shouldWait = lock.withLock {
            guard armed else { return false }
            armed = false
            entered = true
            return true
        }
        if shouldWait { semaphore.wait() }
    }
    func release() { semaphore.signal() }
}
