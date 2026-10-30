import SwiftUI
import Observation

/// Read evidence needs a confirmed native surface. A short native handoff may
/// keep an already eligible editor while its read evidence remains fenced;
/// confirmed overlay coverage blocks both. Geometry never changes task intent.
@MainActor @Observable final class WorkspaceNativeDetailState {
    private(set) var readable = false
    private(set) var confirmedReadable: Bool?
    private(set) var inputVisible = false
    private(set) var requestedProjection: NavigationSplitViewVisibility = .all
    @ObservationIgnored fileprivate weak var observer: WorkspaceNativeDetailObservation.Observer?
    @ObservationIgnored fileprivate var onUnavailable: () -> Void = {}

    func requestRefresh(projection: NavigationSplitViewVisibility) {
        requestedProjection = projection
        invalidate()
        observer?.refresh(projection: projection)
    }
    fileprivate func invalidate() { confirmedReadable = nil; readable = false; onUnavailable() }
    fileprivate func report(_ value: Bool?, from observer: WorkspaceNativeDetailObservation.Observer) {
        guard self.observer === observer else { return }
        if value != true { onUnavailable() }
        confirmedReadable = value
        readable = value == true
        if let value { inputVisible = value }
    }
}

private struct WorkspaceNativeDetailKey: EnvironmentKey {
    static let defaultValue: WorkspaceNativeDetailState? = nil
}
extension EnvironmentValues {
    var workspaceNativeDetail: WorkspaceNativeDetailState? {
        get { self[WorkspaceNativeDetailKey.self] }
        set { self[WorkspaceNativeDetailKey.self] = newValue }
    }
}

/// Native visibility writes explicitly invalidate/refresh this passive child.
/// Layout/appearance alone do not observe callback-free overlay transitions.
struct WorkspaceNativeDetailObservation: UIViewControllerRepresentable {
    let state: WorkspaceNativeDetailState
    let projection: NavigationSplitViewVisibility
    let layout: WorkspaceLayout
    let onUnavailable: () -> Void

    func makeUIViewController(context: Context) -> Observer {
        let observer = Observer(state: state)
        state.observer = observer
        return observer
    }
    func updateUIViewController(_ observer: Observer, context: Context) {
        state.onUnavailable = onUnavailable
        observer.configure(projection: projection, layout: layout)
    }

    final class Observer: UIViewController {
        private let state: WorkspaceNativeDetailState
        private var projection: NavigationSplitViewVisibility?
        private var layout: WorkspaceLayout?
        private var appeared = false
        private var transitions: Set<ObjectIdentifier> = []
        private weak var completedCoordinator: (any UIViewControllerTransitionCoordinator)?
        private var refreshID = UUID()
        private var refreshTask: Task<Void, Never>?
        init(state: WorkspaceNativeDetailState) {
            self.state = state; super.init(nibName: nil, bundle: nil)
            state.observer = self
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func loadView() {
            let marker = WindowMarker()
            marker.moved = { [weak self] in self?.sample() }
            view = marker
        }
        func configure(projection: NavigationSplitViewVisibility, layout: WorkspaceLayout) {
            guard self.projection != projection || self.layout != layout else { return }
            self.layout = layout
            refresh(projection: projection)
        }
        func refresh(projection: NavigationSplitViewVisibility) {
            self.projection = projection
            state.invalidate()
            let id = UUID(); refreshID = id
            refreshTask?.cancel()
            // Sample after the native projection setter returns, rather than
            // treating its requested mode as an already visible surface.
            refreshTask = Task { @MainActor [weak self] in
                guard let self, refreshID == id else { return }
                sample()
            }
        }
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); appeared = true; sample() }
        override func viewWillDisappear(_ animated: Bool) { appeared = false; sample(); super.viewWillDisappear(animated) }
        override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); sample() }
        override func willTransition(to collection: UITraitCollection, with coordinator: any UIViewControllerTransitionCoordinator) {
            observe(coordinator); super.willTransition(to: collection, with: coordinator)
        }
        override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
            observe(coordinator); super.viewWillTransition(to: size, with: coordinator)
        }
        private func observe(_ coordinator: any UIViewControllerTransitionCoordinator) {
            let id = ObjectIdentifier(coordinator as AnyObject)
            guard transitions.insert(id).inserted else { return }
            state.report(nil, from: self)
            let accepted = coordinator.animate(alongsideTransition: nil) { [weak self, weak coordinator] _ in
                self?.completedCoordinator = coordinator
                self?.transitions.remove(id); self?.sample()
            }
            // Enqueue failure is not completion. A later native lifecycle or
            // explicit projection refresh must establish actual coverage.
            if !accepted { transitions.remove(id) }
        }
        private func sample() {
            guard appeared, viewIfLoaded?.window != nil else { state.report(nil, from: self); return }
            if let coordinator = transitionCoordinator,
               completedCoordinator.map({ ObjectIdentifier($0 as AnyObject) }) != ObjectIdentifier(coordinator as AnyObject) {
                observe(coordinator)
                return // Enqueue failure is never treated as completion here.
            }
            guard transitions.isEmpty, let split = splitViewController else { state.report(nil, from: self); return }
            let value: Bool?
            if split.isCollapsed { value = true } // The compact-column owner also gates the detail.
            else {
                switch split.displayMode {
                case .secondaryOnly: value = projection == .all ? nil : true
                case .oneBesideSecondary, .twoBesideSecondary: value = projection == .detailOnly ? nil : true
                default: value = false
                }
            }
            state.report(value, from: self)
        }
        deinit { refreshTask?.cancel() }
        private final class WindowMarker: UIView {
            var moved: (() -> Void)?
            override func didMoveToWindow() { super.didMoveToWindow(); moved?() }
        }
    }
}
