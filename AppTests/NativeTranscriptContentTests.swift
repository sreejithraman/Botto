import Testing
import SwiftUI
import UIKit
import WebKit
import Vision
import BottoCore
@testable import Botto

@Suite(.serialized, RichReplyRuntime()) @MainActor struct NativeTranscriptContentTests {
    @Test func actualCanvasGenerationAndSendKeepEveryHostedRowInsideItsNativeAllocation() async throws {
        let service = DemoBotService()
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://native-canvas.invalid")!)
        let store = AppStore(service: service, persistence: .init(load: { nil }, save: { _ in }, remove: {}))
        try #require(await store.connect(configuration))
        let canvas = try #require(store.bots.first { $0.id == "canvas" })
        let milo = try #require(store.bots.first { $0.id == "milo" })
        await store.open(canvas)
        let profile = try ExactID(canvas.id)
        let initial = try #require(store.chats.screen(profile: profile))
        await store.chats.refreshDirectory(initial.owner); store.chats.displayed(initial.owner)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }
        let viewport = Viewport()
        let host = UIHostingController(rootView: CanvasHost(store: store, viewport: viewport))
        let window = UIWindow(windowScene: scene); window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey(); store.forgetConnection(); LocalHistory.remove(for: configuration.id) }
        let richMessage = try #require(initial.snapshot?.messages.last)
        let fileBlock = try #require(ReplyContent(message: richMessage).blocks.first { $0.filePreview?.isHTML == true })
        try await requirePaintedFile(fileBlock.id, phase: .initial, host: host, window: window)
        let first = try #require(collectionController(host))
        await store.open(milo)
        try await wait("Milo actually replaced the native Canvas subtree") { collectionController(host).map { $0 !== first } ?? false }
        let middle = try #require(collectionController(host))
        await store.open(canvas)
        try await wait("Canvas actual selected subtree returned") { collectionController(host).map { $0 !== middle } ?? false }
        try await wait("returned rich body is actually placed inside its current native allocation before Send") {
            guard let controller = collectionController(host),
                  let cell = controller.collection.cellForItem(at: IndexPath(item: 2, section: 0)) as? NativeTranscriptCell,
                  let root = cell.exposure?.rowGeometry else { return false }
            let rect = root.convert(root.bounds, to: cell.contentView)
            return markers(cell).contains { $0.block == fileBlock.id && $0.role == .document &&
                $0.scope === cell.exposure && $0.bounds.height > 300 } &&
                !webViews(cell).isEmpty && abs(rect.minY) < 1 && abs(rect.height - cell.contentView.bounds.height) < 1
        }
        try await requirePaintedFile(fileBlock.id, phase: .returned, host: host, window: window)
        let screen = try #require(store.chats.screen(profile: profile))
        store.chats.displayed(screen.owner)
        store.chats.editDraft("Canvas tail after rich preview\n  keep this source draft  ", owner: screen.owner)
        viewport.height = 380
        try await wait("actual short composer viewport applied") { collectionController(host)?.view.bounds.height == 380 }
        let intent = try #require(store.chats.captureSend(screen.owner))
        await store.chats.send(intent)
        viewport.height = 434
        try await wait("actual local demo reply delivered") { store.chats.screen(profile: profile)?.snapshot?.messages.count == 4 }
        let controller = try #require(collectionController(host))
        try await wait("actual latest native reply root") {
            guard let reply = controller.collection.cellForItem(at: IndexPath(item: 4, section: 0)) as? NativeTranscriptCell,
                  let root = reply.exposure?.rowGeometry else { return false }
            return root.bounds.height > 100 && root.convert(root.bounds, to: controller.collection).intersects(controller.collection.bounds)
        }
        try await wait("settled rendered roots fit native cell allocations") {
            controller.collection.visibleCells.allSatisfy { cell in
                guard let cell = cell as? NativeTranscriptCell, let root = cell.exposure?.rowGeometry else { return true }
                let rect = root.convert(root.bounds, to: cell.contentView)
                return cell.contentView.bounds.insetBy(dx: -1, dy: -1).contains(rect)
            }
        }
    }
    @MainActor @Observable final class Viewport { var height: CGFloat = 434 }
    private struct CanvasHost: View {
        let store: AppStore
        let viewport: Viewport
        @State private var presentation = WorkspacePresentation()
        var body: some View {
            if let bot = store.selectedBot {
                transcriptFixture(store: store, bot: bot, presentation: presentation, native: true)
                    .frame(width: 382, height: viewport.height)
                    .environment(\.scenePhase, .active)
            }
        }
    }
    private enum PaintPhase: String { case initial, returned }

    private struct PaintReadinessTrace {
        let phase: PaintPhase
        let started = CACurrentMediaTime()
        var attempts = 0
        var maximumAttemptGap: TimeInterval = 0
        var previousAttempt: TimeInterval?
        var samples: [[String: Any]] = []
        var discardedSamples = 0
        var lastImage: UIImage?
        var lastCapture: [String: Any] = [:]
        var oracleError: [String: Any] = [:]

        mutating func beginAttempt() {
            let now = CACurrentMediaTime()
            if let previousAttempt { maximumAttemptGap = max(maximumAttemptGap, now - previousAttempt) }
            previousAttempt = now
            attempts += 1
        }

        mutating func record(_ stage: String, renderers: [String] = []) {
            let sample: [String: Any] = ["elapsed_seconds": CACurrentMediaTime() - started,
                "attempt": attempts, "stage": stage, "renderers_before_capture": renderers]
            // Keep the latest evidence even when a deadline spans many display frames.
            if samples.count == 64 { samples.removeFirst(); discardedSamples += 1 }
            samples.append(sample)
        }
    }

    private func requirePaintedFile(_ block: Int, phase: PaintPhase, host: UIViewController, window: UIWindow,
                                    sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let display = NativeContentDisplayFrames()
        defer { display.stop() }
        var trace = PaintReadinessTrace(phase: phase)
        // Allow the renderer's fifteen-second cold startup and five-second document budget.
        let deadline = ContinuousClock.now + .seconds(21)
        var painted = false
        var failureRecorded = false
        defer {
            if !painted && !failureRecorded { recordPaintFailure(block, trace: trace, host: host, window: window) }
        }
        while ContinuousClock.now < deadline {
            trace.beginAttempt()
            guard let controller = collectionController(host) else {
                trace.record("missing-controller")
                await display.nextFrame(); continue
            }
            guard let cell = controller.collection.cellForItem(at: IndexPath(item: 2, section: 0)) as? NativeTranscriptCell else {
                trace.record("missing-cell")
                await display.nextFrame(); continue
            }
            guard let document = markers(cell).first(where: { $0.block == block && $0.role == .document && $0.scope === cell.exposure }) else {
                trace.record("missing-current-document-marker")
                await display.nextFrame(); continue
            }
            let states = webViews(cell).map { view in
                "\(ObjectIdentifier(view)) renderer=\((view.navigationDelegate as? RichContentRenderer).map { String(describing: $0.state) } ?? "missing") loading=\(view.isLoading) attached=\(view.window === window)"
            }
            trace.record("capture-started", renderers: states)
            let captureStarted = CACurrentMediaTime()
            var drawn = false
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                drawn = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let captureFinished = CACurrentMediaTime()
            let visible = document.convert(document.bounds, to: window)
                .intersection(controller.collection.convert(controller.collection.bounds, to: window)).intersection(window.bounds)
            trace.lastImage = image
            trace.lastCapture = ["elapsed_seconds": captureFinished - trace.started,
                "draw_seconds": captureFinished - captureStarted, "draw_succeeded": drawn,
                "crop_in_window": NSCoder.string(for: visible), "image_scale": image.scale,
                "image_size": NSCoder.string(for: image.size)]
            do {
                let observation = try RenderedTranscriptFile.observe(image, in: visible)
                painted = observation.isComplete
                trace.lastCapture["oracle_seconds"] = CACurrentMediaTime() - captureFinished
                trace.lastCapture["has_bars"] = observation.hasBars
                trace.lastCapture["ocr_attempted"] = observation.hasBars
                trace.lastCapture["recognized_text"] = observation.text
                trace.record(painted ? "painted" : "oracle-incomplete", renderers: states)
            } catch {
                let error = error as NSError
                trace.oracleError = ["domain": error.domain, "code": error.code]
                trace.record("oracle-threw", renderers: states)
                throw error
            }
            if painted { break }
            await display.nextFrame()
        }
        do {
            try #require(painted, "\(phase.rawValue): actual visible file body must paint its known bars; WK presence and measured height alone do not pass",
                         sourceLocation: sourceLocation)
        } catch {
            recordPaintFailure(block, trace: trace, host: host, window: window)
            failureRecorded = true
            await recordPostFailurePaint(block, trace: trace, host: host, window: window)
            throw error
        }
    }

    private func recordPaintFailure(_ block: Int, trace: PaintReadinessTrace, host: UIViewController, window: UIWindow) {
        let controller = collectionController(host)
        let rows: [[String: Any]] = controller?.collection.visibleCells.map { cell in
            let scope = (cell as? NativeTranscriptCell)?.exposure
            let root = scope?.rowGeometry
            let blocks: [[String: Any]] = markers(cell).map { marker in
                ["block": marker.block, "role": String(describing: marker.role),
                 "bounds": NSCoder.string(for: marker.bounds),
                 "frame_in_window": NSCoder.string(for: marker.convert(marker.bounds, to: window)),
                 "visible": marker.presence?.isVisible ?? false, "current_scope": marker.scope === scope]
            }
            return ["index": controller?.collection.indexPath(for: cell)?.item ?? -1,
                    "cell": NSCoder.string(for: cell.frame), "allocation": NSCoder.string(for: cell.contentView.bounds),
                    "root": root.map { NSCoder.string(for: $0.convert($0.bounds, to: cell.contentView)) } ?? "missing",
                    "current": scope?.isCurrent ?? false, "can_present": scope?.canPresent ?? false,
                    "admits_content": scope?.admitsContent ?? false,
                    "root_descends_from_content": root?.isDescendant(of: cell.contentView) ?? false,
                    "root_same_window": root?.window === cell.window, "blocks": blocks]
        } ?? []
        let documents: [[String: Any]] = webViews(host.view).map { view in
            let renderer = view.navigationDelegate as? RichContentRenderer
            return ["identity": String(describing: ObjectIdentifier(view)),
                    "renderer_state": renderer.map { String(describing: $0.state) } ?? "missing",
                    "renderer_height": renderer?.height ?? -1, "loading": view.isLoading,
                    "estimated_progress": view.estimatedProgress, "attached_to_test_window": view.window === window,
                    "hidden": view.isHidden, "alpha": view.alpha,
                    "renderer_owns_view": renderer?.webView === view,
                    "bounds": NSCoder.string(for: view.bounds),
                    "frame_in_window": NSCoder.string(for: view.convert(view.bounds, to: window))]
        }
        let evidence: [String: Any] = ["phase": trace.phase.rawValue, "target_block": block,
            "elapsed_seconds": CACurrentMediaTime() - trace.started, "attempts": trace.attempts,
            "maximum_attempt_gap_seconds": max(trace.maximumAttemptGap, CACurrentMediaTime() - (trace.previousAttempt ?? trace.started)),
            "discarded_samples": trace.discardedSamples,
            "samples": trace.samples, "last_capture": trace.lastCapture, "oracle_error": trace.oracleError,
            "application_state": UIApplication.shared.applicationState.rawValue,
            "scene_state": window.windowScene?.activationState.rawValue ?? -1,
            "test_window_key": window.isKeyWindow, "test_window_hidden": window.isHidden,
            "test_window_bounds": NSCoder.string(for: window.bounds),
            "host_in_test_window": host.view.window === window, "controller_present": controller != nil,
            "viewport": controller.map { NSCoder.string(for: $0.collection.bounds) } ?? "missing",
            "rows": rows, "web_views": documents]
        let name = "Canvas \(trace.phase.rawValue) file failure"
        if let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            Attachment.record(text, named: "\(name).json")
        } else {
            Attachment.record(String(describing: evidence), named: "\(name) serialization fallback.txt")
        }
        if let image = trace.lastImage {
            Attachment.record(image, named: "\(name) last observed.png", as: .png)
        } else {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
            }
            Attachment.record(image, named: "\(name) no oracle capture.png", as: .png)
        }
    }
    private func recordPostFailurePaint(_ block: Int, trace: PaintReadinessTrace,
                                        host: UIViewController, window: UIWindow) async {
        let name = "Canvas \(trace.phase.rawValue) post-failure paint"
        let started = CACurrentMediaTime()
        var evidence: [String: Any] = ["original_verdict": "failed", "target_block": block,
            "original_trace_started_uptime": trace.started, "started_uptime": started,
            "started_unix_seconds": Date().timeIntervalSince1970,
            "original_last_capture": trace.lastCapture, "snapshot_callback_budget_seconds": 3,
            "limits": "Post-verdict evidence; cannot change the original result. Snapshot may trigger later paint. Callback timeout cannot preempt synchronous framework work. Actual-screen witness is separate."]
        defer {
            evidence["finished_uptime"] = CACurrentMediaTime()
            recordPaintMetadata(evidence, named: "\(name).json")
        }
        guard let controller = collectionController(host),
              let cell = controller.collection.cellForItem(at: IndexPath(item: 2, section: 0)) as? NativeTranscriptCell,
              let document = markers(cell).first(where: { $0.block == block && $0.role == .document && $0.scope === cell.exposure }) else {
            evidence["snapshot_status"] = "missing-current-target"; return
        }
        let documentRect = document.convert(document.bounds, to: window)
        let candidates = webViews(cell).filter {
            $0.window === window && $0.convert($0.bounds, to: window).intersects(documentRect)
        }
        evidence["candidate_count"] = candidates.count
        guard candidates.count == 1, let view = candidates.first else {
            evidence["snapshot_status"] = "missing-or-ambiguous-web-view"; return
        }
        let visible = documentRect.intersection(controller.collection.convert(controller.collection.bounds, to: window))
            .intersection(window.bounds)
        let rect = view.convert(visible, from: window).intersection(view.bounds)
        evidence["before"] = paintViewState(view, window: window)
        evidence["ancestors_before"] = paintAncestors(view, window: window)
        evidence["crop_in_window"] = NSCoder.string(for: visible)
        evidence["snapshot_rect_in_view"] = NSCoder.string(for: rect)
        guard !rect.isNull, !rect.isInfinite, rect.width > 0, rect.height > 0 else {
            evidence["snapshot_status"] = "empty-visible-region"; return
        }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = rect
        configuration.afterScreenUpdates = false
        // Bound the separate raster to 1024 pixels on its longest axis.
        let scale = max(1, view.traitCollection.displayScale)
        configuration.snapshotWidth = NSNumber(value: Double(min(rect.width, 1024 * rect.width / max(rect.width, rect.height) / scale)))
        evidence["snapshot_width_points"] = configuration.snapshotWidth?.doubleValue ?? -1
        evidence["snapshot_maximum_requested_pixels"] = 1024
        evidence["snapshot_requested_uptime"] = CACurrentMediaTime()
        let result = await PaintSnapshotRequest().capture(view, configuration: configuration)
        evidence["snapshot_completed_uptime"] = result.completed
        evidence["snapshot_status"] = result.status
        evidence["snapshot_image_returned"] = result.image != nil
        if let error = result.error { evidence["snapshot_error"] = ["domain": error.domain, "code": error.code] }
        evidence["after"] = paintViewState(view, window: window)
        evidence["ancestors_after"] = paintAncestors(view, window: window)
        var drawn = false
        let followingStarted = CACurrentMediaTime()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            drawn = window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        evidence["following_hierarchy"] = ["started_uptime": followingStarted,
            "completed_uptime": CACurrentMediaTime(), "draw_succeeded": drawn,
            "oracle": paintObservation(image, in: visible)]
        Attachment.record(image, named: "\(name) following hierarchy.png", as: .png)
        if let raster = result.image {
            Attachment.record(raster, named: "\(name) WebKit raster.png", as: .png)
            evidence["snapshot_oracle"] = paintObservation(raster, in: CGRect(origin: .zero, size: raster.size))
        }
    }

    private func paintObservation(_ image: UIImage, in rect: CGRect) -> [String: Any] {
        let started = CACurrentMediaTime()
        var result: [String: Any] = ["started_uptime": started, "crop": NSCoder.string(for: rect),
            "image_size": NSCoder.string(for: image.size), "image_scale": image.scale,
            "image_pixel_width": image.cgImage?.width ?? -1, "image_pixel_height": image.cgImage?.height ?? -1]
        do {
            let observation = try RenderedTranscriptFile.observe(image, in: rect)
            result["has_bars"] = observation.hasBars
            result["ocr_attempted"] = observation.hasBars
            result["recognized_text"] = observation.text
            result["complete"] = observation.isComplete
        } catch {
            let error = error as NSError
            result["error"] = ["domain": error.domain, "code": error.code]
        }
        result["completed_uptime"] = CACurrentMediaTime()
        return result
    }

    private func paintViewState(_ view: UIView, window: UIWindow) -> [String: Any] {
        let layer = view.layer
        let presented = layer.presentation()
        var state: [String: Any] = ["identity": String(describing: ObjectIdentifier(view)), "type": String(describing: type(of: view)),
            "hidden": view.isHidden, "alpha": view.alpha, "same_window": view.window === window,
            "bounds": NSCoder.string(for: view.bounds), "frame_in_window": NSCoder.string(for: view.convert(view.bounds, to: window)),
            "clips_to_bounds": view.clipsToBounds, "layer_opacity": layer.opacity, "layer_hidden": layer.isHidden,
            "layer_masks_to_bounds": layer.masksToBounds, "layer_has_mask": layer.mask != nil,
            "layer_z_position": layer.zPosition, "layer_transform": String(describing: layer.transform),
            "presentation_available": presented != nil, "presentation_opacity": presented?.opacity ?? -1,
            "presentation_hidden": presented?.isHidden ?? false,
            "presentation_frame": presented.map { NSCoder.string(for: $0.frame) } ?? "unavailable",
            "presentation_transform": presented.map { String(describing: $0.transform) } ?? "unavailable"]
        if let web = view as? WKWebView {
            let renderer = web.navigationDelegate as? RichContentRenderer
            state["loading"] = web.isLoading
            state["estimated_progress"] = web.estimatedProgress
            state["renderer_state"] = renderer.map { String(describing: $0.state) } ?? "missing"
            state["renderer_height"] = renderer?.height ?? -1
            state["renderer_owns_view"] = renderer?.webView === web
        }
        return state
    }

    private func paintAncestors(_ view: UIView, window: UIWindow) -> [String: Any] {
        var rows: [[String: Any]] = []
        var current: UIView? = view
        var droppedSiblings = 0
        while let node = current, rows.count < 32 {
            var row = paintViewState(node, window: window)
            if let parent = node.superview, let index = parent.subviews.firstIndex(where: { $0 === node }) {
                let above = parent.subviews.dropFirst(index + 1)
                row["later_siblings"] = above.prefix(8).map { paintViewState($0, window: window) }
                row["later_sibling_count"] = above.count
                droppedSiblings += max(0, above.count - 8)
            }
            rows.append(row)
            current = node.superview
        }
        return ["rows": rows, "ancestor_limit": 32, "ancestor_overflow": current != nil,
            "later_sibling_limit_per_ancestor": 8, "dropped_later_siblings": droppedSiblings,
            "limits": "Later siblings are possible overlays; subview order alone does not prove occlusion. Presentation frames use superlayer coordinates."]
    }

    private func recordPaintMetadata(_ evidence: [String: Any], named name: String) {
        if let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            Attachment.record(text, named: name)
        } else { Attachment.record(String(describing: evidence), named: "\(name) serialization fallback.txt") }
    }

    @MainActor private final class PaintSnapshotRequest {
        struct Result {
            let image: UIImage?
            let error: NSError?
            let status: String
            let completed: TimeInterval
        }
        private var continuation: CheckedContinuation<Result, Never>?
        private var timeout: Task<Void, Never>?

        func capture(_ view: WKWebView, configuration: WKSnapshotConfiguration) async -> Result {
            let result = await withCheckedContinuation { (continuation: CheckedContinuation<Result, Never>) in
                self.continuation = continuation
                timeout = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                    self?.finish(image: nil, error: nil, status: "callback-timeout")
                }
                view.takeSnapshot(with: configuration) { [weak self] image, error in
                    self?.finish(image: image, error: error as NSError?, status: error == nil ? "callback-returned" : "callback-error")
                }
            }
            return withExtendedLifetime(self) { result }
        }

        private func finish(image: UIImage?, error: NSError?, status: String) {
            guard let continuation else { return }
            self.continuation = nil
            timeout?.cancel(); timeout = nil
            continuation.resume(returning: Result(image: image, error: error, status: status, completed: CACurrentMediaTime()))
        }
    }
    private func collectionController(_ parent: UIViewController) -> NativeTranscriptController? {
        if let controller = parent as? NativeTranscriptController, controller.isViewLoaded, controller.view.window != nil { return controller }
        return parent.children.lazy.compactMap(collectionController).first
    }
    private func markers(_ view: UIView) -> [NativeTranscriptBlockMarker] {
        (view as? NativeTranscriptBlockMarker).map { [$0] } ?? view.subviews.flatMap(markers)
    }
    private func webViews(_ view: UIView) -> [WKWebView] {
        (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(webViews)
    }
    private func wait(_ reason: String, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(condition(), "Timed out: \(reason)")
    }
}

