#if DEBUG
import SwiftUI
import UIKit
import WebKit

/// The native runner cannot share files with the app sandbox.
@MainActor enum PerformanceStreamGate {
    static var mode: String? { ProcessInfo.processInfo.environment["BOTTO_NATIVE_PERFORMANCE_MODE"] }
    private(set) static var pending: UUID?

    static func waitForGesture() async throws {
        let ticket = UUID()
        pending = ticket
        defer { if pending == ticket { pending = nil } }
        for _ in 0..<1_000 {
            try Task.checkCancellation()
            if pending != ticket { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw GateTimeout()
    }

    static func release(_ ticket: UUID) {
        if pending == ticket { pending = nil }
    }

    private struct GateTimeout: Error {}
}

/// Opt-in frame delivery and anonymous event timing for native interaction tests.
@MainActor final class InteractionFrameTrace: NSObject {
    private let output: URL
    private let publishesAccessibility: Bool
    private static weak var accessibilitySink: UIScrollView?
    private static weak var activeScrollTrace: InteractionFrameTrace?
    private static var streamPublications = 0
    private static var streamIsPublishing = false
    private static var streamPausedAt: CFTimeInterval = 0
    private static let enabled = ["BOTTO_SCROLL_TRACE_OUTPUT", "BOTTO_TYPING_TRACE_OUTPUT"].contains {
        ProcessInfo.processInfo.environment[$0] != nil
    }
    static func setStreamPublishing(_ active: Bool) {
        guard enabled else { return }
        streamIsPublishing = active
        if !active { streamPausedAt = CACurrentMediaTime() }
    }
    static func recordStreamPublication() {
        if enabled { streamPublications += 1 }
    }
    private static let usesAccessibility = ["BOTTO_SCROLL_TRACE_OUTPUT", "BOTTO_TYPING_TRACE_OUTPUT"].contains {
        ProcessInfo.processInfo.environment[$0] == "accessibility"
    }

    static func bindAccessibilitySink(_ viewport: UIScrollView) {
        if usesAccessibility { accessibilitySink = viewport }
    }
    static func unbindAccessibilitySink(_ viewport: UIScrollView) {
        if accessibilitySink === viewport { accessibilitySink = nil }
    }
    private weak var viewport: UIScrollView?
    private var link: CADisplayLink?
    private var previousTimestamp: CFTimeInterval?
    private var previousCallback: CFTimeInterval?
    private var samples: [[String: Double]] = []
    private var events: [[String: Any]] = []
    private var began: CFTimeInterval = 0
    private var startOffset: CGFloat = 0
    private var editsSinceCallback = 0
    private var previousStreamPublications = 0
    private var geometry: [String: Double] = [:]
    var working = false

    static func make(viewport: UIScrollView, outputVariable: String = "BOTTO_SCROLL_TRACE_OUTPUT") -> InteractionFrameTrace? {
        guard let path = ProcessInfo.processInfo.environment[outputVariable] else { return nil }
        let accessibility = path == "accessibility"
        let output = accessibility
            ? FileManager.default.temporaryDirectory.appendingPathComponent("\(outputVariable)-\(UUID().uuidString).json")
            : URL(fileURLWithPath: path)
        return InteractionFrameTrace(output: output, viewport: viewport, publishesAccessibility: accessibility)
    }
    private init(output: URL, viewport: UIScrollView, publishesAccessibility: Bool) {
        self.output = output; self.viewport = viewport
        self.publishesAccessibility = publishesAccessibility
    }
    func begin() {
        finish()
        began = CACurrentMediaTime()
        previousTimestamp = nil; previousCallback = began; samples = []; events = []
        geometry = [:]
        if NativeTranscriptGeometryCollectionView.isEnabled, viewport?.accessibilityIdentifier == "chat-transcript" {
            Self.activeScrollTrace = self
            (viewport as? NativeTranscriptGeometryCollectionView)?.resetDragFrame()
        }
        startOffset = viewport?.contentOffset.y ?? 0
        editsSinceCallback = 0
        previousStreamPublications = Self.streamPublications
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        self.link = link
        link.add(to: .main, forMode: .common)
    }
    @objc private func tick(_ link: CADisplayLink) {
        let callback = CACurrentMediaTime()
        if let previousCallback {
            samples.append(["interval_ms": previousTimestamp.map { (link.timestamp - $0) * 1000 } ?? (callback - previousCallback) * 1000,
                "callback_interval_ms": (callback - previousCallback) * 1000,
                "budget_ms": (link.targetTimestamp - link.timestamp) * 1000,
                "at_ms": (callback - began) * 1000,
                "edits": Double(editsSinceCallback),
                "stream_publications": Double(Self.streamPublications - previousStreamPublications),
                "streaming": Self.streamIsPublishing || Self.streamPausedAt > previousCallback ? 1 : 0,
                "offset_y": viewport?.contentOffset.y ?? 0, "working": working ? 1 : 0])
        }
        editsSinceCallback = 0
        previousStreamPublications = Self.streamPublications
        previousTimestamp = link.timestamp; previousCallback = callback
        if NativeTranscriptGeometryCollectionView.isEnabled {
            (viewport as? NativeTranscriptGeometryCollectionView)?.captureDragFrame()
        }
    }
    func mark(_ name: String) {
        guard link != nil else { return }
        if name == "edit" { editsSinceCallback += 1 }
        events.append(["name": name, "at_ms": (CACurrentMediaTime() - began) * 1000])
    }
    static func recordsGeometry(for viewport: UIScrollView) -> Bool {
        activeScrollTrace?.viewport === viewport && activeScrollTrace?.link != nil
    }
    static func recordDragFrame(for viewport: UIScrollView, counters: [String: Double],
                                slip: CGFloat? = nil, touchDelta: CGFloat = 0) {
        guard let trace = activeScrollTrace, trace.viewport === viewport, trace.link != nil else { return }
        for (key, count) in counters { trace.geometry[key, default: 0] += count }
        trace.geometry["frame_geometry_forces_layout"] = 1
        trace.geometry["frame_geometry_model_only"] = 1
        trace.geometry["frame_input_single_touch_location"] = 1
        if let slip {
            trace.geometry["max_drag_slip_points"] = max(trace.geometry["max_drag_slip_points", default: 0], Double(slip))
            if slip > 0.5 {
                trace.events.append(["name": "drag_slip", "at_ms": (CACurrentMediaTime() - trace.began) * 1000,
                    "phase": "drag", "slip_points": slip, "touch_delta_points": touchDelta,
                    "qualifying_rows": counters["frame_qualifying_rows", default: 0]])
            }
        }
    }
    func finish() {
        guard let link else { return }
        link.invalidate(); self.link = nil
        if Self.activeScrollTrace === self {
            (viewport as? NativeTranscriptGeometryCollectionView)?.resetDragFrame()
            Self.activeScrollTrace = nil
        }
        guard !samples.isEmpty else { return }
        var gestures = (try? Data(contentsOf: output)).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]]
        } ?? []
        var gesture: [String: Any] = ["start_offset_y": startOffset, "end_offset_y": viewport?.contentOffset.y ?? 0,
                                      "frames": samples, "events": events]
        if NativeTranscriptGeometryCollectionView.isEnabled { gesture["geometry"] = geometry }
        gestures.append(gesture)
        do {
            let data = try JSONSerialization.data(withJSONObject: gestures, options: [.sortedKeys])
            try data.write(to: output, options: .atomic)
            if publishesAccessibility {
                Self.accessibilitySink?.accessibilityValue = String(data: data, encoding: .utf8)
            }
        } catch { print("BOTTO_SCROLL_TRACE_WRITE_FAILED \(error.localizedDescription)") }
        samples = []
    }
}

