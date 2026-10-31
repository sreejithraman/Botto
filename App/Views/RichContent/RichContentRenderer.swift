import Foundation
import BottoCore
import Observation
import WebKit

/// One document, one ephemeral WebKit data store, one native lifetime. This type
/// never receives the app's service, session, URL request, cookies or credentials.
@MainActor @Observable
final class RichContentRenderer: NSObject {
    enum State: Equatable { case idle, loading, deferred, ready, failed(String) }
    private(set) var state: State = .idle
    private(set) var height: CGFloat = 120
    private(set) var webView: WKWebView?
    private(set) var presentation: DiagramPresentation?
    @ObservationIgnored private let isolatedScope = RichReplyPresentations()
    @ObservationIgnored private var ticket: DiagramRenderTicket?
    @ObservationIgnored private var pressureBlocked: Input?
    @ObservationIgnored private var context: RichReplyContext = .isolated
    @ObservationIgnored private var deferredToken = UUID()
    @ObservationIgnored private var deferredPressureEpoch: UInt64?
    @ObservationIgnored private var snapshotPending = false
    @ObservationIgnored private var snapshotDeadline: ContinuousClock.Instant?
    @ObservationIgnored private var awaitsInitialMeasurement = false

    private struct Input: Equatable {
        let block: ExactReplyBlock
        let authority: RichReplyContext.RequestIdentity
        let dark: Bool
        let reduceMotion: Bool
        let diagramWidth: CGFloat?
        let viewportHeight: CGFloat?
        let initialHeight: CGFloat?
    }
    @ObservationIgnored private let bundle: Bundle
    @ObservationIgnored private var input: Input?
    @ObservationIgnored private var generation = ""
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var lastHeartbeat = ContinuousClock.now
    @ObservationIgnored private var deadline = ContinuousClock.now
    @ObservationIgnored private var initialNavigationAllowed = false
    @ObservationIgnored private var childNavigationAllowed = false
    @ObservationIgnored private var awaitingHostCommit = false
    private static let bridgeWorld = WKContentWorld.world(name: "Botto.RichContent.Host")
    private static var ruleList: Task<WKContentRuleList, Error>?

    init(bundle: Bundle = .main) {
        self.bundle = bundle
        super.init()
        #if DEBUG && os(iOS) && !RICH_CONTENT_STANDALONE
        TranscriptMeasurements.current?.register(self)
        #endif
    }

