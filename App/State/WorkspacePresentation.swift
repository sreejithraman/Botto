import Foundation
import Observation
import BottoCore

/// Scene-owned task presentation. Native hosts project this state; they never
/// create a second destination or own a download's lifetime.
@MainActor @Observable final class WorkspacePresentation {
    private(set) var artifact: ArtifactPreviewSession?
    /// Loaded pages beside the selected file, by position, so a swipe shows their content.
    /// They never own export or navigation; only `artifact` does.
    private var artifactNeighbors: [Int: ArtifactPreviewSession] = [:]
    private(set) var revision = UUID()

    func openArtifact(_ destination: AppStore.ArtifactDestination, store: AppStore) {
        guard artifact?.id != destination.id else { return }
        guard store.canStartArtifactRead(destination), artifact?.isPresentingOutput != true else {
            store.finishArtifact(destination)
            return
        }
        let previous = artifact
        let session = ArtifactPreviewSession(destination: destination, store: store)
        artifact = session; revision = UUID()
        // Retire UI/callback ownership before releasing its operation reservation.
        previous?.finish(); retireArtifactNeighbors()
        session.retry()
        loadArtifactNeighbors(reusing: [:], store: store)
    }

    func artifactSession(atPage index: Int) -> ArtifactPreviewSession? {
        artifact?.page?.index == index ? artifact : artifactNeighbors[index]
    }

    /// Selects a sibling, returning false when the current reader can't turn the page.
    @discardableResult func moveArtifact(by step: Int, id: UUID, store: AppStore) -> Bool {
        guard let selected = artifact, selected.id == id, !selected.isPresentingOutput,
              let index = selected.page?.index else { return false }
        var pages = artifactNeighbors
        pages[index] = selected
        guard let next = sibling(of: selected, by: step, reusing: pages.removeValue(forKey: index + step),
                                 store: store) else { return false }
        artifact = next
        next.retry()
        loadArtifactNeighbors(reusing: pages, store: store)
        return true
    }

    /// Keeps the pages one step away and retires the rest. A neighbor's failure stays
    /// on its own page, where the reader can retry once it is selected.
    private func loadArtifactNeighbors(reusing pages: [Int: ArtifactPreviewSession], store: AppStore) {
        var retired = pages
        var neighbors: [Int: ArtifactPreviewSession] = [:]
        if let selected = artifact, let page = selected.page {
            for index in [page.index - 1, page.index + 1] where (0..<page.count).contains(index) {
                let retained = retired.removeValue(forKey: index)
                guard let session = sibling(of: selected, by: index - page.index, reusing: retained,
                                            store: store) else { continue }
                neighbors[index] = session
                if session !== retained { session.retry() }
            }
        }
        artifactNeighbors = neighbors
        retired.values.forEach { $0.finish() }
    }

    private func sibling(of selected: ArtifactPreviewSession, by step: Int,
                         reusing retained: ArtifactPreviewSession?, store: AppStore) -> ArtifactPreviewSession? {
        if let retained, retained.isCurrent { return retained }
        retained?.finish()
        guard let destination = selected.adjacentDestination(by: step) else { return nil }
        guard store.canStartArtifactRead(destination) else { store.finishArtifact(destination); return nil }
        return ArtifactPreviewSession(destination: destination, store: store, readerID: selected.readerID)
    }

    private func retireArtifactNeighbors() {
        let neighbors = artifactNeighbors
        artifactNeighbors = [:]
        neighbors.values.forEach { $0.finish() }
    }

    /// Choosing a chat settles presentation at once: an open file reader and its
    /// loaded neighbor pages give up their reads.
    func didChooseConversation() { removeArtifact() }

    func closeArtifact(id: UUID) {
        guard artifact?.id == id, artifact?.isPresentingOutput != true else { return }
        removeArtifact()
    }

    /// A callback from a previous reader cannot close or retry its replacement.
    func acceptsArtifactCallback(id: UUID, revision: UUID) -> Bool {
        self.revision == revision && artifact?.id == id
            && artifact?.isCurrent == true && artifact?.isPresentingOutput != true
    }

    func retryArtifact(id: UUID, revision: UUID, canPresent: () -> Bool) {
        guard acceptsArtifactCallback(id: id, revision: revision), canPresent() else { return }
        artifact?.retry()
    }

    func reconcile(store: AppStore) {
        if let artifact, !artifact.isCurrent(in: store) { removeArtifact() }
    }

    private func removeArtifact() {
        let previous = artifact
        artifact = nil; revision = UUID()
        previous?.finish(); retireArtifactNeighbors()
    }
}

/// Owns one captured capability, load, and local file across all native hosts.
/// Views may request outputs, but cannot load, cancel, or finish the model.
@MainActor @Observable final class ArtifactPreviewSession: Identifiable, ArtifactReadingSession {
    typealias Output = ArtifactOutput

    let id: UUID
    /// Shared by the pages of one reader, so turning a page keeps the reader on screen.
    let readerID: UUID
    private var destination: AppStore.ArtifactDestination
    private let store: AppStore
    private let model = ArtifactPreviewModel()

    var file: ArtifactPreviewFile? { isCurrent ? model.file : nil }
    var errorMessage: String? { isCurrent ? model.errorMessage : nil }
    var requiresConnection: Bool { isCurrent && model.requiresConnection }
    var isLoading: Bool { isCurrent && model.isLoading }
    // Local captures follow semantic presentation; cache misses still require live access.
    var isCurrent: Bool {
        !model.isFinished && store.isAuthorizedArtifactPresentation(destination)
            && (model.file != nil || store.canStartArtifactRead(destination))
    }
    var output: Output? { isCurrent ? model.output : nil }
    var exportError: String? { isCurrent ? model.exportError : nil }
    var exportErrorID: UUID? { isCurrent ? model.exportErrorID : nil }
    var isPresentingOutput: Bool { isCurrent && model.isPresentingOutput }
    var title: String { destination.attachment.name }

    fileprivate init(destination: AppStore.ArtifactDestination, store: AppStore, readerID: UUID = UUID()) {
        id = destination.id; self.destination = destination; self.store = store; self.readerID = readerID
    }

    fileprivate func isCurrent(in store: AppStore) -> Bool { self.store === store && isCurrent }

    var page: (index: Int, count: Int)? {
        let siblings = destination.siblings
        guard siblings.count > 1, let index = siblings.firstIndex(where: { $0.id == destination.attachment.id }) else { return nil }
        return (index, siblings.count)
    }
    fileprivate func adjacentDestination(by step: Int) -> AppStore.ArtifactDestination? {
        store.artifactDestination(adjacentTo: destination, by: step)
    }

    func retry() { load(.initial) }
    func reload() { load(.reload) }

    private func load(_ request: ArtifactPreviewModel.Request) {
        model.request(request, isCurrent: { [weak self] in self?.isCurrent == true }, prepareDownload: {
            if let renewed = store.renewedArtifactDestination(destination) { destination = renewed }
            return { [store, destination] in
                try await store.downloadArtifact(destination, force: request == .reload)
            }
        })
    }

    func beginOutput(_ kind: Output.Kind) {
        guard isCurrent else { return }
        model.beginOutput(kind)
    }

    func endOutput(id: UUID, error: Error? = nil) {
        guard isCurrent else { return }
        model.endOutput(id: id, error: error)
    }

    func clearExportError(id: UUID?) { model.clearExportError(id: id) }

    fileprivate func finish() {
        guard model.finish() else { return }
        store.finishArtifact(destination)
    }
}
