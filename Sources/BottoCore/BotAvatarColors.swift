import Foundation

/// Shared color keys and Botto's local presentation palette. Rendering never rewrites a shared value.
/// Supports 3/4/6/8-digit hex, modern and comma-separated RGB/HSL functions, and a small
/// named-color whitelist. Hue units are deg, turn, rad, and grad. Finite channels clamp to CSS ranges.
/// Inputs must be ASCII and at most 512 UTF-8 bytes; expressions, comments, and context-dependent
/// colors such as currentColor are unsupported. Keep the original value for persistence.
public enum BotAvatarColors {
    public struct Preset: Identifiable, Equatable, Sendable {
        public let id: String
        public let shared: String
        public let hex: String
    }

    public static let presets: [Preset] = [
        ("red", "#ef4444"), ("orange", "#f97316"), ("yellow", "#facc15"),
        ("lime", "#84cc16"), ("green", "#22c55e"), ("mint", "#34d399"),
        ("teal", "#14b8a6"), ("blue", "#38bdf8"), ("indigo", "#6366f1"),
        ("purple", "#8b5cf6"), ("magenta", "#d946ef"), ("pink", "#ec4899")
    ].enumerated().map { index, entry in
        Preset(id: entry.0, shared: "hsl(\(index * 30) 68% 58%)", hex: entry.1)
    }

    /// Returns lowercase sRGB hex, including alpha when translucent, rounded to 8-bit channels.
    public static func presentation(_ source: String) -> String? {
        guard let color = parse(source) else { return nil }
        return preset(for: color)?.hex ?? color.hex
    }

    /// Matches values, not provenance: a custom color identical to a known swatch also matches.
    /// Only exact swatch equivalents match; arbitrary custom hues, saturation, lightness, and alpha do not snap.
    public static func preset(for source: String) -> Preset? {
        parse(source).flatMap { preset(for: $0) }
    }

    public static func isValid(_ source: String) -> Bool {
        parse(source) != nil
    }

    /// Quantizes a generated HSL hue to a shared key. Halfway ties advance clockwise.
    /// Nonfinite generated hues use red; invalid source strings still fail parsing.
    public static func presetColor(hue: Double) -> String {
        guard hue.isFinite else { return presets[0].shared }
        return presets[Int((normalized(hue) / 30).rounded()) % presets.count].shared
    }

    /// Blobatar seeds are OKLCH hues. Translate a representative color to its visible sRGB
    /// hue family, then use Botto's regular palette. Generated tone and shade are intentionally discarded.
    public static func blobatarColor(hue: Double) -> String {
        guard hue.isFinite else { return presets[0].shared }
        let hue = normalized(hue)
        var rgb = blobatarLinearRGB(hue: hue, chroma: 0.12)
        if !inGamut(rgb) {
            var lower = 0.0
            var upper = 0.12
            for _ in 0..<12 {
                let middle = (lower + upper) / 2
                if inGamut(blobatarLinearRGB(hue: hue, chroma: middle)) { lower = middle }
                else { upper = middle }
            }
            rgb = blobatarLinearRGB(hue: hue, chroma: lower)
        }
        let srgb = rgb.map { channel in
            let value = min(1, max(0, channel))
            let encoded = value <= 0.0031308 ? 12.92 * value : 1.055 * pow(value, 1 / 2.4) - 0.055
            // Blobatar renders 8-bit hex; use that representative's actual visible channels.
            return (encoded * 255).rounded() / 255
        }
        let maximum = srgb.max()!
        let delta = maximum - srgb.min()!
        guard delta > 0 else { return presets[0].shared }
        let h: Double
        if maximum == srgb[0] { h = (srgb[1] - srgb[2]) / delta }
        else if maximum == srgb[1] { h = (srgb[2] - srgb[0]) / delta + 2 }
        else { h = (srgb[0] - srgb[1]) / delta + 4 }
        return presetColor(hue: h * 60)
    }

