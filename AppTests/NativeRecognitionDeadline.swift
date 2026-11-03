import Foundation

@MainActor enum NativeRecognitionDeadline {
    static func run<Value: Sendable>(until deadline: ContinuousClock.Instant,
                    operation: @escaping @MainActor () async throws -> Value) async -> Value? {
        guard ContinuousClock.now < deadline else { return nil }
        let value = await run(expiration: { try? await Task.sleep(until: deadline) }, operation: operation)
        return ContinuousClock.now < deadline ? value : nil
    }

    static func run<Value: Sendable>(expiration: @escaping @MainActor () async -> Void,
                    operation: @escaping @MainActor () async throws -> Value) async -> Value? {
        guard !Task.isCancelled else { return nil }
        // A task group would join a blocked Vision request even after cancellation.
        let pending = PendingRecognition<Value>()
        let value = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pending.start(continuation, expiration: expiration, operation: operation)
            }
        } onCancel: {
            Task { @MainActor in pending.cancel() }
        }
        return Task.isCancelled ? nil : value
    }

    @MainActor private final class PendingRecognition<Value: Sendable> {
        private var continuation: CheckedContinuation<Value?, Never>?
        private var recognition: Task<Void, Never>?
        private var timeout: Task<Void, Never>?
        private var cancelled = false

        func start(_ continuation: CheckedContinuation<Value?, Never>,
                   expiration: @escaping @MainActor () async -> Void, operation: @escaping @MainActor () async throws -> Value) {
            self.continuation = continuation
            guard !cancelled else { finish(nil); return }
            recognition = Task {
                let value = try? await operation()
                finish(Task.isCancelled ? nil : value)
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

        private func finish(_ value: Value?) {
            guard let continuation else { return }
            self.continuation = nil
            recognition?.cancel(); recognition = nil
            timeout?.cancel(); timeout = nil
            continuation.resume(returning: value)
        }
    }
}
