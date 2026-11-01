import SwiftUI
import UIKit
import BottoCore

/// Exact byte identity avoids Swift String's canonical-equivalence coalescing.
enum NativeTranscriptItemID: Hashable {
    case date, message(Data), workDetails(Data), request(UUID), empty, terminal, identityNotice, typing
    case ambiguousMessage(Int), ambiguousRequest(Int)
}
enum NativeTranscriptRowValue: Equatable {
    case message(ChatMessage, working: Bool, streaming: Bool = false)
    case workDetails([ChatMessage])
    case request(PendingRequest, enabled: Bool)
    case empty(NativeTranscriptEmptyDisplay)
    case auxiliary(String)

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.message(a, aw, ast), .message(b, bw, bst)):
            return aw == bw && ast == bst && TranscriptContentRevision.sameMessage(a, b)
        case let (.workDetails(a), .workDetails(b)):
            return a.elementsEqual(b, by: TranscriptContentRevision.sameMessage)
        case let (.request(a, ae), .request(b, be)):
            return ae == be && TranscriptContentRevision.sameRequest(a, b)
        case let (.auxiliary(a), .auxiliary(b)): return TranscriptContentRevision.exact(a, b)
        case let (.empty(a), .empty(b)): return a == b
        default: return false
        }
    }
    func hasSameForegroundContent(as other: Self) -> Bool {
        if case let .message(a, _, _) = self, case let .message(b, _, _) = other {
            return Self.message(a, working: false) == Self.message(b, working: false)
        }
        return self == other
    }

}
/// The empty row compares the same captured inputs that its renderer consumes,
/// including a replacement thumbnail for an otherwise unchanged profile.
struct NativeTranscriptEmptyDisplay: Equatable {
    let profile: BotProfile
    let image: UIImage?
    let opening: Bool
    let connected: Bool
    var presentation: BotAvatarPresentation? = nil
    static func == (lhs: Self, rhs: Self) -> Bool {
        let a = lhs.profile, b = rhs.profile
        func bytes(_ value: String?) -> Data? { value.map { Data($0.utf8) } }
        return lhs.opening == rhs.opening && lhs.connected == rhs.connected && lhs.image === rhs.image &&
            lhs.presentation == rhs.presentation && a == b &&
            [a.id, a.name, a.emoji, a.description, a.preview, a.model, a.appearance?.rawShape,
             a.appearance?.color, a.appearance?.imageKind, a.appearance?.expression].map(bytes) ==
            [b.id, b.name, b.emoji, b.description, b.preview, b.model, b.appearance?.rawShape,
             b.appearance?.color, b.appearance?.imageKind, b.appearance?.expression].map(bytes)
    }
}
struct NativeTranscriptContext: Equatable {
    let workspace: ObjectIdentifier
    let profile: Data
    let chat: ChatID?
    let owner: PresentationOwner?
    let generation: UUID
    let reviewingConnection: Bool
    var dynamicType: DynamicTypeSize = .large
    var colorScheme: ColorScheme = .light
    var direction: LayoutDirection = .leftToRight
    var scenePhase: ScenePhase = .active
    var reduceMotion = false
    var actionRevision: UUID? = nil
    func hasSameAuthority(as other: Self) -> Bool {
        workspace == other.workspace && profile == other.profile && chat == other.chat &&
            owner == other.owner && generation == other.generation && reviewingConnection == other.reviewingConnection
    }

}
struct NativeTranscriptRow {
    let id: NativeTranscriptItemID
    let value: NativeTranscriptRowValue
    var request: RequestCardInput? = nil
    let content: @MainActor (NativeTranscriptRowExposure, ReplyBodyMeasurements) -> AnyView
}

struct NativeTranscript: UIViewControllerRepresentable {
    let context: NativeTranscriptContext
    let snapshot: Conversation?
    let rows: [NativeTranscriptRow]
    let active: Bool
    let currentTaskSnapshot: @MainActor () -> Conversation?
    var admitsAction: @MainActor () -> Bool = { true }
    var preview: NativeTranscriptPreview? = nil
    var topContentInset: CGFloat = 0
    var bottomContentInset: CGFloat = 0
    var searchFocus: SearchMessageFocus?
    var reportSearchFocus: @MainActor (UUID, SearchFocusResult) -> Void = { _, _ in }
    // SwiftUI's representable diff must observe exact row values, not canonical String equality.
    private let displayRevision: [NativeTranscriptRowValue]

    init(context: NativeTranscriptContext, snapshot: Conversation?, rows: [NativeTranscriptRow], active: Bool,
         currentTaskSnapshot: @escaping @MainActor () -> Conversation?,
         admitsAction: @escaping @MainActor () -> Bool = { true },
         preview: NativeTranscriptPreview? = nil, topContentInset: CGFloat = 0, bottomContentInset: CGFloat = 0,
         searchFocus: SearchMessageFocus? = nil,
         reportSearchFocus: @escaping @MainActor (UUID, SearchFocusResult) -> Void = { _, _ in }) {
        self.context = context; self.snapshot = snapshot; self.rows = rows; self.active = active
        self.currentTaskSnapshot = currentTaskSnapshot; self.admitsAction = admitsAction
        self.preview = preview; self.topContentInset = topContentInset; self.bottomContentInset = bottomContentInset
        self.searchFocus = searchFocus; self.reportSearchFocus = reportSearchFocus
        displayRevision = rows.map(\.value)
    }

    func makeUIViewController(context: Context) -> NativeTranscriptController { NativeTranscriptController() }
    func updateUIViewController(_ controller: NativeTranscriptController, context: Context) {
        if let preview { preview.bind(controller) }
        else { controller.previewReceiver?.unbind(controller) }
        controller.updateContentInsets(top: topContentInset, bottom: bottomContentInset)
        controller.apply(self.context, snapshot: snapshot, rows: rows, active: active, currentTaskSnapshot: currentTaskSnapshot, admitsAction: admitsAction,
                         searchFocus: searchFocus, reportSearchFocus: reportSearchFocus)
        preview?.refreshHeader()
        preview?.requestCapture(from: controller)
    }
    static func dismantleUIViewController(_ controller: NativeTranscriptController, coordinator: ()) {
        controller.retire()
    }
}

/// UIKit uses this overlay container to shape the native scroll-edge effect.
struct NativeTranscriptHeader<Content: View>: UIViewControllerRepresentable {
    let preview: NativeTranscriptPreview
    var onActivate: (@MainActor () -> Void)? = nil
    @ViewBuilder let content: () -> Content

