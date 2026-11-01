import SwiftUI
import UIKit
import BottoCore
import WebKit

enum RichReplyPresentationMode: String, Identifiable {
    case source, expanded
    var id: String { rawValue }
}

/// Inline preview and foreground controls for a `.preview` block.
/// The native transcript owns foreground lifetime; standalone callers use a local sheet.
struct RichReplyBlockView: View {
    let block: ReplyContent.Block
    let initialHeight: CGFloat?
    @Environment(\.richReplyContext) private var context
    @Environment(\.reportChatModal) private var reportModal
    @Environment(\.nativeTranscriptRow) private var nativeRow
    private var isCurrent: Bool { nativeRow?.isCurrent ?? true }
    @State private var modalID = UUID()
    @State private var presentation: RichReplyPresentationMode?
    @State private var reportedStandaloneModal: UUID?

    init(block: ReplyContent.Block, initialHeight: CGFloat? = nil) {
        self.block = block; self.initialHeight = initialHeight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    sectionTitle
                    Spacer(minLength: 8)
                    HStack(spacing: 12) { actionButtons }.fixedSize()
                }
                VStack(alignment: .leading, spacing: 0) {
                    sectionTitle
                    HStack(spacing: 12) { actionButtons }.fixedSize()
                }
                VStack(alignment: .leading, spacing: 0) {
                    sectionTitle
                    actionButtons
                }
            }
            RichPreviewSurface(block: block, expanded: false, active: presentation == nil, initialHeight: initialHeight)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .onChange(of: presentation == nil) { _, dismissed in
            if dismissed { finishStandaloneCoverage() }
        }
        .onDisappear { finishStandaloneCoverage() }
        .sheet(item: $presentation) { selected in
            RichReplyPresentationContent(block: block, context: context,
                selection: Binding(get: { presentation ?? selected }, set: { presentation = $0 }),
                isCurrent: { isCurrent }, close: { presentation = nil })
            .presentationDragIndicator(.visible)
            .hapticSheet(enabled: presentation != nil && isCurrent)
        }
    }

    private func open(_ mode: RichReplyPresentationMode) {
        guard isCurrent else { return }
        if let nativeRow {
            nativeRow.present(block: block, context: context, mode: mode, report: reportModal)
        } else {
            guard presentation == nil else { return }
            presentation = mode; reportedStandaloneModal = modalID
            reportModal(modalID, true)
        }
    }

    private func finishStandaloneCoverage() {
        guard let id = reportedStandaloneModal else { return }
        reportedStandaloneModal = nil
        reportModal(id, false)
    }

    private var sectionTitle: some View {
        Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var actionButtons: some View {
        Group {
            Button { open(.source) } label: {
                actionLabel("Source", symbol: "chevron.left.forwardslash.chevron.right")
                    .frame(minHeight: 44).contentShape(Rectangle())
            }
                .accessibilityLabel("Show \(formatName) source")
            Button { open(.expanded) } label: {
                actionLabel("Expand", symbol: "arrow.up.left.and.arrow.down.right")
                    .frame(minHeight: 44).contentShape(Rectangle())
            }
                .accessibilityLabel("Expand \(title)")
        }
        .buttonStyle(.borderless)
        .disabled(!isCurrent)
        .controlSize(.regular)
        .frame(minHeight: 44)
    }

    private func actionLabel(_ text: String, symbol: String) -> some View {
        Label {
            Text(text).font(.caption).lineLimit(1).fixedSize()
        } icon: {
            Image(systemName: symbol).font(.caption)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var formatName: String { block.previewFormat?.displayName ?? "Code" }
    private var title: String { block.previewFormat?.previewTitle ?? "Source preview" }
}

/// Shared sheet content; the caller owns its presentation and captured lifetime.
struct RichReplyPresentationContent: View {
    let block: ReplyContent.Block
    let context: RichReplyContext
    @Binding var selection: RichReplyPresentationMode
    let isCurrent: @MainActor () -> Bool
    let close: () -> Void
    private var formatName: String { block.previewFormat?.displayName ?? "Code" }
    private var title: String { block.previewFormat?.previewTitle ?? "Source preview" }
    var body: some View {
        NavigationStack {
            Group {
                if selection == .source { RichSourceView(source: block.source) }
                else {
                    RichPreviewSurface(block: block, expanded: true, active: isCurrent())
                        .environment(\.richReplyContext, context).padding(.horizontal)
                }
            }
            .background(BottoTheme.paper, ignoresSafeAreaEdges: [])
            .bottoNavigationChrome()
            .navigationTitle(selection == .source ? "\(formatName) source" : title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: close) { Text("Done").font(.body).lineLimit(1).fixedSize() }
                        .accessibilityLabel(selection == .source ? "Close \(formatName) source" : "Close \(title)")
                        .background(ToolbarHitRegion { close() })
                }
                if selection == .expanded {
                    ToolbarItem(placement: .primaryAction) {
                        Button(action: showSource) {
                            Text("Source").font(.body).lineLimit(1).fixedSize()
                        }.accessibilityLabel("Show \(formatName) source")
                            .background(ToolbarHitRegion(action: showSource))
                    }
                }
            }
        }
    }

    private func showSource() {
        guard selection != .source, isCurrent(), context.permits(block) else { return }
        selection = .source
        BottoHaptics.shared.play(.selection)
    }
}

