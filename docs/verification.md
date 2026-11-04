# Verification

Botto 0.1.0 was checked on 30 October 2026 with Xcode 27.1. Native observations
below use an iPhone 17 Pro Simulator running iOS 26.5. These results describe
the checked source and workflows, not every supported device or server.

## Static custom avatar compatibility (3 November 2026)

Custom character Save and custom creation now export a transparent 512px PNG
from the canonical resting frame. The recipe remains in shared metadata and
`bottoPreviewSHA256` identifies the derived asset. Botto animates the recipe;
image-capable clients can display the PNG. Color edits refresh it and preset
replacement clears it. Different image bytes and explicitly marked photos
retain image precedence. Other clients own their image-cache refresh behavior.
Hermes Desktop itself was not driven in this run. Interactive Botto fixture
launch hit the unsigned build’s Keychain recovery screen; the native assertions
above use the app’s public test interfaces.

The initial Save regression failed with no asset upload, then passed. All 470
Core tests passed; the MainActor-default compatibility build and arm64 iOS app
and test-bundle build passed. On an owned iPhone 17 Pro / iOS 27.0 Simulator,
51 tests in AppStoreAvatarTests and CustomAvatarLayoutTests passed. These cover
preview-versus-photo precedence, native painting and existing avatar lifecycle.
A refresh between metadata save and image upload reproduced stale cached art in
both Save paths; the test failed before explicit post-Save revalidation and
passed afterward. Timeout/rejection tests retain partial-save reporting and no
automatic replay. Metadata and image writes remain separate host operations.

A later review found that the old 160px face-copy heuristic could still hide a
different marked replacement, and the editor could mistake an unresolved image
for a confirmed preview. Both reproduced through native public interfaces before
repair. The store now retains a distinct confirmed-preview result; pending or
failed reads keep the replacement explanation, and marked nonmatching images
bypass the legacy size heuristic. All 53 tests in the same two native suites
passed after repair, including explicit-photo cases and held or failed reads
followed by Save. Canceling revalidation also reproduced an older confirmation
returning; queueing a recheck now discards that confirmation until fresh matching
bytes arrive. The regression covers cancellation, reuse and successful recovery. An optional offscreen editor capture failed in SwiftUI’s
navigation renderer and was removed from the test harness. No interactive editor
or Desktop UI pass follows from these state checks.

A disposable real Hermes authority host at `4a0eaf79` passed custom generation,
Save, independent metadata and PNG readback, custom bot creation with its PNG,
chat-access preservation, cache roundtrip and later preset replacement. Only the
model was deterministic. Its missing Python interpreter was restored inside the
disposable fixture before the successful run. A first native runner attempt used
the parent SimLock directory and could not find the device; the corrected exact
iOS device set passed. These results do not establish real-provider character
quality, every client’s cache behavior, physical-device or whole-app acceptance.

## Canonical avatars (2 November 2026)

Avatar work started from `origin/main` at `3729934`. All ten Hermes shape
families now use premade Open Bot Avatar v1 definitions and the pinned canonical
engine at `3a5119877844165eebafe57d3100da475f67d0a8`, painted by native Canvas.
Existing identity and metadata need no migration.

The premade body contours start from the earlier Botto shapes from `3729934`,
including Cloud's three puffs and Drop's broad base. Later visual tuning restores
the first canonical hexagon, rounds the triangle's corners with circular arcs
and enlarges Cloud's middle puff. The cloud is mirrored so its larger side puff
sits on the right. Overlapping parts are joined and fitted to the canonical
safe area. IDs, eye definitions, colors and engine behavior are preserved.
The earlier restored catalog passed all 466 Core tests and reproducible preview
generation. Timing and RSS measurements below also describe earlier catalogs.
Contour comparisons use the production painter on macOS. A later iPhone 17 Pro
Simulator run on iOS 27.0 captured the final contours in light and dark appearance:
48 pt catalog, 56 pt rows and fitted chat header, 88 pt gallery, and 110 pt editor.
The triangle corners look rounded and the cloud's larger side puff is on the
right. Thinking and Offline cues were inspected on the changed shapes. Saving
the triangle and reopening retained it; canceling a staged cloud kept the
triangle. These editor checks use demo memory, not Hermes persistence.

The separate 30 pt squircle header sample in the playground lets its Offline
cue touch the adjacent label. Complete containment and the broader native
workflow suite remain unproven. Actual system Reduce Motion, VoiceOver, iPad,
physical devices and device energy were not checked in this visual run. The
fresh supported T3 session succeeded and was released after capture export.

The three-shape tuning passed 48 focused avatar tests; its hexagon render
matches the first canonical version byte-for-byte. The subsequent corner and
cloud repair changes only triangle and cloud body paths. Its geometry checks
verify circular corner radii, tangent joins after canonical normalization and
an exact horizontal cloud reflection. Thirteen focused catalog/reference tests,
reproducible preview generation and generic iOS app/test compilation pass.

The core gate passes 466 tests and its MainActor-default compatibility build.
The reproducible engine build, upstream source hashes and independent Node
frame comparisons pass. On this Mac, decoding all ten bundled resting previews
measured 14.22 ms. Preparing ten complete shapes measured 9.54 s on the engine
actor; bundled resting faces remain available during preparation. A warm
11-avatar workload of 330 frame requests measured 57.13 ms total after moving
cache lookup ahead of validation (previously 1298.96 ms for the same workload).
These numbers cover the earlier single-VM bridge, not native painting or iPhone
energy use. After isolating cold work, a fresh Mac run measured the same 330 warm
frames at 70.70 ms alone and 58.76 ms during a separate cold preparation. This
proves no shared actor queue; the small timing difference is not a speedup claim.
Ten prepared VMs added about 112.6 MB RSS in that process, including geometry and
assets. The revised registry keeps twelve playback VMs plus at most two temporary cold
VMs and a validator. Eighteen engine tests pass, including thirteen
active definitions, temporary preparation at full capacity, shared cancellation,
abandoned work, and per-instance cleanup without a registry-wide barrier.
Physical-device memory and behavior with more simultaneous distinct faces remain
unmeasured.

A disposable authority host at Hermes `4a0eaf7989b6804319ddb94fa5d96c5a716080a1`
with a deterministic local provider passed generation, no pre-Save profile or
chat-history writes, explicit Save, independent fresh-client metadata read,
cache roundtrip, preserved live chat access, and later classic-shape replacement.
It does not prove real Codex character quality or final provider identity.
Native raster parity, layout and UI acceptance are being checked separately.

A source review found that one renderer error could end a mounted avatar's
live loop. A regression failed before the repair, then passed against the
production model and native cache in an isolated macOS Swift Testing harness.
Seven tests cover resumed frames with the current activity and a fresh instance,
bounded persistent failure, suspended cleanup, cancellation, retirement,
replacement and exact instance cleanup. Preparation tests distinguish temporary
failures from invalid definitions and reject late results after replacement.
The same tests are in the iOS app suite; their iOS execution remains pending.
The bundled JavaScript/Swift worker regression also injects a failure after
validation, verifies renderer-error classification and successful preparation of
the same character on retry, and preserves real validator-rejection diagnostics.
Service regressions cover recovery of a valid generated result with one model
request, bounded validation/preparation failures, cancellation/disconnection,
and zero Save/create writes on renderer failure. The new hosted AppStore test
checks deliberate retry before a write and partial-save recovery after metadata
is saved; it compiles but still awaits iOS execution.

Evidence lives in the owning worktree's `.artifacts/custom-avatar/` and
`/tmp/botto-custom-avatar*` logs. Physical-device performance, actual system
Reduce Motion, VoiceOver, iPad layouts, production model quality and complete
avatar recipe acceptance remain unproven by these checks.

## Offline cache withdrawal follow-up (1 November 2026)

The locked-initial-index/no-chat-book regression fails on `436becc`: after a
real roster omits a bot, a new offline library can restore its saved metadata
without another Library entry. The repair retains scoped roster restrictions in
the existing recovery journal. SQLite enumeration cannot retire them because an
unreadable old book may reappear. Checked SQLite replacements admit only their
own chat; book seeds never inherit those receipts. Later omissions revoke the
profile's checked rows. Quota overflow records the narrowest durable withholding
marker that fits, while original captures remain separate.

The macOS harness compiles the production cache, library and chat book owners,
with copied native text/Search declarations and existing test fixtures. Its
62 selected definitions (118 expanded cases) pass, covering the four original
restart cases, unavailable/reappearing books, a checked replacement with an
unchanged or changed tip, withdrawn siblings, delayed/paused/acquisition-pending
writers, scoped quota fallback, queued cleanup, capture rollback, original bytes,
and existing cancellation/publication regressions. A delayed peer acknowledgment
and failed-roster retries (including empty and reentered rosters) also pass.
The new recovery regressions failed before repair. Cached-evidence
Library retry now saves only pending observed evidence. Eight restore/seed
orderings verify immediate pending exclusions, same-roster admission fences,
fresh-read preservation and unaffected peers. Seeds remain unreconciled after a
failed initial restore. Later reseeds preserve admitted fresh rows and their
dirty writes. A successful retry preserves an eligible queued book request;
deferred seed writes remain pending until reconciliation. These eight additional
cases also verify cold persistence and original bytes. Row acknowledgments clear
only their own guards; failed
roster admission retains its pending intersection and warning until Library
retry or a real observation saves it. The original restart, unavailable-book,
quota and changed-tip cases each failed before their repair.

A repeated removal-recovery assertion exposed a refresh returning while a
successor persistence task still wrote metadata. The writer wait now drains
successor tasks and post-scan persistence without retrying failed storage in a
loop. The original assertion passed 30 focused attempts after the drain change.
The unchanged-main control passed 20 attempts; that is not evidence that the
intermittent failure was pre-existing. Logs, failure traces and frozen source
inputs remain under `.artifacts/cache-fix/` in the owning checkout.

All 417 core tests and the MainActor compatibility build pass after integrating
main `5d70927`. The unsigned arm64/x86_64 generic Simulator app and both test bundles
compile. Local verification compiled the new public AppStore regressions for
missing/unreadable LocalHistory, the actual AppStore Library retry, and
later-readable protected history without executing them (five cases). Owner
checks use independent cache instances in one macOS process; they do not establish
an iOS process restart, full Library recipe, export, physical-device or release
acceptance.

## Credential and startup follow-up (1 November 2026)

Source at `332c0a5` confirms that ordinary setup-test launches can load a saved
connection and reconnect before welcome assertions. `SetupUITests` now selects
the existing Simulator-only isolated store, keeps that selection at large text,
and skips physical devices. All seven test bodies and their assertions remain
unchanged. The suite typechecks for iOS and Simulator with warnings as errors;
its UI workflows were not rerun. This is setup coverage, not signed Keychain
coverage. The existing injected-storage launch tests remain in place.
All 408 core tests and the MainActor compatibility build pass locally.

An isolated compiler fixture using the current `BottoWorkspace` body reproduces
the three Xcode 27.1 capture warnings. Explicit strong capture by the startup
task removes them; the global push callbacks still capture the store weakly.
A standalone fixture using the task body retains a substitute store through
suspension and releases it after completion with callbacks still installed.
These fixtures do not establish full-app deallocation or a memory-leak fix.
The initial unsigned Release archive stopped because the disk was full. After
space became available, the arm64 Release archive passed with no startup-capture
warnings. Native execution remains unverified: T3 could not discover the fresh
run-owned Simulator, even after its suggested refresh. No UI suite was started.

