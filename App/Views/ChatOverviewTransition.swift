import SwiftUI
import UIKit

/// Owns presentation pixels and geometry, never a conversation or an editor.
@MainActor @Observable final class ChatOverviewTransition: NSObject {
    @ObservationIgnored var viewportProvider: ((String) -> UIView?)?
    @ObservationIgnored var viewportDidChange: (() -> Void)?
    @ObservationIgnored private var openingSnapshot: (id: String, bounds: CGRect, view: UIView)?
    private var cardSnapshot: (id: String, size: CGSize, view: UIView)?
    @ObservationIgnored private var openedID: String?
    @ObservationIgnored private var backdrop: UIView?
    var selectedID: String?
    var allowsAnimation = true
    fileprivate(set) var animatingID: String?
    @ObservationIgnored private var cards: [String: WeakView] = [:]
    @ObservationIgnored private var activeAnimator: UIViewPropertyAnimator?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(reduceMotionChanged),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func prepareOpening(id: String?) {
        openingSnapshot = nil
        openedID = id
        guard !UIAccessibility.isReduceMotionEnabled,
              let id, let viewport = viewportProvider?(id), viewport.window != nil,
              let snapshot = viewport.snapshotView(afterScreenUpdates: false) else { return }
        openingSnapshot = (id, viewport.bounds, snapshot)
    }

    func hasNativePreview(for id: String) -> Bool {
        animatingID == id || cardSnapshot?.id == id
    }

    func discardSnapshot() {
        openingSnapshot = nil; openedID = nil
        cardSnapshot?.view.removeFromSuperview()
        cardSnapshot = nil
        backdrop?.superview?.clipsToBounds = true
        backdrop?.removeFromSuperview()
        backdrop = nil
    }

    func finishImmediately() {
        guard let activeAnimator, activeAnimator.state == .active else { return }
        activeAnimator.stopAnimation(false)
        activeAnimator.finishAnimation(at: .end)
    }

    @objc private func reduceMotionChanged() {
        if UIAccessibility.isReduceMotionEnabled { finishImmediately() }
    }

    fileprivate func register(_ view: UIView, id: String) {
        cards[id] = WeakView(view)
        layoutCardSnapshot()
    }
    fileprivate func unregister(_ view: UIView, id: String) {
        if cards[id]?.value === view { cards[id] = nil }
    }

    fileprivate func layoutCardSnapshot() {
        guard let snapshot = cardSnapshot, let card = cards[snapshot.id]?.value,
              let bounds = Self.croppedViewportBounds(viewportSize: snapshot.size, filling: card.bounds.size) else { return }
        if snapshot.view.superview !== card { card.addSubview(snapshot.view) }
        snapshot.view.bounds = bounds
        snapshot.view.center = card.bounds.center
        let scale = card.bounds.width / bounds.width
        snapshot.view.transform = CGAffineTransform(scaleX: scale, y: scale)
    }

    fileprivate func layout(in container: UIView) {
        guard let backdrop else { return }
        let viewportFrame = selectedID.flatMap { viewportProvider?($0) }.map { $0.convert($0.bounds, to: container) }
        backdrop.frame = container.bounds.union(viewportFrame ?? backdrop.frame)
    }

