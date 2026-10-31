# Settings and local data lifecycle (`settings`)

## User-facing description

Inspect connection status, choose appearance, read bundled attribution/licenses,
and deliberately remove local setup. Recover saved-storage failures without
overwriting existing data. Sub-features: appearance, About, licenses, local
forget/cancel, unavailable Keychain, scoped cache cleanup, and internal developer tools.

## How to get to it

- `settings.e.inbox`: inbox top-leading Botto mark labeled **Settings**.
- `settings.e.appearance`: Settings → **Appearance** → System / Light / Dark.
- `settings.e.developer`: Debug/Internal Settings → **Developer menu** →
  **Avatar playground** or **Haptics playground**. From welcome, first choose
  **Explore the demo**. Public Release builds exclude this entry.
- Notification setup, preferences, and device removal use the separate
  [notifications recipe](notifications.md).
- `settings.e.about`: Settings → **Open-source licenses** → **Pele · MIT and
  ISC licenses**; About also links Hermes and Hermex externally.
- `settings.e.forget`: connected Settings → **Forget this connection** →
  **Forget on this device** or **Cancel**.
- `settings.e.recovery`: failed normal saved-setup load → **Retry saved setup**
  or **Forget saved setup**. Demo Settings instead offers **Leave demo**;
  [start](start.md) owns that flow. [Auth](auth.md) owns reconnect/details.

## Interactive checks

Use [shared setup](../index.md), an owned disposable connection with distinct
draft/history/pin markers, and an independent host reader. Forget is destructive
to local data; never use a shared personal connection as a fixture. **Draft;
complete sequences were not run.** Do not inspect or retain credential values.

Workflow `settings.appearance`:

1. `.a1` Open Settings, choose each appearance. Expect System follows actual
   system light/dark; Light/Dark force that appearance across inbox, chat,
   rich/native preview, profile/create and Settings. Done returns correctly.
   Proof: system state and screenshots on small iPhone and wide iPad.
2. `.a2` Background/relaunch without demo shortcut; expect saved appearance
   read from fresh app preferences. At accessibility XXXL, increased contrast,
   Reduce Transparency and actual Reduce Motion, controls and content must remain
   readable/reachable. VoiceOver must expose current selected value and Done
   in useful order. Proof: independent preference/current system read and actual
   focus/spoken record. Reset only this run's changed system settings.

Workflow `settings.developer`:

1. `.a1` Build Debug and Internal separately using
   [developer tools](../../../developer-tools.md). Start normally, choose the
   public demo entry if needed, open Settings, then open and close each
   playground. Expect both destinations and return to the same developer menu.
   Run `DeveloperToolsUITests/testDeveloperToolsMatchBuildConfiguration`
   in each configuration on Simulator. Its launch hook selects volatile
   connection storage before any saved setup loads, then requires the public
   demo entry. Physical builds skip this automated check before app launch.
   Proof: configuration, visible controls and native
   navigation assertions. Neither a Debug launch shortcut nor an unsigned
   Simulator install proves an installed TestFlight build.
2. `.a2` Build public Release and open Settings. Expect normal Touch/About
   controls and no developer entry. Run
   `DeveloperToolsUITests/testDeveloperToolsMatchBuildConfiguration`.
   Inspect compilation conditions and confirm the playground types are excluded.
   Proof: configuration, native assertions and built artifact.
3. `.a3` Verify the internal publisher archives Internal and exports Internal
   Only, install that exact new TestFlight build on an owned iPhone, then repeat
   both menu paths. Confirm app/build identity and separate public Release
   selection. Proof: export settings, Apple build record and phone navigation.
   Draft until this signed distribution sequence is run.

Workflow `settings.about`:

1. `.a1` Open licenses. Expect bundled Third-party notices, full Hermex and
   Bloub license text, then Pele license navigation with readable/selectable
   text, including offline. Done returns to Settings. Proof: screenshots and
   text comparison against bundled notices/licenses; “couldn’t be loaded” fails.