    // Minimal OKLCH → linear sRGB conversion and gamut search adapted from Blobatar 2.0.0,
    // src/color.ts (MIT). See the project's Blobatar third-party notice.
    // L = 0.7 and C = 0.12 are representative constants, independent of Blobatar's authored tones.
    private static func blobatarLinearRGB(hue: Double, chroma: Double) -> [Double] {
        let radians = hue * .pi / 180
        let a = chroma * cos(radians)
        let b = chroma * sin(radians)
        let l = 0.7 + 0.3963377774 * a + 0.2158037573 * b
        let m = 0.7 - 0.1055613458 * a - 0.0638541728 * b
        let s = 0.7 - 0.0894841775 * a - 1.291485548 * b
        let ll = l * l * l, mm = m * m * m, ss = s * s * s
        return [
            4.0767416621 * ll - 3.3077115913 * mm + 0.2309699292 * ss,
            -1.2684380046 * ll + 2.6097574011 * mm - 0.3413193965 * ss,
            -0.0041960863 * ll - 0.7034186147 * mm + 1.707614701 * ss
        ]
    }

    private static func inGamut(_ rgb: [Double]) -> Bool {
        rgb.allSatisfy { $0 >= -1e-4 && $0 <= 1 + 1e-4 }
    }

    private static let presetValues: [(RGBA, Preset)] = presets.flatMap { preset in
        let shared = parse(preset.shared)!
        return [(shared, preset), (parse(shared.hex)!, preset), (parse(preset.hex)!, preset)]
    } + [(parse("#f59e0b")!, presets[2])] // Legacy Botto/Hermex amber.

    private static func preset(for color: RGBA) -> Preset? {
        guard color.a == 1 else { return nil }
        return presetValues.first { candidate, _ in
            // Equivalent decimal RGB and HSL can differ by a few representable
            // steps after normalization. Bound that arithmetic noise by ULPs;
            // a fixed epsilon would also swallow subtly different custom shades.
            arithmeticEquivalent(candidate.r, color.r) && arithmeticEquivalent(candidate.g, color.g) &&
                arithmeticEquivalent(candidate.b, color.b)
        }?.1
    }

