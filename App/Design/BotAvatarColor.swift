// Adapted from Hermex; eye geometry from Bloub. MIT; see LICENSES/Hermex.txt and LICENSES/Bloub.txt.
import SwiftUI
import BottoCore

extension Color {
    /// Presets use Botto's palette; supported custom values keep their color and alpha.
    static func botBody(_ hex: String) -> Color {
        return BotAvatarColors.presentation(hex).flatMap(Color.init(botHex:)) ?? .purple
    }

    /// Presets share dark eyes; custom colors choose contrast in both appearances.
    static func botEyes(on hex: String) -> Color {
        if BotAvatarColors.preset(for: hex) != nil { return .black.opacity(0.85) }
        let resolved = BotAvatarColors.presentation(hex) ?? "#8b5cf6"
        return Color(uiColor: UIColor { traits in
            // Translucent custom bodies expose the app surface. Contrast the
            // eyes against that composite, including a fully transparent body.
            botHexIsDark(resolved, darkSurface: traits.userInterfaceStyle == .dark)
                ? UIColor.white.withAlphaComponent(0.9) : UIColor.black.withAlphaComponent(0.85)
        })
    }

    init?(botHex: String) {
        let value = botHex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard [7, 9].contains(value.count), value.first == "#", let encoded = UInt64(value.dropFirst(), radix: 16) else { return nil }
        let rgb = value.count == 9 ? encoded >> 8 : encoded
        self.init(red: Double((rgb >> 16) & 0xff) / 255,
                  green: Double((rgb >> 8) & 0xff) / 255,
                  blue: Double(rgb & 0xff) / 255,
                  opacity: value.count == 9 ? Double(encoded & 0xff) / 255 : 1)
    }

    fileprivate static func botHexIsDark(_ botHex: String, darkSurface: Bool = false) -> Bool {
        let value = botHex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard [7, 9].contains(value.count), value.first == "#", let encoded = UInt64(value.dropFirst(), radix: 16) else { return false }
        let rgb = value.count == 9 ? encoded >> 8 : encoded
        let alpha = value.count == 9 ? Double(encoded & 0xff) / 255 : 1
        let surface = darkSurface ? 19.0 : 250.0
        let red = Double((rgb >> 16) & 0xff) * alpha + surface * (1 - alpha)
        let green = Double((rgb >> 8) & 0xff) * alpha + surface * (1 - alpha)
        let blue = Double(rgb & 0xff) * alpha + surface * (1 - alpha)
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue < 110
    }
}
