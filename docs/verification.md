# Verification

Botto 0.1.0 was checked on 30 October 2026 with Xcode 27.1. Native observations
below use an iPhone 17 Pro Simulator running iOS 26.5. These results describe
the checked source and workflows, not every supported device or server.

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
