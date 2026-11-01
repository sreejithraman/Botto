import SwiftUI
import UIKit
import WebKit
import Observation
import BottoCore

/// Freezes a small cover through the same isolated renderer as the file reader.
@MainActor @Observable final class LibraryPreviewThumbnailRenderer: NSObject {
    private(set) var mountRevision = UUID()
    @ObservationIgnored private weak var host: LibraryPreviewThumbnailContainer?
    @ObservationIgnored private var active: Capture?
    @ObservationIgnored private let timeout: Duration
    private var hostActive = true
    private var backgrounded = false
    private var previouslyMounted = false
    private static let size = CGSize(width: 400, height: 284)

    @MainActor private final class Capture {
        let renderer = RichContentRenderer()
        var load: Task<Void, Never>?
        var snapshotRequested = false
        var snapshotFinished = false
        var image: UIImage?
    }

    init(timeout: Duration = .seconds(22)) {
        self.timeout = min(.seconds(22), max(.zero, timeout))
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(enteredBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(becameActive),
            name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    var isMounted: Bool {
        hostActive && !backgrounded && host?.window?.windowScene?.activationState == .foregroundActive
    }

    func cancel() {
        guard let capture = active else { return }
        active = nil
        capture.load?.cancel()
        capture.renderer.stop()
    }

    func render(_ block: ReplyContent.Block) async -> UIImage? {
        guard block.previewFormat == .html, block.isComplete,
              !block.source.isEmpty, block.source.utf8.count <= ReplyContent.previewByteLimit(for: .html),
              !Task.isCancelled, isMounted, let host else { return nil }
        cancel()
        let capture = Capture()
        active = capture
        defer {
            capture.load?.cancel()
            capture.renderer.stop()
            if active === capture { active = nil }
        }
        let deadline = ContinuousClock.now + timeout
        let document = capture.renderer
        capture.load = Task { await document.load(block, dark: false, reduceMotion: true, initialHeight: 284) }
        while ContinuousClock.now < deadline {
            guard !Task.isCancelled, active === capture, self.host === host, isMounted else { return nil }
            if let web = capture.renderer.webView {
                if web.superview !== host {
                    web.frame = CGRect(origin: .zero, size: Self.size)
                    web.overrideUserInterfaceStyle = .light
                    host.addSubview(web)
                    web.layoutIfNeeded()
                }
                if capture.renderer.state == .ready, !capture.snapshotRequested {
                    capture.snapshotRequested = true
                    let configuration = WKSnapshotConfiguration()
                    configuration.rect = web.bounds
                    configuration.afterScreenUpdates = true
                    configuration.snapshotWidth = NSNumber(value: Double(Self.size.width / max(1, web.traitCollection.displayScale)))
                    web.takeSnapshot(with: configuration) { [weak capture] image, error in
                        guard let capture else { return }
                        capture.snapshotFinished = true
                        guard error == nil, let pixels = image?.cgImage,
                              pixels.width <= 400, pixels.height <= 400 else { return }
                        capture.image = UIImage(cgImage: pixels)
                    }
                }
            }
            if capture.snapshotFinished { return capture.image }
            switch capture.renderer.state {
            case .failed, .deferred: return nil
            default: break
            }
            do { try await Task.sleep(for: .milliseconds(25)) }
            catch { return nil }
        }
        return nil
    }

    fileprivate func mount(_ view: LibraryPreviewThumbnailContainer, isActive: Bool) {
        if host !== view { cancel(); host = view }
        hostActive = isActive
        updateMount()
    }

    fileprivate func unmount(_ view: LibraryPreviewThumbnailContainer) {
        guard host === view else { return }
        cancel(); host = nil
        updateMount()
    }

    fileprivate func attachmentChanged(_ view: LibraryPreviewThumbnailContainer) {
        guard host === view else { return }
        updateMount()
    }

    private func updateMount() {
        let mounted = isMounted
        if !mounted { cancel() }
        if previouslyMounted != mounted {
            previouslyMounted = mounted
            mountRevision = UUID()
        }
    }

    @objc private func enteredBackground() { backgrounded = true; updateMount() }
    @objc private func becameActive() { backgrounded = false; updateMount() }
}

struct LibraryPreviewThumbnailHost: UIViewRepresentable {
    let renderer: LibraryPreviewThumbnailRenderer
    var isActive = true

    func makeUIView(context: Context) -> LibraryPreviewThumbnailContainer {
        let view = LibraryPreviewThumbnailContainer()
        view.bind(renderer, isActive: isActive)
        return view
    }

    func updateUIView(_ view: LibraryPreviewThumbnailContainer, context: Context) {
        view.bind(renderer, isActive: isActive)
    }

    static func dismantleUIView(_ view: LibraryPreviewThumbnailContainer, coordinator: ()) { view.unbind() }
}

final class LibraryPreviewThumbnailContainer: UIView {
    private weak var renderer: LibraryPreviewThumbnailRenderer?

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        clipsToBounds = true
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func bind(_ renderer: LibraryPreviewThumbnailRenderer, isActive: Bool) {
        if self.renderer !== renderer { unbind(); self.renderer = renderer }
        renderer.mount(self, isActive: isActive)
    }
    func unbind() { renderer?.unmount(self); renderer = nil }
    override func didMoveToWindow() { super.didMoveToWindow(); renderer?.attachmentChanged(self) }
}
