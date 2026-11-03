# Open Bot Avatar engine

`upstream/` contains unchanged DOM-free source from Open Bot Avatar revision
`3a5119877844165eebafe57d3100da475f67d0a8`. `UPSTREAM.json` records its hashes
and the pinned bundler version. Preserve the bundled MIT license.

`bridge.ts` passes definitions as data to the canonical validator and renderer.
It prepares vector paths once, transfers only numeric frame changes, and bounds
its registration and animator caches. Generated cross-sections use the engine's
own polyline coordinates; the original body retains exact curves and arcs.

Bridge errors distinguish explicit validator rejections (`invalidDefinition`)
from renderer exceptions (`renderer`). Swift preserves rejection diagnostics and
maps renderer failures to `invalidFrame`, allowing bounded recovery of the same
character. A rendering exception must never permanently reject its definition.

The premade catalog starts from Botto's earlier contours from `3729934` in
`App/Design/BotAvatarGeometry.swift`. Overlapping ellipse parts are joined into
single outlines and fitted to the spec's safe area. Later visual tuning keeps
the first canonical hexagon, rounds the triangle with tangent circular arcs and
enlarges the cloud's center puff. The cloud is mirrored so its larger side puff
sits on the right. Shape IDs, colors and eye definitions stay independent of
those contours. Regenerate resting frames after editing
`HermesAvatarDefinitions.json`.

Regenerate the local JavaScriptCore bundle and canonical resting preset frames:

```sh
python3 scripts/avatar-engine/build.py
python3 scripts/avatar-engine/build.py --check
```

The build uses Node/npm and pinned esbuild 0.28.2. No Node, network, DOM or
external JavaScript is used by the app. Preset previews contain only the paths
their resting frame uses; the actor prepares complete paths before live frames.

Regenerate independent Node reference fixtures for the Swift bridge checks:

```sh
node --experimental-strip-types scripts/avatar-engine/reference.ts
swift test --filter OpenBotAvatarEngineTests
```

The references call the unchanged engine directly, independently of the bridge.
They include fixed moods and side turns, projected eye visibility and happy arcs.