/// Extend the native bar's 36-point hosting view without covering its accessible button.
private struct ToolbarHitRegion: UIViewRepresentable {
    let action: @MainActor () -> Void
    func makeUIView(context: Context) -> RegionView { RegionView(action: action) }
    func updateUIView(_ view: RegionView, context: Context) {
        view.action = action
        view.setNeedsLayout()
    }
    static func dismantleUIView(_ view: RegionView, coordinator: ()) { view.retire() }

    final class RegionView: UIView {
        var action: (@MainActor () -> Void)?
        private let edges = [EdgeButton(type: .custom), EdgeButton(type: .custom)]
        private var retired = false
        init(action: @escaping @MainActor () -> Void) {
            self.action = action
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
            for (index, edge) in edges.enumerated() {
                edge.owner = self
                edge.regionIndex = index
                edge.isAccessibilityElement = false
                edge.accessibilityElementsHidden = true
                edge.addAction(UIAction { [weak self] _ in self?.action?() }, for: .touchUpInside)
            }
        }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
        override func didMoveToWindow() { super.didMoveToWindow(); updateRegions() }
        override func didMoveToSuperview() { super.didMoveToSuperview(); updateRegions() }
        override func layoutSubviews() { super.layoutSubviews(); updateRegions() }
        private func updateRegions() {
            var ancestor = superview
            while let view = ancestor, !(view is UINavigationBar) { ancestor = view.superview }
            guard let bar = ancestor as? UINavigationBar, let regions = regions(in: bar) else {
                edges.forEach { $0.removeFromSuperview() }; return
            }
            for (edge, region) in zip(edges, regions) {
                guard !region.isNull, !region.isEmpty else { edge.removeFromSuperview(); continue }
                if edge.frame != region { edge.frame = region }
                if edge.superview !== bar { bar.addSubview(edge) }
                bar.bringSubviewToFront(edge)
            }
        }
        private func regions(in bar: UINavigationBar) -> [CGRect]? {
            guard !retired,
                  let window, bar.window === window, !bar.isHidden,
                  bounds.width > 0, bounds.height > 0 else { return nil }
            var visible = convert(bounds, to: bar)
            var ancestor = superview
            while let view = ancestor, view !== bar {
                guard !view.isHidden, view.alpha > 0.01 else { return nil }
                visible = visible.intersection(view.convert(view.bounds, to: bar))
                ancestor = view.superview
            }
            guard ancestor === bar, !visible.isNull, !visible.isEmpty else { return nil }
            let height = max(0, (44 - visible.height) / 2)
            let width = max(44, visible.width)
            return edges.indices.map { index in
                let y = index == 0 ? visible.minY - height : visible.maxY
                return CGRect(x: visible.midX - width / 2, y: y, width: width, height: height).intersection(bar.bounds)
            }
        }
        func retire() {
            retired = true
            action = nil
            edges.forEach { $0.removeFromSuperview() }
        }

        private final class EdgeButton: UIButton {
            weak var owner: RegionView?
            var regionIndex = 0
            override var canBecomeFocused: Bool { false }
            override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
                guard let owner, let bar = superview as? UINavigationBar,
                      let regions = owner.regions(in: bar) else { return false }
                // UIKit can move a toolbar host without laying out this marker.
                return regions[regionIndex].contains(convert(point, to: bar))
            }
        }
    }
}

private struct RichSourceView: View {
    let source: String
    var body: some View {
        GeometryReader { viewport in
            ScrollView([.horizontal, .vertical]) {
                Text(source)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding()
            }
            .frame(width: viewport.size.width, height: viewport.size.height)
            .clipped()
            .accessibilityLabel("Preview source")
        }
    }
}

private struct RichPreviewSurface: View {
    let block: ReplyContent.Block
    let expanded: Bool
    let active: Bool
    var initialHeight: CGFloat? = nil
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var renderer = RichContentRenderer()
    @State private var isVisible = false
    @Environment(\.nativeTranscriptRow) private var nativeRow
    @State private var nativeSurface = NativeTranscriptBlockPresence()
    @Environment(\.richReplyContext) private var context

    private struct Request: Equatable {
        let block: ExactReplyBlock
        let authority: RichReplyContext.RequestIdentity
        let dark: Bool
        let reduceMotion: Bool
        let active: Bool
        let width: CGFloat
        let viewportHeight: CGFloat?
    }