@Suite(.serialized, RichReplyRuntime()) @MainActor struct InboxPresentationTests {
    @Test func cachedInboxCountDoesNotFlashAnExtraChatDuringDirectoryRefresh() async throws {
        let service = try WorkspaceTestService()
        let configuration = ConnectionConfiguration(serverURL: URL(string: "https://count-badge.invalid")!)
        var history = LocalHistory()
        history.bots = [.init(id: service.profile.text, name: "Milo")]
        for summary in service.summaries { history.book.merge(summary) }
        try history.save(for: configuration.id)
        let store = AppStore(service: service, persistence: MemoryConnectionStorage(saved: configuration).persistence)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }
        let host = UIHostingController(rootView: InboxView(store: store, onSettings: {}, onNewBot: {}))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer {
            window.isHidden = true; window.rootViewController = nil; previous?.makeKey()
            store.forgetConnection(); LocalHistory.remove(for: configuration.id)
        }
        func renderedCount() throws -> String? {
            host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate; request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: #require(image.cgImage)).perform([request])
            return request.results?.compactMap { $0.topCandidates(1).first?.string }.first { $0.contains("chats") }
        }
        var cached: String?
        let deadline = ContinuousClock.now + .seconds(5)
        while cached == nil, ContinuousClock.now < deadline { await Task.yield(); cached = try renderedCount() }
        try #require(cached != nil, "The cached bot row must actually paint its chat count")
        #expect(!store.chats.aggregate(profile: service.profile).directoryComplete)
        #expect(cached == "2 chats")
        try #require(await store.connect(configuration))
        #expect(store.chats.aggregate(profile: service.profile).directoryComplete)
        #expect(store.chats.aggregate(profile: service.profile).count == 2)
        await Task.yield()
        #expect(try renderedCount() == cached)
        let discovered = SessionIdentity(profile: service.profile, root: try ExactID("discovered-root"),
            stored: try ExactID("discovered-tip"), aliases: [])
        service.summaries.append(.init(identity: discovered, title: "Discovered chat", isCanonical: false,
                                      persistence: .durable))
        store.chats.invalidateActivityDirectory(service.profile)
        await store.chats.refreshActivityDirectories(for: store.bots)
        #expect(store.chats.aggregate(profile: service.profile).count == 3)
        await Task.yield()
        #expect(try renderedCount() == "3 chats")
    }

}

@MainActor struct MarkdownSelectionTests {
    @Test(arguments: [2, 3, 4, 5])
    func headingStyleSurvivesParagraphSeparators(_ newlines: Int) throws {
        let separator = String(repeating: "\n", count: newlines)
        let source = "Intro" + separator + "# Heading\n\nBody"
        let rendered = MarkdownBody(text: source, isReply: true).attributed(source)
        let heading = try #require(rendered.range(of: "Heading"))
        #expect(rendered[heading].font == .title3.weight(.semibold))
        #expect(String(rendered.characters) == "Intro" + separator + "Heading\n\nBody")
    }
}

/// Test-only display readiness, with no sleeps, product mutations or DEBUG API.
@MainActor private final class NativeContentDisplayFrames: NSObject {
    private var link: CADisplayLink?
    private var waiting: CheckedContinuation<Void, Never>?
    func nextFrame() async {
        await withCheckedContinuation { continuation in
            waiting = continuation
            let link = CADisplayLink(target: self, selector: #selector(tick))
            self.link = link; link.add(to: .main, forMode: .common)
        }
    }
    @objc private func tick() { stop() }
    func stop() {
        link?.invalidate(); link = nil
        let pending = waiting; waiting = nil; pending?.resume()
    }
}
