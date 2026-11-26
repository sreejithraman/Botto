#if DEBUG
import SwiftUI
import UIKit

/// Test-only markers for transcript rows, blocks and the end of the list. Product flows leave `current` nil.
@MainActor final class TranscriptMeasurements: NSObject {
    static weak var current: TranscriptMeasurements?
    enum Point: Hashable { case row(Data), block(Data, Int), terminal }
    private let points = NSHashTable<TranscriptMeasurementView>.weakObjects()
    private var link: CADisplayLink?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var frame = 0
    func start() {
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        self.link = link; link.add(to: .main, forMode: .common)
    }
    func stop() { link?.invalidate(); link = nil; resumeWaiters() }
    @objc private func tick(_ link: CADisplayLink) {
        frame += 1
        resumeWaiters()
    }
    private func resumeWaiters() { let pending = waiters; waiters = []; pending.forEach { $0.resume() } }
    func nextFrame() async { await withCheckedContinuation { waiters.append($0) } }
    func register(_ point: TranscriptMeasurementView) { points.add(point) }
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
