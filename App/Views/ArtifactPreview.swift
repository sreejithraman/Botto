// Native preview pattern adapted from Hermex QuickLookFilePreview.swift. MIT; see LICENSES/Hermex.txt.
import SwiftUI
import QuickLook
import UniformTypeIdentifiers
import BottoCore

/// A reader of a scene-owned session. Native host changes never load or retire it.
struct ArtifactPreview: View {
    let session: any ArtifactReadingSession
    let isExpanded: Bool
    var isActive = true
    let onClose: () -> Void
    var onToggleExpanded: (() -> Void)? = nil
    let onRetry: () -> Void
    var onBrowseBots: (() -> Void)? = nil
    var canPresentOutput: () -> Bool = { true }

    var body: some View {
        let errorID = session.exportErrorID
        VStack(spacing: 0) {
            header
            if session.file != nil, let error = session.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.secondary)
                    .padding(.horizontal).padding(.vertical, 8)
                    .accessibilityIdentifier("artifact-reload-error")
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("artifact-preview")
        }
        .background(BottoTheme.paper)
        .background {
            if let file = session.output?.file ?? session.file {
                ArtifactOutputPresenter(session: session, file: file, isActive: isActive)
                    .id(file.id)
            }
        }
        .alert("Export Failed", isPresented: Binding(get: { isActive && session.exportError != nil }, set: { if !$0 { session.clearExportError(id: errorID) } })) {
            Button("OK") { session.clearExportError(id: errorID) }
        } message: { Text(session.exportError ?? "") }
    }

    /// Pane-local controls never contribute navigation preferences. The one
    /// outer stack owns the rail; this header stays attached to the same reader.
    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onClose) {
                Label("Close", systemImage: "xmark").labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }
                .accessibilityIdentifier("artifact-done")
                .disabled(!isActive || session.isPresentingOutput)
            Text(session.title).font(.headline).lineLimit(2).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
                .accessibilityIdentifier("artifact-title")
            if session.isLoading, session.file != nil {
                ProgressView().controlSize(.small).accessibilityLabel("Reloading file")
            }
            Menu {
                Button("Save to Files", systemImage: "square.and.arrow.down") {
                    if isActive && canPresentOutput() { session.beginOutput(.save) }
                }.accessibilityIdentifier("artifact-save")
                Button("Share", systemImage: "square.and.arrow.up") {
                    if isActive && canPresentOutput() { session.beginOutput(.share) }
                }.accessibilityIdentifier("artifact-share")
                if session.canReload {
                    Button("Reload from Bot", systemImage: "arrow.clockwise") {
                        if isActive && canPresentOutput() { session.reload() }
                    }.disabled(session.isLoading)
                }
                if let onBrowseBots {
                    Button("Bots", systemImage: "sidebar.left", action: onBrowseBots)
                }
            } label: {
                Label("Actions", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityIdentifier("artifact-actions")
            .disabled(!isActive || session.file == nil || !session.isCurrent || session.isPresentingOutput || session.isLoading)
            if let onToggleExpanded {
                Button(action: onToggleExpanded) {
                    Label(isExpanded ? "Exit full screen" : "Full screen",
                          systemImage: isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }
                .accessibilityIdentifier("artifact-toggle-expanded")
                .disabled(!isActive || session.isPresentingOutput)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(BottoTheme.paper)
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder private var content: some View {
        if !session.isCurrent {
            ContentUnavailableView("File Unavailable", systemImage: "network.slash",
                                   description: Text("This chat or connection changed. Reopen the file from its original chat."))
                .accessibilityIdentifier("artifact-error")
        } else if let block = session.previewBlock {
            ScrollView {
                RichReplyBlockView(block: block, initialHeight: 440)
                    .padding()
            }
            .environment(\.richReplyContext, .isolated)
        } else if let file = session.file {
            if !file.data.isEmpty, ArtifactPlainText.supports(filename: file.filename, mimeType: file.mimeType) {
                ArtifactTextReader(file: file).background(BottoTheme.paper)
            } else if !file.data.isEmpty, QLPreviewController.canPreview(file.url as NSURL) {
                ArtifactQuickLook(file: file).accessibilityLabel("Artifact preview")
            } else {
                ContentUnavailableView(file.data.isEmpty ? "Empty File" : "Preview Unavailable", systemImage: "doc",
                                       description: Text("You can still save or share the original file."))
                    .accessibilityIdentifier("artifact-unavailable")
            }
        } else if let message = session.errorMessage {
            ContentUnavailableView {
                Label("Could Not Load File", systemImage: "exclamationmark.triangle")
            } description: { Text(message).textSelection(.enabled) } actions: {
                Button("Try Again", action: onRetry)
                    .accessibilityIdentifier("artifact-retry")
                    .disabled(!isActive)
            }
            .accessibilityIdentifier("artifact-error")
        } else {
            ProgressView("Loading file…").accessibilityIdentifier("artifact-loading")
        }
    }
}

/// Mount native output configuration only after the original file is available.
/// Files can retain its initial document configuration across presentation changes.
private struct ArtifactOutputPresenter: View {
    let session: any ArtifactReadingSession
    let file: ArtifactPreviewFile
    let isActive: Bool

    var body: some View {
        let output = session.output
        Color.clear.frame(width: 0, height: 0)
            .sheet(item: shareBinding(output)) { output in
                ArtifactShare(file: output.file) { error in session.endOutput(id: output.id, error: error) }
            }
            .fileExporter(isPresented: saveBinding,
                          document: ArtifactDocument(data: file.data),
                          contentTypes: [ArtifactDocument.exportType(filenameExtension: file.url.pathExtension, mimeType: file.mimeType)],
                          defaultFilename: file.filename) { result in
                guard let output else { return }
                if case .failure(let error) = result { session.endOutput(id: output.id, error: error) }
                else { session.endOutput(id: output.id) }
            } onCancellation: {
                if let output { session.endOutput(id: output.id) }
            }
    }

    private func shareBinding(_ renderedOutput: ArtifactOutput?) -> Binding<ArtifactOutput?> {
        Binding(get: { isActive && session.output?.kind == .share ? session.output : nil }, set: { value in
            if value == nil, let renderedOutput { session.endOutput(id: renderedOutput.id) }
        })
    }

    private var saveBinding: Binding<Bool> {
        // Native false precedes completion too. Finish only the captured token
        // in explicit completion/cancellation callbacks, retaining genuine errors.
        Binding(get: { isActive && session.output?.kind == .save }, set: { _ in })
    }
}

struct ArtifactDocument: FileDocument {
    static let readableContentTypes = [UTType.data]
    // SwiftUI requires concrete writable types; .data does not advertise its
    // subtypes. All representations keep original bytes, without conversion.
    static let writableContentTypes: [UTType] = [
        .data, .pdf, .plainText, .html,
        .png, .jpeg, .gif, .tiff, .heic, .webP, .svg
    ]

    static func exportType(filenameExtension: String, mimeType: String) -> UTType {
        let requested = UTType(filenameExtension: filenameExtension) ?? UTType(mimeType: mimeType) ?? .data
        return writableContentTypes.contains(requested) ? requested : .data
    }

    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

private struct ArtifactQuickLook: UIViewControllerRepresentable {
    let file: ArtifactPreviewFile
    func makeCoordinator() -> Coordinator { Coordinator(file: file) }
    func makeUIViewController(context: Context) -> ArtifactReaderController {
        let preview = QLPreviewController()
        preview.dataSource = context.coordinator
        preview.delegate = context.coordinator
        let controller = ArtifactReaderController(preview: preview)
        return controller
    }
    func updateUIViewController(_ controller: ArtifactReaderController, context: Context) {
        let preview = controller.preview
        guard context.coordinator.file !== file else { return }
        context.coordinator.file = file
        preview.reloadData()
    }
    final class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
        var file: ArtifactPreviewFile
        init(file: ArtifactPreviewFile) { self.file = file }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { file.url as NSURL }
        nonisolated func previewController(_ controller: QLPreviewController, editingModeFor previewItem: any QLPreviewItem) -> QLPreviewItemEditingMode { .disabled }
    }
}

/// QL keeps one documented native navigation owner throughout reader reflow.
/// This container has one child; UIKit forwards appearance automatically. Its
/// native bars are hidden because the workspace and plain header own commands.
private final class ArtifactReaderController: UIViewController {
    let preview: QLPreviewController
    let readerNavigationController: UINavigationController

    init(preview: QLPreviewController) {
        self.preview = preview
        readerNavigationController = ArtifactReaderNavigationController(rootViewController: preview)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        addChild(readerNavigationController)
        let childView = readerNavigationController.view!
        childView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(childView)
        NSLayoutConstraint.activate([
            childView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            childView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            childView.topAnchor.constraint(equalTo: view.topAnchor),
            childView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        readerNavigationController.didMove(toParent: self)
    }

}

/// This reader has pane-local, capability-fenced commands. Its native owner
/// therefore accepts containment/appearance but never a child's chrome request.
/// Enforce at public request entry points, not by fighting layout repeatedly.
private final class ArtifactReaderNavigationController: UINavigationController {
    override init(rootViewController: UIViewController) {
        super.init(rootViewController: rootViewController)
        keepNavigationBarHidden()
        keepToolbarHidden()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isNavigationBarHidden: Bool {
        get { super.isNavigationBarHidden }
        set { keepNavigationBarHidden() }
    }
    override func setNavigationBarHidden(_ hidden: Bool, animated: Bool) {
        keepNavigationBarHidden()
    }
    override var isToolbarHidden: Bool {
        get { super.isToolbarHidden }
        set { keepToolbarHidden() }
    }
    override func setToolbarHidden(_ hidden: Bool, animated: Bool) {
        keepToolbarHidden()
    }
    private func keepNavigationBarHidden() {
        if !super.isNavigationBarHidden { super.setNavigationBarHidden(true, animated: false) }
    }
    private func keepToolbarHidden() {
        if !super.isToolbarHidden { super.setToolbarHidden(true, animated: false) }
    }
}

private struct ArtifactShare: UIViewControllerRepresentable {
    let file: ArtifactPreviewFile
    let completion: (Error?) -> Void
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [file.url], applicationActivities: nil)
        // UIKit retains this completion until the activity finishes or is
        // dismissed. Its reader survives destruction of the parent preview.
        controller.completionWithItemsHandler = { [file] _, _, _, error in
            withExtendedLifetime(file) { completion(error) }
        }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
