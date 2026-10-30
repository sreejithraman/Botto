// Shared identity follows pinned Hermes Desktop; see docs/avatars.md.
// Seed traits and silhouette bands adapted from Blobatar 2.0.0. MIT; see LICENSES/Blobatar.txt.
import Foundation

/// Resolves shared shape vocabulary into Botto's locally drawn silhouettes.
enum BotAvatarRecipe {
    static func isPrimary(_ name: String) -> Bool {
        trim(name).lowercased() == "default"
    }

    private static let bands: [(kind: String, upper: Double, shape: BotAvatarShape)] = [
        ("round", 0.22, .circle), ("organic", 0.48, .blob), ("boxy", 0.60, .squircle),
        ("capsule", 0.70, .pill), ("nub", 0.79, .nub), ("cloud", 0.86, .cloud),
        ("droplet", 0.915, .drop), ("hexagon", 0.95, .hexagon), ("sun", 0.98, .sun), ("triangle", 1, .triangle)
    ]

    static func isBlobatar(_ rawShape: String?) -> Bool {
        guard let rawShape else { return false }
        return rawShape == "blobatar" || rawShape.utf8.starts(with: "blobatar:".utf8)
    }

    static func blobatar(rawShape: String?, profileID: String) -> (shape: BotAvatarShape, hue: Double)? {
        guard let rawShape, isBlobatar(rawShape) else { return nil }
        // JS splits code units. A colon followed by a combining mark belongs
        // to one Swift Character, so String splitting/prefix checks miss it.
        // ASCII separators cannot occur inside a UTF-8 multibyte sequence.
        let parts = rawShape.utf8.split(separator: UInt8(ascii: ":"), omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        let seedPart = parts.count > 1 ? parts[1] : ""
        let seed = !seedPart.isEmpty ? seedPart : (profileID.isEmpty ? "agent" : profileID)
        // JS normalizes before trimming and lowercasing, with no second NFC pass.
        // Foundation's locale-stable casing also handles Greek final sigma;
        // Swift's plain lowercased() does not apply that contextual mapping.
        let normalized = trim(seed.precomposedStringWithCanonicalMapping).lowercased(with: Locale(identifier: "en_US_POSIX"))
        let state = feed(1_779_033_703 ^ UInt32(truncatingIfNeeded: normalized.utf16.count), normalized.utf8)
        let shapeTrait = trait(state, key: "shape")
        let pinnedShape = parts.count > 2 ? bands.first { $0.kind == parts[2] }?.shape : nil
        let shape = pinnedShape ?? bands.first { shapeTrait < $0.upper }?.shape ?? .triangle
        // render.ts reads "hue", not a palette- or color-prefixed trait key.
        return (shape, trait(state, key: "hue") * 360)
    }

    static func defaultHue(for name: String) -> Double? {
        let key = trim(name)
        guard !key.isEmpty, key != "default" else { return nil }
        // profileColor uses indexed charCodeAt, unlike the shape hash below.
        let hash = key.utf16.reduce(UInt32(0)) { $0 &* 31 &+ UInt32($1) }
        return Double(hash % 360)
    }

    static func defaultShape(for name: String) -> BotAvatarShape {
        // JS for-of visits code points; charCodeAt(0) reads only the leading
        // UTF-16 unit, including for an astral character. Swift Character would
        // combine marks and emoji sequences and therefore select another shape.
        let hash = name.unicodeScalars.reduce(UInt32(0)) { hash, scalar in
            let firstUnit = scalar.value > 0xffff ? 0xd800 + ((scalar.value - 0x10000) >> 10) : scalar.value
            return hash &* 31 &+ firstUnit
        }
        let shapes: [BotAvatarShape] = [.circle, .squircle, .pill, .triangle, .hexagon, .cloud, .drop]
        return shapes[Int(hash % UInt32(shapes.count))]
    }

    private static func feed(_ state: UInt32, _ bytes: some Sequence<UInt8>) -> UInt32 {
        bytes.reduce(state) { state, byte in
            let mixed = (state ^ UInt32(byte)) &* 3_432_918_353
            return (mixed << 13) | (mixed >> 19)
        }
    }

    private static func trait(_ state: UInt32, key: String) -> Double {
        var hash = feed(feed(state, [0xff]), key.utf8)
        hash = (hash ^ (hash >> 16)) &* 2_246_822_507
        hash = (hash ^ (hash >> 13)) &* 3_266_489_909
        return Double(hash ^ (hash >> 16)) / 4_294_967_296
    }

    // ECMAScript trim excludes NEL and includes BOM; Foundation's general
    // whitespace set differs. Keep the seed and profile-color rules exact.
    private static func trim(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn:
            "\u{0009}\u{000a}\u{000b}\u{000c}\u{000d}\u{0020}\u{00a0}\u{1680}" +
            "\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200a}" +
            "\u{2028}\u{2029}\u{202f}\u{205f}\u{3000}\u{feff}"))
    }
}
