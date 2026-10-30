import Foundation
import BottoCore

enum BottoBrand {
    static let tagline = "Big ideas. Little sidekicks."

    struct Avatar: Identifiable, Sendable {
        let id: String
        let shape: BotAvatarShape
        let colorPreset: String
        let iconFrame: CGRect
        let iconRoll: Double
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

    static let squircle = Avatar(id: "squircle", shape: .squircle, colorPreset: "orange",
                                iconFrame: CGRect(x: 13, y: 71, width: 168, height: 168),
                                iconRoll: -9, onboardingSize: 76, onboardingRoll: -6)
    static let circle = Avatar(id: "circle", shape: .circle, colorPreset: "blue",
                              iconFrame: CGRect(x: 123, y: 25, width: 120, height: 120),
                              iconRoll: 8, onboardingSize: 60, onboardingRoll: 6)
    static let drop = Avatar(id: "drop", shape: .drop, colorPreset: "purple",
                            iconFrame: CGRect(x: 126, y: 106, width: 116, height: 116),
                            iconRoll: 7, onboardingSize: 50, onboardingRoll: -3)

    static let onboardingAvatars = [squircle, circle, drop]
    static let iconAvatars = [circle, drop, squircle]
}
