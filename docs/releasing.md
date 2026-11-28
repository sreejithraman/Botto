# Source releases

The first Botto source release is **0.1.0**. Release tags use the `v` prefix,
for example `v0.1.0`.

[Internal TestFlight delivery](testflight.md) has a separate GitHub workflow,
signing setup, and beta acceptance path. A source release does not publish an
Apple build.

## Prepare a release

1. Start from the reviewed `main` branch. Set `Botto`, `BottoNotifications`,
   and `BottoMac` to the same `MARKETING_VERSION` in `project.yml`, then
   regenerate the project with XcodeGen 2.46.0.
2. Run the [contributor checks](../CONTRIBUTING.md#check-a-change), including the
   relevant UI and file-export workflows. Verify signed T3 pairing, live Space workflows, and physical notification
   delivery separately from unsigned tests.
   Resolve failures and update the [verification record](verification.md).
3. Clone the exact candidate into a clean directory. Follow the README and run
   checks there without relying on local source checkouts or generated files.
4. Refresh any published sample-data screenshots. Review source, fixtures,
   documentation, dependencies, media, and archive metadata for private content.
   Keep credentials and signing material out of source and release assets.
5. Preserve `LICENSE`, `LICENSES/`, `THIRD_PARTY_NOTICES.md`, and component licenses.
   Keep source pins and captured-fixture provenance accurate.
6. Update the changelog with the version, actual release date, behavior changes,
   and known limitations. State experimental push prerequisites explicitly.

## Publish

1. Confirm that hosted CI passes on the exact commit to be tagged. Local results
   do not substitute for the hosted run.
2. Create an annotated version tag, such as `v0.1.0`, on that commit.
3. Publish the matching GitHub source release using the changelog entry. Include
   relevant compatibility limits and the verification scope. An App Store or
   TestFlight build is a separate distribution process.

Rebuild and recheck the candidate after any source change. An earlier screenshot
or test result does not cover later source.

## macOS releases (Sparkle + Homebrew)

`Botto.app` (Xcode target `BottoMac`, bundle ID `com.sree.botto.mac`) is
distributed outside the Mac App Store as a Developer ID–signed, Apple-notarized
`.zip` archive with Sparkle 2 auto-updates and Homebrew casks in
`sreejithraman/homebrew-tap`:

- **Beta channel:** `brew install --cask sreejithraman/tap/botto@beta` (`Casks/botto@beta.rb`, GitHub prerelease tag `vX.Y.Z-beta.B`, Sparkle `<sparkle:channel>beta</sparkle:channel>`).
- **Stable channel:** `brew install --cask sreejithraman/tap/botto` (`Casks/botto.rb`, GitHub release tag `vX.Y.Z`, default Sparkle channel).
- **Versioning:** Align `MARKETING_VERSION` across iOS (`Botto`, `BottoNotifications`) and macOS (`BottoMac`). Keep `CFBundleVersion` (build number) strictly increasing per platform.

### Local Mac release

Requires a `Developer ID Application` signing identity in Keychain, `asc`
(or `xcrun notarytool` profile via `BOTTO_NOTARY_PROFILE`), `gh` authenticated
to both `sreejithraman/Botto` and `sreejithraman/homebrew-tap`, and the Botto
Sparkle Ed25519 private key in Keychain under account `botto` (matching
`SUPublicEDKey` in `Mac/Resources/Info.plist`).

```sh
python3 scripts/mac-release.py package \
  --channel beta \
  --version 0.2.0 \
  --build 1

python3 scripts/mac-release.py publish \
  --channel beta \
  --version 0.2.0 \
  --build 1 \
  --zip dist/mac-release/Botto-0.2.0-beta.1.zip
```

`package` archives `BottoMac`, exports with Developer ID signing, verifies
`codesign --verify --deep --strict` and the bundled `T3Engine/t3`, notarizes,
staples, verifies `spctl`, and writes the `.zip` and `.sha256`. `publish`
creates or updates the GitHub release, regenerates and pushes the Ed25519-signed
`appcast.xml` on `main`, and updates the matching cask in
`sreejithraman/homebrew-tap`.

### GitHub Actions Mac release

`.github/workflows/mac-release.yml` runs the same `package` and `publish` flow
on demand via **Actions → Mac Release** in the `apple-release` environment. In
addition to the existing `ASC_PRIVATE_KEY` secret, configure these environment
secrets before running it in CI:

- `MAC_DEVELOPER_ID_CERTIFICATE_BASE64` and `MAC_DEVELOPER_ID_CERTIFICATE_PASSWORD`
- `APPLE_API_KEY_ID`, `APPLE_API_ISSUER_ID`, and `APPLE_TEAM_ID`
- `SPARKLE_PRIVATE_KEY` (exported via Sparkle's `generate_keys --account botto -x`)
- `BOTTO_TAP_PUBLISH_TOKEN` (PAT with `contents: write` on `sreejithraman/Botto` and `sreejithraman/homebrew-tap`)
