// File lifetime pattern adapted from Hermex BotArtifactPreview.swift and QuickLookFilePreview.swift. MIT; see LICENSES/Hermex.txt.
import Foundation
import Observation
import BottoCore

@MainActor protocol ArtifactReadingSession: AnyObject {
    var file: ArtifactPreviewFile? { get }
    var errorMessage: String? { get }
    var isCurrent: Bool { get }
    var isLoading: Bool { get }
    var canReload: Bool { get }
    var title: String { get }
    var previewBlock: ReplyContent.Block? { get }
    var output: ArtifactOutput? { get }
    var exportError: String? { get }
    var exportErrorID: UUID? { get }
    var isPresentingOutput: Bool { get }
    func reload()
    func beginOutput(_ kind: ArtifactOutput.Kind)
    func endOutput(id: UUID, error: Error?)
    func clearExportError(id: UUID?)
}

struct ArtifactOutput: Identifiable {
    enum Kind { case share, save }
    let id = UUID()
    let kind: Kind
    let file: ArtifactPreviewFile
}

extension ArtifactReadingSession {
    var previewBlock: ReplyContent.Block? { nil }
    var canReload: Bool { isCurrent }
    func endOutput(id: UUID) { endOutput(id: id, error: nil) }
}

/// A reader retains this object for as long as it needs the local file. Dropping
/// preview state cannot remove a file still held by Quick Look or Share.
final class ArtifactPreviewFile: Identifiable, Sendable {
    let id = UUID()
    let url: URL
    let data: Data
    let mimeType: String
    var filename: String { url.lastPathComponent }

    private init(directory: URL, artifact: DownloadedArtifact) {
        url = directory.appendingPathComponent(Self.safeFilename(artifact.filename))
        data = artifact.data
        mimeType = artifact.mimeType
    }

    deinit { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    static func write(_ artifact: DownloadedArtifact) async throws -> ArtifactPreviewFile {
        try await Task.detached(priority: .userInitiated) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("botto-artifact-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            let file = ArtifactPreviewFile(directory: directory, artifact: artifact)
            try file.data.write(to: file.url, options: [.atomic, .completeFileProtectionUnlessOpen])
            return file
        }.value
    }

    private static func safeFilename(_ raw: String) -> String {
        let leaf = raw.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? ""
        let clean = String(leaf.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet(charactersIn: ":").contains($0)
        }).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != ".", clean != ".." else { return "File" }
        // Bound bytes, not characters: a long emoji filename can exceed NAME_MAX.
        let fallback = "File"
        let suffix = (clean as NSString).pathExtension
        var boundedSuffix = String(suffix.prefix(16))
        // One grapheme can exceed the whole filename budget. Reserve a dot and
        // the fallback stem, and only remove complete characters to keep Unicode valid.
        while !boundedSuffix.isEmpty, boundedSuffix.utf8.count > 200 - fallback.utf8.count - 1 {
            boundedSuffix.removeLast()
        }
        let ext = boundedSuffix.isEmpty ? "" : "." + boundedSuffix
        var stem = suffix.isEmpty ? clean : (clean as NSString).deletingPathExtension
        while !stem.isEmpty, stem.utf8.count + ext.utf8.count > 200 { stem.removeLast() }
        if stem.isEmpty || stem == "." || stem == ".." { stem = fallback }
        return stem + ext
    }
}

@MainActor @Observable final class ArtifactPreviewModel {
    enum Request: Equatable { case initial, reload }
    typealias Download = @MainActor () async throws -> DownloadedArtifact

    private struct Content {
        var file: ArtifactPreviewFile?
        var errorMessage: String?
    }
    private struct Attempt {
        let id: UUID
        let task: Task<Void, Never>
    }
    private enum State {
        case idle(Content)
        case loading(Attempt, Content)
        case output(ArtifactOutput, Content)
        case exportFailed(id: UUID, message: String, content: Content)
        case finished