    var body: some View {
        RichPreviewLayout(block: block, context: context, dark: colorScheme == .dark,
                          reduceMotion: reduceMotion, expanded: expanded,
                          fallbackHeight: renderer.state == .idle ? (initialHeight ?? renderer.height) : renderer.height) {
            GeometryReader { geometry in surface(size: geometry.size) }
        }
        .background {
            if let nativeRow, !expanded {
                NativeTranscriptMarker(scope: nativeRow, presence: nativeSurface, block: block.id, role: .document)
            }
        }
        .onDisappear { renderer.deactivate() }
    }

    private func surface(size: CGSize) -> some View {
        let contentHeight = max(1, size.height - (block.previewFormat == .html ? 0 : DiagramImageView.controlsHeight))
        let viewportHeight = expanded ? contentHeight : nil
        let layout = DiagramLayout(dark: colorScheme == .dark, reduceMotion: reduceMotion,
                                   width: size.width, viewportHeight: viewportHeight)
        let current = nativeRow?.isCurrent ?? true
        let image = current ? (layout.flatMap { context.lookup(block, layout: $0) }
            ?? renderer.diagramPresentation(for: block, dark: colorScheme == .dark,
                                            reduceMotion: reduceMotion, width: size.width,
                                            viewportHeight: viewportHeight)) : nil
        let request = Request(block: ExactReplyBlock(block), authority: context.requestIdentity,
                              dark: colorScheme == .dark, reduceMotion: reduceMotion,
                              active: active && current && scenePhase == .active && (expanded || (nativeRow != nil ? nativeSurface.isVisible : isVisible)),
                              width: size.width, viewportHeight: viewportHeight)
        return ZStack(alignment: .top) {
            if let image {
                DiagramImageView(presentation: image, block: block)
                    .id(ObjectIdentifier(image))
            } else if let webView = renderer.webView, current {
                RichWebView(webView: webView)
                    .frame(height: contentHeight)
                    .id(ObjectIdentifier(webView))
            }
            if image == nil {
                if !context.permits(block) { sourceFallback } else {
                switch renderer.state {
                case .idle, .loading:
                    pendingPreview
                case .ready:
                    if block.previewFormat != .html {
                        if renderer.presentation?.isAvailable == false { sourceFallback }
                        else { pendingPreview }
                    }
                case .deferred: sourceFallback
                case .failed(let message):
                    VStack(alignment: .leading, spacing: 12) {
                        Label(message, systemImage: "doc.text.magnifyingglass")
                            .font(.callout).foregroundStyle(.secondary)
                        Text(block.source).font(.system(.caption, design: .monospaced))
                            .lineLimit(6).textSelection(.enabled)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.secondary.opacity(0.2)))
        .transaction { if block.previewFormat != .html { $0.animation = nil } }
        // A tall eager message row can exist while this particular block is off
        // screen. Appearance of the row is not permission to run its documents.
        .onScrollVisibilityChange(threshold: 0.01) { isVisible = $0 }
        .task(id: request) {
            if request.active && request.width > 0 && (nativeRow?.isCurrent ?? true) {
                await renderer.load(block, context: context, dark: request.dark, reduceMotion: request.reduceMotion,
                                    diagramWidth: block.previewFormat == .html ? nil : request.width,
                                    diagramViewportHeight: request.viewportHeight, initialHeight: initialHeight)
            } else { renderer.deactivate() }
        }

    }

    private var sourceFallback: some View {
        Text(block.source).font(.system(.caption, design: .monospaced))
            .lineLimit(6).textSelection(.enabled).padding()
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pendingPreview: some View {
        // Inline rendering is background work. Keep source usable and WebKit
        // mounted underneath; only an explicit expansion needs loading feedback.
        VStack(alignment: .leading, spacing: 8) {
            if expanded {
                ProgressView { Text("Loading preview").font(.caption) }
            }
            Text(block.source).font(.system(.caption, design: .monospaced))
                .lineLimit(6).textSelection(.enabled)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
    }
}

#if os(iOS)
private struct RichWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#elseif os(macOS)
private struct RichWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#endif

private extension ReplyContent.Format {
    var displayName: String {
        switch self { case .html: "HTML"; case .svg: "SVG"; case .mermaid: "Mermaid" }
    }
    var previewTitle: String { self == .mermaid ? "Mermaid diagram" : "\(displayName) preview" }
}


/// Layout receives the real proposed width before the surface is composed. A
/// recreated row can restore both pixels and measured height on its first frame.
private struct RichPreviewLayout: Layout {
    let block: ReplyContent.Block
    let context: RichReplyContext
    let dark: Bool
    let reduceMotion: Bool
    let expanded: Bool
    let fallbackHeight: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        let height: CGFloat = MainActor.assumeIsolated {
            if expanded { return max(300, proposal.height ?? 480) }
            let controlsHeight = block.previewFormat == .html ? 0 : DiagramImageView.controlsHeight
            guard let layout = DiagramLayout(dark: dark, reduceMotion: reduceMotion, width: width, viewportHeight: nil) else { return fallbackHeight + controlsHeight }
            return (context.lookup(block, layout: layout)?.height ?? fallbackHeight) + controlsHeight
        }
        return CGSize(width: width, height: height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for view in subviews { view.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size)) }
    }
}
