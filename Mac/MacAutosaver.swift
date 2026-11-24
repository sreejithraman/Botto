import Foundation
import Observation

/// Saves an edited value a moment after typing stops, one save at a time, keeping only the newest text.
/// Saves run outside the caller's task, so a newer keystroke never cancels a write already underway.
@MainActor @Observable
final class MacAutosaver {
    enum State: Equatable { case idle, pending, saving, saved, failed(String) }

    private(set) var state: State = .idle
    private let delay: Duration
    private let save: @MainActor (String) async throws -> Void
    private var saved: String
    private var pending: String?
    private var timer: Task<Void, Never>?
    private var inFlight: Task<Void, Never>?

    init(initial: String, delay: Duration = .milliseconds(800), save: @escaping @MainActor (String) async throws -> Void) {
        saved = initial
        self.delay = delay
        self.save = save
    }

    func edit(_ value: String) {
        timer?.cancel()
        guard value != saved || inFlight != nil else {
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

    private func commit() async {
        if let inFlight { await inFlight.value }
        guard let value = pending else { return }
        pending = nil
        state = .saving
        let save = save
        let write = Task { @MainActor [weak self] in
            do {
                try await save(value)
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
