import Foundation
import BottoCore

enum BottoBrand {
    static let tagline = "Big ideas. Little sidekicks."

    struct Avatar: Identifiable, Sendable {
        let id: String
        let shape: BotAvatarShape
        let colorPreset: String
        let onboardingSize: CGFloat
        let onboardingRoll: Double

        var face: BotFace {
            let color = BotAvatarColors.presets.first { $0.id == colorPreset }!
            return BotFace(shape: shape, color: color.hex)
        }

        var profile: BotProfile {
            BotProfile(id: "botto-brand-\(id)", name: "",
                       appearance: BotAppearance(shape: shape, color: face.color, expression: "neutral"))
        }
    }

    static let squircle = Avatar(id: "squircle", shape: .squircle, colorPreset: "orange", onboardingSize: 76, onboardingRoll: -6)
    static let circle = Avatar(id: "circle", shape: .circle, colorPreset: "blue", onboardingSize: 60, onboardingRoll: 6)
    static let drop = Avatar(id: "drop", shape: .drop, colorPreset: "purple", onboardingSize: 50, onboardingRoll: -3)

    static let onboardingAvatars = [squircle, circle, drop]
}
