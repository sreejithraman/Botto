import Foundation
import Testing
import BottoCore
@testable import Botto

// The host sampler reads these markers independently of XCTest's buffered output.
struct NativeTestDiagnostics {
    private let method: String
    private let runID = UUID().uuidString
    private let argument: String?
    private let file: URL

    init(method: String, argument: String? = nil) {
        self.method = String(method.prefix { $0 != "(" })
        self.argument = argument
        file = FileManager.default.temporaryDirectory.appendingPathComponent("botto-native-\(self.method)-\(runID).json")
        record("started")
    }

    func finish() { record("finished") }

    private func record(_ phase: String) {
        var marker: [String: Any] = ["method": method, "runID": runID,
            "pid": ProcessInfo.processInfo.processIdentifier, "phase": phase,
            "timestamp": Date.now.timeIntervalSince1970]
        if let argument { marker["argument"] = argument }
        do {
            try JSONSerialization.data(withJSONObject: marker).write(to: file, options: .atomic)
        } catch {
            print("Native diagnostic marker could not be saved: \(error)")
        }
    }
}

struct NativeTestDiagnosticsTests {
    @Test func overlappingInvocationsRetainIndependentMarkers() throws {
        let method = "markerProbe-\(UUID().uuidString)"
        let first = NativeTestDiagnostics(method: method)
        let second = NativeTestDiagnostics(method: method)
        let files = try FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory,
            includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("botto-native-\(method)") }
        defer {
            first.finish(); second.finish()
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
        try #require(files.count == 2)
        first.finish()
        let markers = try files.map { try JSONSerialization.jsonObject(with: Data(contentsOf: $0)) as? [String: Any] }
        #expect(markers.filter { $0?["phase"] as? String == "started" }.count == 1)
        #expect(markers.filter { $0?["phase"] as? String == "finished" }.count == 1)
        #expect(Set(markers.compactMap { $0?["runID"] as? String }).count == 2)
    }
}

@MainActor final class MemoryConnectionStorage {
    var saved: ConnectionConfiguration?
    var failLoad = false
    var failSave = false
    var beforeSave: ((ConnectionConfiguration) -> Void)?
    init(saved: ConnectionConfiguration? = nil) { self.saved = saved }
    var persistence: ConnectionPersistence {
        .init(load: {
            if self.failLoad { throw HermesServiceError.disconnected }
            return self.saved
        }, save: {
            self.beforeSave?($0)
            if self.failSave { throw HermesServiceError.disconnected }
            self.saved = $0
        }, remove: { self.saved = nil })
    }
}

@MainActor final class StoreTestService: BotService {
    let authority = TestConversationAuthority()

    func conversations(profile: ExactID) async throws -> ConversationDirectory { authority.directory(profile) }
    func createConversation(profile: ExactID, operationID: UUID) async throws -> CreatedSession { throw HermesServiceError.rejected(-32601) }
    func downloadArtifact(_ attachment: ChatAttachment, access: ConversationAccess) async throws -> DownloadedArtifact { throw HermesServiceError.rejected(-32601) }

    var onEvent: ((BotServiceEvent) -> Void)?
    var connectError: (any Error)?
    var duringConnect: ((ConnectionConfiguration) -> Void)?
    var connectBarrier: StoreTestBarrier?
    var connectCount = 0
    var connectedConfigurations: [ConnectionConfiguration] = []
    var profiles: [BotProfile] = []
    var botsBarrier: StoreTestBarrier?
    var createdBot: BotProfile?
    var createCount = 0
    var info = ServerInfo(version: "test", installID: "test-install")
    var chat = Conversation(id: "runtime", storedID: "stored", profileID: "milo")
    var uploadedConversations: [Conversation] = []
    var uploadBarrier: StoreTestBarrier?
    var uploadError: (any Error)?
    var uploadedByteCount: Int?
    private var recovery: Task<Void, Never>?
    private var releaseRecovery: (() -> Void)?
    private(set) var recovered = false
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
        connectedConfigurations.append(configuration)
        duringConnect?(configuration)
        await connectBarrier?.wait()
        if let connectError { throw connectError }
        return info
    }
    func disconnect() { recovery?.cancel() }
    func bots() async throws -> [BotProfile] { await botsBarrier?.wait(); return profiles }
    func createBot(_ draft: BotDraft) async throws -> BotProfile {
        createCount += 1
        guard let createdBot else { throw HermesServiceError.disconnected }
        return createdBot
    }
    func openChat(_ target: SessionTarget) async throws -> OpenedConversation {
        let bot = BotProfile(id: authority.profile(target), name: "Fixture")
        var opened = chat
        opened.profileID = bot.id
        return try authority.opened(opened)
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

    func release() {
        completion?.resume()
        completion = nil
    }
}
