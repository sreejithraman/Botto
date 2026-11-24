# Set up Botto

BottoMac starts a local T3 Code Orchestrator v2 host. The phone joins that host's
workspace over an origin you review before connecting.

<a id="2-choose-the-native-listener"></a>

## Run Botto on your Mac

1. Install the upstream T3 CLI and configure at least one model provider. This
   checkout finds `t3` in standard executable locations, or uses the executable
   path set in Botto Settings.
2. In Xcode, open `Botto.xcodeproj` and run **BottoMac**. Finish first-run setup
   by naming the bot and choosing its drawn face. The Main Space initially takes
   the bot's name.
3. Choose **Pair Phone…** from the Engine menu or the Botto inspector’s
   Advanced section. Pick **LAN**
   for the same trusted network, **Tailscale** for devices on your tailnet, or
   an HTTPS tunnel origin that forwards to the Mac's local T3 host.

## Pair an iPhone or iPad

1. Choose **Pair with your Mac**. Scan the QR shown on the Mac or paste its
   pairing link. Generate a fresh link if the one-time link expired or was used.
2. Verify the displayed origin. For an HTTP address on a trusted local network,
   enable **Allow an HTTP connection** on the review screen. Use HTTPS for a
   public origin.
3. Connect. Botto saves the pairing and opens a Space in the Mac's workspace.
   The Mac must stay awake and reachable while you use it from the phone.

Use the Mac's LAN or Tailscale address for a physical phone. A phone's loopback
address points to the phone itself. An HTTPS tunnel needs to forward both HTTP
and WebSocket traffic to the same host. Treat the QR and copied link as
credentials until they are used or expire.

If a saved connection fails, check that the Mac's host is running and reachable
at the saved origin. To switch origins or replace an expired credential,
generate a fresh link and review the destination again in Settings.

## Build and signing

Use macOS with Xcode 27.1 or later and an installed iOS Simulator runtime.
Botto supports macOS 15, iOS 18, and iPadOS 18 or later and uses Swift 6. The checked-in
`Botto.xcodeproj` is ready to open; `project.yml` owns its generated settings.

For Simulator use, select the **Botto** scheme and an iPhone or iPad, then Run.
**Explore the demo** works offline. Command-line checks can disable
signing, but unsigned runs do not establish native Keychain credential storage.
Use a signed development build when testing real credential storage.

For a physical iPhone or iPad:

1. Use an Apple development team authorized for Push Notifications. Register an
   app identifier and its `.notifications` extension identifier for that team.
2. Set `BOTTO_APP_BUNDLE_IDENTIFIER` in `project.yml` to your app identifier and
   set your `DEVELOPMENT_TEAM`. The extension and shared push Keychain group
   derive from that value. Regenerate the project.
3. In Xcode, confirm automatic signing or supply matching profiles for both
   **Botto** and **BottoNotifications**. The app profile must authorize the
   `aps-environment` entitlement. Debug selects sandbox APNs; Release selects
   production.
4. Keep the app-private Keychain group first and the push group second in the
   app entitlements. The extension receives only the push group. Confirm the
   signed app and extension use the same expanded push group.

The source includes Push Notifications entitlements even when notifications
are unused. A profile without that capability cannot sign the stock device
build. The repository contains no reusable signing identity or provisioning
profile. Distribution requires your own signing and App Store Connect access;
follow [internal TestFlight delivery](testflight.md) for the protected GitHub
publishing path. Contributor builds and checks do not require those release
credentials.

When changing `project.yml`, use
[XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.46.0 and regenerate:

```sh
xcodegen generate
```

See [pairing integration](pairing-integration.md) for connection and storage
boundaries, and [verification](verification.md) for checked routes.
