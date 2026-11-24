import AppKit
import BottoCore
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

enum MacFileKind: Equatable {
    case markdown, text, image, other

    init(name: String, mimeType: String) {
        let ext = (name as NSString).pathExtension.lowercased()
        let mime = mimeType.lowercased()
        if ["md", "markdown"].contains(ext) || mime == "text/markdown" { self = .markdown }
        else if mime.hasPrefix("image/"), ext != "svg" { self = .image }
        else if mime.hasPrefix("text/") || ["json", "csv", "txt", "log", "yaml", "yml", "swift", "py", "js", "ts"].contains(ext) {
            self = .text
        } else { self = .other }
    }

    var label: String {
        switch self {
        case .markdown: "Document"
        case .text: "Text"
        case .image: "Image"
        case .other: "File"
        }
    }
}

/// A file to open from a space, search, or the Botto page. It downloads only when opened or previewed.
struct MacPreviewItem: Identifiable {
    let id: String
    let name: String
    let mimeType: String
    /// The file on this Mac, when it lives in Botto's local workspace folder.
    let localURL: URL?
    let load: @MainActor () async throws -> DownloadedArtifact

    var kind: MacFileKind { MacFileKind(name: name, mimeType: mimeType) }

    @MainActor static func output(_ output: T3OutputFile, store: MacBottoStore) -> MacPreviewItem {
        let root = store.workspaceRoot
        let local = root.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).appending(path: output.relativePath) }
        return MacPreviewItem(id: "output:" + output.relativePath, name: output.name, mimeType: output.mimeType,
                              localURL: local) { try await store.downloadOutput(output) }
    }

    @MainActor static func attachment(_ attachment: ChatAttachment, store: MacBottoStore) -> MacPreviewItem {
        MacPreviewItem(id: "attachment:" + attachment.id, name: attachment.name, mimeType: attachment.mimeType,
                       localURL: nil) { try await store.downloadAttachment(attachment) }
    }
}

/// A miniature page: a real excerpt or image when one is loaded, otherwise drawn lines in the file's shape.
struct MacPageThumbnail: View {
    let kind: MacFileKind
    var excerpt: [String] = []
    var image: NSImage?

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: max(3, width * 0.1))
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.08), radius: 1.5, y: 1)
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipShape(.rect(cornerRadius: max(3, width * 0.1)))
                } else if !excerpt.isEmpty, width > 60 {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(excerpt.prefix(8).enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(size: index == 0 ? 8 : 6, weight: index == 0 ? .bold : .regular))
                                .foregroundStyle(index == 0 ? Color.black.opacity(0.8) : Color.black.opacity(0.55))
                                .lineLimit(index == 0 ? 2 : 1)
                        }
                    }
                    .padding(width * 0.1)
                } else {
                    VStack(alignment: .leading, spacing: max(2, width * 0.07)) {
                        Capsule().fill(kind == .other ? Color.black.opacity(0.25) : MacTheme.action.opacity(0.75))
                            .frame(width: width * 0.62, height: max(2, width * 0.06))
                        ForEach(0..<5, id: \.self) { index in
                            Capsule().fill(Color.black.opacity(0.11))
                                .frame(width: width * (index == 4 ? 0.5 : 0.8), height: max(1.5, width * 0.04))
                        }
                    }
                    .padding(width * 0.12)
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// The lines worth showing on a tiny page: headings and prose, without Markdown marks.
    nonisolated static func excerpt(from text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("```") && !$0.hasPrefix("---") }
            .map { line in
                line.drop { "#>-*+ ".contains($0) }.replacingOccurrences(of: "**", with: "")
            }
            .prefix(8).map { String($0) }
    }
}

/// A live miniature that loads the file once to show its real first lines or image.
struct MacFileThumbnail: View {
    let item: MacPreviewItem
    @State private var excerpt: [String] = []
    @State private var image: NSImage?

    var body: some View {
        MacPageThumbnail(kind: item.kind, excerpt: excerpt, image: image)
            .task(id: item.id) {
                guard item.kind != .other, excerpt.isEmpty, image == nil,
                      let file = try? await item.load(), !Task.isCancelled else { return }
                if item.kind == .image { image = NSImage(data: file.data) }
                else { excerpt = MacPageThumbnail.excerpt(from: String(decoding: file.data.prefix(4096), as: UTF8.self)) }
            }
    }
}

