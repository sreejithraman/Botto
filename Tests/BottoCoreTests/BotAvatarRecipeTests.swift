import Foundation
import Testing
@testable import BottoCore

@Test(arguments: ["sigil-17", "future-shape", "blobatar:locked:sun", ""])
func rawAppearanceChoicesSurviveCacheRoundTrips(raw: String) throws {
    let json = Data("{\"shape\":\"\(raw)\",\"color\":\"#AbC123\",\"custom\":false,\"imageKind\":\"shape\",\"expression\":\"curious\"}".utf8)
    let appearance = try JSONDecoder().decode(BotAppearance.self, from: json)
    #expect(appearance.rawShape == raw)
    #expect(appearance.shape == nil)
    #expect(appearance.color == "#AbC123" && !appearance.custom)
    let encoded = try JSONEncoder().encode(appearance)
    #expect(try JSONDecoder().decode(BotAppearance.self, from: encoded) == appearance)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(object["shape"] as? String == raw)
    #expect(object["rawShape"] == nil)
}

// Expected shapes from defaultShapeFor in the pinned Hermes Desktop avatar.tsx,
// executed by Node. In particular, for-of visits code points, charCodeAt(0) takes
// only their first UTF-16 unit, and combining marks remain separate iterations.
@Test(arguments: [
    ("inbox-triage", BotAvatarShape.cloud), ("Élodie", .drop), ("e\u{301}lodie", .cloud),
    ("🐱bot", .circle), ("👩‍💻", .drop), ("A\u{301}", .cloud), ("\u{feff}Inbox\u{feff}", .pill), ("", .circle)
])
func classicShapeDefaultsMatchHermesDesktop(fixture: (String, BotAvatarShape)) {
    let (name, expected) = fixture
    #expect(BotAppearance(color: "#AbC123").face(for: name) == BotFace(shape: expected, color: "#AbC123"))
    #expect(BotAppearance(rawShape: "future-outline", color: "#AbC123").face(for: name).shape == expected)
}

// Hue fixtures from profileColor in pinned colors.ts, executed by Node. Its
// indexed charCodeAt loop reads both UTF-16 units of astral characters.
@Test(arguments: [
    ("inbox-triage", "hsl(90 68% 58%)"), ("Élodie", "hsl(270 68% 58%)"),
    ("e\u{301}lodie", "hsl(180 68% 58%)"), ("🐱bot", "hsl(150 68% 58%)"),
    ("👩‍💻", "hsl(240 68% 58%)"), ("A\u{301}", "hsl(270 68% 58%)"),
    ("\u{feff}Inbox\u{feff}", "hsl(300 68% 58%)"), ("", "#8b5cf6"), ("default", "#8b5cf6")
])
func classicDefaultHueUsesCanonicalHermesPresets(fixture: (String, String)) {
    let (name, expected) = fixture
    #expect(BotAppearance().face(for: name).color == expected)
    #expect(BotAppearance(rawShape: "cloud", color: "", custom: true).face(for: name).color == expected)
}

// Independent Blobatar 2.0.0 fixtures generated with Node from the distributed
// JS exports, not Swift arithmetic:
// import { _layout, traits } from '/tmp/botto-blobatar/package/dist/index.js';
// ({ kind: _layout(seed).shape, hue: traits(seed).num('hue', 0, 360) })
// The color helper owns the OKLCH-to-preset mapping; these literal source hues
// verify the recipe's separate hashing/normalization boundary.
@Test(arguments: [
    ("fixture-0", BotAvatarShape.blob, 230.1128505449742),
    ("fixture-2", BotAvatarShape.cloud, 346.9816969614476),
    ("fixture-5", BotAvatarShape.pill, 313.3675743173808),
    ("fixture-8", BotAvatarShape.drop, 205.03163860179484),
    ("fixture-12", BotAvatarShape.circle, 178.70096770115197),
    ("fixture-15", BotAvatarShape.nub, 194.07705014571548),
    ("fixture-18", BotAvatarShape.hexagon, 335.69018323905766),
    ("fixture-28", BotAvatarShape.squircle, 337.244721762836),
    ("fixture-33", BotAvatarShape.sun, 335.02056087367237),
    ("fixture-58", BotAvatarShape.triangle, 108.15617012791336),
    ("inbox-triage", BotAvatarShape.nub, 69.49922204017639),
    ("agent", BotAvatarShape.cloud, 245.71232504211366),
    (" Locked ", BotAvatarShape.nub, 239.96370445936918),
    ("Élodie", BotAvatarShape.blob, 184.63534559123218),
    ("e\u{301}lodie", BotAvatarShape.blob, 184.63534559123218),
    ("🐱bot", BotAvatarShape.pill, 274.09242742694914),
    ("İ", BotAvatarShape.pill, 22.432652413845062),
    ("ΟΣ", BotAvatarShape.sun, 94.96192540973425),
    ("\u{feff} A\u{200b} \u{feff}", BotAvatarShape.circle, 282.20519858412445),
    ("\u{85}A\u{85}", BotAvatarShape.circle, 294.2123549245298),
    ("\u{2003}A\u{2003}", BotAvatarShape.squircle, 156.21775774285197),
    ("\u{200b}A\u{200b}", BotAvatarShape.nub, 300.17669359222054),
    ("\u{180e}A\u{180e}", BotAvatarShape.pill, 103.69412734173238),
    ("\u{feff}", BotAvatarShape.squircle, 2.9932188615202904),
])
func generatedBlobatarFacesMatchPackageFixtures(fixture: (String, BotAvatarShape, Double)) {
    let (name, shape, hue) = fixture
    let expected = BotFace(shape: shape, color: BotAvatarColors.blobatarColor(hue: hue))
    // Blobatar's own seed palette wins over a stored classic color.
    #expect(BotAppearance(rawShape: "blobatar", color: "#ff0000", custom: true).face(for: name) == expected)
}

