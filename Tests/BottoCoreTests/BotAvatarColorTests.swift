import Testing
import BottoCore

@Suite struct BotAvatarColorTests {
    @Test func fractionalRGBSpellingsMatchAllTwelveHermesPresets() {
        // Exact decimal channels of HSL(h, 68%, 58%) at the twelve 30-degree hues.
        // Numeric RGB uses 0...255; percentage RGB expresses the same channels.
        let fixtures = [
            ("red", "220.728 75.072 75.072", "86.56% 29.44% 29.44%"),
            ("orange", "220.728 147.9 75.072", "86.56% 58% 29.44%"),
            ("yellow", "220.728 220.728 75.072", "86.56% 86.56% 29.44%"),
            ("lime", "147.9 220.728 75.072", "58% 86.56% 29.44%"),
            ("green", "75.072 220.728 75.072", "29.44% 86.56% 29.44%"),
            ("mint", "75.072 220.728 147.9", "29.44% 86.56% 58%"),
            ("teal", "75.072 220.728 220.728", "29.44% 86.56% 86.56%"),
            ("blue", "75.072 147.9 220.728", "29.44% 58% 86.56%"),
            ("indigo", "75.072 75.072 220.728", "29.44% 29.44% 86.56%"),
            ("purple", "147.9 75.072 220.728", "58% 29.44% 86.56%"),
            ("magenta", "220.728 75.072 220.728", "86.56% 29.44% 86.56%"),
            ("pink", "220.728 75.072 147.9", "86.56% 29.44% 58%")
        ]
        for (id, numeric, percent) in fixtures {
            for channels in [numeric, percent] {
                #expect(BotAvatarColors.preset(for: "rgb(\(channels))")?.id == id)
            }
        }
    }

