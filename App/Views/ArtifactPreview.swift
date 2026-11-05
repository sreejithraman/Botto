// Native preview pattern adapted from Hermex QuickLookFilePreview.swift. MIT; see LICENSES/Hermex.txt.
import SwiftUI
import PDFKit
import QuickLook
import UniformTypeIdentifiers
import BottoCore

/// The pages of a reader whose file came from a message with others.
struct ArtifactPages {
    let index: Int
    let count: Int
    /// The session for a page, or nil when it is too far from the selected one to be loaded.
    let session: (Int) -> (any ArtifactReadingSession)?
    /// Selects the page this many steps away, returning false when the reader refuses.
    let move: (Int) -> Bool
}

/// A reader of a scene-owned session. Native host changes never load or retire it.
struct ArtifactPreview: View {
    private static let controlSide: CGFloat = 44
    private static let controlSpacing: CGFloat = 8
    let session: any ArtifactReadingSession
    let isExpanded: Bool
    var isActive = true
    /// Outlasts `isActive` through a brief inactive scene. Files turns the scene inactive
    /// while it resolves a name collision; dropping its sheet then loses the completion
    /// and presents Files again.
    var holdsOutput = true
    let onClose: () -> Void
    var onToggleExpanded: (() -> Void)? = nil
    let onRetry: () -> Void
    var onBrowseBots: (() -> Void)? = nil
    var canPresentOutput: () -> Bool = { true }
    var connectionFeedback: AnyView? = nil
    var pages: ArtifactPages? = nil
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let errorID = session.exportErrorID
        VStack(spacing: 0) {
            header
            if session.file != nil, let error = session.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.secondary)
                    .padding(.horizontal).padding(.vertical, 8)
                    .accessibilityIdentifier("artifact-reload-error")
            }
            Group {
                if let pages {
                    ArtifactPager(pages: pages, canTurn: isActive && !session.isPresentingOutput) { page, onZoomChange in
                        ArtifactReaderPage(session: page, isPaged: true, isActive: isActive && page === session,
                                           onRetry: onRetry, connectionFeedback: page === session ? connectionFeedback : nil,
                                           onZoomChange: onZoomChange)
                    }
                } else {
                    ArtifactReaderPage(session: session, isPaged: false, isActive: isActive, onRetry: onRetry,
                                       connectionFeedback: connectionFeedback)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("artifact-preview")
        }
        .background(BottoTheme.paper)
        .background {
            if let file = session.output?.file ?? session.file {
                ArtifactOutputPresenter(session: session, file: file, isActive: holdsOutput)
                    .id(file.id)
            }
        }
        .alert("Export Failed", isPresented: Binding(get: { isActive && session.exportError != nil }, set: { if !$0 { session.clearExportError(id: errorID) } })) {
            Button("OK") { session.clearExportError(id: errorID) }
        } message: { Text(session.exportError ?? "") }
    }

    private func move(by step: Int) {
        guard let pages, isActive, !session.isPresentingOutput,
              (0..<pages.count).contains(pages.index + step) else { return }
        _ = pages.move(step)
    }

    private var isReloading: Bool { session.isLoading && session.file != nil }
    private var fileUnavailable: Bool { session.file == nil || !session.isCurrent || session.isLoading }

    /// The title centers in the header whatever each side holds, so it clears the fuller side.
    private var titleInset: CGFloat {
        let trailing = 1 + (isReloading ? 1 : 0) + (onToggleExpanded == nil ? 0 : 1)
        return CGFloat(trailing) * (Self.controlSide + Self.controlSpacing)
    }

    /// Pane-local controls never contribute navigation preferences. The one
    /// outer stack owns the rail; this header stays attached to the same reader.
    private var header: some View {
        ZStack {
            title.padding(.horizontal, titleInset)
            HStack(spacing: Self.controlSpacing) {
                control("Close", systemImage: "xmark", action: onClose)
                    .accessibilityIdentifier("artifact-done")
                    .disabled(!isActive || session.isPresentingOutput)
                Spacer(minLength: 0)
                if isReloading {
                    ProgressView().controlSize(.small).frame(width: Self.controlSide, height: Self.controlSide)
                        .accessibilityLabel("Reloading file")
                }
                if let onToggleExpanded {
                    control(isExpanded ? "Exit full screen" : "Full screen",
                            systemImage: isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                            action: onToggleExpanded)
                        .accessibilityIdentifier("artifact-toggle-expanded")
                        .disabled(!isActive || session.isPresentingOutput)
                }
                actions
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 2)
        .background(BottoTheme.paper)
    }

    private var title: some View {
        VStack(spacing: 1) {
            Text(session.title).font(.headline).truncationMode(.middle)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1).multilineTextAlignment(.center)
                .accessibilityIdentifier("artifact-title")
            if let pages {
                Text("\(pages.index + 1) of \(pages.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .accessibilityIdentifier("artifact-page")
                    .accessibilityLabel("Attachment \(pages.index + 1) of \(pages.count)")
                    .accessibilityAdjustableAction { direction in
                        if direction == .increment { move(by: 1) } else if direction == .decrement { move(by: -1) }
                    }
            }
        }
        // The file below stays the subject, however large the text; the header grows to fit.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func control(_ label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { controlLabel(label, systemImage: systemImage) }.buttonStyle(.plain)
    }

    private func controlLabel(_ label: String, systemImage: String) -> some View {
        Label(label, systemImage: systemImage).labelStyle(.iconOnly)
            .font(.system(size: 16, weight: .semibold))
            .frame(width: Self.controlSide, height: Self.controlSide)
            .controlGlass(in: Circle())
            .contentShape(Circle())
    }

    private var actions: some View {
        Menu {
            Button("Save to Files", systemImage: "square.and.arrow.down") {
                if isActive && canPresentOutput() { session.beginOutput(.save) }
            }
            .accessibilityIdentifier("artifact-save").disabled(fileUnavailable)
            Button("Share", systemImage: "square.and.arrow.up") {
                if isActive && canPresentOutput() { session.beginOutput(.share) }
            }
            .accessibilityIdentifier("artifact-share").disabled(fileUnavailable)
            if session.canReload {
                Button("Reload from Bot", systemImage: "arrow.clockwise") {
                    if isActive && canPresentOutput() { session.reload() }
                }.disabled(session.isLoading)
            }
            if let onBrowseBots {
                Divider()
                Button("Bots", systemImage: "sidebar.left", action: onBrowseBots)
                    .accessibilityIdentifier("workspace-browse-bots")
            }
        } label: {
            controlLabel("Actions", systemImage: "ellipsis")
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("artifact-actions")
        // Bots stays reachable while a file loads or fails, when there is nothing to export.
        .disabled(!isActive || session.isPresentingOutput || (onBrowseBots == nil && fileUnavailable))
    }
}

/// Follows the finger with a native paging scroll view. The page under it stays
/// provisional until scrolling stops, when the reader decides whether to select it.
private struct ArtifactPager<Page: View>: View {
    let pages: ArtifactPages
    let canTurn: Bool
    @ViewBuilder let page: (_ session: any ArtifactReadingSession, _ onZoomChange: @escaping (Bool) -> Void) -> Page
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position: Int?
    /// The file whose zoomed content owns horizontal drags. A new file starts fitted.
    @State private var zoomedFile: ArtifactPreviewFile.ID?

    init(pages: ArtifactPages, canTurn: Bool,
         @ViewBuilder page: @escaping (_ session: any ArtifactReadingSession, _ onZoomChange: @escaping (Bool) -> Void) -> Page) {
        self.pages = pages; self.canTurn = canTurn; self.page = page
        _position = State(initialValue: pages.index)
    }

    private var isZoomed: Bool { zoomedFile != nil && zoomedFile == pages.session(pages.index)?.file?.id }

    var body: some View {
        // Sized from the reader's own bounds: a container-relative height can include the
        // navigation bar's inset, which pushes a paired reader's header out of its pane.
        GeometryReader { geometry in
            ScrollViewReader { scroller in
                ScrollView(.horizontal) {
                    // Not lazy: the pages beside the current one must already be drawn when a drag starts.
                    HStack(spacing: 0) {
                        ForEach(0..<pages.count, id: \.self) { index in
                            pageContent(index)
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .clipped()
                                .accessibilityHidden(index != pages.index)
                        }
                    }
                    .scrollTargetLayout()
                }
                .defaultScrollAnchor(UnitPoint(x: CGFloat(pages.index) / CGFloat(max(pages.count - 1, 1)), y: 0),
                                     for: .initialOffset)
                .scrollPosition(id: $position)
                .scrollTargetBehavior(.paging)
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.always, axes: .horizontal)
                .scrollDisabled(!canTurn || isZoomed)
                .onScrollPhaseChange { _, phase in
                    if phase == .idle { settle() }
                }
                .onChange(of: pages.index) { _, index in
                    guard position != index else { return }
                    withAnimation(reduceMotion ? nil : .default) { position = index }
                }
                // The scroll offset is in points, so a new pane width would strand it between pages.
                .onChange(of: geometry.size.width) { _, _ in
                    var unanimated = Transaction()
                    unanimated.disablesAnimations = true
                    withTransaction(unanimated) { scroller.scrollTo(pages.index, anchor: .leading) }
                }
            }
        }
    }

    @ViewBuilder private func pageContent(_ index: Int) -> some View {
        if let session = pages.session(index) {
            page(session) { zoomed in
                if let file = session.file?.id {
                    if zoomed { zoomedFile = file } else if zoomedFile == file { zoomedFile = nil }
                }
            }
            .id(ObjectIdentifier(session))
        } else {
            ProgressView()
        }
    }

    private func settle() {
        guard let position, position != pages.index else { return }
        if !pages.move(position - pages.index) { self.position = pages.index }
    }
}