    func load(_ block: ReplyContent.Block, context: RichReplyContext = .isolated, dark: Bool = false, reduceMotion: Bool = false,
              diagramWidth: CGFloat? = nil, diagramViewportHeight: CGFloat? = nil, initialHeight: CGFloat? = nil) async {
        guard block.previewFormat != nil else {
            stop(); state = .failed("This content could not be rendered. Source is still available."); return
        }
        let width = block.previewFormat == .html ? nil : diagramWidth
        let initial = block.previewFormat == .html
            ? initialHeight.flatMap { $0.isFinite ? min(1200, max(120, $0)) : nil } : nil
        let next = Input(block: ExactReplyBlock(block), authority: context.requestIdentity, dark: dark, reduceMotion: reduceMotion, diagramWidth: width,
                         viewportHeight: width == nil ? nil : diagramViewportHeight, initialHeight: initial)
        guard context.permits(block) else {
            stop(); state = .deferred; return
        }
        if pressureBlocked == next { state = .deferred; return }
        if input == next, let deferredPressureEpoch,
           deferredPressureEpoch != DiagramMemory.shared.pressureEpoch {
            pressureBlocked = next
            suspend()
            state = .deferred
            return
        }
        if input == next, case .failed = state { return }
        if width != nil, input?.block == next.block, input?.authority == next.authority,
           case .failed = state { return }
        if input == next, presentation?.isAvailable == true, ticket?.isCurrent == true { state = .ready; return }
        if input == next, webView != nil { return }
        let retainedHeight = input == next ? height : (initial ?? 120)
        stop()
        self.context = context
        input = next
        height = retainedHeight
        awaitsInitialMeasurement = initial != nil
        let token = UUID().uuidString
        generation = token
        let layout = width.flatMap { DiagramLayout(dark: dark, reduceMotion: reduceMotion,
                                                   width: $0, viewportHeight: diagramViewportHeight) }
        if width != nil && layout == nil { state = .deferred; return }
        let pressureEpoch = DiagramMemory.shared.pressureEpoch
        let revoke: @MainActor () -> Void = { [weak self] in
            guard let self, self.input == next else { return }
            if DiagramMemory.shared.pressureEpoch != pressureEpoch { self.pressureBlocked = next }
            self.suspend()
            self.state = .deferred
        }
        let admission: DiagramAdmission
        switch context {
        case .isolated:
            admission = isolatedScope.begin(block, messageID: Data(), layout: layout, onRevoke: revoke)
        case .chat:
            admission = context.begin(block, layout: layout, onRevoke: revoke)
        }
        switch admission {
        case .pixels(let pixels, let activity):
            ticket = activity
            presentation = pixels; height = pixels.height; state = .ready; generation = ""; return
        case .denied: state = .deferred; return
        case .busy:
            state = .deferred
            deferredPressureEpoch = DiagramMemory.shared.pressureEpoch
            let retry = deferredToken
            withObservationTracking { _ = DiagramMemory.shared.revision } onChange: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.deferredToken == retry, self.input == next else { return }
                    await self.load(block, context: context, dark: dark, reduceMotion: reduceMotion,
                                    diagramWidth: diagramWidth, diagramViewportHeight: diagramViewportHeight)
                }
            }
            return
        case .render(let ticket): self.ticket = ticket
        }
        state = .loading
        do {
            let script = try RichContentDocument.bootstrap(block: block, generation: token,
                dark: dark, reduceMotion: reduceMotion, bundle: bundle, diagramHeight: width == nil ? nil : (diagramViewportHeight ?? 480))
            let capabilities = try RichContentDocument.resource("capabilities", bundle: bundle)
            let rules = try await Self.blockedResources()
            guard generation == token, ticket?.isCurrent == true else { return }
            guard !Task.isCancelled else { stop(); return }
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
            configuration.preferences.isFraudulentWebsiteWarningEnabled = false
            configuration.preferences.isElementFullscreenEnabled = false
            configuration.preferences.inactiveSchedulingPolicy = .suspend
            configuration.allowsAirPlayForMediaPlayback = false
            configuration.mediaTypesRequiringUserActionForPlayback = .all
            #if os(iOS)
            configuration.allowsPictureInPictureMediaPlayback = false
            configuration.dataDetectorTypes = []
            #endif
            let controller = configuration.userContentController
            controller.add(rules)
            controller.add(WeakHandler(self), contentWorld: Self.bridgeWorld, name: "richContent")
            controller.addUserScript(WKUserScript(source: capabilities, injectionTime: .atDocumentStart,
                forMainFrameOnly: false, in: .page))
            controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd,
                forMainFrameOnly: true, in: Self.bridgeWorld))
            let view = AttachedRichWebView(frame: .zero, configuration: configuration)
            #if DEBUG && os(iOS) && !RICH_CONTENT_STANDALONE
            TranscriptMeasurements.current?.register(view)
            #endif
            view.navigationDelegate = self
            view.uiDelegate = self
            view.allowsBackForwardNavigationGestures = false
            view.allowsLinkPreview = false
            #if os(iOS)
            view.isOpaque = false
            view.backgroundColor = .clear
            view.scrollView.isScrollEnabled = false
            view.scrollView.contentInsetAdjustmentBehavior = .never
            #endif
            webView = view
            initialNavigationAllowed = true
            childNavigationAllowed = true
            view.layoutChanged = { [weak self] in self?.captureDiagramIfReady() }
            view.attachmentChanged = { [weak self] attached in
                // Leave the native mounting callback before starting navigation;
                // a view can also move through a detached container while mounting.
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token else { return }
                    if attached { self.startAttachedDocument(token: token) }
                    else if self.webView?.window == nil, self.watchdog != nil { self.suspend() }
                }
            }
        } catch {
            guard generation == token else { return }
            fail("This preview could not load. Source is still available.")
        }
    }

    /// Called on disappearance and before replacement. Invalidate native ownership
    /// before stopping WebKit; no late messages can revive a retired document.
    func stop() {
        suspend()
        input = nil
        presentation = nil
        state = .idle
    }

    /// Offscreen/background views own no executing document. Preserve measured
    /// height to avoid scroll jumps, and preserve failure so visibility changes
    /// cannot repeatedly restart hostile content that already exhausted its budget.
    func suspend() {
        generation = ""
        deferredToken = UUID()
        deferredPressureEpoch = nil
        ticket?.cancel()
        ticket = nil
        snapshotPending = false
        snapshotDeadline = nil
        awaitingHostCommit = false
        watchdog?.cancel()
        watchdog = nil
        retireWebView()
        if case .failed = state { return }
        state = presentation?.isAvailable == true ? .ready : .idle
    }

    private func startAttachedDocument(token: String) {
        guard watchdog == nil, let view = webView, view.window != nil else { return }
        lastHeartbeat = .now
        // A cold WebKit process can take time to start without having executed
        // any document. The trusted main-frame commit starts the shorter budget
        // before its document-end bootstrap can create the untrusted child.
        awaitingHostCommit = true
        deadline = .now + .seconds(15)
        view.loadHTMLString(RichContentDocument.hostHTML, baseURL: nil)
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, self.generation == token else { return }
                let now = ContinuousClock.now
                if (self.state == .loading && now > self.deadline) ||
                    (self.state == .ready && now > self.lastHeartbeat + .seconds(3)) ||
                    self.snapshotDeadline.map({ now > $0 }) == true {
                    #if DEBUG
                    let diagnostic = (timestamp: Date.now.timeIntervalSince1970, pid: ProcessInfo.processInfo.processIdentifier,
                        blockOffset: self.input?.block.offset, state: self.state, awaitingHostCommit: self.awaitingHostCommit,
                        heartbeatAge: self.lastHeartbeat.duration(to: now),
                        deadlineOverrun: self.deadline.duration(to: now), html: self.input?.diagramWidth == nil)
                    #endif
                    self.fail("Preview stopped responding. Source is still available.")
                    #if DEBUG
                    print("[DEBUG-canvas-budget]", "timestamp=\(diagnostic.timestamp)", "pid=\(diagnostic.pid)",
                          "blockOffset=\(String(describing: diagnostic.blockOffset))", "state=\(diagnostic.state)",
                          "awaitingHostCommit=\(diagnostic.awaitingHostCommit)",
                          "heartbeatAge=\(diagnostic.heartbeatAge)",
                          "deadlineOverrun=\(diagnostic.deadlineOverrun)", "html=\(diagnostic.html)")
                    #endif
                    return
                }
            }
        }
    }

    private func fail(_ message: String) {
        ticket?.cancel(); ticket = nil
        generation = ""
        snapshotDeadline = nil
        watchdog?.cancel()
        watchdog = nil
        retireWebView()
        state = .failed(message)
    }

    private func retireWebView() {
        guard let view = webView else { return }
        webView = nil
        (view as? AttachedRichWebView)?.attachmentChanged = nil
        (view as? AttachedRichWebView)?.layoutChanged = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: "richContent", contentWorld: Self.bridgeWorld)
        view.configuration.userContentController.removeAllUserScripts()
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.stopLoading()
        view.removeFromSuperview()
        // Release ownership of the hung page and its private store. WebKit owns the
        // process lifetime; never wait for JavaScript or navigation to acknowledge.
    }

    private static func blockedResources() async throws -> WKContentRuleList {
        if let ruleList { return try await ruleList.value }
        let task = Task { @MainActor in
            try await withCheckedThrowingContinuation { continuation in
                WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "Botto.RichContent.NoNetwork.v1",
                    encodedContentRuleList: #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#) { list, error in
                    if let list { continuation.resume(returning: list) }
                    else { continuation.resume(throwing: error ?? RichContentDocument.Failure.missingResources) }
                }
            }
        }
        ruleList = task
        return try await task.value
    }

    private func receive(_ message: WKScriptMessage) {
        guard message.webView === webView, message.frameInfo.isMainFrame,
              !generation.isEmpty, let body = message.body as? [String: Any], body.count == 3,
              body["generation"] as? String == generation,
              let kind = body["kind"] as? String else { return }
        if kind == "failed" {
            fail("This content could not be rendered. Source is still available.")
            return
        }
        guard kind == "ready", let value = body["height"] as? Double,
              value.isFinite, (120...480).contains(value) else { return }
        lastHeartbeat = .now
        height = awaitsInitialMeasurement ? ceil(value) : max(height, ceil(value))
        awaitsInitialMeasurement = false
        state = .ready
        if input?.diagramWidth != nil, snapshotDeadline == nil {
            snapshotDeadline = .now + .seconds(5)
        }
        captureDiagramIfReady()
    }

    /// A surface width requests frozen diagram pixels. HTML always keeps its
    /// ordinary live-document behavior.
    func diagramPresentation(for block: ReplyContent.Block, dark: Bool, reduceMotion: Bool,
                             width: CGFloat, viewportHeight: CGFloat? = nil) -> DiagramPresentation? {
        guard context.permits(block), input == Input(block: ExactReplyBlock(block), authority: context.requestIdentity,
              dark: dark, reduceMotion: reduceMotion, diagramWidth: width, viewportHeight: viewportHeight, initialHeight: nil),
              presentation?.isAvailable == true else { return nil }
        return presentation
    }

    /// Only a genuine inactive/active transition resumes work after pressure.
    func deactivate() { pressureBlocked = nil; suspend() }

    private func captureDiagramIfReady() {
        guard state == .ready, !snapshotPending, let width = input?.diagramWidth,
              let view = webView, view.window != nil, !generation.isEmpty,
              abs(view.bounds.width - width) < 1 else { return }
        // Inline height follows the measured document. Expansion can have less
        // vertical space (for example in landscape); snapshot its real viewport.
        if let viewportHeight = input?.viewportHeight {
            guard abs(view.bounds.height - viewportHeight) < 1 else { return }
        } else {
            guard view.bounds.height >= height - 1 else { return }
        }
        guard let capture = ticket, capture.startCapture() else { return }
        snapshotPending = true
        if snapshotDeadline == nil { snapshotDeadline = .now + .seconds(5) }
        let token = generation
        let size = view.bounds.size
        let configuration = WKSnapshotConfiguration()
        configuration.rect = view.bounds
        configuration.afterScreenUpdates = true
        #if os(iOS)
        let scale = max(1, view.traitCollection.displayScale)
        #else
        let scale = view.window?.backingScaleFactor ?? 1
        #endif
        // WKSnapshotConfiguration uses points; the result uses the display scale.
        let factor = 1_024 / max(size.width, size.height) / scale
        configuration.snapshotWidth = NSNumber(value: Double(size.width * factor))
        view.takeSnapshot(with: configuration) { [weak self, weak view] image, error in
            guard let self, let view, self.webView === view, self.generation == token else {
                _ = capture.finishCapture(nil, height: 120); return
            }
            self.snapshotPending = false
            guard view.bounds.size == size else {
                _ = capture.finishCapture(nil, height: 120)
                self.suspend()
                return
            }
            #if os(iOS)
            let pixels = image?.cgImage
            #else
            let pixels = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            #endif
            guard error == nil, let pixels else {
                _ = capture.finishCapture(nil, height: 120)
                self.fail("This preview could not load. Source is still available.")
                return
            }
            self.presentation = capture.finishCapture(pixels, height: self.height)
            guard self.presentation != nil else {
                self.fail("This preview could not load. Source is still available.")
                return
            }
            // Finish native presentation before retiring the untrusted document.
            // A scroll, replacement or destroyed epoch invalidates this callback.
            self.generation = ""
            self.snapshotDeadline = nil
            self.watchdog?.cancel()
            self.watchdog = nil
            self.retireWebView()
        }
    }

    private final class WeakHandler: NSObject, WKScriptMessageHandler {
        weak var owner: RichContentRenderer?
        init(_ owner: RichContentRenderer) { self.owner = owner }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            owner?.receive(message)
        }
    }
}

