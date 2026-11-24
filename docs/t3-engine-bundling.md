# Bundling the BottoMac T3 engine

On Apple Silicon, **Wake Botto** starts the copy of `t3 serve` shipped with
BottoMac. The upstream command-line release contains the Node.js runtime, so a
Mac running the app needs no separate T3, Node, or Bun installation.

Botto checks the **T3 executable** field in Settings first. You can point it at
an unreleased local build and restart the engine. Clear the field to use the
bundled release, with PATH and the usual macOS binary directories as a fallback.
**Engine → View Server Log** shows the selected source and, for the bundle, its
version, commit and runtime. Upstream publishes the macOS CLI archive for Apple
Silicon. Intel builds use Settings or PATH.

## Adopt a new release

Run these two commands from the repo root, substituting the upstream release tag
you want to try.

```sh
scripts/bundle-t3-engine.sh --pin vX.Y.Z
xcodebuild test -project Botto.xcodeproj -scheme BottoMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

The first command resolves the upstream tag to its commit, reads the Node version
and published archive checksum, and stages the verified release before updating
[`scripts/t3-engine-pin.json`](../scripts/t3-engine-pin.json). Commit that file
after testing. For transport changes, also run `swift test --filter T3` and
`swift test --no-parallel`. The upgrade uses the upstream release as published
and leaves any local T3 checkout untouched.

Running `scripts/bundle-t3-engine.sh` with no arguments stages the current pin.
The BottoMac build calls the same script with `--embed`. First builds need network
access to GitHub. The build phase has script sandboxing disabled on BottoMac to
fetch and cache the archive. Staging is keyed by the pin file's SHA-256 under
`.artifacts/t3-engine/`, which Git ignores. Subsequent builds reuse the staged
files. Removing that cache makes the next build fetch the pinned release again.

## App bundle layout

```text
BottoMac.app/Contents/Resources/T3Engine/
├── t3                 upstream executable with embedded Node.js
├── client/            upstream web and pairing assets
├── node_modules/      upstream runtime dependencies and native add-ons
├── resource-monitor/  upstream helper
├── LICENSE            T3's MIT license at the pinned commit
├── NODE-LICENSE       Node.js runtime license and notices
└── pin.json           copy of the Botto engine pin
```

The upstream archive stays intact, including its web assets and adjacent native
packages. This keeps Botto's packaging independent of the server's internal
dependency layout and preserves the upstream HTTP routes. The app runs the
headless `serve` command and uses the same executable to mint Pair Phone links.

## Check engine shutdown

After building the Apple Silicon app, run
`python3 scripts/check-botto-mac-sigterm.py /path/to/BottoMac.app` to exercise
SIGTERM and Quit against the bundled engine. The test uses disposable data and
verifies that a separately launched engine keeps responding in both cases.