/// One file's content, in a reader of its own or as a page of several.
private struct ArtifactReaderPage: View {
    let session: any ArtifactReadingSession
    let isPaged: Bool
    let isActive: Bool
    let onRetry: () -> Void
    var connectionFeedback: AnyView? = nil
    var onZoomChange: (Bool) -> Void = { _ in }

    var body: some View {
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
            } else if !file.data.isEmpty, isPaged, ArtifactPDF.supports(file) {
                ArtifactPDF(url: file.url, onZoomChange: onZoomChange)
                    .id(file.id).accessibilityLabel("Artifact preview")
            } else if !file.data.isEmpty, isPaged, let image = ArtifactZoomableImage.image(in: file) {
                ArtifactZoomableImage(image: image, name: session.title, onZoomChange: onZoomChange).id(file.id)
            } else if !file.data.isEmpty, QLPreviewController.canPreview(file.url as NSURL) {
                ArtifactQuickLook(file: file).accessibilityLabel("Artifact preview")
                    .overlay { if isPaged { ArtifactPageEdges() } }
            } else {
                ContentUnavailableView(file.data.isEmpty ? "Empty File" : "Preview Unavailable", systemImage: "doc",
                                       description: Text("You can still save or share the original file."))
                    .accessibilityIdentifier("artifact-unavailable")
            }
        } else if let message = session.errorMessage {
            ContentUnavailableView {
                Label("Could Not Load File", systemImage: "exclamationmark.triangle")
            } description: { Text(message).textSelection(.enabled) } actions: {
                if let connectionFeedback {
                    connectionFeedback.disabled(!isActive)
                } else {
                    Button("Try Again", action: onRetry)
                        .accessibilityIdentifier("artifact-retry")
                        .disabled(!isActive)
                }
            }
            .accessibilityIdentifier("artifact-error")
        } else {
            ProgressView("Loading file…").accessibilityIdentifier("artifact-loading")
        }
    }
}

