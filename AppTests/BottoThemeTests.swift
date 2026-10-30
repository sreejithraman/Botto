import SwiftUI
import Testing
import UIKit
@testable import Botto

@Suite @MainActor struct BottoThemeTests {
    @Test(arguments: [ColorScheme.light, .dark], [ColorSchemeContrast.standard, .increased])
    func textAndActionColorsRemainReadable(scheme: ColorScheme, contrast: ColorSchemeContrast) throws {
        let traits = UITraitCollection().modifyingTraits {
            $0.userInterfaceStyle = scheme == .dark ? .dark : .light
            $0.accessibilityContrast = contrast == .increased ? .high : .normal
        }
        let pairs: [(String, UIColor, UIColor)] = [
            ("action on canvas", .accent, .bottoPaper),
            ("action on surface", .accent, .bottoSurface),
            ("selected label", .accent, .bottoSelection),
            ("primary action label", .bottoOnAction, .accent),
            ("pressed action label", .bottoOnAction, .bottoPressedAction),
            ("attention label", .accent, .bottoSelection),
            ("error label", .bottoError, .bottoPaper),
            ("error on surface", .bottoError, .bottoSurface),
            ("error action label", .bottoOnAction, .bottoError),
            ("outgoing message", .bottoOnOutgoing, .bottoOutgoing)
        ]
        for (name, foreground, background) in pairs {
            let first = try luminance(foreground.resolvedColor(with: traits))
            let second = try luminance(background.resolvedColor(with: traits))
            let ratio = (max(first, second) + 0.05) / (min(first, second) + 0.05)
            #expect(ratio >= 4.5, "\(name) must retain at least 4.5:1 contrast")
        }
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func nativeActionsUseTheSameAdaptivePalette(scheme: ColorScheme) {
        var environment = EnvironmentValues()
        environment.colorScheme = scheme
        let traits = UITraitCollection().modifyingTraits {
            $0.userInterfaceStyle = scheme == .dark ? .dark : .light
            $0.accessibilityContrast = .normal
        }
        let pairs: [(Color, UIColor)] = [
            (BottoTheme.action, UIColor(resource: .accent)),
            (BottoTheme.onAction, UIColor(resource: .bottoOnAction))
        ]
        for (color, native) in pairs {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            #expect(native.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha))
            let resolved = color.resolve(in: environment)
            #expect(abs(Double(red) - Double(resolved.red)) < 0.01)
            #expect(abs(Double(green) - Double(resolved.green)) < 0.01)
            #expect(abs(Double(blue) - Double(resolved.blue)) < 0.01)
        }
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func latestRespondsToContrastChangesWithoutAnotherApply(scheme: ColorScheme) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let controller = NativeTranscriptController()
        controller.traitOverrides.userInterfaceStyle = scheme == .dark ? .dark : .light
        controller.traitOverrides.accessibilityContrast = .normal
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.isHidden = false
        defer { controller.retire(); window.isHidden = true; window.rootViewController = nil }
        var context = NativeTranscriptContext(workspace: ObjectIdentifier(controller), profile: Data("theme".utf8),
            chat: nil, owner: nil, generation: UUID(), reviewingConnection: false)
        context.colorScheme = scheme
        controller.apply(context, snapshot: nil, rows: [], active: false, currentTaskSnapshot: { nil })
        let button = try #require(controller.view.subviews.compactMap { $0 as? UIButton }
            .first { $0.accessibilityLabel == "Latest messages" })
        let before = try #require(button.configuration?.baseBackgroundColor)
        let highTraits = controller.traitCollection.modifyingTraits { $0.accessibilityContrast = .high }
        let expected = UIColor(resource: .accent).resolvedColor(with: highTraits)
        #expect(!before.isEqual(expected), "The two contrast variants must differ for this control check")

        controller.traitOverrides.accessibilityContrast = .high
        let deadline = ContinuousClock.now + .seconds(2)
        while button.configuration?.baseBackgroundColor?.isEqual(expected) != true, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(button.configuration?.baseBackgroundColor?.isEqual(expected) == true,
                "Latest must adopt Increase Contrast without a content or layout-context publication")
    }

    private func luminance(_ color: UIColor) throws -> Double {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        try #require(color.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        func linear(_ channel: CGFloat) -> Double {
            let value = Double(channel)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}
