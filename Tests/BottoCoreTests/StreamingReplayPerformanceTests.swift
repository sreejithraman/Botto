import Foundation
import Testing
@testable import BottoCore

/// Replays wire bytes through the gateway and observes the app's public publication seam.
/// Set BOTTO_STREAM_BENCHMARK=1 for the optimized, repeated long-history workload.
@MainActor @Test(.timeLimit(.minutes(2))) func streamingReplayPreservesHistoryTokensToolsAndApprovals() async throws {
    let benchmark = ProcessInfo.processInfo.environment["BOTTO_STREAM_BENCHMARK"] == "1"
    let runs = Int(ProcessInfo.processInfo.environment["BOTTO_STREAM_RUNS"] ?? "7") ?? 7
    let historyCount = benchmark ? 2_000 : 40
    let tokenCount = benchmark ? 4_000 : 80
    let repetitions = benchmark ? runs + 1 : 1
    for iteration in 0..<repetitions {
        let elapsed = try await replayStreaming(historyCount: historyCount, tokenCount: tokenCount)
        if benchmark {
            print("BOTTO_STREAM_REPLAY iteration=\(iteration) warmup=\(iteration == 0) history=\(historyCount) deltas=\(tokenCount) milliseconds=\(elapsed)")
        }
    }
}

@MainActor private func replayStreaming(historyCount: Int, tokenCount: Int) async throws -> Double {
    let host = try HermesTestHost(), service = host.service()
    defer { service.disconnect() }
    let historyTexts = (0..<historyCount).map { index in
        "History \(index): café cafe\u{301} " + String(repeating: "A realistic persisted conversation paragraph. ", count: 8)
    }
    host.snapshot["messages"] = .array((0..<historyCount).map { index in
        .object(["row_id": .number(Double(index + 1)), "role": .string(index.isMultiple(of: 2) ? "user" : "assistant"),
                 "text": .string(historyTexts[index])])
    })
    _ = try await service.connect(configuration: host.configuration)
    let opened = try await service.openChat(.canonical(profile: ExactID(host.bot.id), expectedRoot: nil))
    let history = opened.snapshot.messages
    #expect(history.count == historyCount)
    #expect(zip(history, historyTexts).allSatisfy { $0.text.utf8.elementsEqual($1.utf8) })
    var frames: [HermesJSON] = [], sequence = 0
    func append(_ type: String, _ payload: [String: HermesJSON] = [:]) {
        sequence += 1
        frames.append(host.event(type, seq: sequence, payload: payload))
    }
    append("message.start")
    var expectedText = ""
    for index in 0..<tokenCount {
        if index == tokenCount / 2 {
            append("tool.start", ["tool_id": .string("read-1"), "name": .string("read_file"),
                                  "args": .object(["command": .string("Read project notes")])])
            append("approval.request", ["prompt_id": .string("approval-1"), "kind": .string("approval"),
                                        "command": .string("Read project notes"), "execution_generation": .number(7)])
            append("approval.settled", ["prompt_id": .string("approval-1")])
            append("tool.complete", ["tool_id": .string("read-1"), "name": .string("read_file"), "result_text": .string("Read complete")])
        }
        let token = ["Native ", "streaming ", "🙂 ", "café cafe\u{301}\n"][index % 4]
        expectedText += token
        append("message.delta", ["text": .string(token)])
    }
    // Omitting final text proves every delta survived, rather than repairing loss at completion.
    append("message.complete", ["status": .string("completed"),
                                "persisted_turn": .object(["final_assistant_row_id": .number(Double(historyCount + 1))])])
    let bytes = try frames.map { try $0.data }
    let socket = host.sockets[0]
    var last: OpenedConversation?, previous: OpenedConversation?
    var publications = 0, sawApproval = false, sawSettlement = false, sawToolCompletion = false
    var ordered = true
    var expectedSequence = 1
    var batchEnd = 0
    var batch: ReplayBatch?
    service.onEvent = { event in
        guard case .conversation(let value) = event else { return }
        publications += 1
        ordered = ordered && value.snapshot.lastSequence == expectedSequence
        expectedSequence += 1
        sawApproval = sawApproval || value.snapshot.pendingRequests.contains { $0.id == "approval-1" }
        sawSettlement = sawSettlement || (sawApproval && value.snapshot.pendingRequests.isEmpty)
        sawToolCompletion = sawToolCompletion || value.snapshot.messages.last?.text == "Read complete"
        previous = last; last = value
        if value.snapshot.lastSequence == batchEnd { batch?.finish() }
    }
    let start = ContinuousClock.now
    // Bound the scripted FIFO's removeFirst cost; all production decode/reduce/publish work is timed.
    for offset in stride(from: 0, to: bytes.count, by: 32) {
        let end = min(offset + 32, bytes.count)
        batchEnd = end
        let current = ReplayBatch()
        batch = current
        try await current.wait {
            for data in bytes[offset..<end] {
                if let waiting = socket.waiter { socket.waiter = nil; waiting.resume(returning: data) }
                else { socket.queue.append(data) }
            }
        }
    }
    let elapsed = start.duration(to: .now)
    service.onEvent = nil
    let final = try #require(last?.snapshot)
    #expect(ordered)
    #expect(publications == frames.count)
    #expect(final.lastSequence == frames.count)
    #expect(Array(final.messages.prefix(historyCount)) == history)
    #expect(zip(final.messages.prefix(historyCount), historyTexts).allSatisfy { $0.text.utf8.elementsEqual($1.utf8) })
    #expect(final.messages.count == historyCount + 2)
    #expect(final.messages[historyCount].id == host.root + ":row:" + String(historyCount + 1))
    #expect(final.messages[historyCount].text.utf8.elementsEqual(expectedText.utf8))
    #expect(previous?.snapshot.isWorking == true)
    let live = try #require(previous?.snapshot)
    #expect(live.messages[historyCount].text.utf8.elementsEqual(expectedText.utf8))
    #expect(zip(live.messages.prefix(historyCount), historyTexts).allSatisfy { $0.text.utf8.elementsEqual($1.utf8) })
    #expect(previous?.snapshot.messages[historyCount].id.hasPrefix("live:") == true)
    #expect(final.messages.last?.role == .tool)
    #expect(final.messages.last?.text == "Read complete")
    #expect(sawApproval && sawSettlement && sawToolCompletion)
    #expect(final.pendingRequests.isEmpty)
    #expect(!final.isWorking)
    return Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
}

/// A missing publication must fail and disconnect instead of suspending forever.
@MainActor private final class ReplayBatch {
    private var continuation: CheckedContinuation<Void, any Error>?
    private var deadline: Task<Void, Never>?
    private struct Timeout: Error {}

    func wait(enqueue: () -> Void) async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                deadline = Task {
                    do { try await Task.sleep(for: .seconds(3)) }
                    catch { return }
                    finish(throwing: Timeout())
                }
                enqueue()
            }
        } onCancel: {
            Task { @MainActor in self.finish(throwing: CancellationError()) }
        }
    }

    func finish(throwing error: (any Error)? = nil) {
        guard let continuation else { return }
        self.continuation = nil
        deadline?.cancel()
        deadline = nil
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
    }
}
