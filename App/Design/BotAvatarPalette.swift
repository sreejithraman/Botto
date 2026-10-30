// Botto's palette is a local interpretation of the shared Hermes color choices.
import SwiftUI
import BottoCore

struct BotAvatarColor: Identifiable {
    let id: String
    let value: String
    let name: LocalizedStringResource
    var localizedName: String { String(localized: name) }
    var swatch: Color { Color.botBody(value) }

    static var palette: [BotAvatarColor] {
        BotAvatarColors.presets.map { BotAvatarColor(id: $0.id, value: $0.shared, name: name(for: $0.id)) } +
        [BotAvatarColor(id: "brown", value: "#a9703d", name: "Brown"),
         BotAvatarColor(id: "gray", value: "#8e8e93", name: "Gray")]
    }

    static func matching(_ source: String) -> BotAvatarColor? {
        if let preset = BotAvatarColors.preset(for: source) {
            return palette.first { $0.id == preset.id }
        }
        return palette.first { $0.value.caseInsensitiveCompare(source) == .orderedSame }
    }

    static func label(for source: String) -> String {
        matching(source)?.localizedName ?? String(localized: "Custom color")
    }

    private static func name(for id: String) -> LocalizedStringResource {
        switch id {
        case "red": "Red"
        case "orange": "Orange"
        case "yellow": "Yellow"
        case "lime": "Lime"
        case "green": "Green"
        case "mint": "Mint"
        case "teal": "Teal"
        case "cyan": "Cyan"
        case "blue": "Blue"
        case "indigo": "Indigo"
        case "purple": "Purple"
        case "magenta": "Magenta"
        case "pink": "Pink"
        default: "Color"
        }
    }
}

extension BotAvatarShape {
    var label: String { rawValue.capitalized }
}
