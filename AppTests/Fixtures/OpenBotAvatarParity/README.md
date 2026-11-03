# Independent SVG raster references

`OpenBotAvatarParity.json` contains 16 complete SVGs emitted directly by
`renderAvatarSvg` in Open Bot Avatar commit
`3a5119877844165eebafe57d3100da475f67d0a8`. The vendored renderer has SHA-256
`2d16fc3f56263f72f43f92e5e2490af759934259df333ae4280159c7e252bb07`.
The generator imports upstream source directly. It does not import Botto's
bridge, native frame adapter, path converter, or painter.

Run from the repository root with Node 22 or newer:

```
node --experimental-strip-types AppTests/Fixtures/OpenBotAvatarParity/generate.mjs
```

The fixture SHA-256 is
`e046d94d821c5d87265f0d0a0f22a355afd15f0bacb92170666e470bf1d25e98`.

The ten Hermes definitions come from the checked-in preset catalog. Mug and
Watering Can come from upstream examples. `cat.json` is the author's definition
shared in the original demonstration thread:
https://x.com/dom_scholz/status/2116275272903274951

All 13 definitions have a still reference at natural depth. Mug, Watering Can,
and Cat also have a happy reference at depth 10 with yaw 1.1 and pitch 0.17.
These turned cases expose separate cross-section stacks, holes, rotated SVG
arcs, eye arcs, matrix composition, and painter ordering.

Botto intentionally owns its palette. References use literal body `#b0c8e0`
and opaque ink `#1a1e22`, the RGB equivalent of Botto's 85%-opaque black eyes
over that body. This isolates geometry parity from the palette decision.

`OpenBotAvatarParityTests` rasterizes each SVG with a test-owned WKWebView and
renders real engine frames through the production SwiftUI Canvas. Both use a
white 256-point square and are normalized to 256 sRGB pixels. Each reference
load and snapshot has one shared 15-second deadline. Comparison allows one
pixel at quantized paint boundaries and eight channel levels in uniform
interiors. It permits zero pixels outside those allowances. A separate test
requires this same comparator to reject the wrong view and erased happy eyes.
Failures attach both rasters. Native execution is required to establish parity;
fixture regeneration and Swift parsing alone do not establish it.
