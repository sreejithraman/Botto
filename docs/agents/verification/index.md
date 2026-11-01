# Botto feature and verification map

Start here for product acceptance or map maintenance. This index is
authoritative: every recipe under `features/`, including future nested recipes,
must appear exactly once below. Read shared setup before a recipe; read every
recipe for whole-app work. The map inventories capabilities, not passing tests.

All recipes are **draft** until their complete required assertions are
exercised on the recorded target and source snapshot. Component and fixture
tests support particular behaviors; they do not establish that these complete
recipes passed. See the [verification record](../../verification.md) for
recorded checks and current limits.

The chat recipe now follows the button-only contract: the separate overlapping-cards
button opens the chat-pane tab overview beneath the fixed header, the only
in-chat picker. The bot header
avatar/name control opens profile details and editing without chats. Custom chat swipes and adjacent-chat
accessibility shortcuts are removed from the active inventory. Selected native
checks now cover no-switch dragging, picker selection, draft restoration,
creation and Back; complete recipe execution remains draft. See the
[verification record](../../verification.md) for scope and limits.

## Capability inventory

| Feature ID | Recipe | Workflows |
| --- | --- | --- |
| `start` | [Welcome, demo, and destination review](features/start.md) | `start.first-run`, `start.demo`, `start.setup`, `start.address`, `start.qr`, `start.external` |
| `auth` | [Sign in and recover a connection](features/auth.md) | `auth.password`, `auth.browser`, `auth.access`, `auth.interruption`, `auth.recovery` |
| `inbox` | [Find bots and track attention](features/inbox.md) | `inbox.find`, `inbox.activity`, `inbox.pins`, `inbox.navigation` |
| `library` | [Browse artifacts and search chats](features/library.md) | `library.navigation`, `library.outputs`, `library.search`, `library.captures` |
| `chats` | [Choose independent chats with a bot](features/chats.md) | `chats.choose`, `chats.isolation`, `chats.recovery` |
| `chat` | [Converse, keep drafts, and read history](features/chat.md) | `chat.send`, `chat.drafts`, `chat.history`, `chat.reading-position` |
| `requests` | [Answer requests and stop work](features/requests.md) | `requests.approval`, `requests.question`, `requests.recovery`, `requests.stop` |
| `bots` | [Create a bot and inspect its profile](features/bots.md) | `bots.create`, `bots.interruption`, `bots.profile` |
| `avatars` | [Choose avatars and observe motion](features/avatars.md) | `avatars.edit`, `avatars.conflict`, `avatars.identity`, `avatars.images`, `avatars.motion`, `avatars.containment` |
| `uploads` | [Attach files and photos](features/uploads.md) | `uploads.file`, `uploads.photo`, `uploads.budget`, `uploads.retirement` |
| `rich` | [Read interactive replies and diagrams](features/rich.md) | `rich.read`, `rich.source-expand`, `rich.zoom`, `rich.boundaries`, `rich.scroll-lifetime`, `rich.cache` |
| `artifacts` | [Preview, save, and share original files](features/artifacts.md) | `artifacts.preview`, `artifacts.save`, `artifacts.share`, `artifacts.recovery`, `artifacts.retirement` |
| `settings` | [Settings and local data lifecycle](features/settings.md) | `settings.appearance`, `settings.developer`, `settings.about`, `settings.forget`, `settings.storage-recovery` |
| `haptics` | [Choose haptics and feel chat feedback](features/haptics.md) | `haptics.preferences`, `haptics.chat`, `haptics.sheets`, `haptics.playground` |
| `notifications` | [Encrypted push notifications](features/notifications.md) | `notifications.setup`, `notifications.delivery`, `notifications.previews`, `notifications.routing`, `notifications.visibility`, `notifications.removal`, `notifications.recovery` |

IDs are stable coverage keys, independent of filenames. Entry IDs start with
`e.` inside each feature. Required assertions append `.a1`, `.a2`, etc. to the
workflow ID. A step containing multiple obligations requires all of them.
Record every workflow/entry/assertion selected, actions, expected and observed
results, and evidence in an outside-repository run ledger. Use `passed`,
`failed`, `blocked`, or `untested`; workflow precedence is failed, blocked,
untested, then passed only when all required assertions passed. Draft describes
recipe proof; it is separate from a product verdict. A defect reproduction is
also reported separately from fix acceptance.

## Shared setup and readiness

- Open [Botto.xcodeproj](../../../Botto.xcodeproj/project.pbxproj), scheme **Botto**,
  Debug, on an iOS/iPadOS 18+ target. Record HEAD, configuration, signing, model,
  runtime, bundle identifier, and any launch arguments. Use the checked-in
  project; regenerate only after changing [project.yml](../../../project.yml).
  See [setup](../../setup.md) for supported host and authentication paths.
- Read [scripts/check.sh](../../../scripts/check.sh) before running it. From
  the checkout root, `swift test` checks BottoCore. `./scripts/check.sh` repeats
  that and runs Xcode tests on the first available iPhone Simulator, serially,
  with signing disabled and `.artifacts/DerivedData`. It does not select an
  caller-owned target, prove signed Keychain login, or exercise iPad/VoiceOver.
  It attempts a uniquely named Files save/reopen and independently verifies its
  durable provider bytes; `.artifacts/artifact-export-receipt.json` records that
  separate verdict even when UI testing fails. Choose and record the destination
  explicitly when needed; the script's existence does not establish that the
  complete current workflow passed.