    fileprivate func animate(overview: UIView, in container: UIView, opening: Bool,
                             completion: @escaping () -> Void) {
        finishImmediately()
        let animatedID = selectedID
        let geometry = geometry(in: container, opening: opening)
        openingSnapshot = nil
        if !opening, cardSnapshot?.id == animatedID {
            cardSnapshot?.view.isHidden = true
        }
        // Cover the scroll-under region too, so the mounted reader cannot ghost behind the proxy.
        let background = backdrop ?? UIView()
        background.backgroundColor = .bottoPaper
        background.isUserInteractionEnabled = false
        container.insertSubview(background, at: 0)
        container.clipsToBounds = false
        backdrop = background
        layout(in: container)
        let proxy = geometry.map { geometry in
            let snapshot = geometry.snapshot
            let proxy = UIView()
            proxy.clipsToBounds = true
            proxy.autoresizesSubviews = false
            proxy.isAccessibilityElement = false
            proxy.isUserInteractionEnabled = false
            proxy.bounds = opening ? geometry.viewportBounds : geometry.cardBounds
            proxy.center = opening ? geometry.viewportFrame.center : geometry.cardFrame.center
            proxy.transform = opening ? .identity : geometry.cardTransform
            proxy.layer.cornerRadius = opening ? 0 : geometry.cardCornerRadius
            snapshot.frame = geometry.viewportBounds
            proxy.addSubview(snapshot)
            container.addSubview(proxy)
            return proxy
        }
        if geometry != nil { animatingID = selectedID }
        overview.alpha = opening ? 0 : 1
        guard allowsAnimation else {
            overview.alpha = opening ? 1 : 0
            proxy?.removeFromSuperview()
            container.backgroundColor = .clear
            animatingID = nil
            completion()
            return
        }
        let animator = UIViewPropertyAnimator(duration: geometry == nil ? 0.12 : 0.4,
            timingParameters: geometry == nil ? UICubicTimingParameters(animationCurve: .easeOut)
                : UISpringTimingParameters(dampingRatio: 1))
        animator.addAnimations {
            overview.alpha = opening ? 1 : 0
            if let geometry, let proxy {
                proxy.bounds = opening ? geometry.cardBounds : geometry.viewportBounds
                proxy.center = opening ? geometry.cardFrame.center : geometry.viewportFrame.center
                proxy.transform = opening ? geometry.cardTransform : .identity
                proxy.layer.cornerRadius = opening ? geometry.cardCornerRadius : 0
            }
        }
        animator.addCompletion { [weak self, weak animator] _ in
            proxy?.removeFromSuperview()
            if opening, let self, let proxy, let geometry, let animatedID {
                self.cardSnapshot = (animatedID, geometry.viewportFrame.size, proxy)
                self.layoutCardSnapshot()
            }
            container.backgroundColor = .clear
            overview.alpha = opening ? 1 : 0
            if self?.activeAnimator === animator {
                self?.activeAnimator = nil
                self?.animatingID = nil
            }
            completion()
        }
        activeAnimator = animator
        animator.startAnimation()
    }

    fileprivate func geometry(in container: UIView, opening: Bool) -> Geometry? {
        guard allowsAnimation, !UIAccessibility.isReduceMotionEnabled,
              let selectedID, let viewport = viewportProvider?(selectedID),
              let card = cards[selectedID]?.value,
              let window = container.window, viewport.window === window, card.window === window else { return nil }
        let viewportFrame = viewport.convert(viewport.bounds, to: container)
        let cardFrame = card.convert(card.bounds, to: container)
        guard Self.valid(viewportFrame), Self.valid(cardFrame),
              container.bounds.intersects(cardFrame), container.bounds.intersects(viewportFrame),
              let cardBounds = Self.croppedViewportBounds(viewportSize: viewportFrame.size, filling: cardFrame.size) else { return nil }
        let snapshot: UIView?
        if opening, let prepared = openingSnapshot, prepared.id == selectedID, prepared.bounds == viewport.bounds {
            snapshot = prepared.view
        } else {
            snapshot = viewport.snapshotView(afterScreenUpdates: !opening && selectedID != openedID)
        }
        guard let snapshot else { return nil }
        return Geometry(snapshot: snapshot, viewportFrame: viewportFrame, cardFrame: cardFrame, cardBounds: cardBounds)
    }

    static func croppedViewportBounds(viewportSize: CGSize, filling size: CGSize) -> CGRect? {
        guard valid(CGRect(origin: .zero, size: viewportSize)),
              valid(CGRect(origin: .zero, size: size)) else { return nil }
        let scale = max(size.width / viewportSize.width, size.height / viewportSize.height)
        return CGRect(x: 0, y: 0, width: size.width / scale, height: size.height / scale)
    }

    private static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && rect.minX.isFinite && rect.minY.isFinite &&
            rect.width.isFinite && rect.height.isFinite && rect.width > 0 && rect.height > 0
    }

    fileprivate struct Geometry {
        let snapshot: UIView
        let viewportFrame: CGRect
        let cardFrame: CGRect
        let cardBounds: CGRect
        var viewportBounds: CGRect { CGRect(origin: .zero, size: viewportFrame.size) }
        var cardTransform: CGAffineTransform {
            let scale = cardFrame.width / cardBounds.width
            return CGAffineTransform(scaleX: scale, y: scale)
        }
        var cardCornerRadius: CGFloat { 12 * cardBounds.width / cardFrame.width }
    }

    private final class WeakView {
        weak var value: UIView?
        init(_ value: UIView) { self.value = value }
    }
}

