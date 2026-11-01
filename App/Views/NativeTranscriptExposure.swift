import SwiftUI
import UIKit
import BottoCore

enum NativeTranscriptMarkerRole: Hashable { case content, document, search(UUID) }

/// A block's native clipped exposure is an additional prerequisite, never a grant.
@MainActor @Observable final class NativeTranscriptBlockPresence {
    fileprivate(set) var isVisible = false
}

@MainActor @Observable final class NativeTranscriptRowExposure {
    @ObservationIgnored weak var viewport: UIScrollView?
    @ObservationIgnored weak var rowGeometry: UIView?
    @ObservationIgnored private var markers: [UUID: WeakMarker] = [:]
    private var valid = true
    @ObservationIgnored var authority: NativeTranscriptRowAuthority?
    @ObservationIgnored var requestState: RequestCardLifetime?
    @ObservationIgnored var actionAdmission: @MainActor () -> Bool = { true }
    @ObservationIgnored var admitsContent = true
    @ObservationIgnored var presentRequestConfirmation: (@MainActor (RequestCardConfirmation, @escaping @MainActor (UUID, Bool) -> Void) -> Void)?
    private var displayed = false
    private var active = false
    @ObservationIgnored var presentRichReply: (@MainActor (ReplyContent.Block, RichReplyContext, RichReplyPresentationMode, @escaping @MainActor (UUID, Bool) -> Void) -> Void)?
    func present(block: ReplyContent.Block, context: RichReplyContext, mode: RichReplyPresentationMode,
                 report: @escaping @MainActor (UUID, Bool) -> Void) {
        guard canPresent, context.permits(block) else { return }
        presentRichReply?(block, context, mode, report)
    }
    @ObservationIgnored var presentWorkDetails: (@MainActor (WorkDetailsDocument, @escaping @MainActor (UUID, Bool) -> Void) -> Void)?
    func present(details: WorkDetailsDocument, report: @escaping @MainActor (UUID, Bool) -> Void) {
        guard canPresent else { return }
        presentWorkDetails?(details, report)
    }
    private struct WeakMarker { weak var view: NativeTranscriptBlockMarker? }

