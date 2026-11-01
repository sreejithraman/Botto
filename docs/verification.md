# Verification

Botto 0.1.0 was checked on 30 October 2026 with Xcode 27.1. Native observations
below use an iPhone 17 Pro Simulator running iOS 26.5. These results describe
the checked source and workflows, not every supported device or server.

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