`ConnectionVault` still omits an access-group filter. Apple documents that
[search, update, and delete then cover every entitled group](https://developer.apple.com/documentation/security/ksecattraccessgroup).
Current entitlements put the private group first, which scopes implicit new
items but not those other operations. No collision or credential exposure was
observed. Runtime scoping and any migration remain unresolved pending a signed,
disposable same-service/account fixture in both private and shared groups;
unsigned builds and injected storage cannot prove that behavior.

## Test audit (1 November 2026)

The audit removed unsupported standalone macOS rich-content harness branches,
three screenshot-only XCTest generators, one immutable-value assertion, and an
unused publisher stub. Current UIKit rich-content test bodies and assertions
remain intact. Fractional-color checks now share one independently pinned
fixture table instead of repeating the red cases.

The fixed-preset avatar containment matrix retains every shape, size, scale,
expression, and pose while dropping its duplicate light/dark pass. Body and eye
colors for that preset are appearance-independent; dedicated appearance and
contrast tests remain. Source-derived renders fall from 20,400 to 10,200.
No changed-matrix runtime improvement has been measured yet.

All 375 core tests, the MainActor compatibility build, and 188 tooling tests
pass locally, including 14 native-runner fixture tests. The audit repaired
Git signing/hook interference in note fixtures and post-reap group signaling in
the two development hosts. Cleanup checks include no-signal doubles and a real
disposable process group whose leader exits before its descendant. Exit
observation retains the unreaped leader through group retirement on macOS;
signal-denial warnings still permit the final bounded reap. This does not
establish a new live-Hermes acceptance result or force OS PID reuse.

The revised CI runs core, tooling, and unsigned app/test builds on PRs. Main
pushes also run the full serial native suite before TestFlight. Independent
jobs feed the required `verify` result. Focused manual diagnostics have a
different check name and cannot authorize TestFlight delivery. A diagnostic-only
revision passed 33 avatar test methods on a hosted runner. That focused result
does not cover this complete audit patch or explain the earlier failures.
Another diagnostic passed 77 methods across the original six-suite prefix.
Neither diagnostic includes the complete audit patch. The complete workflow
and changed native tests still need hosted verification. Earlier avatar decode
and native navigation readiness failures remain unexplained; their tests
stay required. Local native runtime acceptance is blocked by CoreSimulator
startup failure and shared host load. There is no current whole-suite native
pass or claim that all possible flakes are eliminated.

## Recorded automated checks (30 October 2026)

- BottoCore: 371 package tests and the MainActor-default compatibility build passed.
- Development tooling: 41 Python tests passed, including export exclusions,
  signing-file and symbolic-link refusal, version consistency, project-name
  normalization, and rejection of accidentally tracked relay credentials.
- The complete native contributor run passed 580 tests, with no failures and
  two opt-in transcript measurement tests skipped. It includes rich-file
  exposure and rendering, file installation, notification storage and removal,
  stale status results, header layout, and retained native workspace state.
- Fifteen distinct signed UI workflows passed. They cover setup prompt copy,
  native Share and preview dismissal; large text; bot creation; separate chats
  and draft restoration; live approvals and questions; profile access; interactive
  HTML; PDF rendering and zoom; and Save to Files with reopening in Files.
- Independent local-provider readback confirmed the uniquely named exported file
  contains the exact 80-byte sample, with SHA-256
  `ab2d37c15d4277807c8d7c9ac788d680ce95645b07a1d0e61ee34005a2b41cce`.
  This complements the UI Save and reopen evidence; a preview cache is not a
  durable export.
- The optional notification plugin passed 42 Python tests. The relay passed
  TypeScript checking, 24 Vitest cases, two bundled restart tests, and four
  process-crash scenarios. A local Wrangler dry run passed; no relay was deployed.

## Live Hermes workflows

A disposable host used official Hermes source at
`4a0eaf7989b6804319ddb94fa5d96c5a716080a1`. Local deterministic model responses
avoided external model credentials. Authentication, profiles, SQLite history,
authority events, uploads, downloads, and tool execution used real Hermes code.

The public Connect screen completed password sign-in, loaded the host inbox,
and sent and received a chat message. Service-level probes verified reconnect,
persisted history, cross-client chat discovery, uploaded file and image bytes,
and recovering and resolving a pending approval. Signed UI checks created bots,
approved a harmless local command, and corrected an oversized question response
without losing its draft. Forget returned to welcome without requiring the
optional notification plugin on an unpaired host.

Demo entry, both language and costume directions, Settings credits, and bundled
licenses were observed. The README's three 1206 × 2622 captures show the running
app with sample data and normalized status bars. Their metadata contains color
space and pixel dimensions, with no location or account data.

## Public source audit

The export inventory, authored documentation and comments, fixture provenance,
image pixels and metadata, and local links were reviewed. All 57 included
Markdown documents were read. All 39 external reference URLs responded
successfully during the check. No production credential, private conversation,
personal endpoint, or personal image metadata was identified in that snapshot.

Gitleaks 8.30.1 reported the two documented public encryption-fixture keys.
They are intentional synthetic vectors, not deployment credentials. Export
checks exclude local environments, signing material, development records and
execution logs. Original third-party notices and immutable upstream patch and
source pins remain intact. Repeat the audit after any source or media change.

## Limits

- Hosted CI results are available in the [iOS workflow](https://github.com/sreejithraman/Botto/actions/workflows/ios.yml).
  Release tags must point to a commit with a successful run.
- Physical APNs delivery remains unverified. It requires Apple provisioning,
  the documented Hermes observer and optional plugin, and an operator-hosted
  relay. Local component tests do not prove delivery or a device banner.
- This run does not establish iPad or minimum-iOS-18 runtime acceptance,
  VoiceOver coverage, physical camera or Photos behavior, external browser/OIDC
  sign-in, Cloudflare Access, or performance and energy results.
- The local deterministic model exercises Hermes interoperability. It does not
  establish behavior across every external model provider or Hermes revision.

See [Contributing](../CONTRIBUTING.md) for repeatable checks, the
[verification map](agents/verification/index.md) for workflow assertions, and the
[release checklist](releasing.md) for source publication requirements. A recipe
records required coverage; it is not a passing result by itself.

## Hot feature import — 30 October 2026

The artifact library and Search delta from Hot base `6699e1d` and export-only
commit `65f479ae` was integrated onto Botto `e9e17b8`. The import retains Botto's
notification routing, chat overview and local close/reopen behavior. Four
independent required reviews covered the final 55-file code snapshot
`5774bf6c1f49100f4c206b3c1890ea96645d9e6c06a82d874606ac3d964b7b4d`
and returned no material findings after repairs.

Fresh checks used Xcode 27.1 and an iPhone 17e Simulator running iOS 26.5,
with unsigned Debug native builds:

- The core run completed 394 tests, with three live-host opt-ins skipped;
  the MainActor-default compatibility build passed. All 41 Python tooling
  tests passed.
- The initial complete native run exposed three assertions in two notification
  recovery methods. Repairs keep automatic restoration separate from manual
  navigation, preserve a cold notification's local picker owner, and retain
  editable drafts after failed lookups without restoring retired action grants.
  Existing assertions remain intact, with additional integration regressions.
- The final native rerun passed 669 tests, with two opt-in transcript benchmarks
  skipped. Its 18 unchanged avatar-layout tests passed in the initial run and
  were excluded from the rerun. The final run includes 644 Swift Testing tests
  across 63 suites and 27 XCTest tests; the Swift Testing count includes the two
  skips.
- All six selected public UI workflows passed: library tabs and retained drafts;
  opening an editable originating chat; reference filtering and inline-output
  sharing; readable Search messages and artifact previews; exact older-message
  opening; and an actual glyph jump inside tall text with the draft and Latest
  behavior preserved.

Logs, result bundles, immutable source exports and review receipts are retained
locally under `.artifacts/hot-import/`; they are not part of the source release.
Historical Hot results remain separate from these Botto checks. Complete library
recipes remain draft. Fresh live-host cache interoperability, durable Files-provider
readback, signed physical-device delivery, minimum iOS 18, wide iPad and VoiceOver
acceptance were not exercised in this import.

## Haptics on 31 October 2026

The haptics change was checked with Xcode 27.1 on an iPhone Simulator running
iOS 27.1. Twenty Swift Testing tests and two demo XCTest cases passed. They
cover preferences, output selection, streaming throttling, receipt ownership,
hidden results, direct event delivery, and actual SwiftUI sheet presentation
across redraw and reopening. Core service cases additionally exercise Stop
before and after acknowledgment, restored running work, refresh, replay, and
foreign execution rejection. These checks verify requested feedback, not touch.

The broader native run reported 16 issues across 573 Swift Testing cases.
The PDF sizing assertion and hosted request-row readiness failure also reproduce
on unchanged base `7e22ce109fea7b5eafa9a4f36780d364818403dc` on this target.
Other WebKit rendering/time-out failures from that run remain unattributed;
the complete native suite is not a passing result for this change.

The Debug haptics playground and its sample sheet were opened on an iPhone SE
Simulator running iOS 26.5. Off visibly disables the streaming switch. Physical
iPhone strength, rhythm, timing, and custom-engine interruption/reset behavior
remain untested. The [haptics recipe](agents/verification/features/haptics.md)
remains draft.

## Internal developer tools on 31 October 2026

The final Internal UI case passed on an iPhone SE Simulator running iOS 26.5.
It entered through Explore the demo and Settings, opened both playgrounds,
returned the embedded avatar demo to its gallery, closed both tools, and checked
the main app's Demo exit after a fresh isolated launch. Debug and Release channel
UI checks passed before the preview repairs. Fresh final Debug attempts stopped
before testing when Xcode lost concrete Simulator destinations; the final Release
runtime check was blocked by the same discovery limit. The complete final UI
matrix is not a passing result.

Current Debug, Internal and Release app/test builds passed with Xcode 27.1.
An unsigned Internal iPhone SDK build also passed. Compiled symbols contain the
menu and both playground types in Debug/Internal and omit them in Release.
All three built test bundles contain their expected configuration metadata.
The isolated-test argument is present in Simulator binaries and absent from the
physical Internal binary. These checks prove compilation boundaries, not a
signed installation.

An earlier Debug run passed 35 Swift tests across AppStoreTests and
WorkspaceLaunchTests, including isolated storage and ordinary-launch contrasts.
Forty-one Python tooling tests passed. The preview's storage-error display was
reviewed and compiled; no actual storage-unavailable fault was forced. Signed
TestFlight installation and physical haptic feel remain untested. Integration
and a new Internal TestFlight build are necessary for installed testers to get
the menu; see [developer tools](developer-tools.md). The broader native-suite
limits recorded above still apply.

## Artifact covers and history status — 31 October 2026

The gallery recovery and HTML-cover change was checked against Botto HEAD
`653b89dc`. Four independent required reviews returned no material findings for
the combined 12-path snapshot
`b299588a4528b900ac156b5773f3d00022362b98bf8ba96247318cbcd055c576`.
The two optional external reviews hit provider quotas and supplied no review.

- Baseline regressions reproduced the false history notice after a complete
  single-page scan and missing cover retries after reconnect or reader capture.
- The final native run passed 101 declared test methods across five suites.
  It covers truthful paginated-history status, image recovery, bounded HTML
  rendering, cancellation, inactivity, detachment, timeout cleanup, and reopening
  a persisted HTML cover offline without a mounted renderer.
- Two public UI workflows passed on the iPhone 17e Simulator running iOS 26.5:
  automatic gallery covers and library navigation with a retained draft.
  A strengthened cover rerun also passed. It checks actual PNG pixels and OCR
  from both inline and file HTML covers before opening any reader. Manual dark
  appearance checks confirmed the gallery covers and an HTML Search-result cover.
- A signed Debug build installed in place on sreePhone Pro and launched with
  normal arguments. Installed-app and running-process readbacks matched the new
  bundle URL and PID. The local signing override matches the previous phone
  install's identifiers and Keychain groups; APNs remains unavailable in this
  development build. No tracked signing settings changed.

Evidence, exact source and bundle hashes, result bundles, screenshots, and
original review reports are retained under `.artifacts/gallery-covers-20261031/`.
Physical-device evidence proves installation and launch. It does not prove the
user's particular Hermes file downloads or private phone UI. Wide iPad,
landscape, VoiceOver, and complete library-recipe acceptance were not exercised.

## Cache-first library continuity — 31 October 2026

Artifacts and Search now ask the mounted library whether revalidation is needed.
Automatic checks share a 60-second monotonic freshness window; reconnect,
changed roster identity/name, and server directory notifications invalidate it.
Explicit refresh bypasses the window. ADR 0007 records this policy alongside
the existing cache-first presentation decision.

- The same three-open Store fixture made three directory requests and six
  history reads before the fix, and zero additional requests of either kind
  afterward. This measures request counts, not end-to-end phone performance.
- A restored-index regression reproduced cards changing order when weak
  directory metadata erased known dates. It now preserves card order while
  history is gated and after the check finishes.
- A Store/status-view regression reproduced removal of the history notice
  during local seeding and background checks. The notice, action, and rendered
  height now remain stable; the action stays disabled during work.
- Controlled cancellation/replacement and gated restoration tests reproduced
  missed revalidation after a new revision or roster arrived. The final tests
  require the current follow-up before automatic freshness is accepted.
- The final integrated run passed 141 declared native methods in six suites
  and three public UI workflows on the iPhone 17e Simulator, iOS 26.5: automatic
  PNG/inline-HTML/file-HTML covers, three dark-appearance gallery reopens with
  retained covers and card position, and exact older-message Search opening.
- Four required independent reviews returned no material findings for final
  snapshot `44e5680a4a61f23628dce58a481db65425a1edf10a87ab606fd4ca5fb39fd877`.
  Earlier findings and original review receipts remain in the evidence archive.
  Optional external coverage remains unavailable under the recorded quotas.

The signed build installed in place on sreePhone Pro with the existing local
development signing override. Automatic launch was blocked by the phone lock;
no current physical launch or private phone UI acceptance is claimed.
Logs, result bundles, source/bundle hashes, review originals and demo captures
are retained under `.artifacts/gallery-continuity-20261031/`.
The user's exact live-server recording timing, wide iPad, landscape, VoiceOver,
physical APNs, and whole-product acceptance remain unverified.

## Native chat-header soft edge candidate — 31 October 2026

The candidate connects the transcript to the navigation content owner and uses
the existing native soft edge on iOS 27. It retains the prior material through iOS 26:
a current native-only iOS 26.5 run reproduced transcript text behind the status bar.
Header replacement now retires the predecessor before registering its successor.

- Final four-file snapshot
  `1cbe93c8f7274e831e7769e6ad5b759bf1c4f43f3572c833dc1998095add1b7a`
  builds. Both final iOS 26.5 Search workflows pass: dark (23.954s) and light with an
  active keyboard/draft (100.882s), including status/composer OCR and Latest return.
- A dark iOS 27.0 prototype passed its Search workflow in 27.716s. Its synthetic capture
  shows the requested strong status blur clearing toward crisp floating controls.
  That prototype includes temporary diagnostics removed from final source; it
  does not prove final-source iOS 27 acceptance or physical iOS 27.2 rendering.
- The successor/late-retirement/reappearance native test passed in 1.926s before a
  test-fixture mounting repair. The final corrected fixture still needs a run.
- Final iOS 27 light/profile/overview and paired/full-screen return checks are blocked
  by device-support communication and destination-enumeration failures. Stopped
  prelaunch attempts count as neither product failures nor passes. Physical,
  large-text, Reduce Transparency, VoiceOver and pre-iOS 26 runtime remain untested.

The user is away and chose Showroom instead of phone verification. The shown
dark capture is explicitly provisional. No final phone installation, launch, or
full header acceptance is claimed. Narrow bases, frozen sources, research, test
logs, captures and independent review originals are retained under
`.artifacts/chat-header-soft-20261031/`.

## Shorter status-area blur — 31 October 2026

The iOS 27 candidate now uses a bounded system material at its own window's
top safe inset, followed by a 20-point fade. It hides the longer native top
edge and keeps the existing profile and control geometry. The through-26
backing remains unchanged. The native-only and content-local candidates passed
checks but failed the parent's visual comparison; their passes are historical.

Final narrow snapshot
`b3eea3ab12a2ce65e236505eb2a86f6472bf3433fe14814a34cb3f166ec6a517`
builds and has no supported findings in its independent primary review. Its
dark Search workflow passed in 27.769s on iPhone 17 Pro, iOS 27.0 Simulator,
including rendered status/composer legibility and Latest return. The actual
dark capture shows the shorter region and is available in a Showroom comparison.
Device support stalled during the light/keyboard workflow; that run was stopped
and no final light acceptance is claimed. Physical, paired iPad, landscape and
accessibility settings remain unverified. No new phone installation is claimed.
Evidence and frozen turn-start bases remain in `.artifacts/blur-status-20261031/`.

## Native blur restored after visual rejection — 31 October 2026

The user rejected the shorter fixed-material backdrop as too strong. The three
chat view/native view/native test files are restored to the exact earlier
native soft-edge candidate bytes. The custom backdrop and mask are removed,
and the native top effect is enabled again. No 20-point extent is claimed for
the system effect. This supersedes the prior shorter-backdrop visual judgment.

The restored candidate builds and has no findings in its narrow independent
Primary review. Device support is unavailable, so no fresh runtime, light-mode,
paired-pane or phone acceptance is claimed. Showroom reuses an explicitly
labeled earlier native capture. Exact before/restored hashes and review
originals remain under `.artifacts/blur-native-restored-20261031/`.


### Header reference match exploration — 31 October 2026

The local iOS 27 Simulator candidate retains the native soft scroll edge and floats the controls above a short color contrast fade. The comparison uses the same public-domain photo in the original and matched treatments; it uses a different photo from the supplied visual reference. Candidate source, patch, unsigned app, screenshot manifests and raw logs are in `.artifacts/header-reference-match-20261031/`. The five app/demo/UI-test files were restored to their captured starting bytes; the candidate is not the normal app or a phone install.

On the owned iPhone 17 Pro Simulator `88D78CC2-A89F-4689-8159-F0D41E996EBB`, iOS 27.0 with SDK 27.1, `matched-r2-green.xcresult` records the photo comparison passing in 33.902s and the dark older-Search/Latest workflow passing in 22.959s. The light workflow preserves its draft value and reveals the matching glyphs, then fails the new keyboard-presence assertion in 30.914s. Later assertions in that method were not reached. Using the existing compact-column navigation Binding for the candidate Back button did not resolve this keyboard gap. The earlier `matched-ui.xcresult` passed three methods without that keyboard assertion and before the photo width repair; it does not supersede the stricter failure.

The candidate remains a visual exploration. Production navigation integration, keyboard continuity, iPad/file pairing, orientation and accessibility material adaptations remain unverified. No commit, publication or merge was performed.


## 2026-11-01 combined-library review repairs (native acceptance pending)

The combined Botto import review found duplicate-ID admission, stale partial
history, rejected metadata replacement, missing preview evidence, independently
evicted originals, overlapping Reload, and inline Reload capability gaps. Source
repairs and focused regressions cover those paths. Partial history preserves
indexed same-ID content; complete reads and accepted transcript updates can
replace it. Duplicate occurrences remain unavailable until unambiguous accepted
or complete evidence. A rejected saved replacement removes its older disk row
and reports a save failure. Captured-cover lookup retains a separately bounded
occurrence-to-digest mapping. Forced reads follow earlier reads; inline source
keeps export without offering a host-file reload.

The directory-preview package regression passes both missing and explicitly
empty preview cases, including JSON round trips and legacy decoding. New native
regressions have not executed: the coordinating release thread holds local
Simulator work while the shared host is unhealthy. Earlier native and UI results
above do not certify these repairs or the complete prospective PR head. Fresh
independent review, focused hosted library/search/header acceptance, and the full
main native release gate remain required before distribution.


The second combined review also repaired confirmed Forget after unreadable setup,
canonical capture serialization across alias discovery, cross-page overlap and
hidden-row evidence, forced capture-save failure, and metadata self-eviction.
Original bytes and their digest mapping now publish in one SQLite transaction.
Quota enforcement reports a missing replacement instead of certifying it saved.
A live-work-to-idle transition refreshes each mounted file directive once while
authority recovery and ordinary reopen reuse captured bytes. Gallery and Search
keep same-source covers visible while an occurrence-specific replacement loads.
Focused native regressions cover these paths; they remain unexecuted locally.
The raw hidden-row history test failed before its adapter fix and passes after it.
Latest main `13a1845` is integrated with the feature WIP preserved; its CI, signing
and native-renderer cleanup remain intact. Current integrated checks and final
review are recorded with the preparation packet; fresh hosted acceptance remains
required.


### Combined library PR R10 preparation — 2026-11-01

R9's four full static reviews found four source gaps: pre-discovery gallery
capture admission, reuse of a failed forced-history certificate, unrelated-chat
projection invalidation, and saved-history restoration after complete directory
absence. The repair adds per-chat projection versions, cancellable asynchronous
capture publication readiness with transactional retry, bounded hidden absence
rows, and failed-check certificate invalidation. The capture recipe now arranges
a qualifying TTL event before expecting another directory check.

The first R10 generic unsigned arm64 Debug build-for-testing passed for the app
and both test bundles in 29.814 seconds, with all 68 source hashes unchanged.
Subsequent cancellation handling, native regression fixtures, and this record
require the final compiler receipt in the outside-checkout R10 packet. Core 404
methods/10 suites, MainActor compatibility, and 188 tooling checks reuse unchanged
source evidence. None of these results executes the new native assertions.
Exact-published-pin library, public UI, export, and full-main acceptance remain
with the coordinating root; prior Apple builds do not certify these features.


### Combined library PR R12 preparation — 2026-11-01

The full R11 reviews found three source gaps and one fixture gap: failed index
writes could restore old rows/certificates, a ready historical peer could release
a gallery waiter before its own provenance, first admission implicitly parsed
Search text, and the second-reader fixture lacked a registration handshake.
The repairs add scoped recovery invalidations, independent cancellable gallery
completion, explicit Search projections, and an observed registration handshake.
Native lock/reopen, peer-success/cache-failure, scope and recovery-quota cases
are compiled acceptance candidates; no current native execution is claimed.

An owned macOS pure-data harness extracted the exact LibraryChat and
NativeMessageText bodies. For identical 25,000-message / 9,375,000-byte input,
the old constructor's median was 14.336 seconds across three runs. The actual
updated default-empty constructor took under 0.1 milliseconds per run. The
unchanged detached Search helper still took about 14.4–14.7 seconds and produced
identical content in the original comparison. This measures the isolated
constructor's removed synchronous parsing, not full admission or iPhone frames.
The source bindings and raw results live in the outside-checkout R12 packet.

Compiler-r12 and compiler-r12-final retain exit65 diagnostics for a throwing
condition and continuation inference, corrected before the next full review.
The final generic receipt will bind the complete repaired source. Core404,
MainActor and188tooling evidence reuse unchanged source; all hosted native/UI,
export, integration and final beta proof remain with the coordinating root.

R13 source repair follows four accepted R12 static findings: changes arriving
during blocked SQL, guards blocked by initial acquisition, pre-reconciliation
seed exposure, and negative evidence lost through successful eviction. Added
gated two-chat, pre-acquisition lock, earlier-seed/later-projection, successful
eviction and older-write/newer-guard assertions. These native assertions are
unexecuted locally. The first repaired variant compiled in 48.178s with all 68
before/after hashes unchanged. Runtime-only guard coalescing and the final
sequential seed handshake follow that variant; their final compiler receipt and
fresh full review evidence accompany the R13 packet. Root owns hosted native,
public UI/export and full-main acceptance.

R14 source repair follows R13 Ponytail's static rollback finding. Capture
transactions track newly created eviction guards. Confirmed SQL rollback removes
only their unchanged local tokens; preexisting or newer guards remain. A
speculative eviction rejects guard overflow before adding configuration
quarantine. Added revoked/pending, prior/newer guard, quota rejection, and
independent offline gallery/Search/capture-reuse assertions. These native
assertions remain unexecuted locally; final compiler and fresh review receipts
bind the next packet. Root retains hosted native/public UI/export acceptance.

## Haptic engine callback ownership follow-up

The post-merge follow-up gives each custom Knock/Ta-da its own engine lifetime.
Late SDK callbacks stay with that playback. A monotonic interruption flag
covers startup and player creation. Current retirement requests cancellation
before releasing resources, including when the player rejects stop after reset.
Preference storage, semantic selection and reader gates remain unchanged.

The original queued stop/reset cancellation cases failed before the fix. The
portable harness reproduced the broader ownership and startup failures with
22 failed assertions on the prior implementation. All 20 lifecycle cases pass
on the final production and test excerpts in a macOS harness using
MainActor-default compiler flags. This checks the SDK-boundary ownership logic;
it does not run the iOS app or actual Core Haptics playback.

The final 28 selected native test definitions compile. Local execution remains
blocked because Xcode lost the owned iOS 27.1 Simulator destination; T3 device
support also failed. The Simulator test build and unsigned Release iPhone SDK build pass. The 376
core tests and MainActor compatibility build pass; package checks exclude
native playback.
Local final native execution remains unverified.

The broader native-suite limits above still apply. Physical haptic feel,
interruption/reset behavior and the startup cost of fresh engines remain
unmeasured.

## Draft feature integration and R15 source repairs — 1 November 2026

Draft PR 9 first published the exact R14 bytes at `c4cb956`. The merge at
`f806a5e` integrates main `ae72bef`: all 68 feature paths remain, 66 R14 path
hashes are unchanged, the demo timing auto-merge is retained, and both complete
verification records above are preserved. Hosted run `41306636184` passed its
required checks on that exact integration. Its native job built the app and
tests but did not execute tests, so it does not settle the six R14 blockers.

R15 repairs startup-maintenance guard admission, first in-flight writer
withdrawal, canonical roster removal and bounded acceptance fencing. The
two-chat fixture now performs same-ID producer edits, and the reader fixture
uses actual preview close/cancellation with a real registered gallery peer.
New gated tests cover pending/failed production startup prune, new lease versus
queued cleanup, first-write eviction/retirement, roster withdrawal before another
history response, bounded stale scan/seed rejection and unrelated read progress.
These assertions remain unexecuted locally. The final compiler/review packet
will bind the repaired source; root owns hosted native, public UI, export,
full-main and final TestFlight acceptance.

## R15 executed feedback and R16 repairs — 1 November 2026

Exact R15 `74ebcfe` passed PR build checks (`41308723117`) but failed full
native execution (`41308928053`): 789 definitions, 780 passed, seven failed,
two skipped, with eight failed parameter executions. The retained result ZIP
SHA-256 is `f72c07355fe86b408981107f4761fbe517a5ce29c7ce633a03c6a4800f04da3f`.
Three identity cases expected a grant already denied by raw duplicate evidence;
the fixtures now check that denial and retain independent native preflight,
mounted-document withdrawal and unique-row recovery controls. The layout fixture
now uses one actual capability for its work-state transition. Fresh successor
projection and ordinary cold reuse await their actual projection or durable
checkpoint. Interrupted-write assertions remain separate. One initial blank
mounted document remains a rendering failure without a proved product cause;
its OCR helper now allows the renderer's existing startup/document budget.

The product-identical public UI run (`41309799161`) passed ten workflows,
including PNG/HTML covers, cover reopen, Share, origin navigation, drafts and
Search jumps. Save to Files never ran because Xcode timed out launching the app.
The remaining inbox case reached only Word 48 of the 200-publication stream;
its 30-second deadline and demo timing remain unchanged pending diagnosis.

R16 adds source repairs and gated regressions for transient capture identity,
late withdrawn-bot reads, same-mount storage retry and bounded failed-guard
bookkeeping. All original 68 paths remain; the producer regression adds one Core
test path. The unsigned generic arm64 Debug app and both test bundles compile
in 33.022 seconds with all 69 source hashes unchanged during the build. The first
attempt's nested test-macro compiler error is preserved and corrected. New native
assertions remain unexecuted locally. Root owns focused next-pin native/UI,
independent export readback, full-main acceptance, merge and final beta delivery.

The R16 follow-up preserves an initially present legacy profile's first
incremental publication while still rejecting events and pre-withdrawal reads
after roster reentry. A positive/negative/fresh-recovery test compiles. Its exact
unsigned generic app/test build passes in 34.442 seconds; all 69 before/after
hashes match. Core source remains the same405-test/MainActor checked source.
This follow-up changes the roster admission branch and its fixture; prior hosted
68085 results need an impact assessment, not an unrelated gate reset.

## R16 execution and R17 repairs — 1 November 2026

Hosted targeted native run `41315488702` used all 69 feature blobs from
`68085fc`, with four disjoint main diagnostics files and root-owned routing.
The actual result matched all 136 selected method IDs: 135 passed and one
failed, with no skips. AppStoreRichReply, ArtifactCache, NativeTranscriptIdentity
and ReplyFileBodyLayout passed completely. WorkspaceLibrary passed 84 of 85;
`aMountedLibraryRetriesStartupStorageAfterTheLockClears` failed because its
unaffected saved artifact remained hidden after recovery. The original assertion
and deadline remain. R17 clears the temporary recovery hint when admitting the
checked row and resolves unchanged saved reads before scheduling new guards.

R17 also repairs actual submit/steer transient provenance, working-bot roster
withdrawal, quick reentry, stale roster scans and forced joins, same-mount
restoration of withdrawn or evicted producers, and duplicate evidence carried
through malformed history failures. Gated native fixtures cover these paths and
independent cold readback. They compile but remain unexecuted locally.
All original 69 paths remain; the actual Core mutation producer adds one path.
The final unsigned generic arm64 Debug app and both test bundles compile in
35.238 seconds, with all 70 before/after file hashes equal. Core passes 407
methods in ten suites in 13.184 seconds; MainActor compatibility builds in
3.12 seconds. Raw receipts and original R16 review packets remain preserved.

Public UI run `41315488498` executed two methods against the same feature pin.
The inbox still showed ongoing output through Word 80 when its unchanged
30-second completion assertion failed. Actual video and AX agree; no product
hotspot or scheduling cause is established. A portable same-workload Mac
measurement does not establish iOS frame or UI causality. Baseline run
`41317355662` timed out at app launch before Send and is inconclusive.
The Files case reached the native local root and enabled Save, then failed its
filename-editor prerequisite before any Save tap. No output file was produced;
this is not evidence of corrupt exported bytes. Root owns startup diagnosis,
the separate Files fixture repair, affected hosted execution, full-main
acceptance, merge and final beta delivery. The prior ten passing UI workflows
retain their original source binding; these results do not prove final release
acceptance.

## Integrated Files acceptance and R18 repairs — 1 November 2026

The reviewed Files module `6ae7670` was cherry-picked as `e6ee422` after the
R17 source freeze closed. All eight imported file hashes match the handoff.
Its four initial required module reviews are archived; the root owner repaired
bounded findings afterward. There is no independent post-fix module clean
claim. The next full integrated PR review owns those final bytes. The helper
now saves default `notes.txt` after explicit owned-device absence preflight,
requires real preview close and independent Files reopen, and retains separate
per-run absence/readback verdicts. Removing the duplicate completed-chat-Save
wrapper leaves the library as the public successful-Save representative;
chat cancellation, reopen, Share, retirement and shared output lifecycle tests
remain. Actual native Save and fresh 80-byte provider readback remain pending.
The shared verification setup recipe now describes that protocol.

Three distinct R17 findings have repairs in the integrated candidate. Refresh
and roster callers explicitly distinguish cached labels from observed membership;
public AppStore fixtures preserve offline gallery, Search and captured originals
with missing, unreadable or partial local history, then require real roster
withdrawal and independent cold readback. Correctly associated rejected pages
retain bounded stable raw IDs, so a malformed later page cannot hide an overlap
with an earlier producer; oversized pages conservatively withhold that chat's
retained references. Core's eight adapter/shape cases failed before repair and
pass afterward. Native fixtures retain an in-flight capture, unaffected peer,
old-original rollback and cold reopen. The roster-restore fixture now registers
the waiting refresh before changing membership, retains its added-profile
oracle, and expects the current two-profile scan's two directory reads. Local
entry waits are bounded, and the forced-followup fixture removes its one-shot
directory gate before the next pass. These native assertions are compiled,
not executed locally; no assertion deadline or default demo timing changed.

All original 70 paths remain. The integrated Files tooling and documentation
bring the complete scope to 77 paths. Core passes 408 methods in ten suites in
12.728 seconds; MainActor compatibility builds in 1.52 seconds. The unsigned
generic arm64 Debug app and both test bundles compile in 35.958 seconds, with
all 77 before/after file hashes equal. Product/test bytes remain unchanged after
that build; only the final documentation notes were added. The integrated
Files filesystem 17 and runner 7 Python tests pass. Prior native 135/136 and UI
outcomes retain their source bindings. Root owns affected exact-pin execution,
independent export, full-main checks, integration, merge and Apple delivery.

## R18 native acceptance and first-roster repair — 1 November 2026

Root run `41326432411` executed exact `c0fe84e` feature/test bytes with four
disjoint main diagnostics files. Its actual xcresult matches all five selected
method IDs and nine expanded cases: zero failures or skips. Offline tab entry
passes missing, partial and unreadable history; malformed later-page capture
passes both cases; working-roster withdrawal passes both cases; the roster-
restore fixture passes. The original
`aMountedLibraryRetriesStartupStorageAfterTheLockClears` now passes in
2.2478459 seconds. Artifact `13091358442` has SHA-256
`29c5baced2e04ae3d9a6d9a9f11a6740cf2c19bd5813905d4e546408bc75a2c5`.
The source owner independently matched that ZIP hash and retained the root
settlement, provenance, parsed result and audit script. These are five-method
acceptance results at that pin, not whole-PR or full-main proof.

R18's final four static reviews are archived. Primary, Ponytail and Thermo
found no new material issue. Adversarial found a distinct first-roster race:
online tab entry could scan an initial empty roster before the first service
response, then treat that scan as fresh when equal cached labels arrived.
The repair uses the existing unknown-roster state to block membership scans
and freshness certification until a real observation, and invalidates the
first observation even when labels match. A public AppStore regression holds
the service roster across online tab refresh, retains gallery/Search/captured
bytes and an independent cold read, and covers equal, empty and failed first
responses plus genuine withdrawal and a surviving peer. It compiles but has
not run locally. It does not replace or invalidate the nine prior passes.

The unsigned generic arm64 Debug app and both test bundles compile in
36.061 seconds, with all 77 before/after file hashes equal. Only the final
documentation notes followed. Core/MainActor and Python tooling bytes are
unchanged from the recorded 408-method and 223-test checks. Files-module bytes
remain unchanged. Root owns the new exact-pin regression execution, pending
UI/Files readback, full-main checks, merge and final TestFlight delivery.

## Bounded final integration — 1 November 2026

Root run `41329562960` passes the reconnect method's equal, empty and failed
first-roster cases at product pin `72d6b36`, with the root Files test delta.
Artifact `13093091015` has SHA-256
`8dda676b3dd43da9ccb1a2e4aea43f92886eac1e7a8783719159f5523abbcad2`;
the source owner independently matched the ZIP hash. This settles that method's
three cases, not the later projection repair or the whole PR. Files reached
the actual exporter but failed its readiness assertion before Save. The final
root corrections remove redundant Actions roundtrips and point-in-time hit-test
prechecks; actual taps, dismissal, Close, Files reopen and independent exact
80-byte provider proof remain required. No Save pass or product/AX cause is claimed.

The remaining projection repair lets passive discovery follow the current
canonical row/version while the original read still fences completion metadata.
A gated last-saved-row test covers a roster arriving during discovery, unchanged
strong-summary reuse, Search/artifact visibility, captured-byte reuse and actual
absence. Its two cases compile and remain unexecuted locally. The final unsigned
generic arm64 Debug app and both test bundles compile in 7.557 seconds with all
78 before/after hashes equal; the extra path is the ordinary contributor command
correction. All 77 feature paths remain. Core/MainActor and Python tooling retain
their unchanged 408-method and 223-test bindings.

The user explicitly narrowed the remaining process for simple delivery: retain
the R18 full 77-path assessments and mappings, then run one bounded independent
Primary assessment of the final delta since `c0fe84e`, including the full changed
production module and direct callers. This does not claim a fresh four-role
whole-PR clean snapshot. Root retains merge judgment, essential native/UI/Files
acceptance, unfiltered full-main checks and final Apple delivery.

Known deferred limit: a genuine bot withdrawal received while the initial index
is unreadable and local history supplies no saved chat IDs may be absent only in
memory. An offline restart before a successful reconciliation can show stale
metadata again. This is not fixed. The existing read-failure warning remains;
reenter the library or refresh after storage becomes readable before closing.
Root accepted this disposable-cache staleness deferral, conditional on the bounded
review confirming no new network/mutation authority, original-byte loss or
corruption, or account-scope escape. No profile-incarnation layer or broad
quarantine was added. The exact follow-up is saved in Hot as
`7F24A8D9-B726-406C-9099-E7770DA89C9C`.
## Inbox fixture separation — 1 November 2026

Baseline run `41330004685` requested `pinned-bot-scout`, but its recording
shows Scout and Iris exchanging pinned positions around the tap. Its final
accessibility hierarchy identifies Iris in the header, picker and composer,
with Iris's ordinary history and Word 0–37 without completion. This proves a
slow demo stream without PR9's library. It does not prove streaming over
Scout's 400-row history: the performance fixture streams 200 chunks for any
bot, while only Scout receives that history.

`testRevealedInboxShowsReplyAndReopeningKeepsDraft` now uses the ordinary demo
reply. It retains completion, fresh roster preview, navigation, unselected-row
and exact-draft assertions, and checks Scout's identity on opening and reopening.
The dedicated first-stream and reading-position tests retain 200 chunks, the
default 20 ms delay and their existing deadlines. They now require Scout and
history row 399 before sending; the long-history opening check also requires
Scout's identity within its existing budget. The native service test still
asserts 200 distinct partial texts with zero injected delay.

The changed UI workflows remain unexecuted locally. T3 could not discover a
new owned Simulator after its prescribed refresh and retry. The streaming
bottleneck and pinned-selection race remain unresolved under Snip Snap item
`B14EBCD5-EA29-4987-B202-A4FA7B4D5160`; this change does not claim a performance
repair. Source/artifact evidence is retained in
`/tmp/botto-stream-followup-20261101/investigation.json`.


## Shared inbox and chat history — 1–2 November 2026

The inbox retains typed messages in the transcript that chat renders. Its
excerpt derives from that content, so opening a chat can display a fetched
reply while live attachment waits. Recent reads use one bounded 300-row
response instead of joining moving offset pages. The maximum row budget
stays unchanged; ordinary reads may return more than the former first 100 rows.

The stale-chat regression failed before integration. Additional regressions
reproduced delayed-selection races, partial-read quarantine loss, safe revision
loss, failed-restoration gate escapes, deferred writes, absent saved disputes,
and unchanged reseeding hiding resolved results. The repaired cases preserve
exact drafts, read evidence, live access, stable row exclusions and saved data.

Identity resolution now has separate process-local evidence. Core tests cover
raw duplicates and malformed IDs before filtering, deletion across an offset
boundary, exactly 100-row uncertainty, source mismatch, replay/buffer additions,
incremental expiry, and compressed ancestry. Paged active-tip reads retain their
read-acknowledgment behavior without gaining identity-resolution proof. Book
and Library resolve only observed verified IDs; absent disputes remain. Library
can display coherent results during a storage failure while retaining unread
negative metadata and deferred writes. Recovery tests use real temporary caches,
SQL-lock cases and injected read-result failures, then independent reopen.

The final producer contract check, `./scripts/check-core.sh`, passed 438 tests
in 11 suites and the MainActor-default compatibility build. The final integrated
native run passed 321 tests in 16 suites on an owned iPhone 17 Pro Simulator
running iOS 27. Two UI workflows passed: Scout's fetched typed reply appeared
before a held first attachment, and Milo's cached content remained usable while
attaching. Both allowed drafting, retained exact draft text afterward and
sent no message. These counts overlap earlier checks and should not be added.

Recovery regressions distinguish hint-first safe revisions from actual identity
disputes, preserve verified Search/artifact rows and captured originals beside a
new unverified row, and deny resolution from a complete page without producer
identity evidence. Codec controls cover separate and overlapping uncertainty,
legacy decoding and conservative older-reader exclusions. A separate boundary
regression reproduces safe revision loss when a fresh page lacks optional proof;
the complete-page fix preserves that revision across recovery and independent
cold reopen while retaining the actual saved dispute. Follow-up partial-page
checks keep conflicting revisions unverified across recovery and cold reopen,
then admit the current row from a resolving read. Existing stale-file-deletion
and unsettled-live-tail controls pass. Rejected, hidden and oversized page
controls promote hint-only or removal-only evidence into actual dispute metadata;
six cases verify partial-read exclusion, durable reopen and coherent resolution.
Repeated-publication controls add six sequences with failed/incomplete pagination
or repeated refresh, each with and without a working assistant tail. Weak merges
retain revision uncertainty through recovery and cold partial reads; a later
accepted resolving read saves the current file while keeping an absent dispute. Directory and partial-read gates still
apply. Temporary caches exercise actual persistence and injected read failures.

Final logs are `.artifacts/page-identity-read-core-check.log` and
`.artifacts/repeated-partial-native-acceptance.log`. Source bindings are
`.artifacts/page-identity-read-source-sha256.txt` and
`.artifacts/repeated-partial-final-source.json`; all Swift bytes matched the final run.
Red/green logs are `.artifacts/recovery-evidence-{red,green}.log` and
`.artifacts/page-revision-recovery-{red,green}.log`. The initial integrated
318-function run is retained in `recovery-evidence-native-acceptance.log`;
the final run supersedes it after the additional boundary fix. Prior identity,
startup and SQL-lock evidence remains in the earlier named artifacts. The latest
regressions are `.artifacts/hint-quarantine-{red,green}.log` and
`.artifacts/partial-revision-uncertainty-{red,green}.log`. Repeated-publication
red/green proof is `.artifacts/repeated-partial-revision-{red,green}.log`;
the focused green run passed five functions in one suite. The attempted broad
partial-page revision replacement failed existing controls and was reverted;
`hint-quarantine-native-acceptance.log` records that rejected candidate and does
not establish final acceptance. Exported final UI screenshots and receipts are in
`/tmp/botto-chat-sync-evidence/repeated-partial-final-ui/`.

The working changes are based on
`a31309e6dab97cd6295f7149679cf1b37cd9cb2c`. These deterministic transport, model
and demo checks do not establish a production-host reproduction, physical-device
acceptance, a full verification-map recipe, or a latency improvement.

## Cache restoration and admission — 2 November 2026

The Library restoration lifecycle now owns its active task, attempt ID and prior
outcome. Concurrent callers join it; retries preserve prior-attempt persistence
eligibility; retirement rejects late completion and ends loading immediately.
Typed admission inputs replace the independent reconciliation/coverage/proof
parameters. Partial history and recovery hints cannot carry resolving proof.
Saved rows carry their checked persistence certificate; row ordering uses a
separate policy. External interfaces and the saved format are unchanged.

A held-read regression reproduced continued loading after retirement on the
previous implementation (`.artifacts/cache-restoration-lifecycle-red.log`).
The lifecycle change passed six focused functions in two suites, including
retry, joined restore, roster change and deferred durability controls
(`.artifacts/cache-restoration-lifecycle-green.log`). The integrated refactor
passed 322 native functions in 16 suites and both held-attachment/draft UI
workflows (`.artifacts/cache-architecture-native-acceptance.log`). Its
272 Swift hashes are in `.artifacts/cache-architecture-source.json`. Unchanged
Core code retains the prior 438-function and MainActor compatibility evidence.
Counts overlap and are not added. UI exports are in
`/tmp/botto-cache-architecture/ui/`. These fixture/Simulator checks do not
establish production-host, physical-device, full-map or performance acceptance.

The held-read test also asserts that the second restore remains unfinished
before release and completes afterward. Replacing the join with an immediate
return fails that assertion (`.artifacts/cache-restoration-join-red.log`).
Restoring the production implementation passes all six focused functions in
two suites (`.artifacts/cache-restoration-join-green.log`). Only this test's
assertions changed after the integrated run; production Swift hashes still
match it. The final 272-file source binding is
`.artifacts/cache-restoration-join-source.json`. The focused rerun covers the
stronger assertion; the integrated and UI results retain their original source
binding. Counts overlap and are not added.

## Reader and connection lifecycles — 2 November 2026

Chat and Library artifact readers now use one lifecycle in `ArtifactPreviewModel`.
Their source/access policies remain distinct. Read, output, export failure and
terminal finish states own their tasks and captured files. Reload failures keep
the last useful file; stale read and export callbacks cannot settle a new owner.
AppStore's connection lifecycle now owns its candidate, event/recovery lifetimes
and status. An interrupted explicit handshake retains its candidate and cannot
be committed by an automatic recovery event. Durable credential rotation remains
separate from the retiring screen.

The new interrupted-sign-in sequence passed against the previous AppStore and
after refactoring, covering completion, backgrounding and replacement. The
baseline changed only the preview implementation and added this test; it is not
a reproduction of a connection bug (`.artifacts/lifecycle-interrupted-baseline.log`).
Focused checks passed 116 functions in six suites
(`.artifacts/lifecycle-focused-green.log`). Integrated checks passed 371 functions
in 15 suites, plus four UI cases: completed preview/share after background recovery,
Save cancellation/reopen and connection replacement, retained inbox history before
attachment, and drafting while attachment waits
(`.artifacts/lifecycle-integrated-green.log`). Counts overlap and are not added.
The source bindings and UI exports are in `/tmp/botto-lifecycle-followup/`.
Each run has a source binding; focused and integrated runtime/test hashes match.
Runtime and test sources stayed stable while those checks ran. These
fixture/Simulator checks do not establish
signed Keychain or live-host sign-in, physical-device, full-map, exhaustive
interleaving or performance acceptance. Core code is unchanged.

The subsequent ARCH-02 review found that a queued chat reload could renew access
after recovery. Request admission now synchronously prepares an immutable loader
before scheduling the read. A new actual-reader regression requests Reload offline,
publishes recovery before the task starts, and checks that a deliberate new retry
is required. The app and tests compiled for the generic Simulator destination while T3
Simulator capacity and boot failures blocked execution
(`.artifacts/lifecycle-authority-build.log`). After an owned Simulator became
available, the regression failed against the exact pre-fix producers with an extra
network read and replaced file (`.artifacts/lifecycle-authority-red.log`), then
passed against the repaired source
(`.artifacts/lifecycle-authority-regression-green.log`). The repaired source also
passed 372 native functions in 15 suites; its two chat UI cases and completed-file
background case passed (`.artifacts/lifecycle-authority-integrated-green.log`).

That integrated command failed at the text UI check's file-card setup. One
unchanged retry failed there too (`.artifacts/lifecycle-authority-ui-retry.log`).
The helper used its first accessibility match, and Canvas contains two notes.txt
references. Instability during transcript replacement is a source-based explanation;
the retained frames do not identify the queried accessibility row. It now waits
for an enabled, reachable card with the requested filename, preserving the content
and export assertions.
All four affected artifact UI cases then passed: background recovery, text
Save/reopen/replacement, PDF zoom/Share cancellation, and rendered image/Share
replacement (`.artifacts/lifecycle-authority-ui-ready-green.log`). Together with
the two unchanged chat cases, six distinct UI cases have passing observations.
The failed attempts remain recorded; the initial integrated command is not a
passing full-suite gate. Counts overlap and are not added.

Production and native test bytes remained unchanged between the regression,
372-function run and final UI run; only the UI helper changed before the last
run. Source bindings, failure recording, and UI exports remain in
`/tmp/botto-lifecycle-followup/`. The earlier 371-function/four-UI run covers the
pre-ARCH-02 snapshot. These fixture/Simulator checks retain the limits above.


PR integration on current main also exposed a queued metadata-write handoff gap.
The cache rejected a superseded revision as a retired writer, and Library could
leave the newer dirty revision unsaved. A controlled Library test holds the old
write before its revision check, accepts and projects a newer read, and requires
that content and its artifact after an independent cold reopen without another
refresh. It failed on the integrated writer with a retained guard and missing
cold content, then passed after distinguishing supersession and continuing with
the newer local revision. Genuine SQL-failure and stale-write controls also
passed (three functions in two suites). Logs and source manifests are under
`/tmp/botto-pr-integration/writer-handoff-controlled-red*` and
`/tmp/botto-pr-integration/writer-handoff-green*`. An earlier test attempt only
confirmed that a guarded book seed is withheld; it did not exercise the newer
accepted-read handoff and is not the regression control. The first full-gate
attempt was stopped for this repair before native/UI completion; its partial
results are retained in `/tmp/botto-pr-integration/full-gate.log`.


The restarted full gate found a second integration regression: in the held
notification-open retirement test, a background history window changed the
retained main snapshot ID from its runtime ID to its stored tip. The selected
chat, history preference and authority fences stayed correct. The unchanged test
reproduced both disabled and remotely removed pairing cases in isolation
(`/tmp/botto-pr-integration/retained-snapshot-red.log`). A same-profile, same-tip
window now preserves the retained runtime ID while replacing its history. The
selected `NotificationStoreTests` and `ConversationDirectoryPreviewTests` suites
then passed, 27 functions
(`/tmp/botto-pr-integration/retained-snapshot-green.log`), with the original
retirement assertions intact. The separate `InboxMessagePreviewTests` suite was
not selected. The second full-gate attempt was stopped for this
repair before completion; its failures remain in
`/tmp/botto-pr-integration/full-gate-fixed.log`.


The third full-gate attempt completed with exit 65
(`/tmp/botto-pr-integration/full-gate-retained.log`). Core checks passed
(438 functions in 11 suites and MainActor compatibility). The native run found
26 issues across two recovery test functions. Their positive reads now obtain
identity evidence from the existing test service's history producer, preserving
all assertions and parameter cases. That fixture migration exposed six remaining
issues: during failed restoration, a stale book seed could enter a fresh accepted
chat and survive a cold reopen. The initial seed guard distinguished an inert seed
from an already accepted source using the acceptance fence and source proofs. The same Library recovery, retention and inbox-history suites then passed
183 functions in three suites (`/tmp/botto-pr-integration/recovery-seed-green.log`).
The preceding failed run remains in `coherent-fixtures-green.log`; its filename
does not indicate success.

The third gate also had six UI assertion failures before its Simulator lease was
released externally. Later runner failures and independent export readback occurred
after that release. The gate did not pass. Its log and summary remain; focused
reruns rotated away its original Xcode result bundle. New comparison runs retain
explicit result bundles. Subsequent comparisons and export checks are recorded below.


Pass 20 found that bounded ordering-fence eviction could reopen the stale-seed
path, and that inbox windows updated chat without publishing their fetched rows
to Library. Both were reproduced through actual restoration and workspace paths.
Admission now retains explicit seed/window/guard provenance with each canonical
record. A shared transcript publication carries live reads and inbox windows;
only fetched rows receive fresh read evidence. Exhaustive producers may certify
window identity, while bounded windows preserve unresolved exclusions. Passive
positive windows defer guarding unread saved rows; new negative evidence still
guards immediately. Windows preserve known unsettled working tails.

Four new test functions cover fence churn, fetched-window publication, working
tail persistence, and a dispute arriving before saved metadata can be read. The
existing offline withdrawal test also covers inbox prefetch in all eight parameter
cases, preserving its original assertions. Against the final tests, restoring the
two old behaviors failed with 31 issues across those four functions (113-function
Library suite). Removing only the negative-evidence barrier failed the privacy
check with three issues; treating a window as working-state evidence failed the
tail check with four. After restoring the exact candidate, all 200 functions in
four suites passed. Core checks passed 438 tests in 11 suites plus MainActor
compatibility. Logs, commands, source manifests and explicit result bundles are
under `/tmp/botto-pr-integration/`: `recovery-publication-final-mutant-red`,
`passive-window-negative-mutant-red`, `window-working-state-mutant-red`,
`recovery-publication-final-green`, and `recovery-window-core`.

On the preceding `97d63dc` snapshot, all 843 Swift Testing functions in 70 suites
and 24 XCTest cases passed. Six comparison UI cases failed; immutable immediate
main reproduced the six original assertion failures. One current stress attempt
stopped earlier at Scout/Iris profile readiness, so it is not a comparable
performance observation. Duo passed six cases, skipped its iPad-only case, and
failed at notes.txt card setup; main reproduced that setup failure. These results
do not establish performance acceptance. The distinct avatar, offline feedback,
Duo setup and streaming follow-ups are saved in Snip Snap.

All five artifact export UI cases passed on that snapshot. Independent provider
readback verified all 80 expected bytes and SHA-256
`ab2d37c15d4277807c8d7c9ac788d680ce95645b07a1d0e61ee34005a2b41cce`
in AppleLocalStorage. Its first readback attempt rejected a `/tmp` symlink input;
the same absence receipt passed through its canonical `/private/tmp` path.
The pass-21 snapshot and subsequent repairs are recorded below. No passing full
gate or release acceptance is claimed.


On `b76dab9`, the broad run passed all 847 Swift Testing functions in 70 suites
and 24 XCTest cases. Both chat UI cases and four artifact UI cases passed. The
text-preview case timed out at the Actions-dismissal accessibility predicate;
the retained recording shows the menu closed and the document visible, but does
not establish which predicate term failed. The immutable-main comparison passed
that case, so this timeout is not classified as a reproduced baseline failure.
The combined command exited 65. Save/reopen in Files passed, and independent
provider readback again verified all 80 bytes and the digest above. Commands,
manifests, attachments, video and receipts are retained as
`/tmp/botto-pr-integration/final-native-chat-export*` and
`main-text-menu-baseline*`. New native test edits began only after that native
phase; compiled app/UI binary hashes stayed identical through its UI phase
(`pass21-postnative-test-edit.json`).

Pass 21 identified two more recovery guard cases. Two bounded inbox windows
could revise the same known message without guarding its saved older producer.
An unresolved exclusion already present in an inert seed could also be mistaken
for protected evidence. Actual locked-SQL, writable-journal checks reproduced
both cold Search/artifact leaks, with three issues each. The original unseeded
case and an unchanged-producer control passed. A further empty-window case
reproduced three issues when rows stayed identical: changing admission state
alone did not schedule a guard. Promotion now marks metadata dirty as well.
The final two functions, across six parameter cases, passed with unrelated saved
peers still available. Evidence is retained under
`/tmp/botto-pr-integration/seeded-window-dispute-{red,green}*`,
`revised-window-producer-red*`, `window-guard-regressions-green*`, and
`unchanged-dispute-guard-{red,green}*`.

A fresh Core run passed 438 tests in 11 suites and the MainActor compatibility
build, with recorded command, source hashes and unchanged-during-run audit
(`final-core*`). Its Core dependencies remain unchanged by these App repairs.
On `8862cc8`, four native suites passed 201 functions. Six of seven affected UI
cases passed; the background export case failed at the initial file card because
its activation point was invalid. That unchanged case passed on retry. All seven
therefore have passing results across runs, with no single combined gate pass.
Independent provider readback passed all 80 bytes and the digest above. Evidence:
`final-recovery-chat-export*` and `artifact-background-unchanged-retry*` under
`/tmp/botto-pr-integration/`.

Pass 22 found that indexing budgets could discard a passive producer's revision
baseline or required exclusions before the recovery journal protected them.
The corrected locked-SQL regression failed in all four pressure cases (row,
chat, initial-window and exclusion limits), with 16 issues covering guards and
cold Search/artifact leaks. The unrelated saved peer remained available.
Admission now records guards before canonical eviction. Bounded scope hashes
retain the resulting uncertainty until saved evidence is reconciled.

A second regression exposed replay of an already-fetched saved row after a guard
was created during restoration. Recovery now rechecks that row and merges its
negative evidence as a hint. The first executed duplicate-hint check then found
four live/cold Search and artifact issues; hint conversion now retains duplicate
IDs as disputes. The broader run passed 241 of 243 functions but exposed two
existing fence-churn cases where valid accepted rows remained hidden. Retry now
preserves those rows behind the gate and releases them after SQL proves their
source has no saved metadata. The focused rerun passed three functions across
nine parameter cases.

These results, including failed attempts and exact source manifests, are retained
as `bounded-window-producer-red*`, `guarded-restore-replay-red*`,
`guarded-hint-identity-executed-red*`, `recovery-budget-identity-green*` (failed),
`churn-reconciliation-green*`, and `recovery-budget-final*`. The initial
`bounded-window-guard-red` used an incomplete pressure fixture; its corrected
successor supplies the four-case failure evidence. The first hint-identity
attempt stopped before tests executed and supplies no runtime result. The final
five-suite run passed all 243 functions. Production and test hashes
remained unchanged during that run; only these proof and contract docs changed.
On `e93d567`, all seven affected UI cases passed in one run and independent
provider readback verified all 80 bytes and the expected digest. The source and
test hashes stayed unchanged. Result bundle, binding, readback receipt and retained
provider bytes are under `/tmp/botto-pr-integration/budget-final-chat-export*`
and `budget-final-retained-notes.txt`. This selected run does not replace the
failed full gate.

Pass 23 found that an oversized recovery hint could stop unrelated saved peers
from loading, a skipped different-tip hint could lose retirement evidence, and a
failed guard could let an older producer return during a later retry. With the
saved producer explicitly loaded before its healthy peer, the three-function
regression failed across five cases with 25 issues: 16 peer-availability issues,
four different-tip issues, and five live/cold failed-guard issues. The same-tip
control passed. Loading the peer first had retried the guard and masked that
last failure; the final fixture asserts the actual saved-row order.

Hint installation now returns a typed installed/deferred result, with receipts
bound to the retained source. Deferred scopes keep their gate while independent
saved rows load. Discarded scopes retry guard admission and merge saved negative
hints before any SQL body can return. The focused five cases passed. A further
seed-before-restore cold control reproduced eight peer-availability issues;
checked saved rows now release their own inert seed gate while another hint
remains pending. The first broader run executed 246 functions and failed with
11 issues in two existing recovery functions. A hidden hint could occupy the
only retained chat slot, and its installation incorrectly required the separate
presentation/save-ready result. Hints now rank after chat rows, and admission
checks their actual retained source. The five focused functions passed all 12
parameter cases, followed by all 246 functions in the five affected suites.
All 486 tracked hashes stayed unchanged through the final native run; this proof
wording changed afterward. On `8a54e29`, all seven affected UI cases passed in
one run and provider readback verified all 80 bytes and the expected digest
(`admission-final-chat-export*`); all 486 hashes stayed unchanged. These selected
results do not replace the failed full gate. Evidence: `hint-disposition-final-red*`, `hint-disposition-green*`,
`hint-seeded-peer-red*`, `hint-disposition-final-native*` (failed),
`hint-liveness-green*`, and `hint-admission-final-native*` under the same retained
directory. The initial red attempts included an overstrict same-tip
immediate-visibility assertion; independently persisted conflicting revisions
correctly stay unverified until a fresh read. All privacy and peer controls remain.
Earlier full-gate failures remain disclosed.


Pass 24 found that a deferred oversized hint could still hold an unrelated partial
inbox window behind the global recovery gate. The new public producer regression
covers an absent saved row, a same-tip revision and a different older stored tip.
All three publish before restoration, retry twice, check live visibility and
persistence, publish another update without restoring again, and cold reopen with
an offline captured peer. The different-tip case seeds an older Book and requires
persisted retirement evidence. Four disputed IDs keep the unrelated hint larger
than the three-slot budget; current row, retirement and peer fit within it.

The final controlled regression failed with 26 issues across three cases. An
initial fixture also had three invalid coverage assertions: an unchanged partial
window correctly retained a complete Book's coverage. The corrected fixture starts
with a partial Book. Reconciliation now records checked or deferred state per chat,
with source, fence and canonical-content-version checks. Installed or absent saved
metadata releases only that chat; subsequent updates retain its checked state.
The first focused candidate passed the new cases but failed two unchanged
fence-churn cases when retry withdrew a checked chat for its own pending save.
Preserving the per-chat result fixed those cases; eight functions across 21
parameter cases then passed. The first broader run executed 247 functions and
found four issues in two legacy-tip compatibility functions. Per-chat settlement
now preserves the established Book-versus-legacy-index tip choice and records the
displaced tip. The four focused functions across nine cases passed. The final
five-suite run passed all 247 functions. All 486 tracked hashes stayed unchanged
through that run; this proof wording changed afterward. On `0c0e8fa`, all seven
affected UI cases passed in one run and independent provider readback verified all 80 bytes and the expected
digest (`scoped-final-chat-export*`). All 486 tracked hashes stayed unchanged.
Pass 25 found the unchecked discarded-scope issue described below. Evidence under
`/tmp/botto-pr-integration/`:
`independent-window-{red,controlled-red,final-red,green}*` (green failed two cases),
`scope-liveness-green*`, `scoped-recovery-final-native*` (failed),
`scope-legacy-green*`, and `scope-settlement-verified-native*`. The earlier
`scope-settlement-final-native` attempt refused an ended Simulator lease before
executing tests. The replacement Pro Max failed to boot without host details;
the advised retry on an iPhone 17 Pro booted and ran the verified suite.


Pass 25 found that a successful retry could clear a hold for an evicted chat
whose failed recovery guard had never been checked. The new regression starts
with no saved row for that chat, fails the guard, evicts it under chat pressure,
repairs storage, retries and then seeds an older Book. Its unrelated saved peer
has a fresh producer read and captured bytes available offline. The controlled
red run reproduced five Search, artifact and persistence issues across two cases.
Two earlier attempts stopped at a missing-peer precondition before exercising
the stale-seed path. The corrected fixture keeps that peer through a fresh
producer read while applying pressure. Those attempts provide no evidence of
the stale-seed failure. A still earlier attempt refused an ended lease before executing tests.

Restoration now preserves unchecked scope holds after other chats settle. Book
seeds remain gated for those scopes. Only a matching coherent producer read,
whose complete rows survive admission, releases that scope; later partial
updates can then continue normally. The focused run passed nine functions,
including both new cases. The five affected native suites passed all 248
functions. App and test dependencies matched the run manifest; only proof prose
changed during that run. On `dc4eb02`, all seven affected UI cases passed in one
run and independent provider readback verified all 80 bytes and the expected
digest (`hold-final-chat-export*`). All 486 tracked hashes matched before and
after the run. Pass-26 Thermo and Adversarial reviews found the scan and freshness
issues described below; the other two assessments were canceled before repair.
That partial review round does not supply complete four-angle acceptance. Evidence: `unchecked-hold-{executed-red,fixture-diagnostic,controlled-red,green,final-native}*`
under `/tmp/botto-pr-integration/`. Prior failed full-gate results and acceptance
limits remain unchanged.


Pass 26 found two further routes around a held scope: a Library scan could save
unchecked data or use SQL absence to release the hold, and a delayed coherent
read could lose its freshness fence after eviction. The expanded public-path
regression covers failed and partial scans after storage recovery, a partial
scan before recovery, a captured older inbox response delivered after a newer
Library read and eviction, and the existing no-scan case. Each runs with and
without a later trusted read. The scan cases cold reopen with a distinct-ID
stale Book row and check Search, artifacts, SQL and offline captured peer bytes.
The delayed response includes a removed recent row so it fits the budget and
exposes a material failure. The final controlled red reported 34 issues across
ten cases. Raw source/test controls are bound to the retained run manifests.
An earlier attempt included unsupported cold assertions after a guard could not
be written and no subsequent durable operation occurred. Another proved delayed
admission but its old row did not fit the retention budget. Neither supplies the
final delayed-content or recovered-scan acceptance evidence.

Shared admission now checks held history reads, scoped loss times survive
eviction, and the writer cannot clear a held scope's guard through an unchecked
upsert. SQL absence keeps those holds. The first shared repair passed nine
focused functions, including all ten new cases. A further positive control uses
a complete Library scan to resolve the hold. It found one case where the scan
left fresh metadata waiting for another restore. The scan now settles that
metadata before its final save. That rerun found three cold privacy issues in
the pre-recovery scan case. Source tracing linked these to withdrawal clearing
an empty hint's dirty flag before its guard could be retried. Guard inventory
now includes every held canonical scope, independently of dirty state. The final
focused run passed all nine functions, including ten recovery cases. The five
affected native suites passed all 248 functions. Runtime and test bytes matched
the run manifest; only contract/proof prose changed during that run.
Evidence: `scan-hold-{red,controlled-red,final-red,green}*`,
`scan-settlement-{red,green}*` (green failed three assertions), and
`scan-{guard-inventory-green,hold-final-native}*` under
`/tmp/botto-pr-integration/`. On `1b951a4`, all seven affected UI cases passed in
one run and independent provider readback verified all 80 bytes and the expected
digest (`scan-final-chat-export*`). All 486 tracked hashes matched before and
after the run; provider bytes were retained on the host. All four pass-27
assessments completed on that snapshot. Adversarial found the saved-hint issue
below; the other three found no additional material issue. Earlier full-gate
failures and acceptance limits remain.


Pass 27 found that a saved-row hint could release a discarded-scope hold without
a complete source read. The regression now shares one fixture across separate
absent-row and saved-row tests. Each runs ten cases. The saved-row setup leaves
room for the old SQL hint after failed guard admission and eviction, then covers
failed/partial scans, distinct-ID Book reseeding, live/cold Search, artifacts,
SQL and the offline captured peer. The controlled red recorded 30 issues in the
saved-row test; all ten absent-row controls passed. Raw production and final test
bytes are bound to that run's manifest.

Saved-state receipts now defer held scopes both when recorded and after awaits.
Only qualified complete producer/scan admission releases the hold. The first
focused candidate passed the new cases but failed nine unchanged availability
assertions in the independent same-tip partial-window test. Source tracing found
that rejecting an older SQL revision was being classified as lost fresh history.
That incoming-row loss check now applies only to producer rows; canonical
retention still protects actual accepted rows and exclusions. The next focused
candidate passed the availability control but missed one initial-window guard:
the existing scan-read classifier excludes producer publications. A separate
`hasProducerRows` classification covers publications plus complete/partial scan
pages. The final focused run passed all ten functions, including both ten-case
saved/absent matrices. All 249 functions passed in the five affected native
suites. Runtime/test bytes matched the run manifest; only proof prose changed
during the run. Evidence:
`saved-hint-{red,green,admission-green,producer-guard-green,final-native}*`
under `/tmp/botto-pr-integration/`; the first green label records a failed run.
On `2a50b59`, all seven affected UI cases passed in one run and independent
provider readback verified all 80 bytes and the expected digest
(`hint-final-chat-export*`). All 486 tracked hashes matched before and after the
run, and provider bytes were retained on the host. All four pass-28 assessments
completed; Adversarial found the retry-timing issue below, while the other three
found no additional material issue.


Pass 28 found that retrying the same oversized negative hint could move an
existing loss timestamp and reject a complete read started after the actual
loss. The new barrier test pauses a real complete inbox response, retries the
hint twice, then releases the response. A current stored tip lets its row and
retirement evidence fit while the four-ID old hint cannot. The no-retry control
passed on the old production; the retry case failed admission and saved-row
assertions. The initial fixture stopped at a missing-publication precondition;
its service identity omitted the root/tip aliases added by Book binding. The
corrected fixture uses the same proven aliases and supplies the controlled red.

Hint deferral now initializes an unknown scope's loss time once. An unchanged
retry preserves an existing time; actual canonical producer/evidence loss still
records a newer time. The test checks fresh Search/artifacts, actual SQL/guard
settlement, persisted retirement, cold rejection of the old Book and independent
captured peer bytes offline. Existing pre-loss delayed-read rejection remains in
the focused selection. All eleven focused functions passed, including the two
barrier cases and twenty saved/absent cases. All 250 functions passed in the
five affected native suites. Runtime/test bytes matched the run manifest; only
contract/proof prose changed during the run.
Evidence: `hint-clock-{red,controlled-red,green,final-native}*` under
`/tmp/botto-pr-integration/`. These native results do not establish full-gate or
release acceptance.
Final UI/source-review and integration results follow.

The final history head `1f62478` passed all seven chat/export UI cases in one
run. Independent Files-provider readback verified the expected 80 bytes and
SHA-256 `ab2d37c15d4277807c8d7c9ac788d680ce95645b07a1d0e61ee34005a2b41cce`.
All 486 tracked source hashes matched before and after; host bytes were retained.
All four pass-29 source assessments completed without material findings.

Integration with `main` at `ec4dc58` produced `f49e66c`. The sole conflict was
adjacent additions in `WorkspaceLibraryRetentionTests`; the resolution retained
the complete upstream readiness helper and both parents' tests. All four
pass-30 assessments covered the 35 integration paths and affected assumptions,
retaining their accepted coverage for unchanged history/cache code. They found
no material source issue. Ponytail disclosed an inventory of prior other-angle
acceptance filenames and digests; it read no peer reports, receipts or
conclusions. The parent accepted that metadata-only caveat. Review originals,
read receipts and hashes remain under `/tmp/botto-chat-sync-review/pass-30/`.

On that integrated source, the full `scripts/check.sh` attempt passed 438 core
functions across eleven suites, MainActor compatibility, 24 native XCTest
cases and 863 native functions across 70 suites. A separate complete Python
run passed all 234 tests. The full gate did not pass: nine UI assertions failed
before an explicit release of its exact simulator lease. SimLock recorded the
release at 2026-11-03 06:10:09 UTC; the releasing actor is unknown. The parent
stopped and awaited only its owned consumers after observing the lease absent.
It issued no commands or cleanup against the ended device. Later runner
failures and the missing final provider proof do not establish product defects.
The artifact-export and all twelve inbox-retention UI cases passed before the
interruption. These partial results are not a completed full-gate result.

A fresh, nine-case control on an exact archive of `ec4dc58` reproduced eight
failures: four Avatar cases (chosen shared avatar, name/custom mode changes,
offline background/reconnect and save-sheet dismissal), the offline file/action
feedback case, both first-stream fixture cases and the Duo parked-file reopening
case. The diagram-scroll case passed in that control. Baseline source hashes
matched the pinned Git objects before and after. No production cause or fix for
these baseline failures is claimed. The unchanged integrated branch also passed
that diagram case in a separate focused run. Its full-run visibility failure remains unresolved and has a saved
Snip Snap follow-up; the focused pass is not a demonstrated fix.

The integrated source separately passed all seven affected chat/export UI cases
in one run. A new absence receipt and independent Files-provider readback
verified all 80 original bytes and the expected digest; those bytes were copied
to the host before device release. All 489 source hashes matched the run's
manifest. Evidence: `main-integration/{full-gate*,baseline-nine*,tooling*,
integrated-ui-binding.json,integrated-retained-notes.txt}` and
`integrated-final-chat-export*` under `/tmp/botto-pr-integration/`.
These author-run before/after bindings do not constitute continuous filesystem
monitoring. There is no full-suite, performance, live-host, physical-device,
complete verification-map or release acceptance. Final PR preparation changes
only this verification prose; runtime and test bytes retain those bindings.


## Local chat UI gate repair — 3 November 2026

The branch includes `main` at `9c7412f` and repairs native creation dismissal,
offline file feedback, reconnect feedback, and shared cache publication. Bot
inventory hints trigger a leading read and coalesce further reads through a
fixed five-second cooldown. Explicit refreshes and live conversation publications
bypass the cooldown. Inventory hints can wait five seconds plus read latency.

The controlled store workload kept 205 profiles, 400 history messages, 200
fragments, 20 ms sleeps, and all 203 advisory emissions. Single observations on
the integrated source took 16.69 seconds before the cache/activity refinements and cooldown tuning
and 13.65 seconds afterward; roster reads fell from 13 to 3. These are individual
runs, not a statistical latency claim. Commands, logs, and full source bindings
are retained under `/tmp/botto-ui-gate-repair/` (`integrated-control8` and
`restored26`).

A main-thread profile recorded 1,527 of 8,775 samples inside XCTest accessibility
attribute queries. The performance helper now waits on a fixture completion
signal, then checks the actual native reply within the original 20-second budget.
The signal follows the unchanged 200-fragment sequence. A controlled
mutant omitted only its final publication while still writing the signal; it
failed at the native reply assertion (`missing-publication-mutant25`). Restoring
the exact publisher passed both workflows at 19.59 and 18.51 seconds, including
three reading-position and draft-preservation cycles. The same `restored26` run
passed 261 Swift Testing tests in seven suites and its XCTest store measurement.

One earlier control stopped before streaming after a Scout tap opened Iris.
The pinned rail inherited the inbox's changing activity order; it now uses a
stable name and exact-ID order. No frame trace established that ordering as the
observed failure mechanism. The subsequent control reached and rejected the
intended missing-publication mutation.

The complete local gate is pending on this repaired source. Earlier partial UI
runs and passing GitHub build checks do not establish that full-gate result.


The follow-up creation repair binds the published result to the workspace,
connection and socket-recovery lifetime captured before creation. Selection
revalidates inside the observable mutation, so a synchronous callback cannot
replace newer navigation or acquire recovered authority. Root acknowledges a
successful creation while inactive; an unavailable opening leaves a clear inbox
notice rather than a submitted form inviting another create.

A controlled Root scene-phase fixture reproduced both inactive failures:
unchanged Root left the form open; removing only its first active-scene guard
dismissed the form but failed to open Orbit. This injects the native environment
value and does not claim an exercised Control Center interruption. The native
handoff control with the former late-capture behavior failed seven assertions
across creation, selection, dismissal and replacement-navigation cases; its
normal-opening control passed. The repaired run passed all 95 functions in
AppStoreTests, AppStoreRefreshTests and AppStoreAvatarTests, plus all six
NewBotUITests, including the inactive case and create/refresh/open replacement
interruptions. Evidence: `arch23/{red,dismissal-red}*`, `authority-red5*` and
`authority-green2*` under `/tmp/botto-ui-gate-repair/`, with complete source
copies. Failed compilation, an empty selection, and an earlier recursive test
callback are excluded from proof. The first full-gate attempt was deliberately
stopped before this repair; a complete gate on the repaired source remains pending.

### Navigation ownership integration — 3 November 2026

Bot entry, Library commits and creation now share one navigation claim taken
before queued work or creation I/O. Callers honor a rejected selection, and
attachment rechecks ownership after synchronous callbacks. Root always
acknowledges a confirmed creation. A nested same-value or nil selection write
now also supersedes an older in-flight selection.

The ARCH29 control on the integrated source without that last change failed 4
of 10 reentrancy cases (11 issues): raw same-value and nil writes during creation
and ordinary opening. Real Inbox captures and byte-distinct Unicode writes already
passed, as did the ordinary-opening controls. The final source passed 182 Swift
Testing functions in AppStoreTests, AppStoreRefreshTests, AppStoreAvatarTests,
ConversationWorkspaceTests, LibraryNavigationIntegrationTests,
NotificationStoreTests and WorkspacePresentationTests, plus all six
NewBotUITests, on an owned iPhone 17 Pro (iOS 27.0) simulator.
`scripts/check-core.sh` passed. Those source bindings and logs were stored at
`/tmp/botto-ui-gate-repair/nav33/claude-final/` and were lost in the 3 November
host reboot. This entry records the earlier reported result; it no longer has
its original raw evidence. The full gate on this source remains pending.

### Notification and Library ordering — 3 November 2026

A notification tap now takes its navigation order at admission, and notification
and Library openings settle bot selection inside their attachment commit. Picker
and chat-creation captures and direct selection writes cancel a retained tap. A
pending Library selection yields to any newer selection write.

On exact `75c8cff` production, 24 of 34 new cases failed: all 8 where older
creation, opening or Library navigation beat a held tap, plus 12 notification and
4 Library cases with a newer same-value or nil write. Positive controls and the
real Inbox route passed. Five repeats failed the same 175 sites each time. The
first red run, before a host reboot and macOS upgrade, recorded 174 issues in the
same 24 cases. The one known difference: production's held Library opening in the
status case now also reports success. Its cause was not isolated.

The same source bytes then passed the seven suites above (185 Swift Testing
functions) and all six NewBotUITests on an owned iPhone 17 Pro (iOS 27.0) simulator,
under macOS 27.2 and Xcode 27.1. All 34 new cases also passed 20 further iterations
with a host load average above 150. A supplementary run of the whole BottoTests
bundle had no failures: 930 passed and two transcript measurement tests skipped.
Core code did not change, and `scripts/check-core.sh` was not rerun. The new
post-reboot evidence and source bindings are preserved at
`/Users/sree/.t3/userdata/verification/botto-chat-pr24/nav34/`.
The reboot also removed the earlier `/tmp/botto-*` logs and review archives;
their recorded results remain historical claims. Fresh review of the combined
change and the full gate on this source remain pending.

### Recent-read dispute propagation

The inbox reader now reports observed duplicate raw IDs even when the response
is omitted, truncated or otherwise rejected. A scoped negative publication
updates Book and Library without admitting rows or resolving earlier disputes.
On starting production, the Core control failed seven of 19 cases and the native
control failed eight of 27 tests with 34 issues. The fixed source passed
`scripts/check-core.sh` (492 tests and MainActor build) and 248 native tests in
six suites. Five repeats of the 27 focused tests passed. These checks cover
cached-artifact withdrawal, cold restoration, unaffected peers and coherent-read
recovery. HTTP producer and native consumer checks are composed; no single test
crosses HTTP through AppStore to Library. Evidence and source bindings are at
`/Users/sree/.t3/userdata/verification/botto-chat-pr24/repairs-35/cache/outputs/`.
Combined navigation integration and the full local gate remain pending.

### Integrated cache and interrupted-opening check

One native-only `BottoTests` run on the combined cache and retry source passed
944 tests with no failures. Two opt-in transcript measurements were skipped:
`BOTTO_TRANSCRIPT_ACTIVE_RICH` and `BOTTO_TRANSCRIPT_BENCH` were unset. All 555
source hashes and the 15-path dirty diff stayed unchanged throughout the run.
Evidence is at `/Users/sree/.t3/userdata/verification/botto-chat-pr24/integrated-native35/`.

The retry UI regression passed in eight fixed-source executions. The six existing
creation UI tests still showed an intermittent compact-navigation failure on
both unchanged production and the retry candidate. That required gate failure
remains open; these separate runs do not establish a passing UI suite or full gate.

### Compact navigation projection

Two deterministic native UI controls failed on the old compact-column code:
an ordinary selection rejected before attachment and a created bot whose sheet
then lifts. Both kept their five-second deadlines. Deriving the compact column
from current presentation and live selection fixed both controls. The final
focused run passed 167 native functions, all nine NewBot UI tests together,
12 Inbox-retention tests and seven Duo tests. One paired-iPad-only Duo test was
skipped. A first candidate failed a live-roster-presence control; the corrected
candidate passed it. No unchanged-source retry supplied the final pass.

The interruption fixture simulates a tap; selection, rejection, compact push,
Back and Retry use the actual native interface. The saved retry-row screenshot
was inspected in light mode at default text size. Evidence is at
`/Users/sree/.t3/userdata/verification/botto-chat-pr24/repairs-35/availability/arch35/`.
These focused results do not establish a full gate or a measured flake rate.

### Notification presentation transaction

The hosted Root controls exposed a second navigation failure: a notification
selected its exact chat while the native stack stayed on Inbox. Moving the
accepted presentation into the store's actor turn fixed the retained controls.
WorkspacePresentation now settles the tab, Library reader, pending opening and
chat surface together. A connection-choice token also prevents an older attempt
from dismissing a reopened connection sheet; that control failed six times on
the previous Boolean and passed on the token.

One run on `0329509` plus the eight-file repair passed 265 native functions in
seven suites and all nine NewBot UI tests, with no failures or skips. All 555
tracked file hashes match the submitted source. Evidence is at
`/Users/sree/.t3/userdata/verification/botto-chat-pr24/repairs-35/availability/arch35/notification-control/tab-repair/`.

The Artifacts-tab control is retained and passes for both profiles. Its latest
red comparison did not reproduce the earlier intermittent failure, so it does
not establish a measured improvement. Notification delivery uses a sealed fake
envelope in a hosted window; the real app scene and an open Library reader are
not exercised together. Reader cancellation has model-level coverage. The full
local gate remains pending.