/// Measures the preview canvas without retaining a lazy grid cell.
struct ChatOverviewCardAnchor: UIViewRepresentable {
    let id: String
    let transition: ChatOverviewTransition

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIView {
        let view = AnchorView()
        view.transition = transition
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.detach(view)
        context.coordinator.id = id
        context.coordinator.transition = transition
        transition.register(view, id: id)
    }
    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) { coordinator.detach(view) }

    private final class AnchorView: UIView {
        weak var transition: ChatOverviewTransition?
        override func layoutSubviews() {
            super.layoutSubviews()
            transition?.layoutCardSnapshot()
        }
    }

    @MainActor final class Coordinator {
        var id: String?
        weak var transition: ChatOverviewTransition?
        func detach(_ view: UIView) {
            if let id { transition?.unregister(view, id: id) }
        }
    }
}

/// The overview occupies only the chat pane; its parent keeps header and editor ownership.
struct ChatOverviewContainer<Content: View>: UIViewControllerRepresentable {
    let isPresented: Bool
    let transition: ChatOverviewTransition
    let onDismiss: () -> Void
    @ViewBuilder let content: () -> Content

    func makeUIViewController(context: Context) -> Controller { Controller(transition: transition) }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.update(isPresented: isPresented, content: content(), onDismiss: onDismiss)
    }
    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) { controller.tearDown() }

    @MainActor final class Controller: UIViewController {
        let transition: ChatOverviewTransition
        private var content: Content?
        private var host: UIHostingController<Content>?
        private var wantsPresentation = false
        private var changingPresentation = false
        private var hasOutstandingRequest = false
        private var reconciliationScheduled = false
        private var dismantled = false
        private var previousBounds: CGRect?
        private var onDismiss: () -> Void = {}

        init(transition: ChatOverviewTransition) {
            self.transition = transition
            super.init(nibName: nil, bundle: nil)
            transition.viewportDidChange = { [weak self] in self?.scheduleReconciliation() }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func loadView() {
            let view = UIView()
            view.backgroundColor = .clear
            view.clipsToBounds = true
            view.isUserInteractionEnabled = false
            self.view = view
        }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            scheduleReconciliation()
        }
        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            if let previousBounds, previousBounds != view.bounds {
                transition.finishImmediately()
            }
            previousBounds = view.bounds
            host?.view.frame = view.bounds
            transition.layout(in: view)
            scheduleReconciliation()
        }

        func update(isPresented: Bool, content: Content, onDismiss: @escaping () -> Void) {
            self.content = content
            self.onDismiss = onDismiss
            wantsPresentation = isPresented
            if isPresented { hasOutstandingRequest = true }
            host?.rootView = content
            scheduleReconciliation()
        }

        private func scheduleReconciliation() {
            guard !reconciliationScheduled, !dismantled else { return }
            reconciliationScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.reconciliationScheduled = false
                self.reconcile()
            }
        }

        private func reconcile() {
            guard !dismantled, !changingPresentation else { return }
            if wantsPresentation {
                guard host == nil, viewIfLoaded?.window != nil,
                      view.bounds.width > 0, view.bounds.height > 0, let content else { return }
                let host = UIHostingController(rootView: content)
                addChild(host)
                host.view.backgroundColor = .bottoPaper
                host.view.clipsToBounds = true
                host.view.frame = view.bounds
                host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                view.addSubview(host.view)
                host.didMove(toParent: self)
                self.host = host
                view.isUserInteractionEnabled = true
                host.view.setNeedsLayout()
                host.view.layoutIfNeeded()
                changingPresentation = true
                transition.animate(overview: host.view, in: view, opening: true) { [weak self, weak host] in
                    guard let self, let host, self.host === host else { return }
                    self.changingPresentation = false
                    self.scheduleReconciliation()
                }
            } else if let host {
                if transition.allowsAnimation, !UIAccessibility.isReduceMotionEnabled,
                   let id = transition.selectedID, transition.viewportProvider?(id) == nil { return }
                changingPresentation = true
                transition.animate(overview: host.view, in: view, opening: false) { [weak self, weak host] in
                    guard let self, let host, self.host === host else { return }
                    self.removeHost()
                    self.changingPresentation = false
                    self.finishClosedRequest()
                    self.scheduleReconciliation()
                }
            } else {
                finishClosedRequest()
            }
        }

        private func removeHost() {
            guard let host else { return }
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
            self.host = nil
            view.isUserInteractionEnabled = false
        }

        private func finishClosedRequest() {
            guard !wantsPresentation, !changingPresentation, host == nil, hasOutstandingRequest else { return }
            hasOutstandingRequest = false
            transition.discardSnapshot()
            onDismiss()
        }

        func tearDown() {
            dismantled = true
            transition.viewportDidChange = nil
            transition.discardSnapshot()
            wantsPresentation = false
            transition.finishImmediately()
            removeHost()
            changingPresentation = false
            finishClosedRequest()
        }
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