    @Test func clearPresetsKeepCanonicalSharedKeys() {
        #expect(BotAvatarColors.presets.map(\.id) == [
            "red", "orange", "yellow", "lime", "green", "mint",
            "teal", "blue", "indigo", "purple", "magenta", "pink"
        ])
        #expect(BotAvatarColors.presets.map(\.shared) == [
            "hsl(0 68% 58%)", "hsl(30 68% 58%)", "hsl(60 68% 58%)", "hsl(90 68% 58%)",
            "hsl(120 68% 58%)", "hsl(150 68% 58%)", "hsl(180 68% 58%)", "hsl(210 68% 58%)",
            "hsl(240 68% 58%)", "hsl(270 68% 58%)", "hsl(300 68% 58%)", "hsl(330 68% 58%)"
        ])
        #expect(BotAvatarColors.presets.map(\.hex) == [
            "#ef4444", "#f97316", "#facc15", "#84cc16", "#22c55e", "#34d399",
            "#14b8a6", "#38bdf8", "#6366f1", "#8b5cf6", "#d946ef", "#ec4899"
        ])
    }

    @Test(arguments: [
        ("#abc", "#aabbcc"), ("#aBcD", "#aabbccdd"),
        ("  #AbC123 \n", "#abc123"), ("#12345678", "#12345678"),
        ("#123456ff", "#123456"), ("#0000", "#00000000"),
        ("#a9703d", "#a9703d"), ("#ffffff", "#ffffff")
    ])
    func hexColorsPreserveCustomChannels(input: String, expected: String) {
        #expect(BotAvatarColors.presentation(input) == expected)
        #expect(BotAvatarColors.isValid(input))
    }

    @Test(arguments: ["", "#12", "#12345", "#1234567", "#123456789", "#ggg", "123456", "#abc;", "#ab cd"])
    func rejectsMalformedHex(input: String) {
        #expect(BotAvatarColors.presentation(input) == nil)
        #expect(!BotAvatarColors.isValid(input))
    }

    @Test(arguments: [
        ("rgb(255, 0, 128)", "#ff0080"), ("RGBA(12, 34, 56, .5)", "#0c223880"),
        ("rgb(100% 0% 50% / 25%)", "#ff008040"), ("rgba(100%, 0%, 50%, 25%)", "#ff008040"),
        ("rgba(12 34 56)", "#0c2238"), ("rgb(12,34,56,.5)", "#0c223880"),
        ("rgb(100% 128 0% / .2)", "#ff800033"), ("rgb(1e2 +2.55e2 0)", "#64ff00"),
        ("rgb(-100 500 127.5 / 200%)", "#00ff80"), ("rgb(1 2 3 / -1)", "#01020300"),
        ("hsl(0 100% 50%)", "#ff0000"), ("hsl(120, 100%, 50%)", "#00ff00"),
        ("hsla(240,100%,50%,.5)", "#0000ff80"), ("hsl(210deg 50% 40% / .4)", "#33669966"),
        ("hsl(.5turn 100% 50%)", "#00ffff"), ("hsl(200grad 100% 50%)", "#00ffff"),
        ("hsl(3.141592653589793rad 100% 50%)", "#00ffff"), ("hsl(-90 100% 50%)", "#8000ff"),
        ("hsl(480 100% 50%)", "#00ff00"), ("hsla(0 100% 50%/.125)", "#ff000020"),
        ("hsl(60 -20% 50%)", "#808080"), ("hsl(60 150% 200%)", "#ffffff"),
        ("hsl(1e300turn 100% 50%)", "#ff0000"), ("rgb(1e300 -1e300 0 / 1e300)", "#ff0000")
    ])
    func cssFunctionsPreserveChannelsAndClampFiniteValues(input: String, expected: String) {
        #expect(BotAvatarColors.presentation(input) == expected)
        #expect(BotAvatarColors.isValid(input))
    }

    @Test(arguments: [
        "rgb(1 2)", "rgb(1 2 3 4)", "rgb(1,,2,3)", "rgb(1,2,3 / .5)",
        "rgb(100%,0,0)", "rgb(1 2 3 /)", "rgb(1 2 3 // .5)", "rgb(1. 2 3)",
        "hsl(0 1 1)", "hsl(0, 100%, 50% / .5)", "hsl(0deg100% 50%)",
        "hsl(nan 50% 50%)", "hsl(infinity 50% 50%)", "hsl(1e999 50% 50%)",
        "rgb(1e999 0 0)", "rgb(0x10 0 0)", "rgb(1_0 0 0)", "rgb(1 2 3 / NaN)",
        "rgb(1 2 3);background:red", "rgb(1 2 3)junk", "rgb(1 2 3))", "rgb (1 2 3)",
        "url(https://example.com)", "var(--color)", "currentColor", "color-mix(in srgb,red,blue)",
        "rgb(calc(1 + 2) 0 0)", "rgb(1/**/ 2 3)", "rgb(1 2 3)\u{0}",
        "rgb(１ 2 3)", "rgb(1\u{00a0}2 3)", String(repeating: " ", count: 513) + "#abc"
    ])
    func rejectsUnsupportedOrUnsafeCSS(input: String) {
        #expect(BotAvatarColors.presentation(input) == nil)
        #expect(!BotAvatarColors.isValid(input))
    }

    @Test func presetEquivalenceIsValueBasedWithoutSnappingCustomColors() {
        // Independently calculated with Python colorsys.hls_to_rgb(h/360, .58, .68).
        let hermesHex = ["#dd4b4b", "#dd944b", "#dddd4b", "#94dd4b", "#4bdd4b", "#4bdd94",
                         "#4bdddd", "#4b94dd", "#4b4bdd", "#944bdd", "#dd4bdd", "#dd4b94"]
        for (index, preset) in BotAvatarColors.presets.enumerated() {
            #expect(BotAvatarColors.preset(for: preset.shared) == preset)
            #expect(BotAvatarColors.preset(for: preset.hex) == preset)
            #expect(BotAvatarColors.preset(for: hermesHex[index]) == preset)
            #expect(BotAvatarColors.presentation(preset.shared) == preset.hex)
            #expect(BotAvatarColors.presentation(hermesHex[index]) == preset.hex)
        }
        #expect(BotAvatarColors.preset(for: " HsLa(360deg, 68%, 58%, 100%) ")?.id == "red")
        #expect(BotAvatarColors.preset(for: "hsl(.5turn 68% 58%)")?.id == "teal")
        #expect(BotAvatarColors.preset(for: "rgb(221 75 75)")?.id == "red")
        #expect(BotAvatarColors.preset(for: "#DD4B4BFF")?.id == "red")
        #expect(BotAvatarColors.preset(for: "#f59e0b")?.id == "yellow")
        #expect(BotAvatarColors.presentation("#f59e0b") == "#facc15")
        for custom in ["#a9703d", "#ffffff", "#8e8e93", "#abcdef", "#ef444480",
                       "hsl(1 68% 58%)", "hsl(0 67.99% 58%)", "hsl(0 68% 58.01%)",
                       "hsl(0 68% 58% / .9999)", "rgb(221.01 75 75)"] {
            #expect(BotAvatarColors.preset(for: custom) == nil)
            #expect(BotAvatarColors.isValid(custom))
        }
        #expect(BotAvatarColors.presentation("hsl(0 67.99% 58%)") == "#dd4b4b")
        #expect(BotAvatarColors.presentation("#ef444480") == "#ef444480")
        #expect(BotAvatarColors.preset(for: "invalid") == nil)
    }

    @Test(arguments: [
        (0.0, "hsl(0 68% 58%)"), (14.99, "hsl(0 68% 58%)"), (15, "hsl(30 68% 58%)"),
        (44.9, "hsl(30 68% 58%)"), (45, "hsl(60 68% 58%)"), (344.9, "hsl(330 68% 58%)"),
        (345, "hsl(0 68% 58%)"), (360, "hsl(0 68% 58%)"), (-30, "hsl(330 68% 58%)"),
        (-735, "hsl(0 68% 58%)"), (750, "hsl(30 68% 58%)"),
        (Double.nan, "hsl(0 68% 58%)"), (Double.infinity, "hsl(0 68% 58%)"),
        (-Double.infinity, "hsl(0 68% 58%)")
    ])
    func generatedHSLHuesChooseNearestSharedPreset(hue: Double, expected: String) {
        #expect(BotAvatarColors.presetColor(hue: hue) == expected)
    }

    @Test(arguments: [
        (0.0, "hsl(330 68% 58%)"), (30, "hsl(0 68% 58%)"),
        (60, "hsl(30 68% 58%)"), (90, "hsl(60 68% 58%)"),
        (120, "hsl(60 68% 58%)"), (150, "hsl(120 68% 58%)"),
        (180, "hsl(180 68% 58%)"), (210, "hsl(180 68% 58%)"),
        (240, "hsl(210 68% 58%)"), (270, "hsl(240 68% 58%)"),
        (300, "hsl(270 68% 58%)"), (330, "hsl(300 68% 58%)"),
        (-30, "hsl(300 68% 58%)"), (390, "hsl(0 68% 58%)")
    ])
    func blobatarHuesUseVisibleSRGBFamily(hue: Double, expected: String) {
        // Reference: Blobatar 2.0.0 toHex({l:.7,c:.12,h}) gives #da7d9b at 0,
        // #d58b4b at 60, #09b2c7 at 210, #aa8dde at 300; their HSL families differ.
        #expect(BotAvatarColors.blobatarColor(hue: hue) == expected)
    }

    @Test func generatedColorsHandleExtremeInputsWithoutTraps() {
        for hue in [Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude] {
            #expect(BotAvatarColors.presets.map(\.shared).contains(BotAvatarColors.presetColor(hue: hue)))
            #expect(BotAvatarColors.presets.map(\.shared).contains(BotAvatarColors.blobatarColor(hue: hue)))
        }
        for hue in [Double.nan, Double.infinity, -Double.infinity] {
            #expect(BotAvatarColors.blobatarColor(hue: hue) == "hsl(0 68% 58%)")
        }
    }

    @Test(arguments: [
        ("black", "#000000"), ("silver", "#c0c0c0"), ("gray", "#808080"), ("grey", "#808080"),
        ("white", "#ffffff"), ("maroon", "#800000"), ("red", "#ff0000"), ("purple", "#800080"),
        ("fuchsia", "#ff00ff"), ("magenta", "#ff00ff"), ("green", "#008000"), ("lime", "#00ff00"),
        ("olive", "#808000"), ("yellow", "#ffff00"), ("navy", "#000080"), ("blue", "#0000ff"),
        ("teal", "#008080"), ("aqua", "#00ffff"), ("cyan", "#00ffff"), ("orange", "#ffa500"),
        ("rebeccapurple", "#663399"), (" Transparent ", "#00000000")
    ])
    func boundedNamedColorsKeepCSSValues(input: String, expected: String) {
        #expect(BotAvatarColors.presentation(input) == expected)
        #expect(BotAvatarColors.isValid(input))
        #expect(BotAvatarColors.preset(for: input) == nil)
    }

    @Test(arguments: ["hsl(0 68.0000000001% 58%)", "hsl(0 68% 58.0000000001%)", "rgb(221.00000000001 75 75)"])
    func tinyCustomDifferencesNeverTriggerLargePaletteReplacement(input: String) {
        #expect(BotAvatarColors.preset(for: input) == nil)
        #expect(BotAvatarColors.presentation(input) == "#dd4b4b")
    }

    @Test(arguments: ["rgb(86.56% 29.44% 29.44%)", "rgb(220.728 75.072 75.072)"])
    func exactFractionalRGBEquivalentRecognizesHermesPreset(input: String) {
        // HSL(0, .68, .58) has exact unrounded channels .8656, .2944, .2944.
        #expect(BotAvatarColors.preset(for: input)?.id == "red")
        #expect(BotAvatarColors.presentation(input) == "#ef4444")
    }
}
