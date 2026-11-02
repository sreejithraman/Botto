import Foundation

@MainActor enum NativeRecognitionDeadline {
    static func run(until deadline: ContinuousClock.Instant,
                    operation: @escaping @MainActor () async throws -> [String]) async -> [String]? {
        guard ContinuousClock.now < deadline else { return nil }
        let words = await run(expiration: { try? await Task.sleep(until: deadline) }, operation: operation)
        return ContinuousClock.now < deadline ? words : nil
    }

    static func run(expiration: @escaping @MainActor () async -> Void,
                    operation: @escaping @MainActor () async throws -> [String]) async -> [String]? {
        guard !Task.isCancelled else { return nil }
        // A task group would join a blocked Vision request even after cancellation.
        let pending = PendingRecognition()
        let words = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pending.start(continuation, expiration: expiration, operation: operation)
            }
        } onCancel: {
            Task { @MainActor in pending.cancel() }
        }
        return Task.isCancelled ? nil : words
    }

    @MainActor private final class PendingRecognition {
        private var continuation: CheckedContinuation<[String]?, Never>?
        private var recognition: Task<Void, Never>?
        private var timeout: Task<Void, Never>?
        private var cancelled = false

        func start(_ continuation: CheckedContinuation<[String]?, Never>,
                   expiration: @escaping @MainActor () async -> Void, operation: @escaping @MainActor () async throws -> [String]) {
            self.continuation = continuation
            guard !cancelled else { finish(nil); return }
            recognition = Task {
                let words = try? await operation()
                finish(Task.isCancelled ? nil : words)
            }
            timeout = Task {
                await expiration()
                finish(nil)
            }
        }

        func cancel() {
            cancelled = true
            finish(nil)
        }

        private func finish(_ words: [String]?) {
            guard let continuation else { return }
            self.continuation = nil
            recognition?.cancel(); recognition = nil
            timeout?.cancel(); timeout = nil
            continuation.resume(returning: words)
        }
    }
}
