import Foundation
import Observation
import BottoCore

@MainActor @Observable final class AvatarGenerationModel {
    var description = "" {
        didSet { if description != oldValue { cancel() } }
    }
    private enum State {
        case ready, generating(UUID), failed(String)
    }
    private var state = State.ready
    @ObservationIgnored private var task: Task<BotAvatarGeometry, Error>?

    var isGenerating: Bool {
        if case .generating = state { return true }
        return false
    }
    var error: String? {
        if case .failed(let message) = state { return message }
        return nil
    }

    func generate(using action: @escaping @MainActor (String) async throws -> BotAvatarGeometry,
                  accept: @MainActor (BotAvatarGeometry) -> Void) async {
        guard !isGenerating else { return }
        let owner = UUID(), prompt = description
        state = .generating(owner)
        let work = Task { try await action(prompt) }
        task = work
        let result = await work.result
        guard case .generating(let current) = state, current == owner else { return }
        task = nil
        guard !Task.isCancelled else { state = .ready; return }
        switch result {
        case .success(let geometry):
            state = .ready
            accept(geometry)
        case .failure(let error):
            state = error is CancellationError ? .ready : .failed(error.localizedDescription)
        }
    }

    func cancel() {
        state = .ready
        task?.cancel()
        task = nil
    }
}