/// WebKit's `.suspend` policy stops detached documents. Begin both execution and
/// its watchdog only after UIKit/AppKit actually attaches the view to a window.
private final class AttachedRichWebView: WKWebView {
    var attachmentChanged: ((Bool) -> Void)?
    var layoutChanged: (() -> Void)?
    #if os(iOS)
    override func layoutSubviews() {
        super.layoutSubviews()
        layoutChanged?()
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        attachmentChanged?(window != nil)
    }
    #elseif os(macOS)
    override func layout() {
        super.layout()
        layoutChanged?()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachmentChanged?(window != nil)
    }
    #endif
}

extension RichContentRenderer: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard webView === self.webView, !generation.isEmpty, awaitingHostCommit else { return }
        awaitingHostCommit = false
        deadline = .now + .seconds(5)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard webView === self.webView, !generation.isEmpty, !navigationAction.shouldPerformDownload else {
            decisionHandler(.cancel); return
        }
        let url = navigationAction.request.url?.absoluteString
        if initialNavigationAllowed && navigationAction.targetFrame?.isMainFrame == true && url == "about:blank" {
            initialNavigationAllowed = false
            decisionHandler(.allow)
        } else if childNavigationAllowed && navigationAction.sourceFrame.isMainFrame &&
                    navigationAction.targetFrame?.isMainFrame == false && url == "about:srcdoc" {
            childNavigationAllowed = false
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView else { return }
        fail("This preview could not load. Source is still available.")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        self.webView(webView, didFail: navigation, withError: error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        fail("Preview stopped. Source is still available.")
    }
}

extension RichContentRenderer: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) { completionHandler() }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) { completionHandler(false) }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) { completionHandler(nil) }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) { decisionHandler(.deny) }

    @available(iOS 18.4, *)
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor ([URL]?) -> Void) { completionHandler(nil) }
}
