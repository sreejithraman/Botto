import Foundation
import Observation
import BottoCore

@MainActor @Observable final class LibraryArtifactPreviewSession: Identifiable, ArtifactReadingSession {
    let id = UUID()
    let item: LibraryArtifact
    private let library: WorkspaceLibrary
    private let model = ArtifactPreviewModel()

    init(item: LibraryArtifact, library: WorkspaceLibrary) {
        self.item = item
        self.library = library
    }

    var isCurrent: Bool { !model.isFinished && library.isCurrent(item) }
    var file: ArtifactPreviewFile? { isCurrent ? model.file : nil }
    var errorMessage: String? { isCurrent ? model.errorMessage : nil }
    var requiresConnection: Bool { isCurrent && model.requiresConnection }
    var isLoading: Bool { isCurrent && model.isLoading }
    var canReload: Bool { isCurrent && item.artifact.attachment != nil }
    var title: String { item.artifact.title }
    var previewBlock: ReplyContent.Block? { isCurrent ? item.artifact.block : nil }
    var output: ArtifactOutput? { isCurrent ? model.output : nil }
    var exportError: String? { isCurrent ? model.exportError : nil }
    var exportErrorID: UUID? { isCurrent ? model.exportErrorID : nil }
    var isPresentingOutput: Bool { isCurrent && model.isPresentingOutput }

    func retry() { load(.initial) }

    func reload() {
        guard canReload else { return }
        load(.reload)
    }

    private func load(_ request: ArtifactPreviewModel.Request) {
        model.request(request, isCurrent: { [weak self] in self?.isCurrent == true }, prepareDownload: { [library, item] in
            { try await library.download(item, force: request == .reload) }
        })
    }

    func beginOutput(_ kind: ArtifactOutput.Kind) {
        guard isCurrent else { return }
        model.beginOutput(kind)
    }

    func endOutput(id: UUID, error: Error? = nil) { model.endOutput(id: id, error: error) }
    func clearExportError(id: UUID?) { model.clearExportError(id: id) }
    func finish() { model.finish() }
}