- [Contributor CI](../../../scripts/check-ci.sh) runs package, MainActor,
  tooling, and unsigned app/test builds on PRs. Main pushes also execute the
  full serial native suite before TestFlight. Its independent jobs
  feed one required `verify` result; focused manual diagnostics have a separate
  result and do not establish full-suite or release acceptance. The
  [workflow](../../../.github/workflows/ios.yml) runs automatically for public
  repositories and supports manual dispatch once Actions is enabled. Private
  repositories use manual dispatch. The revised split workflow still requires
  hosted verification; prior native readiness failures remain recorded.
- Choose and record an owned Simulator or physical device before native checks.
  Keep builds, automated suites, and interactive work serial when they share a
  device or app container. Use Xcode or a supported device driver for interaction,
  and retain screenshots plus semantic state for visual assertions. Preserve
  unrelated devices and services. If the required platform is unavailable,
  record the affected assertions as blocked rather than substituting another target.
- For first-run checks, use a run-owned fresh Simulator/device profile with an
  empty Botto container and no saved Botto Keychain entry. Reinstall alone does not
  establish empty secure storage. Record isolation and observe welcome without
  a recovery warning. Never erase a shared device or delete a user's connection
  to prepare a run. A reused signed-in launch cannot pass `start.first-run`.
- Normal demo entry is **Explore the demo**; `--demo` is a DEBUG test shortcut
  that skips welcome and starts a fresh in-memory sample workspace. It proves
  neither public onboarding nor durable server state. It seeds Milo's decision,
  Scout's tool details, and Canvas's rich replies and local files. Demo is ready
  when the sample-workspace banner and selectable bot rows appear;
  a chat is ready when opening has settled and `chat-composer` is enabled.
- For real-host checks, use an owned disposable runtime from
  [current authority host](../../dev-host.md) or
  [sidecar host](../../dev-host-sidecar.md), following their setup/status/smoke
  and teardown instructions. These run real Hermes with a deterministic local
  model; preserve reused hosts. A status response alone is insufficient:
  authenticate, publish the roster, open canonical history, and establish a
  usable live socket. Record handshake identity and selected authority/sidecar
  mode, not just a version. Keep named-profile ownership on every readback.
  A physical phone's loopback is not this Mac.
- Existing [core integration](../../core-integration.md) and
  [pairing integration](../../pairing-integration.md) document lower-level
  probes. The opt-in core environment key is `BOTTO_TEST_HERMES_URL`; UI uses
  `BOTTO_UI_TEST_HERMES_URL`, passed to xcodebuild's runner as
  `TEST_RUNNER_BOTTO_UI_TEST_HERMES_URL`. The UI `--fixture-server` loopback-only
  shortcut injects fixture login; it cannot prove the visible sign-in form.

## Credentials, state, and proof

The designated account for host tests is the disposable local Hermes account
defined by the linked host docs, with access to run-owned profiles and harmless
approval tools. Those docs own its setup; copy no credential values here.
No production destination/account or secure automatic UI delivery is established
by this map. Before real-account sign-in, establish approved account scope, runtime
credential access, and delivery into the selected device separately. Missing
delivery blocks automatic login, even if an authenticated session already works.
Use a signed development build for native Keychain login; unsigned Simulator
builds previously failed secure-storage use. Keep credentials, refresh tokens,
tickets, cookies, Access fields, and private chat content out of retained proof.

Use unique `verify-<run>-<purpose>` names and known harmless content. Readiness
and timeout defaults: wait at most 10 seconds for native navigation, 15 seconds
for a local preview, and a declared 30 seconds for an ordinary disposable host
operation. Current-authority creation can wait 45 seconds for shared-profile
publication; browser sign-in owns a 180-second total attempt deadline. Record
these and any fixture-specific longer bound before starting. Capture the first
unexpected result before a recovery retry. For intermittent scrolling choose
three equivalent offscreen/return cycles before driving and record all outcomes.
Do not convert a prelaunch host/CoreSimulator stall into a product failure.

For durable assertions, relaunch/refetch through a fresh model or inspect the
saved value through the public host API/independent Files-provider read. A
same-screen value, staged chip, temporary export URL, reducer test, or successful
download is insufficient. Flush local drafts through normal backgrounding before
relaunch; demo changes reset and do not prove disk persistence. After connection
loss, inspect canonical history before resending an uncertain message or mutation.

Keep evidence outside the map and disposable state. Record logs, semantic
snapshots, screenshots/video, independent durable readbacks, and failed attempts.
Stop only run-owned sessions/processes and remove only run-owned fixtures after
preserving proof. Creation/approval/upload can affect a real host; Save writes
to a provider and Share may leave the device. Use a disposable local destination
and authorized harmless choices. Cancellation cannot promise a remote mutation
was undone. Preserve reused connections, server data, and original system settings.

## Current evidence and material gaps

The [verification record](../../verification.md) identifies the checks and
limits for the source release candidate. Development-only run logs and
historical local artifact paths are not distributed with this source snapshot.
Run the selected recipes against the actual revision and retain new proof in a
run-owned directory. A past test count is not current whole-product acceptance.

Complete recipe sequences remain draft. Material gaps include empty first-run
setup; physical camera/Photos permissions; production Access and external OIDC;
locked-device storage; live Stop and clarification; gateway cold restart;
long compacted/image-heavy history; full iPad resizing and minimum iOS 18
coverage; VoiceOver; and complete signed-device push delivery. Record missing
hardware, credentials, or host support as blocked. Prelaunch infrastructure
stalls are separate from product assertions.

Botto does not expose model/tool administration, a schedule editor, or bot
deletion. Source availability does not establish a published TestFlight flow or
an operated notification service. Host configuration remains in setup docs.
Renderer security components and transport limits support recipes but do not
replace their public UI paths. This map makes no exhaustive security,
performance, localization, or physical-device certification claim.