    func makeUIViewController(context: Context) -> NativeTranscriptHeaderController {
        NativeTranscriptHeaderController(rootView: AnyView(content().environment(\.self, context.environment)), preview: preview, onActivate: onActivate)
    }
    func updateUIViewController(_ controller: NativeTranscriptHeaderController, context: Context) {
        controller.rootView = AnyView(content().environment(\.self, context.environment))
        controller.onActivate = onActivate
        controller.view.setNeedsLayout()
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiViewController: NativeTranscriptHeaderController, context: Context) -> CGSize? {
        uiViewController.sizeThatFits(in: proposal.replacingUnspecifiedDimensions(by: UIView.layoutFittingExpandedSize))
    }
    static func dismantleUIViewController(_ controller: NativeTranscriptHeaderController, coordinator: ()) {
        controller.retire()
    }
}

final class NativeTranscriptHeaderController: UIHostingController<AnyView> {
    private let preview: NativeTranscriptPreview
    private var scrollEdge: (any UIInteraction)?
    private weak var barContentOwner: UIViewController?
    private weak var barScrollView: UIScrollView?
    var onActivate: (@MainActor () -> Void)?
    private let navigationTarget = UIButton(type: .custom)
    private var retired = false

    init(rootView: AnyView, preview: NativeTranscriptPreview, onActivate: (@MainActor () -> Void)? = nil) {
        self.preview = preview
        self.onActivate = onActivate
        super.init(rootView: rootView)
        safeAreaRegions = []
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        navigationTarget.isAccessibilityElement = false
        navigationTarget.accessibilityElementsHidden = true
        navigationTarget.addAction(UIAction { [weak self] _ in self?.onActivate?() }, for: .touchUpInside)
        if #available(iOS 26, *) {
            let interaction = UIScrollEdgeElementContainerInteraction()
            interaction.edge = .top
            view.addInteraction(interaction)
            scrollEdge = interaction
        }
        preview.bindHeader(self)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateScrollView()
        updateNavigationTarget()
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updateScrollView()
        updateNavigationTarget()
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        navigationTarget.removeFromSuperview()
        releaseBarScrollView()
    }
    private func updateNavigationTarget() {
        // The bar receives touches above the content. Mirror only the header's actual overlap.
        guard !retired, onActivate != nil, let bar = navigationController?.navigationBar,
              let window = view.window, bar.window === window, !bar.isHidden else {
            navigationTarget.removeFromSuperview()
            return
        }
        let overlap = view.convert(view.bounds, to: bar).intersection(bar.bounds)
        guard !overlap.isNull, !overlap.isEmpty else {
            navigationTarget.removeFromSuperview()
            return
        }
        navigationTarget.frame = overlap
        if navigationTarget.superview !== bar { bar.addSubview(navigationTarget) }
        bar.bringSubviewToFront(navigationTarget)
    }
    func retire() {
        retired = true
        onActivate = nil
        navigationTarget.removeFromSuperview()
        releaseBarScrollView()
        if #available(iOS 26, *), let interaction = scrollEdge as? UIScrollEdgeElementContainerInteraction {
            interaction.scrollView = nil
        }
    }
    func updateScrollView() {
        if #available(iOS 26, *), let interaction = scrollEdge as? UIScrollEdgeElementContainerInteraction {
            let scrollView = retired ? nil : preview.viewportView as? UIScrollView
            if interaction.scrollView !== scrollView { interaction.scrollView = scrollView }
            guard !retired, let scrollView, let owner = navigationController?.topViewController,
                  view.window != nil, view.isDescendant(of: owner.view), scrollView.isDescendant(of: owner.view) else {
                releaseBarScrollView()
                return
            }
            if barContentOwner !== owner || barScrollView !== scrollView {
                releaseBarScrollView()
                owner.setContentScrollView(scrollView, for: .top)
                barContentOwner = owner; barScrollView = scrollView
            }
        }
    }

    private func releaseBarScrollView() {
        if let owner = barContentOwner, let scrollView = barScrollView,
           owner.contentScrollView(for: .top) === scrollView {
            owner.setContentScrollView(nil, for: .top)
        }
        barContentOwner = nil; barScrollView = nil
    }
}

@MainActor final class NativeTranscriptPreview {
    struct State: Equatable {
        let owner: PresentationOwner
        let generation: UUID
        let revision: UInt64
        let bounds: CGRect
        let colorScheme: ColorScheme
        let textSize: DynamicTypeSize
    }
    private weak var controller: NativeTranscriptController?
    private weak var header: NativeTranscriptHeaderController?
    func bindHeader(_ header: NativeTranscriptHeaderController) {
        if self.header !== header { self.header?.retire() }
        self.header = header
        refreshHeader()
    }
    func refreshHeader() { header?.updateScrollView() }
    var viewportView: UIView? { controller?.collection }
    func viewportView(for id: String) -> UIView? {
        guard let state = controller?.viewportIdentity, state.owner.chat.value.uuidString == id else { return nil }
        return controller?.collection
    }
    var viewportDidChange: (() -> Void)?
    var hasCurrentViewportCapture: Bool {
        guard let captured, let controller else { return false }
        return captured == controller.viewportIdentity
    }
    private var task: Task<Void, Never>?
    private var pending: State?
    private var captured: State?
    var canCapture: @MainActor () -> Bool = { true }
    var didCapture: (@MainActor (PresentationOwner, UIImage, ColorScheme, DynamicTypeSize) -> Void)?
    #if DEBUG
    private(set) var lastCaptureMilliseconds: Double?
    #endif

    func bind(_ controller: NativeTranscriptController) {
        if controller.previewReceiver !== self { controller.previewReceiver?.unbind(controller) }
        if self.controller !== controller { invalidate(); self.controller = controller }
        controller.previewReceiver = self
    }

    func unbind(_ controller: NativeTranscriptController) {
        guard self.controller === controller else { return }
        invalidate(); self.controller = nil
        refreshHeader()
        viewportDidChange?()
        if controller.previewReceiver === self { controller.previewReceiver = nil }
    }

    func invalidate() { cancel(); captured = nil }
    func cancel() { task?.cancel(); task = nil; pending = nil }
    func cancel(from controller: NativeTranscriptController) {
        if self.controller === controller { cancel() }
    }

    func requestCapture(from controller: NativeTranscriptController) {
        guard self.controller === controller else { return }
        viewportDidChange?()
        guard didCapture != nil, canCapture(), let state = controller.previewState else { cancel(); return }
        guard state != captured, state != pending else { return }
        cancel(); pending = state
        // Coalesce streaming/layout changes. This delay is an idle policy, not a frame budget.
        task = Task { [weak self, weak controller] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard let self else { return }
            defer { if self.pending == state { self.pending = nil; self.task = nil } }
            guard !Task.isCancelled, self.pending == state, let controller,
                  self.canCapture(), self.controller === controller, controller.previewState == state else { return }
            #if DEBUG
            let started = ContinuousClock.now
            #endif
            guard let image = controller.capturePreview(state: state) else { return }
            #if DEBUG
            let elapsed = started.duration(to: .now).components
            self.lastCaptureMilliseconds = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
            #endif
            self.captured = state
            self.didCapture?(state.owner, image, state.colorScheme, state.textSize)
        }
    }
}

