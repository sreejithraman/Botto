# Botto identity

Botto's mark brings together three of the app's avatars: an orange squircle,
a blue circle, and a purple drop. The squircle sits in front. The drop overlaps
the circle. Each face uses the app's neutral expression with matching eyes.

The avatar colors come from `BotAvatarColors` presets. The icon background
comes from the dark `BottoSurface` asset. Onboarding uses the same trio over
the adaptive `BottoPaper` canvas.

The wordmark uses the rounded system font with semantic text sizes. It needs
no bundled font and follows Dynamic Type. The surrounding interface uses
the app's colors and navigation.

## Assets

- [Vector mark](../../App/Resources/Assets.xcassets/BottoMark.imageset/BottoMark.svg)
  is the in-app asset used by `BottoMark`.
- [App icon](../../App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png)
  is an opaque 1024 × 1024 PNG. iOS supplies its outer corner mask.

## Regenerate

Run this command from the checkout root on macOS:

```sh
swift scripts/generate-brand.swift
```

[The generator](../../scripts/generate-brand.swift) builds BottoCore and compiles
the app's avatar geometry with [the shared brand definition](../../App/Design/BottoBrand.swift).
It writes both assets from the same paths. Edit the brand definition for
composition changes, or the existing palette and color assets for color changes.
Build files stay in the ignored `.artifacts/brand-generator` directory.

The avatar geometry includes adaptations from Hermex and Bloub. Their MIT
notices remain in [LICENSES](../../LICENSES/). The assets include no external
fonts or symbols.

The mark keeps fixed brand colors in both appearances. App text and controls
continue to use the adaptive color assets.

## Small greeting

Tap the Botto name on welcome or in Settings' About section to show
`ボット`, twisted indigo-and-white headbands, and open indigo happi-style
jackets with crew crests, checkered hems, and dark trim. The costumes stay
inside the original silhouettes, with no hands or sleeves.
The trio is visible before tapping in both places. A tap turns the bots around,
changes their outfits while their backs face you, and finishes with a small
celebratory hop and sparkles. Tap again to return to English: the bots turn
and remove their attire, without a hop or sparkles. Reduce Motion changes
the name and costumes immediately, without the turn, hop, or sparkles.
Changing that preference or leaving the app settles the trio in its current state.

The tagline is **Big ideas. Little sidekicks.** Welcome and Settings share
the same copy from `BottoBrand.tagline`. Welcome keeps the three bots, name,
tagline, and connection/demo actions. Hermes remains named in the Connect action.
