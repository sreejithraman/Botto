import Foundation
import Observation

/// Saves an edited value a moment after typing stops, one save at a time, keeping only the newest text.
/// Saves run outside the caller's task, so a newer keystroke never cancels a write already underway.
@MainActor @Observable
final class MacAutosaver {
    enum State: Equatable { case idle, pending, saving, saved, failed(String) }

    private(set) var state: State = .idle
    private(set) var text: String
    var hasUnsavedEdits: Bool { pending != nil || inFlight != nil }
    private var revision = UUID()
    private let delay: Duration
    private let save: @MainActor (String, String) async throws -> Void
    private var saved: String
    private var pending: String?
    private var timer: Task<Void, Never>?
    private var inFlight: Task<Void, Never>?

    init(initial: String, delay: Duration = .milliseconds(800), save: @escaping @MainActor (String, String) async throws -> Void) {
        saved = initial
        text = initial
        self.delay = delay
        self.save = save
    }

    func edit(_ value: String) {
        text = value
        revision = UUID()
        timer?.cancel()
        guard value != saved || inFlight != nil || state.isFailure else {
            pending = nil
            if state == .pending { state = .saved }
            return
        }
        pending = value
        state = .pending
        timer = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.commit()
        }
    }

    /// Saves any waiting edit now, for example when the editor closes.
    func flush() async {
        timer?.cancel()
        timer = nil
        await commit()
    }

    var refreshRevision: UUID? { hasUnsavedEdits ? nil : revision }

    func refresh(_ loaded: String, revision observed: UUID?) {
        guard let observed, observed == refreshRevision else { return }
        accept(loaded)
    }

    func reload(using read: @MainActor () async throws -> String) async {
        let observed = revision
        do {
            let loaded = try await read()
            guard !Task.isCancelled, observed == revision, inFlight == nil else { return }
            accept(loaded)
        } catch where !Task.isCancelled && observed == revision {
            state = .failed(error.localizedDescription)
        } catch { }
    }

    private func accept(_ loaded: String) {
        timer?.cancel()
        pending = nil
        text = loaded
        saved = loaded
        revision = UUID()
        state = .idle
    }

    private func commit() async {
        while let writing = inFlight {
            await writing.value
            if inFlight == writing { inFlight = nil }
        }
        guard let value = pending else { return }
        pending = nil
        state = .saving
        let save = save
        let expected = saved
        let write = Task { @MainActor [weak self] in
            do {
                try await save(value, expected)
                guard let self else { return }
                self.saved = value
                if self.pending == nil { self.state = .saved }
            } catch {
                guard let self else { return }
                // Keep the text so the next edit or flush retries it.
                if self.pending == nil { self.pending = value }
                self.state = .failed(error.localizedDescription)
            }
        }
        inFlight = write
        await write.value
        if inFlight == write { inFlight = nil }
    }
}

private extension MacAutosaver.State {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
