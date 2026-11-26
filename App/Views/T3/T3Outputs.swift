import SwiftUI
import UIKit
import BottoCore

/// Files Botto saved under outputs/. Listing is quiet and cached for the drawer's search and
/// Botto's shelf; a small preview of each file loads only once a miniature page is on screen.
@MainActor @Observable final class T3OutputsModel {
    private(set) var outputs: [T3OutputFile]?
    private(set) var error: String?
    private(set) var previews: [String: T3OutputMiniature] = [:]
    private var loadingPreviews: Set<String> = []
    private var latestLoad: UUID?

    func load(_ store: AppStore) async {
        guard store.isConnected else { return }
        let workspace = store.chats
        let request = UUID()
        latestLoad = request
        do {
            let loaded = try await store.listT3Outputs()
            guard !Task.isCancelled, store.chats === workspace, latestLoad == request else { return }
            outputs = loaded
            error = nil
        } catch where !Task.isCancelled && store.chats === workspace && latestLoad == request {
            // Keep the last good list visible; only surface the failure when nothing is shown.
            if outputs == nil { self.error = error.localizedDescription }
        } catch { }
    }

    func loadPreview(_ output: T3OutputFile, store: AppStore) async {
        let key = output.relativePath
        guard previews[key] == nil, !loadingPreviews.contains(key), store.isConnected,
              T3OutputKind(output) != .other else { return }
        let workspace = store.chats
        loadingPreviews.insert(key)
        defer { loadingPreviews.remove(key) }
        guard let downloaded = try? await store.downloadT3Output(output), store.chats === workspace else { return }
        let preview = await T3OutputMiniature.make(output, data: downloaded.data)
        guard !Task.isCancelled, store.chats === workspace else { return }
        previews[key] = preview
    }
}

/// The first lines of a document, or a small picture, for a page-sized thumbnail.
enum T3OutputMiniature: Equatable {
    case lines([String])
    case image(UIImage)

    static func make(_ output: T3OutputFile, data: Data) async -> T3OutputMiniature? {
        let kind = T3OutputKind(output)
        return await Task.detached(priority: .utility) { () -> T3OutputMiniature? in
            switch kind {
            case .image:
                guard let image = UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 240, height: 300)) else { return nil }
                return .image(image)
            case .markdown, .text:
                guard case .success(let text) = ArtifactPlainText.decode(data.prefix(4096), mimeType: output.mimeType) else {
                    return nil
                }
                let lines = text.split(whereSeparator: \.isNewline).map { String($0.prefix(60)) }
                    .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                return lines.isEmpty ? nil : .lines(Array(lines.prefix(9)))
            case .other: return nil
            }
        }.value
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.lines(let a), .lines(let b)): a == b
        case (.image(let a), .image(let b)): a === b
        default: false
        }
    }
}

/// A file drawn as a tiny page: real first lines or the picture itself, never just an extension badge.
struct T3OutputThumbnail: View {
    let output: T3OutputFile
    let model: T3OutputsModel
    let store: AppStore
    var width: CGFloat = 104

    var body: some View {
        MiniPage(kind: T3OutputKind(output), miniature: model.previews[output.relativePath], width: width)
            .task(id: output.relativePath) { await model.loadPreview(output, store: store) }
    }
}

struct MiniPage: View {
    let kind: T3OutputKind
    var miniature: T3OutputMiniature?
    var width: CGFloat = 104

    var body: some View {
        let height = width * 1.18
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: width * 0.11, style: .continuous).fill(Color(.systemBackground))
            switch miniature {
            case .image(let image):
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: width, height: height).clipped()
            case .lines(let lines):
                VStack(alignment: .leading, spacing: width * 0.035) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        let heading = line.hasPrefix("#")
                        Text(heading ? String(line.drop { $0 == "#" || $0 == " " }) : line)
                            .font(.system(size: width * (heading ? 0.085 : 0.062), weight: heading ? .bold : .regular,
                                          design: heading ? .rounded : .default))
                            .foregroundStyle(heading && index == 0 ? BottoTheme.ink : .secondary)
                            .lineLimit(1)
                    }
                }
                .padding(width * 0.1)
            case nil:
                placeholderLines.padding(width * 0.1)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: width * 0.11, style: .continuous))
        .shadow(color: .black.opacity(0.07), radius: 2, y: 1)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var placeholderLines: some View {
        if kind == .image || kind == .other {
            Image(systemName: kind.symbol).font(.system(size: width * 0.26)).foregroundStyle(BottoTheme.action.opacity(0.75))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: width * 0.065) {
                Capsule().fill(BottoTheme.ink.opacity(0.75)).frame(width: width * 0.5, height: width * 0.055)
                ForEach(0..<6, id: \.self) { index in
                    Capsule().fill(Color.secondary.opacity(0.25))
                        .frame(width: width * (index % 3 == 2 ? 0.45 : 0.78), height: width * 0.038)
                }
            }
        }
    }
}