    init(viewport: UIScrollView) { self.viewport = viewport }
    var isCurrent: Bool { valid && (authority?.isCurrent ?? true) }
    var canPresent: Bool {
        access(keyPath: \.canPresent)
        return isCurrent && displayed && active && actionAdmission()
    }
    var requestActions: RequestCardActions? {
        requestState?.actions { [weak self] in
            guard let self else { return false }
            return self.canPresent
        }
    }
    func register(_ marker: NativeTranscriptBlockMarker) {
        markers[marker.identity] = WeakMarker(view: marker)
        refresh()
        marker.reportSearchGeometryIfChanged()
    }
    func setDisplayed(_ value: Bool) { displayed = value; refresh() }
    func setActive(_ value: Bool) {
        // An unchanged apply can replace admission while active stays equal.
        withMutation(keyPath: \.canPresent) { active = value }
        refresh()
    }
    func invalidate() { valid = false; actionAdmission = { false }; admitsContent = false; presentRichReply = nil; presentWorkDetails = nil; presentRequestConfirmation = nil; refresh(); markers.removeAll() }
    func refresh() {
        markers = markers.filter { $0.value.view != nil }
        for entry in markers.values {
            guard let marker = entry.view else { continue }
            // Fitting must not repeatedly retire and recreate an already-visible
            // document. Only new admissions require the completed allocation.
            let allocated = marker.presence?.isVisible == true || hasAllocatedContentGeometry(marker)
            marker.presence?.isVisible = permits(marker) && admitsContent && allocated
        }
    }
    private func hasAllocatedContentGeometry(_ marker: UIView) -> Bool {
        var ancestor: UIView? = marker
        while let view = ancestor {
            if let cell = view as? NativeTranscriptCell {
                guard let rowGeometry, rowGeometry.window === cell.window,
                      rowGeometry.isDescendant(of: cell.contentView) else { return false }
                // A hosted row can be temporarily centered inside its old allocation
                // during fitting. Those pixels must not start new file work.
                let preferred = rowGeometry.convert(rowGeometry.bounds, to: cell.contentView)
                let allocated = cell.contentView.bounds
                return abs(preferred.minX - allocated.minX) < 1 &&
                    abs(preferred.minY - allocated.minY) < 1 &&
                    abs(preferred.width - allocated.width) < 1 &&
                    abs(preferred.height - allocated.height) < 1
            }
            ancestor = view.superview
        }
        return true
    }
    private func permits(_ marker: UIView) -> Bool {
        guard isCurrent, displayed, active, let viewport, let window = viewport.window,
              marker.window === window, !viewport.isHidden, viewport.alpha > 0,
              marker.bounds.width > 0, marker.bounds.height > 0 else { return false }
        var clipped = marker.convert(marker.bounds, to: window)
        var ancestor: UIView? = marker
        while let view = ancestor {
            guard !view.isHidden, view.alpha > 0 else { return false }
            if view.clipsToBounds { clipped = clipped.intersection(view.convert(view.bounds, to: window)) }
            ancestor = view.superview
        }
        clipped = clipped.intersection(viewport.convert(viewport.bounds, to: window)).intersection(window.bounds)
        return !clipped.isNull && clipped.width > 0 && clipped.height > 0
    }
    @ObservationIgnored var searchGeometryChanged: @MainActor () -> Void = {}
    func firstSearchMarker(id: UUID) -> (block: Int, marker: UIView)? {
        guard isCurrent, let viewport else { return nil }
        return markers.values.compactMap(\.view).filter {
            $0.role == .search(id) && $0.window != nil && $0.window === viewport.window &&
                $0.bounds.width > 0 && $0.bounds.height > 0
        }.sorted {
            let a = $0.convert($0.bounds, to: viewport), b = $1.convert($1.bounds, to: viewport)
            return a.minY == b.minY ? a.minX < b.minX : a.minY < b.minY
        }.first.map { ($0.block, $0 as UIView) }
    }
    func blockOffsetInPreferredRow(_ marker: UIView) -> CGFloat? {
        guard isCurrent, let rowGeometry, rowGeometry.window != nil, rowGeometry.window === marker.window else { return nil }
        return marker.convert(marker.bounds, to: rowGeometry).minY
    }
    func marker(for block: Int, role: NativeTranscriptMarkerRole) -> UIView? {
        guard isCurrent, let viewport else { return nil }
        return markers.values.compactMap(\.view).first {
            $0.block == block && $0.role == role && $0.window != nil && $0.window === viewport.window
        }
    }
    /// A real visible block landmark, including blocks inside a viewport-tall row.
    func landmark() -> (block: Int, role: NativeTranscriptMarkerRole, marker: UIView, y: CGFloat)? {
        guard let viewport else { return nil }
        return markers.values.compactMap { entry in
            guard let marker = entry.view, permits(marker) else { return nil }
            if case .search = marker.role { return nil }
            return (marker.block, marker.role, marker as UIView, marker.convert(marker.bounds, to: viewport).minY - viewport.bounds.minY)
        }.sorted { abs($0.3) < abs($1.3) }.first
    }
}

