import SwiftUI
import UIKit
import Testing
@testable import Botto

@Suite(.serialized) @MainActor struct WorkspaceNativeDetailObservationTests {
    @Test(arguments: [false, true])
    func nativeProjectionRefreshTracksActualCoverageWithoutDelegateReplacement(overlay: Bool) async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let split = FocusTestSplitController(style: .doubleColumn)
        split.traitOverrides.horizontalSizeClass = .regular
        split.minimumPrimaryColumnWidth = 160; split.maximumPrimaryColumnWidth = 160
        split.setViewController(UINavigationController(rootViewController: UIViewController()), for: .primary)
        fixture.window.rootViewController = nil
        split.setViewController(UINavigationController(rootViewController: fixture.root), for: .secondary)
        split.preferredSplitBehavior = overlay ? .overlay : .tile
        split.preferredDisplayMode = overlay ? .oneOverSecondary : .oneBesideSecondary
        let state = WorkspaceNativeDetailState()
        let observer = WorkspaceNativeDetailObservation.Observer(state: state)
        observer.configure(projection: .all, layout: .init(compact: false, accessibilityText: false, workspaceWidth: 466))
        fixture.root.addChild(observer); fixture.root.view.addSubview(observer.view)
        observer.view.frame = fixture.root.view.bounds; observer.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        observer.didMove(toParent: fixture.root)
        let projection = FocusNativeProjection(state: state)
        split.delegate = projection
        if overlay { fixture.window.rootViewController = split }
        else {
            // A narrow device window cannot honor a preferred tiled mode.
            // Use the same native wide-bounds fixture
            // as the mounted production workspace tests, without a new scene.
            let outer = UIViewController(); fixture.window.rootViewController = outer
            outer.addChild(split); outer.view.addSubview(split.view)
            split.view.bounds = CGRect(x: 0, y: 0, width: 1000, height: 700)
            let scale = min(fixture.window.bounds.width / 1000, fixture.window.bounds.height / 700)
            split.view.transform = CGAffineTransform(scaleX: scale, y: scale)
            split.view.frame.origin = .zero; split.didMove(toParent: outer)
        }
        fixture.window.makeKeyAndVisible()
        try await ready { split.hasAppeared && split.transitionCoordinator == nil }
        let originalDelegate = split.delegate
        let target: UISplitViewController.DisplayMode = overlay ? .oneOverSecondary : .oneBesideSecondary
        split.show(.primary)
        try await ready { split.displayMode == target && state.confirmedReadable == !overlay && state.inputVisible == !overlay }
        split.hide(.primary)
        try await ready {
            split.displayMode == .secondaryOnly && state.readable && state.inputVisible &&
                split.viewController(for: .primary)?.viewIfLoaded?.window == nil
        }
        split.show(.primary)
        try await ready { split.displayMode == target && state.confirmedReadable == !overlay && state.inputVisible == !overlay }
        #expect(split.delegate === originalDelegate)
    }

    private func ready(sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() && ContinuousClock.now < deadline { await Task.yield() }
        try #require(condition(), "Native coverage fixture settled", sourceLocation: sourceLocation)
    }
    private func fixture() async throws -> Fixture {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let fixture = Fixture(scene: scene)
        fixture.window.makeKeyAndVisible(); fixture.window.layoutIfNeeded()
        try await ready { fixture.root.hasAppeared && fixture.window.isKeyWindow }
        return fixture
    }
    @MainActor private final class Fixture {
        let window: UIWindow
        let root = FocusTestController()
        weak var previous: UIWindow?
        init(scene: UIWindowScene) {
            previous = scene.windows.first { $0.isKeyWindow }
            window = UIWindow(windowScene: scene); window.rootViewController = root
        }
        func close() { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
    }
}

@MainActor private final class FocusTestController: UIViewController {
    private(set) var hasAppeared = false
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); hasAppeared = true }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); hasAppeared = false }
}
@MainActor private final class FocusTestSplitController: UISplitViewController {
    private(set) var hasAppeared = false
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); hasAppeared = true }
}
@MainActor private final class FocusNativeProjection: NSObject, UISplitViewControllerDelegate {
    let state: WorkspaceNativeDetailState
    init(state: WorkspaceNativeDetailState) { self.state = state }
    func splitViewController(_ svc: UISplitViewController, willChangeTo displayMode: UISplitViewController.DisplayMode) {
        state.requestRefresh(projection: displayMode == .secondaryOnly ? .detailOnly : .all)
    }
}
