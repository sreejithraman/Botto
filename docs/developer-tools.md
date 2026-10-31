# Developer tools

In Debug and Internal builds, open **Settings → Developer menu**. The menu
contains **Avatar playground** and **Haptics playground**. No unlock gesture or
saved preference is required. Before connecting a host, choose **Explore the
demo**, then open Settings from the inbox.

The avatar playground uses isolated sample bots and the app's avatar renderer.
Its embedded demo returns to the gallery when you leave; host pairing stays
outside that preview.
The haptics playground auditions the shared vocabulary and a sample bottom sheet.
Its haptic preferences are the app's saved preferences. Use a physical iPhone to
judge touch; Simulator only checks the interface and requested feedback.

## Build channels

| Configuration | Scheme | Developer menu | Build behavior |
| --- | --- | --- | --- |
| Debug | Botto | Included | Development build and test fixtures. |
| Internal | Botto Internal | Included | Release optimization, production APNs, playgrounds. |
| Release | Botto | Excluded | Public App Store candidate. |

`Internal` defines `BOTTO_INTERNAL_TOOLS`; it does not define `DEBUG`. Only the
menu, playgrounds and their avatar preview hooks use that flag. Debug launch
shortcuts, fixture servers, test gates and instrumentation remain Debug-only.
Keep the configuration definitions in `project.yml`; regenerate with XcodeGen
after changing them.

Debug also supports `--developer-menu` and `--bot-motion-lab` launch shortcuts.
Internal builds use the normal Settings entry.

## Internal TestFlight delivery

The integrated publisher archives scheme **Botto Internal** with
**configuration Internal**:

```sh
asc xcode archive --project Botto.xcodeproj --scheme 'Botto Internal' \
  --configuration Internal --archive-path /path/to/Botto.xcarchive
```

The publisher preserves its signing, version, destination and profile arguments.
Both target version lookups select Internal. It exports with
`testFlightInternalTestingOnly = true` in ExportOptions.plist and distributes
only to the internal group. Apple's
[Internal Only distribution](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases)
prevents that build from being submitted to the App Store. A public candidate
needs a separate Release archive without the internal-tools flag.

Changing tester groups does not change a compiled app. An already-installed
TestFlight build gains the menu only after a new Internal build is uploaded
and installed. Source integration is complete. Hosted signed delivery, Apple
readback and signed-device installation still need verification.

## Checks

`DeveloperToolsUITests/testDeveloperToolsMatchBuildConfiguration` follows the
normal welcome/demo and Settings route, without a Debug launch shortcut. Run it
in Debug, Internal and Release. Its expected behavior comes from the test
bundle's build-configuration metadata, independently of the app's tool flag.
The Botto Internal scheme selects this test class and builds only the app and
UI-test target. Cmd-U therefore avoids suites that require Debug-only fixtures.

The automated check uses a Simulator-only launch argument to choose volatile
connection storage before AppStore initializes. It never loads a saved host,
touches its credentials or cleans its caches, and it must use the public
**Explore the demo** entry. Physical builds exclude that launch hook; the check
skips before launching them. Use manual signed-device checks for TestFlight
navigation and tactile quality.

These checks prove menu access, both playground presentations and return, and
the public build's menu exclusion. Physical haptic tuning and signed TestFlight
installation require separate checks.