    private static func arithmeticEquivalent(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) <= 4 * max(lhs.ulp, rhs.ulp)
    }

    private struct RGBA: Sendable {
        let r: Double
        let g: Double
        let b: Double
        var a: Double = 1

        var hex: String {
            let channels = a < 1 ? [r, g, b, a] : [r, g, b]
            return "#" + channels.map { String(format: "%02x", Int(($0 * 255).rounded())) }.joined()
        }
    }

    private static let whitespace = CharacterSet(charactersIn: " \t\n\r\u{0c}")

    // CSS basic names, their common aliases, orange, rebeccapurple, and transparent.
    private static let namedColors: [String: String] = [
        "black": "#000000", "silver": "#c0c0c0", "gray": "#808080", "grey": "#808080",
        "white": "#ffffff", "maroon": "#800000", "red": "#ff0000", "purple": "#800080",
        "fuchsia": "#ff00ff", "magenta": "#ff00ff", "green": "#008000", "lime": "#00ff00",
        "olive": "#808000", "yellow": "#ffff00", "navy": "#000080", "blue": "#0000ff",
        "teal": "#008080", "aqua": "#00ffff", "cyan": "#00ffff", "orange": "#ffa500",
        "rebeccapurple": "#663399", "transparent": "#00000000"
    ]

    private static func parse(_ source: String) -> RGBA? {
        // Bound work before copying, lowercasing, tokenizing, or running a numeric regex.
        guard source.utf8.prefix(513).count <= 512, source.unicodeScalars.allSatisfy({ $0.isASCII }) else { return nil }
        let text = source.trimmingCharacters(in: whitespace).lowercased()
        if text.first == "#" { return parseHex(text) }
        if let named = namedColors[text] { return parseHex(named) }
        guard text.last == ")", let open = text.firstIndex(of: "(") else { return nil }
        let function = String(text[..<open])
        guard ["rgb", "rgba", "hsl", "hsla"].contains(function),
              let components = components(String(text[text.index(after: open)..<text.index(before: text.endIndex)])) else { return nil }
        let values = components.channels
        let alpha: Double
        if let token = components.alpha {
            guard let parsed = component(token, scale: 1) else { return nil }
            alpha = parsed
        } else {
            alpha = 1
        }
        if function == "rgb" || function == "rgba" {
            // Legacy comma RGB requires either three percentages or three numbers.
            if components.legacy && Set(values.map { $0.hasSuffix("%") }).count > 1 { return nil }
            guard let r = component(values[0], scale: 255), let g = component(values[1], scale: 255),
                  let b = component(values[2], scale: 255) else { return nil }
            return RGBA(r: r, g: g, b: b, a: alpha)
        }
        guard let hue = hue(values[0]), values[1].hasSuffix("%"), values[2].hasSuffix("%"),
              let saturation = component(values[1], scale: 1), let lightness = component(values[2], scale: 1) else { return nil }
        return hsl(hue: hue, saturation: saturation, lightness: lightness, alpha: alpha)
    }

    private static func parseHex(_ text: String) -> RGBA? {
        let digits = Array(text.dropFirst().utf8)
        guard [3, 4, 6, 8].contains(digits.count),
              digits.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        let expanded = digits.count < 5 ? digits.flatMap { [$0, $0] } : digits
        let pairs = stride(from: 0, to: expanded.count, by: 2).map { index in
            Double(UInt8(String(bytes: expanded[index...index + 1], encoding: .utf8)!, radix: 16)!) / 255
        }
        return RGBA(r: pairs[0], g: pairs[1], b: pairs[2], a: pairs.count == 4 ? pairs[3] : 1)
    }

    private struct Components {
        let channels: [String]
        let alpha: String?
        let legacy: Bool
    }

    private static func components(_ body: String) -> Components? {
        if body.contains(",") {
            guard !body.contains("/") else { return nil }
            let parts = body.components(separatedBy: ",").map { $0.trimmingCharacters(in: whitespace) }
            guard parts.count == 3 || parts.count == 4 else { return nil }
            return Components(channels: Array(parts.prefix(3)), alpha: parts.count == 4 ? parts[3] : nil, legacy: true)
        }
        let parts = body.components(separatedBy: "/")
        guard parts.count <= 2 else { return nil }
        let channels = parts[0].components(separatedBy: whitespace).filter { !$0.isEmpty }
        guard channels.count == 3 else { return nil }
        return Components(channels: channels, alpha: parts.count == 2 ? parts[1].trimmingCharacters(in: whitespace) : nil, legacy: false)
    }

    private static let numberPattern = try! NSRegularExpression(
        pattern: #"\A[+-]?(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)(?:e[+-]?[0-9]+)?\z"#
    )

    private static func number(_ text: String) -> Double? {
        guard numberPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil,
              let value = Double(text), value.isFinite else { return nil }
        return value
    }

    private static func component(_ text: String, scale: Double) -> Double? {
        let percent = text.hasSuffix("%")
        guard let value = number(percent ? String(text.dropLast()) : text) else { return nil }
        let maximum = percent ? 100 : scale
        return min(maximum, max(0, value)) / maximum
    }

    private static func hue(_ text: String) -> Double? {
        for (unit, period) in [("turn", 1.0), ("grad", 400.0), ("rad", 2 * Double.pi), ("deg", 360.0)] {
            if text.hasSuffix(unit) {
                guard let value = number(String(text.dropLast(unit.count))) else { return nil }
                return normalized(value.truncatingRemainder(dividingBy: period) / period * 360)
            }
        }
        return number(text).map(normalized)
    }

    private static func normalized(_ hue: Double) -> Double {
        let remainder = hue.truncatingRemainder(dividingBy: 360)
        return remainder < 0 ? remainder + 360 : remainder
    }

    private static func hsl(hue: Double, saturation: Double, lightness: Double, alpha: Double = 1) -> RGBA {
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let x = chroma * (1 - abs((hue / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = lightness - chroma / 2
        let rgb: (Double, Double, Double)
        switch hue {
        case ..<60: rgb = (chroma, x, 0)
        case ..<120: rgb = (x, chroma, 0)
        case ..<180: rgb = (0, chroma, x)
        case ..<240: rgb = (0, x, chroma)
        case ..<300: rgb = (x, 0, chroma)
        default: rgb = (chroma, 0, x)
        }
        return RGBA(r: rgb.0 + m, g: rgb.1 + m, b: rgb.2 + m, a: alpha)
    }
}