// Pinned kinds use the desktop BLOB_KIND_TRAIT band centers; expected kinds
// were confirmed with _layout('Locked', { traits: { shape: center } }).shape.
@Test(arguments: [
    ("blobatar:Locked:round", "renamed", BotAvatarShape.circle, 239.96370445936918),
    ("blobatar:Locked:organic", "renamed", .blob, 239.96370445936918),
    ("blobatar:Locked:boxy", "renamed", .squircle, 239.96370445936918),
    ("blobatar:Locked:capsule", "renamed", .pill, 239.96370445936918),
    ("blobatar:Locked:nub", "renamed", .nub, 239.96370445936918),
    ("blobatar:Locked:cloud", "renamed", .cloud, 239.96370445936918),
    ("blobatar:Locked:droplet", "renamed", .drop, 239.96370445936918),
    ("blobatar:Locked:hexagon", "renamed", .hexagon, 239.96370445936918),
    ("blobatar:Locked:sun", "renamed", .sun, 239.96370445936918),
    ("blobatar:Locked:triangle", "renamed", .triangle, 239.96370445936918),
    ("blobatar:Locked", "renamed", .nub, 239.96370445936918),
    ("blobatar:Locked:Sun", "renamed", .nub, 239.96370445936918),
    ("blobatar:Locked:future-kind", "renamed", .nub, 239.96370445936918),
    ("blobatar:Locked:sun:ignored", "renamed", .sun, 239.96370445936918),
    ("blobatar::sun", "fixture-0", .sun, 230.1128505449742),
    ("blobatar:", "fixture-0", .blob, 230.1128505449742),
    ("blobatar::", "fixture-0", .blob, 230.1128505449742),
    ("blobatar:::sun", "fixture-0", .blob, 230.1128505449742),
    ("blobatar", "", .cloud, 245.71232504211366),
    ("blobatar::sun", "", .sun, 245.71232504211366),
    ("blobatar: :", "renamed", .squircle, 2.9932188615202904),
    ("blobatar: ÉLODIE :boxy", "renamed", .squircle, 184.63534559123218)
])
func pinnedBlobatarRecipesKeepDesktopSeedAndKindSemantics(fixture: (String, String, BotAvatarShape, Double)) {
    let (raw, name, shape, hue) = fixture
    #expect(BotAppearance(rawShape: raw, custom: true).face(for: name) ==
            BotFace(shape: shape, color: BotAvatarColors.blobatarColor(hue: hue)))
}

@Test(arguments: ["default", "DEFAULT", " Default ", "\u{feff}default\u{feff}"])
func primaryProfileKeepsPurpleSquircleUntilExplicitlyCustomized(name: String) {
    var appearance = BotAppearance(rawShape: "blobatar:fixture-33:sun", color: "#123456", custom: false,
                                   imageKind: "shape", expression: "curious")
    #expect(appearance.face(for: name) == BotFace(shape: .squircle, color: "#8b5cf6"))
    appearance.custom = true
    #expect(appearance.face(for: name) == BotFace(shape: .sun,
            color: BotAvatarColors.blobatarColor(hue: 335.02056087367237)))
    #expect(BotAppearance(shape: .triangle, color: "#aBc123").face(for: name) ==
            BotFace(shape: .triangle, color: "#aBc123"))
}

@Test(arguments: ["sigil-17", "icosahedron", "future-outline", "Blobatar:Locked:sun", "blobatar-like"])
func unsupportedRawShapeUsesClassicFallbackWithoutLosingTheSharedChoice(raw: String) {
    let appearance = BotAppearance(rawShape: raw, color: "#AbC123", custom: true, imageKind: "shape", expression: "curious")
    #expect(appearance.face(for: "inbox-triage") == BotFace(shape: .cloud, color: "#AbC123"))
    #expect(appearance.rawShape == raw && appearance.expression == "curious")
}

@Test(arguments: [
    ("blobatar:\u{301}seed:sun", BotAvatarShape.sun, 217.84051685594022),
    ("blobatar:\u{301}seed", .nub, 217.84051685594022),
    ("blobatar:\u{fe0f}seed:sun", .sun, 165.85799320600927),
    ("blobatar:\u{fe0f}seed", .circle, 165.85799320600927)
])
func recipeSeparatorsMatchJavaScriptEvenBeforeCombiningMarks(fixture: (String, BotAvatarShape, Double)) {
    let (raw, shape, hue) = fixture
    #expect(BotAppearance(rawShape: raw, custom: true).face(for: "renamed") ==
            BotFace(shape: shape, color: BotAvatarColors.blobatarColor(hue: hue)))
}