/// Quick Look can draw in another process, where a drag never reaches the pager.
/// These edges stay in this app, so a page of any type can still be swiped away.
private struct ArtifactPageEdges: View {
    private static let width: CGFloat = 28

    var body: some View {
        HStack {
            edge
            Spacer()
            edge
        }
    }

    private var edge: some View {
        Color.clear.frame(width: Self.width).contentShape(Rectangle()).accessibilityHidden(true)
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

/// Quick Look draws PDFs in another process, where a swipe never reaches this app, so
/// attachments that page use PDFKit. Encrypted PDFs stay with Quick Look's password prompt.
private struct ArtifactPDF: UIViewRepresentable {
    let url: URL
    let onZoomChange: (Bool) -> Void

    static func supports(_ file: ArtifactPreviewFile) -> Bool {
        file.mimeType == "application/pdf" && CGPDFDocument(file.url as CFURL)?.isEncrypted == false
    }
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.backgroundColor = .clear
        view.document = PDFDocument(url: url)
        context.coordinator.observation = NotificationCenter.default.addObserver(
            forName: .PDFViewScaleChanged, object: view, queue: .main) { [weak view, coordinator = context.coordinator] _ in
            MainActor.assumeIsolated {
                guard let view else { return }
                coordinator.onZoomChange(view.scaleFactor > view.scaleFactorForSizeToFit * 1.01)
            }
        }
        return view
    }
    func updateUIView(_ view: PDFView, context: Context) { context.coordinator.onZoomChange = onZoomChange }
    func makeCoordinator() -> Coordinator { Coordinator(onZoomChange: onZoomChange) }
    static func dismantleUIView(_ view: PDFView, coordinator: Coordinator) {
        coordinator.observation.map(NotificationCenter.default.removeObserver)
    }
    @MainActor final class Coordinator {
        var onZoomChange: (Bool) -> Void
        var observation: (any NSObjectProtocol)?
        init(onZoomChange: @escaping (Bool) -> Void) { self.onZoomChange = onZoomChange }
    }
}

/// A photo a pager can reach, with the pinch and double tap of Photos. Formats this
/// can't show faithfully, such as animated GIFs, stay with Quick Look.
private struct ArtifactZoomableImage: UIViewRepresentable {
    let image: UIImage
    let name: String
    let onZoomChange: (Bool) -> Void

