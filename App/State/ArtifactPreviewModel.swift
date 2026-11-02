// File lifetime pattern adapted from Hermex BotArtifactPreview.swift and QuickLookFilePreview.swift. MIT; see LICENSES/Hermex.txt.
import Foundation
#if DEBUG
import Darwin
#endif
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
        NativeStartupTrace.shared.record("model-queued", id: startupTrace)
        #endif
        let task = Task {
            #if DEBUG
            NativeStartupTrace.shared.record("model-body", id: startupTrace)
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
            NativeStartupTrace.shared.record("download-ready", id: startupTrace)
            #endif
            try Task.checkCancellation()
            guard generation == owner else { return }
            guard artifact.data.count <= DownloadedArtifact.maximumBytes else {
                throw ArtifactPreviewFailure.tooLarge
            }
            #if DEBUG
            NativeStartupTrace.shared.record("file-write-start", id: startupTrace)
            #endif
            let written = try await ArtifactPreviewFile.write(artifact)
            #if DEBUG
            NativeStartupTrace.shared.record("file-write-ready", id: startupTrace)
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

#if DEBUG
nonisolated final class NativeStartupTrace: @unchecked Sendable {
    static let shared = NativeStartupTrace()
    private let lock = NSLock()
    private var events: [String] = []
    private var dropped = 0

    func record(_ phase: String, id: UUID) {
        let uptime = ProcessInfo.processInfo.systemUptime
        var cpu = timespec(), usage = rusage(), thread: UInt64 = 0
        let threadResult = clock_gettime(CLOCK_THREAD_CPUTIME_ID, &cpu)
        let processResult = getrusage(RUSAGE_SELF, &usage)
        pthread_threadid_np(nil, &thread)
        let threadCPU = threadResult == 0 ? Double(cpu.tv_sec) + Double(cpu.tv_nsec) / 1e9 : -1
        let processCPU = processResult == 0
            ? Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6 : -1
        let event = "[DEBUG-memory-startup] \(id) \(phase) \(uptime) priority=\(Task.currentPriority.rawValue) thread=\(thread) tcpu=\(threadCPU) pcpu=\(processCPU)"
        lock.withLock {
            if events.count == 512 { events.removeFirst(); dropped += 1 }
            events.append(event)
        }
    }

    func failureSnapshot() -> String {
        lock.withLock { "dropped=\(dropped)\n" + events.joined(separator: "\n") }
    }
}
#endif