        var content: Content {
            switch self {
            case .idle(let content), .loading(_, let content), .output(_, let content),
                 .exportFailed(_, _, let content): content
            case .finished: Content()
            }
        }
        var attempt: Attempt? {
            if case .loading(let attempt, _) = self { attempt } else { nil }
        }
    }
    private var state: State = .idle(Content())

    var file: ArtifactPreviewFile? { state.content.file }
    var errorMessage: String? { state.content.errorMessage }
    var isLoading: Bool { state.attempt != nil }
    var isFinished: Bool { if case .finished = state { true } else { false } }
    var output: ArtifactOutput? { if case .output(let output, _) = state { output } else { nil } }
    var exportError: String? { if case .exportFailed(_, let message, _) = state { message } else { nil } }
    var exportErrorID: UUID? { if case .exportFailed(let id, _, _) = state { id } else { nil } }
    var isPresentingOutput: Bool { output != nil || exportError != nil }

    func request(_ request: Request, isCurrent: @escaping @MainActor () -> Bool,
                 prepareDownload: () -> Download) {
        guard !isFinished, !isLoading, !isPresentingOutput, isCurrent(),
              request == .reload || file == nil else { return }
        let download = prepareDownload()
        _ = begin(preservingFile: request == .reload, isCurrent: isCurrent, download: download)
    }

    func load(preservingFile: Bool = false,
              download: @escaping @MainActor () async throws -> DownloadedArtifact) async {
        guard !isFinished, !isPresentingOutput else { return }
        let attempt = begin(preservingFile: preservingFile, isCurrent: { true }, download: download)
        await withTaskCancellationHandler { await attempt.task.value } onCancel: { attempt.task.cancel() }
    }

    private func begin(preservingFile: Bool, isCurrent: @escaping @MainActor () -> Bool,
                       download: @escaping @MainActor () async throws -> DownloadedArtifact) -> Attempt {
        let previous = Content(file: preservingFile ? file : nil)
        let retired = state.attempt
        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let artifact = try await download()
                try Task.checkCancellation()
                guard state.attempt?.id == id else { return }
                guard artifact.data.count <= DownloadedArtifact.maximumBytes else {
                    throw ArtifactPreviewFailure.tooLarge
                }
                let written = try await ArtifactPreviewFile.write(artifact)
                try Task.checkCancellation()
                guard state.attempt?.id == id else { return }
                state = .idle(isCurrent() ? Content(file: written) : previous)
            } catch {
                guard state.attempt?.id == id else { return }
                var content = previous
                if !Task.isCancelled, isCurrent() { content.errorMessage = error.localizedDescription }
                state = .idle(content)
            }
        }
        let attempt = Attempt(id: id, task: task)
        state = .loading(attempt, previous)
        retired?.task.cancel()
        return attempt
    }

    func beginOutput(_ kind: ArtifactOutput.Kind) {
        guard !isFinished, !isLoading, !isPresentingOutput, let file else { return }
        state = .output(ArtifactOutput(kind: kind, file: file), state.content)
    }

    func endOutput(id: UUID, error: Error?) {
        guard case .output(let output, let content) = state, output.id == id else { return }
        if let error { state = .exportFailed(id: id, message: error.localizedDescription, content: content) }
        else { state = .idle(content) }
    }

    func clearExportError(id: UUID?) {
        guard let id, case .exportFailed(let current, _, let content) = state, current == id else { return }
        state = .idle(content)
    }

    func cancel() {
        guard !isFinished else { return }
        let retired = state.attempt
        state = .idle(Content())
        retired?.task.cancel()
    }

    @discardableResult func finish() -> Bool {
        guard !isFinished else { return false }
        let retired = state.attempt
        state = .finished
        retired?.task.cancel()
        return true
    }
}

private enum ArtifactPreviewFailure: Error, LocalizedError {
    case tooLarge
    var errorDescription: String? { "This file is too large to preview on this device (25 MB maximum)." }
}
