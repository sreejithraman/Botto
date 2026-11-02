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
    private(set) var file: ArtifactPreviewFile?
    private(set) var errorMessage: String?
    private(set) var isLoading = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var downloadTask: Task<DownloadedArtifact, Error>?

    func load(preservingFile: Bool = false, download: @escaping @MainActor () async throws -> DownloadedArtifact) async {
        let previous = preservingFile ? file : nil
        cancel()
        file = previous
        let owner = generation
        isLoading = true
        #if DEBUG
        let startupTrace = UUID()
        print("[DEBUG-native-startup] \(startupTrace) model-queued \(ProcessInfo.processInfo.systemUptime)")
        #endif
        let task = Task {
            #if DEBUG
            print("[DEBUG-native-startup] \(startupTrace) model-body \(ProcessInfo.processInfo.systemUptime)")
            #endif
            return try await download()
        }
        downloadTask = task
        defer { if generation == owner { downloadTask = nil; isLoading = false } }
        do {
            let artifact = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            #if DEBUG
            print("[DEBUG-native-startup] \(startupTrace) download-ready \(ProcessInfo.processInfo.systemUptime)")
            #endif
            try Task.checkCancellation()
            guard generation == owner else { return }
            guard artifact.data.count <= DownloadedArtifact.maximumBytes else {
                throw ArtifactPreviewFailure.tooLarge
            }
            #if DEBUG
            print("[DEBUG-native-startup] \(startupTrace) file-write-start \(ProcessInfo.processInfo.systemUptime)")
            #endif
            let written = try await ArtifactPreviewFile.write(artifact)
            #if DEBUG
            print("[DEBUG-native-startup] \(startupTrace) file-write-ready \(ProcessInfo.processInfo.systemUptime)")
            #endif
            guard generation == owner, !Task.isCancelled else { return }
            file = written
            isLoading = false
        } catch {
            guard generation == owner, !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    func cancel() {
        generation = UUID()
        downloadTask?.cancel()
        downloadTask = nil
        file = nil
        errorMessage = nil
        isLoading = false
    }
}

private enum ArtifactPreviewFailure: Error, LocalizedError {
    case tooLarge
    var errorDescription: String? { "This file is too large to preview on this device (25 MB maximum)." }
}