@MainActor final class NativeTranscriptBlockMarker: UIView {
    let identity = UUID()
    weak var scope: NativeTranscriptRowExposure?
    weak var presence: NativeTranscriptBlockPresence?
    var block = 0
    var role = NativeTranscriptMarkerRole.content
    private struct SearchGeometry: Equatable {
        let rect: CGRect
        let window: ObjectIdentifier?
        let scope: ObjectIdentifier?
        let role: NativeTranscriptMarkerRole
    }
    private var searchGeometry: SearchGeometry?
    fileprivate func reportSearchGeometryIfChanged() {
        guard case .search = role else { return }
        let geometry = SearchGeometry(rect: convert(bounds, to: scope?.rowGeometry ?? superview),
            window: window.map(ObjectIdentifier.init), scope: scope.map(ObjectIdentifier.init), role: role)
        guard geometry != searchGeometry else { return }
        searchGeometry = geometry
        scope?.searchGeometryChanged()
    }
    func connect(scope: NativeTranscriptRowExposure, presence: NativeTranscriptBlockPresence, block: Int, role: NativeTranscriptMarkerRole = .content) {
        if self.scope !== scope || self.presence !== presence { self.presence?.isVisible = false }
        self.scope = scope; self.presence = presence; self.block = block; self.role = role
        scope.register(self)
    }
    override func layoutSubviews() { super.layoutSubviews(); scope?.refresh(); reportSearchGeometryIfChanged() }
    override func didMoveToWindow() { super.didMoveToWindow(); scope?.refresh(); reportSearchGeometryIfChanged() }
}
/// Coordinates owned by the SwiftUI row itself. During fitting, UIKit may
/// center a larger hosted root in the old cell allocation; block-local offsets
/// already express its preferred placement without inspecting private children.
struct NativeTranscriptRowGeometry: UIViewRepresentable {
    let scope: NativeTranscriptRowExposure
    func makeUIView(context: Context) -> UIView {
        let view = UIView(); view.isUserInteractionEnabled = false; scope.rowGeometry = view; return view
    }
    func updateUIView(_ view: UIView, context: Context) { scope.rowGeometry = view }
}
struct NativeTranscriptMarker: UIViewRepresentable {
    let scope: NativeTranscriptRowExposure
    let presence: NativeTranscriptBlockPresence
    let block: Int
    var role = NativeTranscriptMarkerRole.content
    func makeUIView(context: Context) -> NativeTranscriptBlockMarker {
        let view = NativeTranscriptBlockMarker(); view.isUserInteractionEnabled = false
        view.connect(scope: scope, presence: presence, block: block, role: role); return view
    }
    func updateUIView(_ view: NativeTranscriptBlockMarker, context: Context) {
        view.connect(scope: scope, presence: presence, block: block, role: role)
    }
    static func dismantleUIView(_ view: NativeTranscriptBlockMarker, coordinator: ()) {
        view.presence?.isVisible = false; view.scope = nil
    }
}

struct NativeTranscriptBlock<Content: View>: View {
    let block: Int
    @ViewBuilder var content: () -> Content
    @Environment(\.nativeTranscriptRow) private var row
    @State private var presence = NativeTranscriptBlockPresence()
    #if DEBUG
    @Environment(\.transcriptMeasurementMessage) private var measuredMessage
    #endif
    var body: some View {
        Group {
        if let row {
            content().environment(\.nativeTranscriptBlock, presence).environment(\.nativeTranscriptBlockID, block)
                .background(NativeTranscriptMarker(scope: row, presence: presence, block: block))
        } else { content() }
        }
        #if DEBUG
        .background {
            if TranscriptMeasurements.current != nil, let measuredMessage {
                TranscriptMeasurementPoint(point: .block(measuredMessage, block))
            }
        }
        #endif
    }
}
private struct NativeTranscriptRowKey: EnvironmentKey {
    static let defaultValue: NativeTranscriptRowExposure? = nil
}
private struct NativeTranscriptBlockKey: EnvironmentKey {
    static let defaultValue: NativeTranscriptBlockPresence? = nil
}
extension EnvironmentValues {
    var nativeTranscriptRow: NativeTranscriptRowExposure? {
        get { self[NativeTranscriptRowKey.self] }
        set { self[NativeTranscriptRowKey.self] = newValue }
    }
    var nativeTranscriptBlock: NativeTranscriptBlockPresence? {
        get { self[NativeTranscriptBlockKey.self] }
        set { self[NativeTranscriptBlockKey.self] = newValue }
    }
}