@MainActor @Observable private final class NativeTranscriptWidth {
    var value: CGFloat = 1
}
private struct NativeTranscriptHostedRow: View {
    let row: NativeTranscriptRow
    let scope: NativeTranscriptRowExposure
    let history: ReplyBodyMeasurements
    let width: NativeTranscriptWidth
    let searchMatch: NativeSearchMatch?
    var body: some View {
        row.content(scope, history).environment(\.nativeTranscriptRow, scope)
            .environment(\.nativeSearchMatch, searchMatch)
            .tint(BottoTheme.action)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: width.value, alignment: .leading)
            .background(NativeTranscriptRowGeometry(scope: scope))
    }
}

/// Preferred fitting precedes UICollectionView's visible-cell registration.
@MainActor final class NativeTranscriptLayoutAttributes: UICollectionViewLayoutAttributes {
    var fittingPassCount = 0

    override func copy(with zone: NSZone? = nil) -> Any {
        let result = super.copy(with: zone) as! NativeTranscriptLayoutAttributes
        result.fittingPassCount = fittingPassCount
        return result
    }
}

@MainActor class NativeTranscriptCollectionView: UICollectionView {
    override func layoutSubviews() {
        super.layoutSubviews()
        for case let cell as NativeTranscriptCell in visibleCells {
            cell.exposure?.refresh()
        }
    }
}

@MainActor final class NativeTranscriptCell: UICollectionViewCell {
    var exposure: NativeTranscriptRowExposure?
    var isDisplayed = false
    var committedFittingSize: CGSize?
    private var fittingPassCount = 0
    override init(frame: CGRect) {
        super.init(frame: frame)
        #if DEBUG
        TranscriptMeasurements.current?.register(self)
        #endif
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    override func prepareForReuse() {
        isDisplayed = false; committedFittingSize = nil; fittingPassCount = 0
        exposure?.invalidate(); exposure = nil; contentConfiguration = nil
        super.prepareForReuse()
    }
    override func preferredLayoutAttributesFitting(_ attributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        if fittingPassCount < 2 { fittingPassCount += 1 }
        let result = super.preferredLayoutAttributesFitting(attributes)
        // Height comes from UIKit's hosting configuration. Width belongs to the
        // full-width native row proposal, never its unconstrained text ideal.
        result.size.width = attributes.size.width
        (result as? NativeTranscriptLayoutAttributes)?.fittingPassCount = fittingPassCount
        return result
    }
}

/// All offset compensation belongs to native layout invalidation, never didScroll.
@MainActor final class NativeTranscriptLayout: UICollectionViewFlowLayout {
    weak var owner: NativeTranscriptController?
    override class var layoutAttributesClass: AnyClass { NativeTranscriptLayoutAttributes.self }
    override func prepare() {
        if let collectionView {
            let margin = max(20, (collectionView.bounds.width - 740) / 2 + 20)
            let width = max(1, collectionView.bounds.width - margin * 2)
            sectionInset = UIEdgeInsets(top: 12, left: margin, bottom: 14, right: margin)
            owner?.proposeRowWidth(width)
            if estimatedItemSize.width != width { estimatedItemSize = CGSize(width: width, height: 100) }
        }
        super.prepare()
    }
    override func shouldInvalidateLayout(forPreferredLayoutAttributes preferred: UICollectionViewLayoutAttributes,
                                         withOriginalAttributes original: UICollectionViewLayoutAttributes) -> Bool {
        abs(preferred.size.width - original.size.width) > 0.001 ||
            abs(preferred.size.height - original.size.height) > 0.001
    }
    override func invalidationContext(forPreferredLayoutAttributes preferred: UICollectionViewLayoutAttributes,
                                     withOriginalAttributes original: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutInvalidationContext {
        let context = super.invalidationContext(forPreferredLayoutAttributes: preferred, withOriginalAttributes: original)
        let delta = preferred.size.height - original.size.height
        if abs(delta) > 0.001, let owner {
            let adjustment = owner.offsetAdjustment(original: original, heightDelta: delta,
                isInitialFitting: (preferred as? NativeTranscriptLayoutAttributes)?.fittingPassCount == 1)
            context.contentOffsetAdjustment.y += adjustment
            if adjustment != 0, let collectionView, collectionView.isDragging || collectionView.isDecelerating {
                // Pair a newly visible estimate's extent with drag compensation;
                // stale bounds can clamp scrolling and recreate visible rows.
                context.contentSizeAdjustment.height = delta
            }
        }
        return context
    }
    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.size != collectionView?.bounds.size || super.shouldInvalidateLayout(forBoundsChange: newBounds)
    }
}

@MainActor final class NativeTranscriptController: UIViewController, UICollectionViewDelegate, UIAdaptivePresentationControllerDelegate {
    weak var previewReceiver: NativeTranscriptPreview?
    fileprivate var viewportIdentity: NativeTranscriptPreview.State? {
        guard committed, let context, let owner = context.owner, isViewLoaded else { return nil }
        return .init(owner: owner, generation: context.generation, revision: revision,
                     bounds: collection.bounds, colorScheme: context.colorScheme, textSize: context.dynamicType)
    }
    var previewState: NativeTranscriptPreview.State? {
        guard active, isViewLoaded,
              let window = view.window, window.isKeyWindow, transitionCoordinator == nil,
              snapshot?.isWorking != true, !collection.isTracking, !collection.isDragging,
              !collection.isDecelerating, collection.bounds.width > 0, collection.bounds.height > 0,
              window.keyboardLayoutGuide.layoutFrame.height <= window.safeAreaInsets.bottom + 1 else { return nil }
        return viewportIdentity
    }