    static func image(in file: ArtifactPreviewFile) -> UIImage? {
        guard file.mimeType.hasPrefix("image/"), file.mimeType != "image/gif" else { return nil }
        return UIImage(data: file.data)
    }
    func makeUIView(context: Context) -> ArtifactImageScrollView {
        ArtifactImageScrollView(image: image, name: name, onZoomChange: onZoomChange)
    }
    func updateUIView(_ view: ArtifactImageScrollView, context: Context) { view.onZoomChange = onZoomChange }
}

private final class ArtifactImageScrollView: UIScrollView, UIScrollViewDelegate {
    private static let maximumEnlargement: CGFloat = 5
    private let imageView: UIImageView
    private var fittedSize = CGSize.zero
    var onZoomChange: (Bool) -> Void

    init(image: UIImage, name: String, onZoomChange: @escaping (Bool) -> Void) {
        imageView = UIImageView(image: image)
        self.onZoomChange = onZoomChange
        super.init(frame: .zero)
        delegate = self
        addSubview(imageView)
        contentSize = image.size
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = name
        imageView.accessibilityTraits = .image
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var isFitted: Bool { zoomScale <= minimumZoomScale * 1.01 }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != fittedSize, bounds.width > 0, bounds.height > 0,
              let size = imageView.image?.size, size.width > 0, size.height > 0 else { return }
        let wasFitted = isFitted
        fittedSize = bounds.size
        let fit = min(bounds.width / size.width, bounds.height / size.height)
        minimumZoomScale = fit
        maximumZoomScale = fit * Self.maximumEnlargement
        zoomScale = wasFitted ? fit : min(max(zoomScale, fit), maximumZoomScale)
        centerImage()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
        onZoomChange(!isFitted)
    }

    private func centerImage() {
        let horizontal = max((bounds.width - contentSize.width) / 2, 0)
        let vertical = max((bounds.height - contentSize.height) / 2, 0)
        contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }

    @objc private func toggleZoom(_ tap: UITapGestureRecognizer) {
        if isFitted {
            let enlarged = min(minimumZoomScale * 2.5, maximumZoomScale)
            let point = tap.location(in: imageView)
            let size = CGSize(width: bounds.width / enlarged, height: bounds.height / enlarged)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                            width: size.width, height: size.height), animated: !UIAccessibility.isReduceMotionEnabled)
        } else {
            setZoomScale(minimumZoomScale, animated: !UIAccessibility.isReduceMotionEnabled)
        }
    }
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