2. `.a2` Open each About external link through its public entry. Expect the
   documented Hermes/Hermex destination in system browser and usable return to
   Botto. Do not authenticate or mutate external services. Proof: URL and return
   capture. Repeat large text/VoiceOver license scrolling and navigation.

Workflow `settings.forget`:

1. `.a1` Capture owned host bot IDs/count and local marker state. Open forget
   confirmation, Cancel. Expect original connection, draft/history/pins intact
   on fresh relaunch. Proof: confirmation and fresh state readback.
2. `.a2` Reopen, choose Forget on this device. Expect welcome, local credentials
   removed, local drafts/cache cleared, no old pending actions or late content.
   Relaunch normally and independently verify saved configuration absent without
   printing Keychain values. Inspect run-owned cache marker removal through a
   fresh filesystem read. Proof: welcome, redacted absence result, marker absence.
3. `.a3` Refetch host profiles/history independently. Expect server bots and
   messages unchanged. Reconnect deliberately; expect host history returns but
   old local draft/pin overrides do not. Release held old events/download/upload
   after forget; expect no restoration into welcome/new workspace. Proof: host
   readback and late-completion UI, not an assumption that disconnect stopped work.

Workflow `settings.storage-recovery`:

1. `.a1` On an isolated signed target/owned secure-store fault fixture, make
   saved Keychain read unavailable. Launch normally; expect **Can’t open saved
   setup**, Retry/Forget options, and no implicit overwrite/cache
   pruning. Restore access and tap Retry; expect the existing verified setup.
   Proof: native recovery UI and independent redacted storage/cache presence.
2. `.a2` Separately fail save/remove/readback during connection replacement or
   Forget. Expect honest error and prior usable setup/cache preserved until
   removal/commit is confirmed; no false welcome/success. Retry after restoring
   prerequisite. Proof: UI plus independent original identity/cache markers.
   For the store's Demo transition, a failed history save must leave the
   original connection, selection, conversation, and draft intact, with the
   save warning visible. Restore storage and retry; a fresh cache read and
   return from Demo must recover the latest draft. Background save failure
   must also retain the draft through same-workspace recovery.
3. `.a3` Prepare run-owned old UUID caches alongside a noncache file/directory/
   symlink fixture. Successfully commit replacement or forget; expect only
   unreachable owned connection caches removed, unrelated fixtures intact.
   Proof: fresh directory manifest before/after, never credential contents.
   Core/native injected persistence tests support this boundary but do not
   prove locked physical-device Keychain behavior.

## Gotchas

Source: [SettingsView](../../../../App/Views/SettingsView.swift),
[OnboardingView](../../../../App/Views/OnboardingView.swift),
[LocalHistory](../../../../App/State/LocalHistory.swift),
[ConnectionVault](../../../../App/State/ConnectionVault.swift),
[AppStore](../../../../App/State/AppStore.swift).
[Native state tests](../../../../AppTests/AppStoreTests.swift) and
[verification history](../../../verification.md) support transactional storage,
refresh persistence and scoped cleanup. No live locked-device acceptance is
claimed. Fresh reinstall may retain Keychain; simulated faults cannot substitute
for physical lock/unlock proof. No app UI provides arbitrary cache erasure or
credential inspection; use only owned diagnostic readback for independence.
[History transition tests](../../../../AppTests/AppStoreHistoryTests.swift)
block a run-owned cache file and verify Demo, replacement, and background
recovery through the store boundary, including fresh cache reads.
Local forget does not revoke host credentials or delete server bots. Verify
notification pairing removal and pending remote cleanup using the notifications
recipe. Preserve run evidence before deleting owned data and restore changed
appearance settings.
The separate [admission-identity journal](../../../../Sources/BottoCore/Networking/HermesSubmissionJournal.swift)
stores bounded send/admission IDs without prompt text or credentials; it is not
an outbox. Cache pruning deliberately excludes its directory, other directories,
and symlinks. Do not misreport those surviving files as stale conversation caches.