/// Keeps the temporary copy alive for the preview or a share in progress.
final class MacPreviewFile: Transferable, Sendable {
    let url: URL
    let data: Data

    private init(directory: URL, artifact: DownloadedArtifact) {
        url = directory.appendingPathComponent(Self.filename(artifact.filename), isDirectory: false)
        data = artifact.data
    }

    deinit { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { file in SentTransferredFile(file.url) }
    }

    static func write(_ artifact: DownloadedArtifact) async throws -> MacPreviewFile {
        try await Task.detached {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("botto-preview-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            let file = MacPreviewFile(directory: directory, artifact: artifact)
            try file.data.write(to: file.url, options: .atomic)
            return file
        }.value
    }

    private static func filename(_ raw: String) -> String {
        let leaf = raw.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last ?? ""
        var clean = String(leaf.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && $0 != ":"
        }).trimmingCharacters(in: .whitespacesAndNewlines)
        while clean.utf8.count > 200 { clean.removeLast() }
        return clean.isEmpty || clean == "." || clean == ".." ? "File" : clean
    }
}

struct MacFilePreview: View {
    let item: MacPreviewItem
    @Environment(\.dismiss) private var dismiss
    @State private var file: MacPreviewFile?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                MacPageThumbnail(kind: item.kind).frame(width: 22, height: 28)
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.name).font(MacTheme.rounded(.headline, weight: .bold)).lineLimit(1).truncationMode(.middle)
                    Text("Made by Botto · \(item.kind.label)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let localURL = item.localURL, FileManager.default.fileExists(atPath: localURL.path) {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([localURL]) }
                        .buttonStyle(MacPillButtonStyle(prominent: false))
                }
                if let file {
                    ShareLink(item: file, preview: SharePreview(item.name)) { Label("Share", systemImage: "square.and.arrow.up") }
                        .buttonStyle(MacPillButtonStyle(prominent: false))
                }
                Button("Done") { dismiss() }
                    .buttonStyle(MacPillButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Rectangle().fill(MacTheme.hairline).frame(height: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 680, height: 620)
        .background(MacTheme.paper)
        .tint(MacTheme.action)
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let file {
            switch item.kind {
            case .markdown, .text:
                let text = String(decoding: file.data, as: UTF8.self)
                ScrollView {
                    Group {
                        if item.kind == .markdown { MacMarkdownView(text: text, style: .editorial) }
                        else { Text(text).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
                    }
                    .frame(maxWidth: 620, alignment: .leading)
                    .padding(28)
                    .frame(maxWidth: .infinity)
                }
            case .image:
                if let image = NSImage(data: file.data) {
                    ScrollView([.vertical, .horizontal]) {
                        Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 640).padding(20)
                            .accessibilityLabel(item.name)
                    }
                } else { unavailable }
            case .other:
                unavailable
            }
        } else if let error {
            VStack(spacing: 10) {
                Text("Couldn’t open this file").font(MacTheme.rounded(.title3, weight: .bold))
                Text(error).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Try Again") { Task { await load() } }.buttonStyle(MacPillButtonStyle())
            }
            .padding(30)
        } else {
            ProgressView("Opening \(item.name)…").controlSize(.small)
        }
    }

    private var unavailable: some View {
        VStack(spacing: 12) {
            MacPageThumbnail(kind: item.kind).frame(width: 70, height: 88)
            Text("No preview for this kind of file.").foregroundStyle(.secondary)
            if let file {
                Button("Open with Default App") {
                    NSWorkspace.shared.open(file.url, configuration: .init()) { [file] _, _ in
                        withExtendedLifetime(file) { }
                    }
                }
                .buttonStyle(MacPillButtonStyle())
            }
        }
    }

    private func load() async {
        error = nil
        do {
            let loaded = try await item.load()
            try Task.checkCancellation()
            let preview = try await MacPreviewFile.write(loaded)
            guard !Task.isCancelled else { return }
            file = preview
        } catch {
            if !Task.isCancelled, file == nil { self.error = error.localizedDescription }
        }
    }
}
