import UIKit
import SwiftUI
import Observation
import Testing
@testable import Botto

@Suite(.serialized) @MainActor struct HapticPresentationTests {
    @Test func repeatedAppearancesDoNotRepeatTheSheetCue() {
        var plays = 0
        let observer = HapticPresentationController(isActive: { true }, perform: { plays += 1 })
        observer.viewDidAppear(false)
        observer.viewWillDisappear(false)
        observer.viewDidAppear(false)
        #expect(plays == 1)
    }

    @Test func inactiveOrDisabledAppearanceIsConsumedWithoutLaterReplay() {
        var active = false
        var plays = 0
        let observer = HapticPresentationController(isActive: { active }, perform: { plays += 1 })
        observer.viewDidAppear(false)
        active = true
        observer.viewDidAppear(false)
        #expect(plays == 0)

        let disabled = HapticPresentationController(isActive: { true }, perform: { plays += 1 })
        disabled.enabled = false
        disabled.viewDidAppear(false)
        disabled.enabled = true
        disabled.viewDidAppear(false)
        #expect(plays == 0)
    }

    @Test func cancelledPresentationCannotPlayLateCompletion() {
        var plays = 0
        let observer = HapticPresentationController(isActive: { true }, perform: { plays += 1 })
        observer.retire()
        observer.viewDidAppear(false)
        #expect(plays == 0)
    }

    @Test func aRealSwiftUISheetPlaysOnceAcrossRedrawAndAgainOnReopen() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }
        let model = SheetModel()
        let host = UIHostingController(rootView: SheetHost(model: model))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            host.dismiss(animated: false)
            window.isHidden = true; window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await ready { host.view.window != nil }
        model.shown = true
        try await ready { model.plays == 1 }
        model.revision = 2
        try await ready { model.renderedRevision == 2 }
        #expect(model.plays == 1)
        model.shown = false
        try await ready { model.dismissals == 1 }
        model.shown = true
        try await ready { model.plays == 2 }
    }

    @MainActor @Observable final class SheetModel {
        var shown = false
        var revision = 0
        var renderedRevision = 0
        var plays = 0
        var dismissals = 0
    }

    private struct SheetHost: View {
        @Bindable var model: SheetModel
        var body: some View {
            Color.clear.sheet(isPresented: $model.shown, onDismiss: { model.dismissals += 1 }) {
                Text("Revision \(model.revision)")
                    .hapticSheet(perform: { model.plays += 1 })
                    .onChange(of: model.revision) { _, value in model.renderedRevision = value }
            }
        }
    }

    private func ready(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(condition())
    }
}
