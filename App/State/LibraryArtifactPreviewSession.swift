import Foundation
import Observation
import BottoCore

@MainActor @Observable final class LibraryArtifactPreviewSession: Identifiable, ArtifactReadingSession {
    let id = UUID()
    let item: LibraryArtifact
    private let library: WorkspaceLibrary
    private let model = ArtifactPreviewModel()
    private var finished = false
    private var completedFile: ArtifactPreviewFile?
    private var pendingOutput: ArtifactOutput?
    private var outputFailure: (id: UUID, message: String)?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(item: LibraryArtifact, library: WorkspaceLibrary) {
        self.item = item
        self.library = library
    }

    var isCurrent: Bool { !finished && library.isCurrent(item) }
    var file: ArtifactPreviewFile? { isCurrent ? completedFile : nil }
    var errorMessage: String? { isCurrent ? model.errorMessage : nil }
    var isLoading: Bool { isCurrent && model.isLoading }
    var canReload: Bool { isCurrent && item.artifact.attachment != nil }
    var title: String { item.artifact.title }
    var previewBlock: ReplyContent.Block? { isCurrent ? item.artifact.block : nil }
    var output: ArtifactOutput? { isCurrent ? pendingOutput : nil }
    var exportError: String? { isCurrent ? outputFailure?.message : nil }
    var exportErrorID: UUID? { isCurrent ? outputFailure?.id : nil }
    var isPresentingOutput: Bool { output != nil || exportError != nil }

    func retry() { load(force: false) }

    func reload() {
        guard canReload else { return }
        load(force: true)
    }

    private func load(force: Bool) {
        guard isCurrent, loadTask == nil, (force || completedFile == nil), !isPresentingOutput else { return }
        loadTask = Task { [weak self] in
            guard let self else { return }
            defer { loadTask = nil }
            await model.load(preservingFile: force) { [library, item] in try await library.download(item, force: force) }
            guard isCurrent else { model.cancel(); return }
            if let file = model.file { completedFile = file }
        }
    }

    func beginOutput(_ kind: ArtifactOutput.Kind) {
        guard isCurrent, loadTask == nil, !isPresentingOutput, let file else { return }
        pendingOutput = ArtifactOutput(kind: kind, file: file)
    }

    func endOutput(id: UUID, error: Error? = nil) {
        guard pendingOutput?.id == id else { return }
        pendingOutput = nil
        outputFailure = error.map { (id, $0.localizedDescription) }
    }

    func clearExportError(id: UUID?) {
        guard let id, outputFailure?.id == id else { return }
        outputFailure = nil
    }

    func finish() {
        finished = true
        loadTask?.cancel(); loadTask = nil
        model.cancel(); completedFile = nil
        pendingOutput = nil; outputFailure = nil
    }
}