    func capturePreview(state: NativeTranscriptPreview.State) -> UIImage? {
        guard previewState == state else { return nil }
        let scale = min(1, 300 / collection.bounds.width, 560 / collection.bounds.height)
        let size = CGSize(width: collection.bounds.width * scale, height: collection.bounds.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = true
        var captured = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            UIColor.bottoPaper.resolvedColor(with: collection.traitCollection).setFill()
            renderer.fill(CGRect(origin: .zero, size: size))
            renderer.cgContext.scaleBy(x: scale, y: scale)
            captured = collection.drawHierarchy(in: CGRect(origin: .zero, size: collection.bounds.size), afterScreenUpdates: false)
        }
        return captured ? image : nil
    }
    private enum Section { case transcript }
    private(set) var collection: UICollectionView!
    #if DEBUG
    private var scrollTrace: InteractionFrameTrace?
    private var performanceStreamRelease: Task<Void, Never>?
    private var performanceStreamReleaseID: UUID?
    #endif
    private var source: UICollectionViewDiffableDataSource<Section, NativeTranscriptItemID>!
    private var context: NativeTranscriptContext?
    private var snapshot: Conversation?
    private var currentTaskSnapshot: @MainActor () -> Conversation? = { nil }
    private var rows: [NativeTranscriptRow] = []
    private var lookup: [NativeTranscriptItemID: NativeTranscriptRow] = [:]
    // Dimensions only; no cell/host/renderer/document survives recycling here.
    private var measurements: [NativeTranscriptItemID: ReplyBodyMeasurements] = [:]
    private let scopes = NSHashTable<NativeTranscriptRowExposure>.weakObjects()
    private var rowAuthorities: [NativeTranscriptItemID: NativeTranscriptRowAuthority] = [:]
    private var requestStates: [NativeTranscriptItemID: RequestCardLifetime] = [:]
    private var requestConfirmation: RequestCardConfirmation?
    private var requestAlert: UIAlertController?
    private var reportRequestModal: (@MainActor (UUID, Bool) -> Void)?
    private let foreground = NativeTranscriptPresentation()
    private var applicationSequence: UInt64 = 0
    private var revision: UInt64 = 0
    private var active = false
    private var committed = false
    private var actionAdmission: @MainActor () -> Bool = { false }
    private var scrollPolicy = TranscriptScrollPolicy()
    var followsLatest: Bool { scrollPolicy.followsLatest }
    private enum ViewportTarget { case end, reading(Landmark?, fallback: CGPoint), search }
    private var searchFocus: SearchMessageFocus?
    private var displayedSearchID: UUID?
    private var reportSearchFocus: @MainActor (UUID, SearchFocusResult) -> Void = { _, _ in }
    private var pendingSearch = false
    private var positioningSearch = false
    private var scheduledSearch = false
    private var viewportTarget = ViewportTarget.end
    private var positionedContent = false
    private var quietHeld = false
    private var permitsLayoutAttention = true
    private var interruptedReaderScroll = false
    private var previousSize = CGSize.zero
    private let rowWidth = NativeTranscriptWidth()
    private var readingLandmark: Landmark? {
        if case let .reading(anchor, _) = viewportTarget { return anchor }
        return nil
    }
    private var targetsEnd: Bool { if case .end = viewportTarget { return true }; return false }
    private let latest = UIButton(type: .system)
    private var latestBottom: NSLayoutConstraint?
    private var contentInsetsChanged = false

    func updateContentInsets(top: CGFloat, bottom: CGFloat) {
        loadViewIfNeeded()
        guard abs(collection.contentInset.top - top) > 0.5 || abs(collection.contentInset.bottom - bottom) > 0.5 else { return }
        collection.contentInset.top = top
        collection.contentInset.bottom = bottom
        collection.verticalScrollIndicatorInsets.top = top
        collection.verticalScrollIndicatorInsets.bottom = bottom
        latestBottom?.constant = -bottom - 8
        contentInsetsChanged = true
        view.setNeedsLayout()
    }
    private struct Landmark {
        let item: NativeTranscriptItemID
        let block: Int?
        let role: NativeTranscriptMarkerRole?
        let y: CGFloat
        weak var marker: UIView?
    }