/// Opt-in settled model geometry relative to single-touch movement.
@MainActor final class NativeTranscriptGeometryCollectionView: NativeTranscriptCollectionView {
    static let isEnabled = ProcessInfo.processInfo.environment["BOTTO_SCROLL_GEOMETRY_TRACE"] == "1"
    private let itemIdentifier: @MainActor (IndexPath) -> NativeTranscriptItemID?
    private let modelRevision: @MainActor () -> UInt64?
    private var previousDragFrame: DragFrame?

    init(frame: CGRect, collectionViewLayout layout: UICollectionViewLayout,
         itemIdentifier: @escaping @MainActor (IndexPath) -> NativeTranscriptItemID?,
         modelRevision: @escaping @MainActor () -> UInt64?) {
        self.itemIdentifier = itemIdentifier; self.modelRevision = modelRevision
        super.init(frame: frame, collectionViewLayout: layout)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private struct Row {
        let cell: NativeTranscriptCell
        let scope: NativeTranscriptRowExposure
        let root: UIView
        let id: NativeTranscriptItemID
        let rect: CGRect
        let cellSize: CGSize
    }
    private struct Input {
        let window: UIWindow
        let viewport: CGRect
        let size: CGSize
        let inset: UIEdgeInsets
        let touchLocation: CGPoint
        let touchCount: Int
        let panState: UIGestureRecognizer.State
        let dragging: Bool
        let decelerating: Bool
        let tracking: Bool
        let revision: UInt64
        let atEdge: Bool
        let updating: Bool
    }
    private struct DragFrame {
        let input: Input
        let rows: [Row]
    }

    func resetDragFrame() { previousDragFrame = nil }

    /// Settled model geometry versus one touch's window location; forcing layout makes timings diagnostic.
    /// This does not sample rendered pixels or synchronize the presentation tree with touch timestamps.
    func captureDragFrame() {
        guard InteractionFrameTrace.recordsGeometry(for: self) else {
            resetDragFrame(); return
        }
        layoutIfNeeded()
        var counters: [String: Double] = ["frame_samples": 1]
        func reject(_ reason: String) {
            counters["frame_rejected_\(reason)", default: 0] += 1
            InteractionFrameTrace.recordDragFrame(for: self, counters: counters)
        }
        guard let current = input() else { resetDragFrame(); reject("input"); return }
        counters[current.dragging ? "frame_dragging_samples" : "frame_not_dragging_samples"] = 1
        counters[current.decelerating ? "frame_decelerating_samples" : "frame_not_decelerating_samples"] = 1
        counters[current.tracking ? "frame_tracking_samples" : "frame_tracking_false_samples"] = 1
        let touchCategory = current.touchCount == 0 ? "zero" : current.touchCount == 1 ? "one" : "multiple"
        counters["frame_touch_\(touchCategory)_samples"] = 1
        counters["frame_pan_state_\(current.panState.rawValue)_samples"] = 1
        guard current.dragging, !current.decelerating, current.touchCount == 1,
              current.panState == .changed, !current.atEdge, !current.updating,
              abs(zoomScale - 1) < 0.001, !isZooming, !isZoomBouncing else {
            resetDragFrame(); reject("state"); return
        }
        let rows: [Row] = visibleCells.sorted { $0.frame.minY < $1.frame.minY }.prefix(8).compactMap { cell in
            guard let cell = cell as? NativeTranscriptCell, cell.isDisplayed,
                  let index = indexPath(for: cell), let id = itemIdentifier(index), case .message = id,
                  let scope = cell.exposure, scope.isCurrent, let root = scope.rowGeometry,
                  root.window === current.window else { return nil }
            let rect = root.convert(root.bounds, to: current.window)
            guard rect.intersects(current.viewport) else { return nil }
            return Row(cell: cell, scope: scope, root: root, id: id, rect: rect, cellSize: cell.bounds.size)
        }
        let previous = previousDragFrame
        previousDragFrame = DragFrame(input: current, rows: rows)
        guard let previous else { reject("first"); return }
        let prior = previous.input
        guard prior.window === current.window, prior.viewport == current.viewport,
              prior.size == current.size, prior.inset == current.inset else { reject("viewport"); return }
        guard prior.revision == current.revision else { reject("model"); return }
        let touchDelta = current.touchLocation.y - prior.touchLocation.y
        var slip: CGFloat = 0
        for row in rows {
            guard let old = previous.rows.first(where: { $0.cell === row.cell && $0.scope === row.scope &&
                $0.root === row.root && $0.id == row.id }), old.scope.isCurrent,
                  row.cellSize == old.cellSize, row.rect.size == old.rect.size else { continue }
            counters["frame_qualifying_rows", default: 0] += 1
            slip = max(slip, abs((row.rect.minY - old.rect.minY) - touchDelta))
        }
        if counters["frame_qualifying_rows", default: 0] > 0 {
            counters["frame_qualifying_pairs"] = 1
            InteractionFrameTrace.recordDragFrame(for: self, counters: counters, slip: slip, touchDelta: touchDelta)
        } else {
            reject("rows")
        }
    }

    private func input() -> Input? {
        guard let window, let revision = modelRevision() else { return nil }
        let lower = -adjustedContentInset.top
        let upper = max(lower, contentSize.height - bounds.height + adjustedContentInset.bottom)
        return Input(window: window, viewport: convert(bounds, to: window), size: bounds.size,
                     inset: adjustedContentInset,
                     touchLocation: panGestureRecognizer.location(in: window),
                     touchCount: panGestureRecognizer.numberOfTouches, panState: panGestureRecognizer.state,
                     dragging: isDragging, decelerating: isDecelerating, tracking: isTracking,
                     revision: revision,
                     atEdge: contentOffset.y <= lower + 1 || contentOffset.y >= upper - 1,
                     updating: hasUncommittedUpdates)
    }

}

/// Opt-in test measurement only. Normal/demo product flows leave this nil.
/// Weak registries include allocated/prefetched content, not only visible views.
@MainActor final class TranscriptMeasurements: NSObject {
    static weak var current: TranscriptMeasurements?
    enum Point: Hashable { case row(Data), block(Data, Int), terminal }
    private let points = NSHashTable<TranscriptMeasurementView>.weakObjects()
    private let cells = NSHashTable<NativeTranscriptCell>.weakObjects()
    private let documents = NSHashTable<WKWebView>.weakObjects()
    private let renderers = NSHashTable<RichContentRenderer>.weakObjects()
    private var link: CADisplayLink?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var previousTimestamp: CFTimeInterval?
    private(set) var frame = 0
    private(set) var frameIntervals: [Double] = []
    private(set) var frameSampleTimes: [Double] = []
    private(set) var frameBudgets: [Double] = []
    private(set) var pointAllocations = 0, rowAllocations = 0, cellAllocations = 0, documentAllocations = 0, rendererAllocations = 0
    var followsLatest = true
    func start() {
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        self.link = link; link.add(to: .main, forMode: .common)
    }
    func stop() { link?.invalidate(); link = nil; resumeWaiters() }
    @objc private func tick(_ link: CADisplayLink) {
        frame += 1
        if let previousTimestamp {
            frameIntervals.append(link.timestamp - previousTimestamp)
            frameSampleTimes.append(link.timestamp)
        }
        previousTimestamp = link.timestamp
        frameBudgets.append(link.targetTimestamp - link.timestamp)
        resumeWaiters()
    }
    private func resumeWaiters() { let pending = waiters; waiters = []; pending.forEach { $0.resume() } }
    func nextFrame() async { await withCheckedContinuation { waiters.append($0) } }
    func register(_ point: TranscriptMeasurementView) {
        points.add(point); pointAllocations += 1
        if case .row = point.point { rowAllocations += 1 }
    }
    func register(_ cell: NativeTranscriptCell) { cells.add(cell); cellAllocations += 1 }
    func register(_ document: WKWebView) { documents.add(document); documentAllocations += 1 }
    func register(_ renderer: RichContentRenderer) { renderers.add(renderer); rendererAllocations += 1 }
    func point(_ id: Point) -> TranscriptMeasurementView? {
        points.allObjects.last { $0.point == id && $0.window != nil }
    }
    func visible(_ id: Point, revision: Data? = nil) -> Bool {
        guard let point = point(id), revision == nil || point.revision == revision,
              point.revisionFrame < frame, let viewport = point.viewport, point.bounds.height > 0 else { return false }
        return point.convert(point.bounds, to: viewport).intersects(viewport.bounds)
    }
    func terminalVisible() -> Bool {
        guard let point = point(.terminal), let viewport = point.viewport, point.bounds.height > 0 else { return false }
        return viewport.bounds.insetBy(dx: -1, dy: -1).contains(point.convert(point.bounds, to: viewport))
    }
    func isReady(_ document: WKWebView) -> Bool {
        renderers.allObjects.contains { $0.webView === document && $0.state == .ready }
    }
    func counts() -> [String: Int] {
        let rows = points.allObjects.filter { if case .row = $0.point { true } else { false } }
        return ["live_row_surfaces": rows.count, "attached_row_surfaces": rows.filter { $0.window != nil }.count,
            "live_allocated_cells": cells.allObjects.count, "live_WKWebViews_including_unmounted": documents.allObjects.count,
            "attached_WKWebViews": documents.allObjects.filter { $0.window != nil }.count,
            "live_renderers_including_prefetched": renderers.allObjects.count, "row_surface_allocations": rowAllocations, "all_marker_allocations": pointAllocations,
            "cell_allocations": cellAllocations, "WKWebView_allocations": documentAllocations, "renderer_allocations": rendererAllocations]
    }
}
@MainActor final class TranscriptMeasurementView: UIView {
    var point = TranscriptMeasurements.Point.terminal
    var revision = Data()
    var revisionFrame = 0
    weak var measurement: TranscriptMeasurements?
    var viewport: UIScrollView? {
        var ancestor = superview
        while let view = ancestor {
            if let scroll = view as? UIScrollView { return scroll }
            ancestor = view.superview
        }
        return nil
    }
}
struct TranscriptMeasurementPoint: UIViewRepresentable {
    let point: TranscriptMeasurements.Point
    var revision = Data()
    func makeUIView(context: Context) -> TranscriptMeasurementView {
        let view = TranscriptMeasurementView(); view.isUserInteractionEnabled = false
        view.point = point; view.revision = revision
        view.measurement = TranscriptMeasurements.current
        view.revisionFrame = view.measurement?.frame ?? 0
        view.measurement?.register(view)
        return view
    }
    func updateUIView(_ view: TranscriptMeasurementView, context: Context) {
        if view.revision != revision { view.revision = revision; view.revisionFrame = view.measurement?.frame ?? 0 }
    }
}
private struct TranscriptMeasurementMessageKey: EnvironmentKey { static let defaultValue: Data? = nil }
extension EnvironmentValues {
    var transcriptMeasurementMessage: Data? {
        get { self[TranscriptMeasurementMessageKey.self] }
        set { self[TranscriptMeasurementMessageKey.self] = newValue }
    }
}
#endif
