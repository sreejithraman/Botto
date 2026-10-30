import SwiftUI
import BottoCore
import ImageIO

struct ArtifactsView: View {
    let store: AppStore
    let library: WorkspaceLibrary
    let onOpen: (LibraryArtifact) -> Void
    @State private var bot: ExactID?
    @State private var kind: DiscoveredArtifact.Kind?
    @State private var includesReferences = false
    @State private var thumbnails = LibraryThumbnails()

    private var items: [LibraryArtifact] {
        library.artifacts.filter {
            (includesReferences || $0.artifact.category == .output)
                && (bot == nil || $0.chat.identity.profile == bot)
                && (kind == nil || $0.artifact.kind == kind)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if store.isDemo { DemoBanner().padding(.horizontal, -20) }
                    HStack(alignment: .firstTextBaseline) {
                        Text(includesReferences ? "Outputs and references" : "Made and shared by your bots")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        filterMenu
                    }
                    LibraryStatus(library: library, refresh: { await store.refreshLibrary(force: true) })
                    if items.isEmpty {
                        emptyState.frame(maxWidth: .infinity).padding(.vertical, 60)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 155, maximum: 260), spacing: 16)], spacing: 22) {
                            ForEach(items) { item in
                                Button { onOpen(item) } label: { LibraryArtifactCard(item: item, library: library, thumbnails: thumbnails) }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("library-artifact-\(item.artifact.title)")
                            }
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 28)
                .frame(maxWidth: 1100).frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("artifact-library")
            .background(BottoTheme.paper)
            .navigationTitle("Artifacts")
            .bottoNavigationChrome()
            .refreshable { await store.refreshLibrary(force: true) }
        }
    }

    private var hasFilters: Bool { bot != nil || kind != nil || includesReferences }

    private var filterMenu: some View {
        Menu {
            Menu("Bot", systemImage: "person.crop.circle") {
                Picker("Bot", selection: $bot) {
                    Text("All bots").tag(ExactID?.none)
                    ForEach(store.bots) { profile in
                        if let id = try? ExactID(profile.id) {
                            Text(profile.name).tag(Optional(id))
                        }
                    }
                }
            }
            Menu("File type", systemImage: "doc") {
                Picker("File type", selection: $kind) {
                    Text("All types").tag(DiscoveredArtifact.Kind?.none)
                    ForEach(DiscoveredArtifact.Kind.allCases, id: \.self) { kind in
                        Text(kind.libraryLabel).tag(Optional(kind))
                    }
                }
            }
            Toggle("Include references", isOn: $includesReferences)
            if hasFilters {
                Button("Clear filters") { bot = nil; kind = nil; includesReferences = false }
            }
        } label: {
            Label("Filter", systemImage: hasFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityIdentifier("library-filters")
    }

    @ViewBuilder private var emptyState: some View {
        if library.isLoading && library.artifacts.isEmpty {
            ProgressView("Finding artifacts…")
        } else if hasFilters {
            ContentUnavailableView("No Matching Artifacts", systemImage: "line.3.horizontal.decrease.circle",
                                   description: Text("Try another bot or file type."))
        } else {
            ContentUnavailableView("Your Bots’ Work, Together", systemImage: "square.stack",
                                   description: Text("Files and previews your bots share will appear here, with the chat they came from."))
        }
    }
}

private struct LibraryArtifactCard: View {
    let item: LibraryArtifact
    let library: WorkspaceLibrary
    let thumbnails: LibraryThumbnails
    @State private var thumbnail: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 18).fill(BottoTheme.surface)
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFit().padding(12)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: item.artifact.kind.librarySymbol)
                            .font(.system(size: 34, weight: .regular)).foregroundStyle(BottoTheme.action)
                        Text(fileType).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(height: 142).clipped().accessibilityHidden(true)
            Text(item.artifact.title).font(.subheadline.weight(.semibold))
                .foregroundStyle(BottoTheme.ink).lineLimit(2).truncationMode(.middle)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.chat.botName).font(.caption.weight(.medium))
                Text(item.chat.title).font(.caption).lineLimit(1)
                if item.artifact.category == .reference {
                    Text("Reference").font(.caption2)
                }
            }.foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .task(id: LibraryThumbnails.request(for: item, library: library)) {
            thumbnail = nil
            guard item.artifact.kind == .image else { return }
            let image = await thumbnails.image(for: item, library: library)
            guard !Task.isCancelled, library.isCurrent(item) else { return }
            thumbnail = image
        }
    }

    private var fileType: String {
        if let format = item.artifact.block?.previewFormat {
            return switch format {
            case .html: "Interactive preview"
            case .svg: "Illustration"
            case .mermaid: "Diagram"
            }
        }
        let ext = (item.artifact.title as NSString).pathExtension.uppercased()
        return ext.isEmpty ? item.artifact.kind.libraryLabel : ext
    }

}

/// Optional covers use one bounded download at a time and retain only small
/// decoded images. A failed cover never blocks opening the original file.
@MainActor final class LibraryThumbnails {
    struct Request: Hashable, Sendable {
        let artifact: LibraryArtifact.ID
        let sourceRevision: Data?
        let captureRevision: UUID
    }
    static func request(for item: LibraryArtifact, library: WorkspaceLibrary) -> Request {
        Request(artifact: item.id, sourceRevision: item.chat.sourceRevisions[Data(item.artifact.messageID.utf8)],
            captureRevision: library.captureRevision)
    }
    private var images: [(request: Request, image: UIImage)] = []
    private var tail: Task<Void, Never>?

    func image(for item: LibraryArtifact, library: WorkspaceLibrary) async -> UIImage? {
        let request = Self.request(for: item, library: library)
        if let image = images.first(where: { $0.request == request })?.image { return image }
        let previous = tail
        let task = Task<UIImage?, Never> {
            await previous?.value
            guard !Task.isCancelled, library.isCurrent(item),
                  let data = await library.thumbnail(for: item, render: Self.thumbnailData) else { return nil }
            return await Task.detached(priority: .utility) { UIImage(data: data) }.value
        }
        tail = Task { _ = await task.value }
        let image = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        guard !Task.isCancelled, library.isCurrent(item), Self.request(for: item, library: library) == request,
              let image else { return nil }
        images.removeAll { $0.request == request }
        images.append((request, image))
        if images.count > 16 { images.removeFirst(images.count - 16) }
        return image
    }

    private nonisolated static func thumbnailData(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 32_768, height <= 32_768,
              Int64(width) * Int64(height) <= 100_000_000 else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 400,
            kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

struct LibraryStatus: View {
    let library: WorkspaceLibrary
    let refresh: () async -> Void

    var body: some View {
        if let warning = library.warning {
            VStack(alignment: .leading, spacing: 8) {
                Text(warning).font(.footnote).foregroundStyle(.secondary)
                Button("Try Again") { Task { await refresh() } }
                    .font(.footnote.weight(.medium)).disabled(library.isLoading)
            }
            .accessibilityIdentifier("library-status")
        }
    }
}

extension DiscoveredArtifact.Kind {
    var libraryLabel: String {
        switch self {
        case .image: "Images"
        case .document: "Documents"
        case .audio: "Audio"
        case .video: "Video"
        case .preview: "Previews"
        }
    }
    var librarySymbol: String {
        switch self {
        case .image: "photo"
        case .document: "doc.text"
        case .audio: "waveform"
        case .video: "film"
        case .preview: "rectangle.and.pencil.and.ellipsis"
        }
    }
}