    override func loadView() {
        let layout = NativeTranscriptLayout(); layout.minimumLineSpacing = 14; layout.owner = self
        #if DEBUG
        let collection: UICollectionView
        if NativeTranscriptGeometryCollectionView.isEnabled {
            collection = NativeTranscriptGeometryCollectionView(frame: .zero, collectionViewLayout: layout,
                itemIdentifier: { [weak self] in self?.source?.itemIdentifier(for: $0) },
                modelRevision: { [weak self] in self?.applicationSequence })
        } else {
            collection = NativeTranscriptCollectionView(frame: .zero, collectionViewLayout: layout)
        }
        #else
        let collection = NativeTranscriptCollectionView(frame: .zero, collectionViewLayout: layout)
        #endif
        collection.backgroundColor = .bottoPaper; collection.alwaysBounceVertical = true
        if #available(iOS 26, *) { collection.topEdgeEffect.style = .soft }
        collection.keyboardDismissMode = .interactive; collection.delegate = self
        collection.selfSizingInvalidation = .enabledIncludingConstraints
        collection.accessibilityIdentifier = "chat-transcript"
        collection.register(NativeTranscriptCell.self, forCellWithReuseIdentifier: "message")
        self.collection = collection
        #if DEBUG
        scrollTrace = InteractionFrameTrace.make(viewport: collection)
        #endif
        view = UIView(); view.backgroundColor = .clear; view.tintColor = UIColor(resource: .accent)
        collection.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(collection)
        NSLayoutConstraint.activate([collection.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collection.trailingAnchor.constraint(equalTo: view.trailingAnchor), collection.topAnchor.constraint(equalTo: view.topAnchor),
            collection.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        setContentScrollView(collection, for: .top)
        source = UICollectionViewDiffableDataSource<Section, NativeTranscriptItemID>(collectionView: collection) { [weak self] collection, index, id in
            guard let self, let row = self.lookup[id] else { return nil }
            let cell = collection.dequeueReusableCell(withReuseIdentifier: "message", for: index) as! NativeTranscriptCell
            self.prepare(cell, for: row)
            return cell
        }
        latest.accessibilityLabel = "Latest messages"
        latest.addTarget(self, action: #selector(requestLatest), for: .touchUpInside)
        latest.translatesAutoresizingMaskIntoConstraints = false; latest.isHidden = true; view.addSubview(latest)
        let latestBottom = latest.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8)
        self.latestBottom = latestBottom
        NSLayoutConstraint.activate([latest.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            latestBottom,
            latest.widthAnchor.constraint(equalTo: latest.heightAnchor),
            latest.widthAnchor.constraint(greaterThanOrEqualToConstant: 44), latest.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)])
        registerForTraitChanges([UITraitAccessibilityContrast.self]) { (controller: NativeTranscriptController, _: UITraitCollection) in
            if let context = controller.context { controller.updateLatestAppearance(context) }
        }
    }

    func apply(_ next: NativeTranscriptContext, snapshot nextSnapshot: Conversation?, rows nextRows: [NativeTranscriptRow], active: Bool,
               currentTaskSnapshot: @escaping @MainActor () -> Conversation?,
               admitsAction: @escaping @MainActor () -> Bool = { true },
               searchFocus nextFocus: SearchMessageFocus? = nil,
               reportSearchFocus: @escaping @MainActor (UUID, SearchFocusResult) -> Void = { _, _ in }) {
        loadViewIfNeeded()
        #if DEBUG
        scrollTrace?.working = nextSnapshot?.isWorking == true
        if active {
            InteractionFrameTrace.bindAccessibilitySink(collection)
        } else {
            scrollTrace?.finish()
            performanceStreamRelease?.cancel()
            performanceStreamRelease = nil
            performanceStreamReleaseID = nil
        }
        #endif
        applicationSequence &+= 1
        let applyingSequence = applicationSequence
        self.currentTaskSnapshot = currentTaskSnapshot
        let focusChanged = displayedSearchID != nextFocus?.id
        displayedSearchID = nextFocus?.id
        self.reportSearchFocus = reportSearchFocus
        if focusChanged {
            searchFocus = nextFocus
            pendingSearch = nextFocus?.needsReveal == true
            if nextFocus == nil, case .search = viewportTarget {
                viewportTarget = .reading(captureLandmark(), fallback: collection.contentOffset)
            }
            if nextFocus == nil, case .search? = readingLandmark?.role {
                viewportTarget = .reading(captureLandmark(), fallback: collection.contentOffset)
            }
        }
        let taskChanged = context?.workspace != next.workspace || context?.profile != next.profile || context?.chat != next.chat
        let contentChanged = !TranscriptContentRevision.sameSnapshotContent(snapshot, nextSnapshot)
        let followsChange = scrollPolicy.snapshotChanged(from: snapshot, to: nextSnapshot)
        let hasContent = nextRows.contains { row in
            switch row.id { case .message, .workDetails, .ambiguousMessage, .request, .ambiguousRequest: true; default: false }
        }
        if taskChanged {
            scrollPolicy = TranscriptScrollPolicy(); positionedContent = false
            viewportTarget = .end; quietHeld = false; permitsLayoutAttention = true
        }
        if !positionedContent && hasContent {
            viewportTarget = .end; positionedContent = true; quietHeld = false
        } else if followsChange && !taskChanged {
            viewportTarget = .end; quietHeld = false; permitsLayoutAttention = true
        } else if contentChanged && !taskChanged {
            viewportTarget = .reading(readingLandmark ?? captureLandmark(), fallback: collection.contentOffset)
            // Attention policy is the authority: a quiet append does not change
            // its attention sequence, even beside an unchanged pending request.
            quietHeld = !TranscriptScrollPolicy.attentionChanged(from: snapshot, to: nextSnapshot)
            permitsLayoutAttention = !quietHeld
        }
        if let context, context != next, !taskChanged {
            permitsLayoutAttention = false; clearFittingBaselines()
        }
        if pendingSearch {
            scrollPolicy.requestHistoricalPosition()
            viewportTarget = .search
        }
        self.snapshot = nextSnapshot
        updateLatestAppearance(next)
        let authorityChanged = context != next
        let changed = nextRows.filter { nextRow in
            authorityChanged || focusChanged || lookup[nextRow.id]?.value != nextRow.value
        }.map(\.id)
        let structural = rows.map(\.id) != nextRows.map(\.id)
        let unchanged = !authorityChanged && !structural && changed.isEmpty
        // Refresh display policy even when the hosted rows stay intact. For a
        // replacement, fence old scopes before installing its new policy below.
        if unchanged { actionAdmission = admitsAction }
        let incomingByID = Dictionary(uniqueKeysWithValues: nextRows.map { ($0.id, $0) })
        let sameAuthority = context.map { $0.hasSameAuthority(as: next) } ?? false
        for (id, state) in requestStates {
            if incomingByID[id]?.request.map({ state.input.matches($0) }) != true || !state.isCurrent {
                state.invalidate(); requestStates.removeValue(forKey: id)
            }
        }
        if requestConfirmation?.isCurrent == false, let alert = requestAlert { finishRequestConfirmation(alert, dismiss: true) }
        // Releasing coverage can synchronously apply a newer presentation.
        guard applicationSequence == applyingSequence else { return }
        // Foreground lifetime follows the exact unique row, not its reusable
        // host, environment or working-state projection.
        let messageIndex = TranscriptMessageIndex(nextSnapshot)
        for (id, token) in rowAuthorities {
            guard sameAuthority, let old = lookup[id], let incoming = incomingByID[id],
                  old.value.hasSameForegroundContent(as: incoming.value),
                  rawMessageIsCurrent(incoming, index: messageIndex, snapshot: nextSnapshot) else { token.invalidate(); continue }
        }
        rowAuthorities = rowAuthorities.filter { $0.value.isCurrent }
        foreground.reconcile(environment: next)
        guard applicationSequence == applyingSequence else { return }
        let becameCovered = self.active && !active
        self.active = active
        if becameCovered, pendingSearch {
            cancelSearchPosition()
            guard applicationSequence == applyingSequence else { return }
        }
        for scope in scopes.allObjects { scope.setActive(active && committed) }
        if unchanged {
            settleViewport()
            updateLatest()
            return
        }
        // Reconfigured hosts may briefly occupy estimated positions. Their
        // presence cannot admit file/document work before this native snapshot
        // has laid out and restored the user's reading landmark.
        committed = false
        scopes.allObjects.forEach { $0.setActive(false) }
        revision &+= 1; let applying = revision
        if authorityChanged {
            for scope in scopes.allObjects { scope.invalidate() }
        }
        actionAdmission = admitsAction
        // A conversation replacement discards dimensions; authority refresh in
        // the SAME task does not. Renderer authority still changes below it.
        if context?.workspace != next.workspace || context?.profile != next.profile || context?.chat != next.chat {
            measurements.removeAll(); committed = false
        }
        context = next; rows = nextRows; lookup = Dictionary(uniqueKeysWithValues: nextRows.map { ($0.id, $0) })
        measurements = measurements.filter { lookup[$0.key] != nil }
        var snapshot = NSDiffableDataSourceSnapshot<Section, NativeTranscriptItemID>()
        snapshot.appendSections([.transcript]); snapshot.appendItems(nextRows.map(\.id))
        let existing = Set(source.snapshot().itemIdentifiers)
        snapshot.reconfigureItems(changed.filter { existing.contains($0) })
        source.apply(snapshot, animatingDifferences: false) { [weak self] in
            guard let self, self.revision == applying else { return }
            self.collection.layoutIfNeeded()
            self.settleViewport()
            self.committed = true
            self.recordFittingBaselines()
            self.scopes.allObjects.forEach { $0.setActive(self.active) }
            self.refreshExposure(); self.updateLatest()
            self.previewReceiver?.requestCapture(from: self)
        }
    }
    private func rawMessageIsCurrent(_ row: NativeTranscriptRow, index: TranscriptMessageIndex, snapshot: Conversation?) -> Bool {
        if case let .workDetails(messages) = row.value {
            return messages.first.map { row.id == .workDetails(Data($0.id.utf8)) } == true && messages.allSatisfy(index.matches) && currentWorkDetailsGroup(messages, in: snapshot)
        }
        if case let .message(message, _, _) = row.value {
            return row.id == .message(Data(message.id.utf8)) && index.matches(message)
        }
        if case let .message(id) = row.id { return index.containsVisible(id) }
        return true
    }
    private func rawMessageIsCurrent(_ row: NativeTranscriptRow, in snapshot: Conversation?) -> Bool {
        if case let .workDetails(messages) = row.value {
            let index = TranscriptMessageIndex(snapshot)
            return messages.first.map { row.id == .workDetails(Data($0.id.utf8)) } == true &&
                messages.allSatisfy(index.matches) && currentWorkDetailsGroup(messages, in: snapshot)
        }
        if case let .message(message, _, _) = row.value {
            return row.id == .message(Data(message.id.utf8)) && TranscriptContentRevision.uniqueMessage(message, in: snapshot)
        }
        if case let .message(id) = row.id {
            let matches = snapshot?.messages.lazy.filter { Data($0.id.utf8) == id }
            return matches?.count == 1 && matches?.first?.isVisible == true
        }
        return true
    }
    private func currentWorkDetailsGroup(_ messages: [ChatMessage], in snapshot: Conversation?) -> Bool {
        NativeTranscriptMessagePlan(snapshot?.messages ?? []).displayRows.contains { row in
            guard case let .workDetails(current) = row else { return false }
            return current.elementsEqual(messages, by: TranscriptContentRevision.sameMessage)
        }
    }
    private func document(_ document: WorkDetailsDocument, matches row: NativeTranscriptRow) -> Bool {
        switch row.value {
        case let .workDetails(messages):
            return messages.elementsEqual(document.messages, by: TranscriptContentRevision.sameMessage)
        case let .message(message, _, _):
            return document.messages.count == 1 && TranscriptContentRevision.sameMessage(message, document.messages[0])
        default: return false
        }
    }
    private func rowActionsAreCurrent(_ row: NativeTranscriptRow, in snapshot: Conversation?) -> Bool {
        if case .message = row.id {
            guard case .message = row.value else { return false }
        }
        if case .workDetails = row.id {
            guard case .workDetails = row.value else { return false }
        }
        return rawMessageIsCurrent(row, in: snapshot)
    }
    func prepare(_ cell: NativeTranscriptCell, for row: NativeTranscriptRow) {
        cell.exposure?.invalidate(); cell.committedFittingSize = nil
        let scope = NativeTranscriptRowExposure(viewport: collection)
        scope.searchGeometryChanged = { [weak self] in self?.scheduleSearchPosition() }
        scope.actionAdmission = { [weak self] in
            guard let self, self.actionAdmission() else { return false }
            return self.rowActionsAreCurrent(row, in: self.currentTaskSnapshot())
        }
        if case .message = row.id {
            if case .message = row.value { scope.admitsContent = true }
            else { scope.admitsContent = false }
        }
        if case .workDetails = row.id { scope.admitsContent = false }
        cell.exposure = scope
        scopes.add(scope)
        let authority = rowAuthorities[row.id] ?? NativeTranscriptRowAuthority()
        rowAuthorities[row.id] = authority
        if !rawMessageIsCurrent(row, in: snapshot) { authority.invalidate() }
        scope.authority = authority
        if let input = row.request {
            let state = requestStates[row.id] ?? RequestCardLifetime(input)
            requestStates[row.id] = state; scope.requestState = state
            scope.presentRequestConfirmation = { [weak self, weak scope] confirmation, report in
                guard let self, let scope, scope.canPresent, confirmation.isCurrent else {
                    confirmation.cancel(); return
                }
                self.presentRequest(confirmation, report: report)
            }
        }
        scope.presentRichReply = { [weak self, weak scope, weak authority] block, rich, mode, report in
            guard let self, let scope, scope.canPresent, self.active, self.committed,
                  self.requestConfirmation == nil, self.requestAlert == nil,
                  let authority, authority.isCurrent, let context = self.context,
                  let current = self.lookup[row.id], self.rowActionsAreCurrent(current, in: self.currentTaskSnapshot()) else { return }
            self.foreground.open(block: block, context: rich, authority: authority, mode: mode,
                                 environment: context, report: report, from: self)
        }
        scope.presentWorkDetails = { [weak self, weak scope, weak authority] document, report in
            guard let self, let scope, scope.canPresent, self.active, self.committed,
                  self.requestConfirmation == nil, self.requestAlert == nil,
                  let authority, authority.isCurrent, let context = self.context,
                  let current = self.lookup[row.id], self.document(document, matches: current),
                  self.rowActionsAreCurrent(current, in: self.currentTaskSnapshot()) else { return }
            self.foreground.openDetails(document, authority: authority, environment: context, isCurrent: { [weak self, weak authority] in
                guard let self, authority?.isCurrent == true else { return false }
                return self.rowActionsAreCurrent(current, in: self.currentTaskSnapshot())
            }, report: report, from: self)
        }
        let history = measurements[row.id] ?? ReplyBodyMeasurements(); measurements[row.id] = history
        cell.contentConfiguration = UIHostingConfiguration {
            NativeTranscriptHostedRow(row: row, scope: scope, history: history, width: rowWidth,
                searchMatch: searchFocus.flatMap { row.id == .message(Data($0.message.id.utf8)) ? NativeSearchMatch(id: $0.id, query: $0.query) : nil })
        }.margins(.all, 0)
        cell.backgroundColor = .clear
        scope.setActive(active && committed)
        scope.setDisplayed(cell.isDisplayed)
    }
    func retire() {
        previewReceiver?.unbind(self)
        pendingSearch = false; searchFocus = nil
        #if DEBUG
        performanceStreamRelease?.cancel()
        performanceStreamRelease = nil
        performanceStreamReleaseID = nil
        scrollTrace?.finish()
        if let collection { InteractionFrameTrace.unbindAccessibilitySink(collection) }
        #endif
        applicationSequence &+= 1
        actionAdmission = { false }; currentTaskSnapshot = { nil }; snapshot = nil
        revision &+= 1; active = false; committed = false
        scopes.allObjects.forEach { $0.invalidate() }; scopes.removeAllObjects()
        rowAuthorities.values.forEach { $0.invalidate() }; rowAuthorities.removeAll()
        requestStates.values.forEach { $0.invalidate() }; requestStates.removeAll()
        if let alert = requestAlert { finishRequestConfirmation(alert, dismiss: true) }
        foreground.retire()
        lookup.removeAll(); measurements.removeAll()
    }
    private func presentRequest(_ confirmation: RequestCardConfirmation, report: @escaping @MainActor (UUID, Bool) -> Void) {
        guard requestAlert == nil, requestConfirmation == nil, !foreground.isPresenting, presentedViewController == nil, viewIfLoaded?.window != nil else { confirmation.cancel(); return }
        let alert = UIAlertController(title: "Allow future actions?",
            message: "This choice can let Hermes run matching actions again without asking you. Only continue if you trust the scope described in this request.",
            preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: confirmation.choice.label, style: .default) { [weak self, weak alert] _ in
            confirmation.confirm()
            if let alert { self?.finishRequestConfirmation(alert, dismiss: false) }
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self, weak alert] _ in
            if let alert { self?.finishRequestConfirmation(alert, dismiss: false) }
        })
        if let popover = alert.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.maxY, width: 1, height: 1)
        }
        requestConfirmation = confirmation; requestAlert = alert; reportRequestModal = report
        report(confirmation.modalID, true)
        guard requestAlert === alert, confirmation.isCurrent else {
            finishRequestConfirmation(alert, dismiss: true); return
        }
        present(alert, animated: true)
        alert.presentationController?.delegate = self
    }
    private func finishRequestConfirmation(_ alert: UIAlertController, dismiss: Bool) {
        guard requestAlert === alert, let confirmation = requestConfirmation else { return }
        let report = reportRequestModal
        requestConfirmation = nil; requestAlert = nil; reportRequestModal = nil
        confirmation.cancel(); report?(confirmation.modalID, false)
        if dismiss { alert.dismiss(animated: false) }
    }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        if let alert = requestAlert, alert.presentationController === presentationController {
            finishRequestConfirmation(alert, dismiss: false)
        }
    }
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard let cell = cell as? NativeTranscriptCell else { return }
        cell.isDisplayed = true
        cell.exposure?.setActive(active && committed)
        cell.exposure?.setDisplayed(true)
    }
    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        (cell as? NativeTranscriptCell)?.isDisplayed = false
        (cell as? NativeTranscriptCell)?.exposure?.setDisplayed(false)
    }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        previewReceiver?.cancel(from: self)
        cancelSearchPosition()
        #if DEBUG
        scrollTrace?.begin()
        if PerformanceStreamGate.mode == "scroll", let ticket = PerformanceStreamGate.pending,
           performanceStreamRelease == nil {
            let releaseID = UUID()
            performanceStreamReleaseID = releaseID
            performanceStreamRelease = Task { [weak self] in
                defer {
                    if self?.performanceStreamReleaseID == releaseID {
                        self?.performanceStreamRelease = nil
                        self?.performanceStreamReleaseID = nil
                    }
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard !Task.isCancelled else { return }
                PerformanceStreamGate.release(ticket)
            }
        }
        #endif
        interruptedReaderScroll = false
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if !interruptedReaderScroll && (scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating) {
            recordReaderIntent(scrolling: true)
        }
        #if DEBUG
        TranscriptMeasurements.current?.followsLatest = followsLatest
        #endif
        refreshExposure(); updateLatest()
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        #if DEBUG
        if !decelerate { scrollTrace?.finish() }
        #endif
        if !interruptedReaderScroll { recordReaderIntent(scrolling: decelerate) }
        updateLatest()
        if !decelerate { previewReceiver?.requestCapture(from: self) }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        #if DEBUG
        scrollTrace?.finish()
        #endif
        if !interruptedReaderScroll { recordReaderIntent(scrolling: false) }
        updateLatest()
        previewReceiver?.requestCapture(from: self)
    }
    private func recordReaderIntent(scrolling: Bool) {
        scrollPolicy.readerChanged(isUserScrolling: scrolling, isNearBottom: nearBottom)
        if nearBottom && !quietHeld { viewportTarget = .end }
        else { viewportTarget = .reading(captureLandmark(), fallback: collection.contentOffset) }
        if !scrolling { recordFittingBaselines() }
    }
    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        if previousSize != .zero && previousSize != view.bounds.size {
            permitsLayoutAttention = false; clearFittingBaselines()
        }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let resized = previousSize != view.bounds.size; previousSize = view.bounds.size
        let insetChanged = contentInsetsChanged; contentInsetsChanged = false
        if resized || insetChanged {
            collection.layoutIfNeeded()
            settleViewport()
        }
        refreshExposure()
        previewReceiver?.requestCapture(from: self)
    }
    private func settleViewport() {
        guard !collection.isTracking, !collection.isDragging, !collection.isDecelerating else { return }
        switch viewportTarget {
        case .end: if scrollPolicy.shouldFollowLatest { scrollToTerminal() }
        case .search: positionSearchMatch()
        case let .reading(anchor, fallback):
            if let anchor, restore(anchor) { return }
            setClampedOffset(fallback)
        }
    }
    private func scheduleSearchPosition() {
        guard pendingSearch, !scheduledSearch else { return }
        scheduledSearch = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.scheduledSearch = false
            self.positionSearchMatch()
        }
    }

    private func positionSearchMatch() {
        guard pendingSearch, !positioningSearch, active, let focus = searchFocus,
              let context, context.workspace == focus.workspace, context.owner == focus.owner,
              context.profile == focus.identity.profile.bytes, !context.reviewingConnection,
              collection.window != nil, collection.bounds.height > 0, collection.bounds.width > 0,
              !collection.isTracking, !collection.isDragging, !collection.isDecelerating else { return }
        guard TranscriptMessageIndex(currentTaskSnapshot()).matches(focus.message) else {
            pendingSearch = false; searchFocus = nil
            viewportTarget = .reading(captureLandmark(), fallback: collection.contentOffset)
            reportSearchFocus(focus.id, .unavailable)
            return
        }
        let item = NativeTranscriptItemID.message(Data(focus.message.id.utf8))
        guard let index = source.indexPath(for: item) else { return }
        positioningSearch = true
        defer { positioningSearch = false }
        if collection.cellForItem(at: index) == nil {
            collection.scrollToItem(at: index, at: .top, animated: false)
            collection.layoutIfNeeded()
        }
        guard let scope = (collection.cellForItem(at: index) as? NativeTranscriptCell)?.exposure,
              let hit = scope.firstSearchMarker(id: focus.id) else { return }
        // Code owns an inner horizontal scroll view; reveal its real glyph range
        // before positioning the outer transcript on the same native marker.
        var ancestor = hit.marker.superview
        while let view = ancestor, view !== collection {
            if let scroll = view as? UIScrollView, scroll.contentSize.width > scroll.bounds.width + 1 {
                scroll.scrollRectToVisible(hit.marker.convert(hit.marker.bounds, to: scroll), animated: false)
                scroll.layoutIfNeeded()
            }
            ancestor = view.superview
        }
        let position = hit.marker.convert(hit.marker.bounds, to: collection)
        setClampedOffset(CGPoint(x: collection.contentOffset.x,
            y: position.minY - collection.adjustedContentInset.top - 24))
        collection.layoutIfNeeded()
        guard pendingSearch, searchFocus?.id == focus.id,
              TranscriptMessageIndex(currentTaskSnapshot()).matches(focus.message),
              let window = collection.window, hit.marker.window === window else { return }
        var visible = hit.marker.convert(hit.marker.bounds, to: window)
        ancestor = hit.marker.superview
        while let view = ancestor {
            guard !view.isHidden, view.alpha > 0 else { return }
            if view.clipsToBounds { visible = visible.intersection(view.convert(view.bounds, to: window)) }
            ancestor = view.superview
        }
        let viewport = collection.bounds.inset(by: collection.adjustedContentInset)
        visible = visible.intersection(collection.convert(viewport, to: window)).intersection(window.bounds)
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return }
        let y = hit.marker.convert(hit.marker.bounds, to: collection).minY - collection.bounds.minY
        viewportTarget = .reading(.init(item: item, block: hit.block, role: .search(focus.id), y: y, marker: hit.marker),
                                  fallback: collection.contentOffset)
        pendingSearch = false
        reportSearchFocus(focus.id, .revealed)
        UIAccessibility.post(notification: .announcement, argument: "Search match")
    }

    private func cancelSearchPosition() {
        guard let focus = searchFocus else { return }
        pendingSearch = false; searchFocus = nil
        viewportTarget = .reading(captureLandmark(), fallback: collection.contentOffset)
        reportSearchFocus(focus.id, .cancelled)
    }
    private func setClampedOffset(_ point: CGPoint) {
        let lower = -collection.adjustedContentInset.top
        let upper = max(lower, collection.contentSize.height - collection.bounds.height + collection.adjustedContentInset.bottom)
        collection.setContentOffset(CGPoint(x: point.x, y: min(upper, max(lower, point.y))), animated: false)
    }
    private func clearFittingBaselines() {
        collection.visibleCells.forEach { ($0 as? NativeTranscriptCell)?.committedFittingSize = nil }
    }
    private func recordFittingBaselines() {
        for case let cell as NativeTranscriptCell in collection.visibleCells {
            if let root = cell.exposure?.rowGeometry, abs(root.bounds.height - cell.bounds.height) < 1 {
                cell.committedFittingSize = cell.bounds.size
            }
        }
    }
    private func recordOrdinaryGrowth(_ original: UICollectionViewLayoutAttributes, delta: CGFloat) {
        guard committed, !quietHeld, permitsLayoutAttention, !scrollPolicy.followsLatest, delta > 0.001,
              !collection.hasUncommittedUpdates, !collection.isDragging, !collection.isDecelerating,
              case .message = source.itemIdentifier(for: original.indexPath),
              let cell = collection.cellForItem(at: original.indexPath) as? NativeTranscriptCell,
              let baseline = cell.committedFittingSize,
              abs(baseline.width - original.size.width) < 1, abs(baseline.height - original.size.height) < 1,
              snapshot?.messages.last?.requiresAttention == true else { return }
        if let id = source.itemIdentifier(for: original.indexPath), case let .message(message, _, _) = lookup[id]?.value,
           !message.requiresAttention { return }
        _ = scrollPolicy.snapshotChanged()
        updateLatest()
    }
    var nearBottom: Bool {
        collection.contentSize.height + collection.adjustedContentInset.bottom - collection.bounds.maxY <= 40
    }
    func proposeRowWidth(_ width: CGFloat) {
        if rowWidth.value != width {
            if rowWidth.value > 1 { permitsLayoutAttention = false; clearFittingBaselines() }
            rowWidth.value = width
        }
    }
    func offsetAdjustment(original: UICollectionViewLayoutAttributes, heightDelta: CGFloat, isInitialFitting: Bool = false) -> CGFloat {
        if collection.isDragging || collection.isDecelerating {
            // Resolve a newly visible estimate without moving the rows already under the finger.
            guard original.frame.minY < collection.bounds.minY,
                  isInitialFitting,
                  let layout = collection.collectionViewLayout as? NativeTranscriptLayout,
                  abs(original.size.height - layout.estimatedItemSize.height) < 0.001 else { return 0 }
            return heightDelta
        }
        recordOrdinaryGrowth(original, delta: heightDelta)
        if targetsEnd && scrollPolicy.shouldFollowLatest { return heightDelta }
        if let anchor = readingLandmark, anchor.item == source.itemIdentifier(for: original.indexPath),
           let scope = (collection.cellForItem(at: original.indexPath) as? NativeTranscriptCell)?.exposure,
           let block = anchor.block,
           let marker = scope.marker(for: block, role: anchor.role ?? .content),
           let localY = scope.blockOffsetInPreferredRow(marker) {
            // Use the owned row's preferred coordinates. Its temporary UIKit
            // placement can be centered inside the old allocation during fitting.
            return original.frame.minY + localY - collection.bounds.minY - anchor.y
        }
        return original.frame.maxY <= collection.bounds.minY ? heightDelta : 0
    }
    private func refreshExposure() {
        collection.visibleCells.forEach { ($0 as? NativeTranscriptCell)?.exposure?.refresh() }
    }
    private func captureLandmark() -> Landmark? {
        let candidates = collection.indexPathsForVisibleItems.sorted()
        for index in candidates {
            guard let cell = collection.cellForItem(at: index) as? NativeTranscriptCell,
                  let item = source.itemIdentifier(for: index) else { continue }
            if let block = cell.exposure?.landmark() {
                return Landmark(item: item, block: block.block, role: block.role, y: block.y, marker: block.marker)
            }
            if cell.frame.intersects(collection.bounds) {
                return Landmark(item: item, block: nil, role: nil, y: cell.frame.minY - collection.bounds.minY, marker: nil)
            }
        }
        return nil
    }
    @discardableResult private func restore(_ anchor: Landmark) -> Bool {
        guard let index = source.indexPath(for: anchor.item) else { return false }
        let y: CGFloat
        let currentMarker = anchor.marker.flatMap { $0.window != nil ? $0 : nil }
            ?? anchor.block.flatMap { (collection.cellForItem(at: index) as? NativeTranscriptCell)?.exposure?.marker(for: $0, role: anchor.role ?? .content) }
        if let marker = currentMarker, marker.window === collection.window {
            y = marker.convert(marker.bounds, to: collection).minY
            viewportTarget = .reading(Landmark(item: anchor.item, block: anchor.block, role: anchor.role, y: anchor.y, marker: marker), fallback: collection.contentOffset)
        } else if let attributes = collection.layoutAttributesForItem(at: index) { y = attributes.frame.minY }
        else { return false }
        setClampedOffset(CGPoint(x: collection.contentOffset.x, y: y - anchor.y))
        return true
    }
    private func scrollToTerminal() {
        guard collection.bounds.height > 0, let index = source.indexPath(for: .terminal) else { return }
        collection.scrollToItem(at: index, at: .bottom, animated: false)
    }
    private func updateLatestAppearance(_ context: NativeTranscriptContext) {
        let traits = traitCollection.modifyingTraits {
            $0.userInterfaceStyle = context.colorScheme == .dark ? .dark : .light
        }
        var button = UIButton.Configuration.filled()
        button.image = UIImage(systemName: "arrow.down")
        button.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        button.cornerStyle = .capsule
        button.baseBackgroundColor = UIColor(resource: .accent).resolvedColor(with: traits)
        button.baseForegroundColor = UIColor(resource: .bottoOnAction).resolvedColor(with: traits)
        button.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
        latest.configuration = button
    }

    @objc private func requestLatest() {
        guard active, committed, actionAdmission() else { return }
        cancelSearchPosition()
        interruptedReaderScroll = true
        collection.setContentOffset(collection.contentOffset, animated: false)
        scrollPolicy.requestLatest(); quietHeld = false; viewportTarget = .end
        scrollToTerminal(); updateLatest()
    }
    private func updateLatest() { latest.isHidden = !scrollPolicy.showsLatest }
}
