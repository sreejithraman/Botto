import SwiftUI
import UIKit

extension View {
    func hapticSheet(enabled: Bool = true,
                     perform: @escaping @MainActor () -> Void = { BottoHaptics.shared.play(.surface) }) -> some View {
        background(HapticPresentationObserver(enabled: enabled, perform: perform))
    }
}

private struct HapticPresentationObserver: UIViewControllerRepresentable {
    let enabled: Bool
    let perform: @MainActor () -> Void

    func makeUIViewController(context: Context) -> HapticPresentationController {
        let controller = HapticPresentationController(perform: perform)
        controller.enabled = enabled
        return controller
    }

    func updateUIViewController(_ controller: HapticPresentationController, context: Context) {
        controller.enabled = enabled
    }

    static func dismantleUIViewController(_ controller: HapticPresentationController, coordinator: ()) {
        controller.retire()
    }
}

/// The first UIKit appearance consumes the cue even when playback is suppressed.
@MainActor final class HapticPresentationController: UIViewController {
    var enabled = true
    private var consumed = false
    private let isActive: @MainActor () -> Bool
    private let perform: @MainActor () -> Void

    init(isActive: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState == .active },
         perform: @escaping @MainActor () -> Void = { BottoHaptics.shared.play(.surface) }) {
        self.isActive = isActive
        self.perform = perform
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        self.view = view
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !consumed else { return }
        consumed = true
        if enabled && isActive() { perform() }
    }

    func retire() { consumed = true }
}
