import Foundation
import Observation

/// Scene-owned task presentation. Native hosts project this state; they never
/// create a second destination or own a download's lifetime.
@MainActor @Observable final class WorkspacePresentation {
    private enum Target {
        case chat
        case artifact(ArtifactPreviewSession, expanded: Bool)
    }
    private enum Surface {
        case reading(Target)
        case browsingBots(returnTo: Target)
    }
    private var surface: Surface = .reading(.chat)
    private(set) var revision = UUID()

    private var target: Target {
        switch surface {
        case .reading(let target), .browsingBots(let target): target
        }
    }
    var isBrowsingBots: Bool {
        if case .browsingBots = surface { return true }
        return false
    }
    var artifact: ArtifactPreviewSession? {
        if case .artifact(let session, _) = target { return session }
        return nil
    }
    var isArtifactExpanded: Bool {
        if case .artifact(_, let expanded) = target { return expanded }
        return false
    }

    func openArtifact(_ destination: AppStore.ArtifactDestination, store: AppStore) {
        guard artifact?.id != destination.id else { return }
        guard store.isCurrentArtifactDestination(destination), artifact?.isPresentingOutput != true else {
            store.finishArtifact(destination)
            return
        }
        let previous = artifact
        let session = ArtifactPreviewSession(destination: destination, store: store)
        surface = .reading(.artifact(session, expanded: false)); revision = UUID()
        // Retire UI/callback ownership before releasing its operation reservation.
        previous?.finish()
        session.retry()
    }

    func browseBots() {
        guard !isBrowsingBots, artifact?.isPresentingOutput != true else { return }
        surface = .browsingBots(returnTo: target); revision = UUID()
    }

    func resumeTask() {
        guard isBrowsingBots else { return }
        surface = .reading(target); revision = UUID()
    }

    func didChooseConversation() {
        let previous = artifact
        surface = .reading(.chat); revision = UUID()
        previous?.finish()
    }

    func closeArtifact(id: UUID) {
        guard artifact?.id == id, artifact?.isPresentingOutput != true else { return }
        removeArtifact()
    }

    func setArtifactExpanded(_ expanded: Bool, id: UUID) {
        guard let artifact, artifact.id == id, artifact.isCurrent,
              !isBrowsingBots, !artifact.isPresentingOutput,
              isArtifactExpanded != expanded else { return }
        surface = .reading(.artifact(artifact, expanded: expanded)); revision = UUID()
    }

    /// Bindings also check their geometric host. A callback from a previous
    /// semantic surface cannot close a resumed or replacement reader.
    func acceptsArtifactCallback(id: UUID, revision: UUID) -> Bool {
        self.revision == revision && artifact?.id == id && !isBrowsingBots
            && artifact?.isCurrent == true && artifact?.isPresentingOutput != true
    }

    func retryArtifact(id: UUID, revision: UUID, canPresent: () -> Bool) {
        guard acceptsArtifactCallback(id: id, revision: revision), canPresent() else { return }
        artifact?.retry()
    }

    func reconcile(store: AppStore) {
        guard let artifact else { return }
        if !artifact.isCurrent(in: store) { removeArtifact() }
    }

    private func removeArtifact() {
        let previous = artifact
        surface = isBrowsingBots ? .browsingBots(returnTo: .chat) : .reading(.chat)
        revision = UUID()
        previous?.finish()
    }
}

/// Owns one captured capability, load, and local file across all native hosts.
/// Views may request outputs, but cannot load, cancel, or finish the model.
@MainActor @Observable final class ArtifactPreviewSession: Identifiable {
    struct Output: Identifiable {
        enum Kind { case share, save }
        let id = UUID()
        let kind: Kind
        let file: ArtifactPreviewFile
    }

    let id: UUID
    private let destination: AppStore.ArtifactDestination
    private let store: AppStore
    private let model = ArtifactPreviewModel()
    private var completedFile: ArtifactPreviewFile?
    private var finished = false
    private var pendingOutput: Output?
    private var outputError: (id: UUID, message: String)?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    var file: ArtifactPreviewFile? { isCurrent ? completedFile : nil }
    var errorMessage: String? { isCurrent ? model.errorMessage : nil }
    var isLoading: Bool { isCurrent && model.isLoading }
    // Completed bytes belong to the semantic task, independently of its socket.
    // An unfinished reader still needs the original, strict read capability.
    var isCurrent: Bool {
        !finished && store.isAuthorizedArtifactPresentation(destination)
            && (completedFile != nil || isReadEligible)
    }
    private var isReadEligible: Bool { !finished && store.isCurrentArtifactDestination(destination) }
    var output: Output? { isCurrent ? pendingOutput : nil }
    var exportError: String? { isCurrent ? outputError?.message : nil }
    var exportErrorID: UUID? { isCurrent ? outputError?.id : nil }
    var isPresentingOutput: Bool { output != nil || exportError != nil }
    var title: String { file?.filename ?? destination.attachment.name }

    fileprivate init(destination: AppStore.ArtifactDestination, store: AppStore) {
        id = destination.id; self.destination = destination; self.store = store
    }

    fileprivate func isCurrent(in store: AppStore) -> Bool { self.store === store && isCurrent }

    func retry() {
        guard isCurrent, isReadEligible, loadTask == nil, completedFile == nil, !isPresentingOutput else { return }
        loadTask = Task { [weak self] in
            guard let self else { return }
            defer { loadTask = nil }
            await model.load { [store, destination] in try await store.downloadArtifact(destination) }
            // File writing also suspends. A late write must not turn a retired
            // network read into an authorized completed reader.
            guard isCurrent, isReadEligible else { model.cancel(); return }
            completedFile = model.file
        }
    }

    func beginOutput(_ kind: Output.Kind) {
        guard isCurrent, !isPresentingOutput, let file else { return }
        pendingOutput = Output(kind: kind, file: file)
    }

    func endOutput(id: UUID, error: Error? = nil) {
        guard isCurrent, pendingOutput?.id == id else { return }
        pendingOutput = nil
        outputError = error.map { (id, $0.localizedDescription) }
    }

    func clearExportError(id: UUID?) {
        guard let id, outputError?.id == id else { return }
        outputError = nil
    }

    fileprivate func finish() {
        guard !finished else { return }
        finished = true
        completedFile = nil
        pendingOutput = nil; outputError = nil
        loadTask?.cancel(); loadTask = nil; model.cancel()
        store.finishArtifact(destination)
    }
}