enum T3OutputKind {
    case markdown, text, image, other

    init(_ output: T3OutputFile) {
        let ext = (output.name as NSString).pathExtension.lowercased()
        let mime = output.mimeType.lowercased()
        if ["md", "markdown"].contains(ext) || mime == "text/markdown" { self = .markdown }
        else if mime.hasPrefix("image/"), ext != "svg" { self = .image }
        else if ArtifactPlainText.supports(filename: output.name, mimeType: output.mimeType) { self = .text }
        else { self = .other }
    }

    var symbol: String {
        switch self {
        case .markdown: "doc.richtext"
        case .text: "doc.text"
        case .image: "photo"
        case .other: "doc"
        }
    }

    static func extensionLabel(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.uppercased()
        return ext.isEmpty ? String(localized: "FILE") : ext
    }
}

struct T3OutputPreview: View {
    let store: AppStore
    let output: T3OutputFile
    @Environment(\.dismiss) private var dismiss
    @State private var file: ArtifactPreviewFile?
    @State private var error: String?
    @State private var retry = 0
    private let workspace: ConversationWorkspace

    init(store: AppStore, output: T3OutputFile) {
        self.store = store
        self.output = output
        workspace = store.chats
    }

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(BottoTheme.paper)
                .bottoNavigationChrome()
                .navigationTitle(output.name).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                    if let file {
                        ToolbarItem(placement: .primaryAction) {
                            ShareLink(item: file.url) { Label("Share", systemImage: "square.and.arrow.up") }
                                .accessibilityIdentifier("t3-output-share")
                        }
                    }
                }
                .tint(BottoTheme.action)
        }
        .task(id: retry) { await download() }
        .onChange(of: ObjectIdentifier(store.chats)) { _, _ in
            if store.chats !== workspace { dismiss() }
        }
    }

    @ViewBuilder private var content: some View {
        if let file {
            switch T3OutputKind(output) {
            case .markdown:
                if case .success(let text) = ArtifactPlainText.decode(file.data, mimeType: file.mimeType) {
                    ScrollView {
                        MarkdownBody(text: text)
                            .padding(20).frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity)
                    }
                } else {
                    ArtifactTextReader(file: file)
                }
            case .text:
                ArtifactTextReader(file: file)
            case .image:
                if let image = UIImage(data: file.data) {
                    ScrollView([.vertical, .horizontal]) {
                        Image(uiImage: image).resizable().scaledToFit()
                            .frame(maxWidth: 900).padding(16)
                            .accessibilityLabel(output.name)
                    }
                } else {
                    unavailable
                }
            case .other:
                unavailable
            }
        } else if let error {
            VStack(spacing: 14) {
                T3FriendlyPlaceholder(avatarID: "t3-output", asleep: !store.isConnected,
                                      title: "Couldn’t open this file", verbatim: error)
                if !store.isConnected { ConnectionStatusView(store: store).padding(.horizontal, 20) }
                Button("Try again", systemImage: "arrow.clockwise") { retry += 1 }
                    .buttonStyle(BottoPillButtonStyle(prominent: true))
                    .accessibilityIdentifier("t3-output-retry")
            }
        } else {
            VStack(spacing: 12) {
                ProgressView()
                Text("Opening \(output.name)…").font(.subheadline).foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("t3-output-loading")
        }
    }

    @ViewBuilder private var unavailable: some View {
        if let file {
            VStack(spacing: 14) {
                Image(systemName: T3OutputKind(output).symbol)
                    .font(.system(size: 44)).foregroundStyle(BottoTheme.action)
                    .frame(width: 88, height: 88)
                    .background(BottoTheme.selection, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .accessibilityHidden(true)
                Text(output.name).font(.bottoRounded(.title3, weight: .bold)).multilineTextAlignment(.center)
                Text("No preview here, but you can save or share the original file.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                ShareLink(item: file.url) { Label("Save or share", systemImage: "square.and.arrow.up") }
                    .buttonStyle(BottoPillButtonStyle(prominent: true))
            }
            .padding(24)
        }
    }

    private func download() async {
        guard file == nil, store.chats === workspace else { return }
        error = nil
        do {
            let downloaded = try await store.downloadT3Output(output)
            let written = try await ArtifactPreviewFile.write(downloaded)
            guard !Task.isCancelled, store.chats === workspace else { return }
            file = written
        } catch where !Task.isCancelled && store.chats === workspace {
            self.error = error.localizedDescription
        } catch { }
    }
}
