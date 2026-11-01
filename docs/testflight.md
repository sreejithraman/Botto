# Internal TestFlight delivery

Botto keeps contributor checks separate from official distribution. Pull
requests, including forks, run tests and unsigned builds without Apple
credentials. The [TestFlight workflow](../.github/workflows/testflight.yml)
publishes a tested commit from protected `main` to an internal tester group.
PRs run core tests, tooling tests, and an unsigned app/test build. Merging runs
the full native suite; a failure blocks distribution. Maintainers need only
push their PR and merge it after the fast checks pass. Fork PRs never receive
Apple secrets or upload builds.
It does not submit an App Store release or invite external testers.

Merges close together share one delivery: a newer main push cancels obsolete
main checks, and only the latest tested main can start publishing. Notes cover
all changes since the last confirmed beta. An upload already in progress is
allowed to finish; the next delivery rechecks the latest tested source and
delivery baseline after queueing. Manual diagnostics cannot cancel main checks.

## Delivery flow

1. The [iOS workflow](../.github/workflows/ios.yml) passes on a push to `main`.
2. Automatic delivery compares current, tested `main` with the last confirmed
   GitHub TestFlight delivery. Pending app or build-tooling changes still ship
   when a later commit changes only docs. Docs-only changes since that delivery
   skip publishing; an unknown delivery baseline publishes conservatively.
   A confirmed baseline records the source commit and successful sign/upload
   step in GitHub job metadata.
3. The publishing job loads the `apple-release` environment, assigns one build
   number to **Botto** and **BottoNotifications**, then archives and exports
   them with matching distribution profiles.
4. The job verifies the final exported IPA's app and extension, including their
   signing identities and profiles. It uploads that IPA, waits for Apple
   processing, saves What to Test notes, and adds the build to the internal group.
5. The workflow retains the source commit, version, build number, IPA checksum,
   and Apple build ID with its release artifacts.

Publishing jobs use
[GitHub's bounded queue](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency)
and run one at a time. A stale job cannot replace the current pending candidate, and a new commit does not
cancel an active upload. Each job rechecks current main and the latest delivery
baseline after queueing, before loading protected inputs. Delivery history
retains successful earlier attempts within the bounded lookup, even when a later rerun fails. Only official main workflow runs can
supply a baseline; fork and pull-request jobs cannot claim a delivery.

The lookup inspects at most 20 recent runs and 100 job executions per run,
with a 30-second budget and five-second request deadlines. Missing, older,
partial, inconsistent, unconfirmed, or slow history is treated as unknown and
publishes conservatively. An older baseline is used only when newer runs
prove that publication was skipped, so an unfinished release cannot hide a
later revert. The current run's unfinished selection is excluded from that
uncertainty check. Main-app guidance excluded by `project.yml` does not
trigger a beta by itself; bundled legal notices remain release inputs.
Current main is checked after lookup and again just before publication.

The workflow also supports **Run workflow** on `main` for a manual beta.
Manual delivery does not bypass checks or make another branch trusted.
Both triggers require a successful iOS run for the exact source commit before
loading protected inputs.

## Maintainer setup

Create the app record, explicit app and notification-extension identifiers,
distribution certificate, and two App Store profiles in your Apple account.
Use one signing team for both targets. The app profile must allow production
APNs even when notifications are unused; both signed targets must share the
expanded push Keychain group. The app-private group must come first, followed
by the shared push group; the extension must have only the shared group.
See [build and signing](setup.md#build-and-signing).

Botto uses Apple's CryptoKit AES-GCM for authenticated push decryption and
SHA-256 for sign-in, plus system TLS. It bundles no cryptographic implementation.
The app declares `ITSAppUsesNonExemptEncryption = false`: it uses encryption,
but none requiring documentation under Apple's
[OS-provided encryption guidance](https://developer.apple.com/help/app-store-connect/reference/app-information/export-compliance-documentation-for-encryption/).
Reassess that declaration if the app's cryptography changes.

Keep the signing identity as a password-protected PKCS#12 file with its private
key. A downloaded certificate alone cannot sign an app. Keep the original
identity and profile backups outside the repository.

Create a GitHub environment named `apple-release`. Allow deployments only from
protected `main`, and require the PR's `verify` check before merging. The full
main checks gate distribution, so PRs need not be rebuilt after every unrelated
main update. Keep Apple inputs
in that environment, not in repository files or pull-request jobs. GitHub
[environments](https://docs.github.com/en/actions/concepts/workflows-and-actions/deployment-environments)
restrict access to release secrets. Run publishing on a disposable
GitHub-hosted macOS runner rather than a contributor's machine.

Configure these environment variables:

| Variable | Value |
| --- | --- |
| `ASC_KEY_ID` | App Store Connect API key ID |
| `ASC_ISSUER_ID` | API key issuer ID |
| `BOTTO_TEAM_ID` | Apple signing team ID |
| `BOTTO_APP_ID` | App Store Connect numeric app ID |
| `BOTTO_INTERNAL_GROUP_ID` | Internal TestFlight group ID |

Configure these environment secrets:

| Secret | Value |
| --- | --- |
| `ASC_PRIVATE_KEY` | Original `.p8` API private key text |
| `BOTTO_SIGNING_IDENTITY_BASE64` | Base64-encoded distribution PKCS#12 file |
| `BOTTO_SIGNING_PASSWORD` | PKCS#12 password |
| `BOTTO_APP_PROFILE_BASE64` | Base64-encoded main-app App Store profile |
| `BOTTO_NOTIFICATIONS_PROFILE_BASE64` | Base64-encoded extension App Store profile |

A Developer API key can upload builds and manage their internal testing notes
and groups. Creating signing assets requires Account Holder or Admin access;
the routine publishing job does not need an Admin key. See Apple's
[API key guidance](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api/)
and [certificate roles](https://developer.apple.com/help/account/certificates/certificates-overview/).

The script stores temporary signing inputs with restricted permissions, uses a
dedicated keychain, and removes only resources it created. Do not upload those
inputs, the keychain, or unredacted command logs as workflow artifacts.

## Internal group access

Keep automatic distribution disabled for every internal TestFlight group.
[Apple can give these groups access to uploaded builds automatically](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers/),
which would bypass the publisher's notes-readback and explicit group assignment.
Immediately before a fresh upload, the publisher requires each internal group
returned by Apple to report `hasAccessToAllBuilds=false`. Missing or enabled
access stops the upload with configuration advice. Already committed builds
can still reconcile their notes and group assignment. This read does not lock
Apple settings; leave the setting unchanged during a delivery.

## First hosted delivery

The publisher reads versions from configuration `Internal` for both targets
and archives scheme `Botto Internal` with that configuration. Internal builds
include the [developer menu and playgrounds](developer-tools.md); public App
Store candidates use a separate `Release` archive without them. The publisher exports with `testFlightInternalTestingOnly = true`, so
its builds cannot be promoted to the public App Store.

1. Leave the repository variable `BOTTO_TESTFLIGHT_AUTOMATIC` set to `false`.
2. Merge the reviewed workflow and scripts into `main`, then wait for its iOS
   checks to pass.
3. Start **Run workflow** for the TestFlight workflow on `main`.
4. Confirm that the recorded commit, app version, extension version, and build
   number match. Check Apple processing, the internal group assignment, and
   What to Test notes in App Store Connect.
5. Set `BOTTO_TESTFLIGHT_AUTOMATIC` to `true` after the hosted delivery passes.

Accept the invitation in TestFlight on a physical device to verify launch,
demo entry, real Hermes sign-in, chat, and connection restoration after
relaunch. An accepted upload does not prove installation or those workflows.

The existing manual beta does not establish that this GitHub delivery path
has passed. Record hosted evidence separately. Production push delivery also
needs its [host, plugin, relay, and device checks](push-notifications.md).

## What to Test notes

Each build receives notes from app and core changes after the last confirmed
delivered source. The generator reads the tested commit, not a moving `main`.
It uses first-parent commit titles, removes PR-number suffixes, and skips
docs, tests, guidance files, version bumps, default merge subjects and internal conventional commits.
It considers at most the latest 200 first-parent commits in that range,
counting all commits before filtering. Older app changes may appear only in
the linked history. If delivery history is unknown, the range is the available
history at that source.
Notes include the version, build, source SHA
and a link to the corresponding GitHub history; text stays within 3,500 UTF-8
bytes. When space is limited, recent entries take priority; an oversized entry
does not hide later eligible changes. Duplicate wording keeps its latest
position. A build without eligible entries gets a short build-update note.
Before signing or uploading a fresh build, the generator NFC-normalizes text
and removes characters rejected by the
[pinned CLI's Apple character rules](https://github.com/rorkai/App-Store-Connect-CLI/blob/5.16.0/internal/cli/shared/test_notes.go):
`<`, leftover generic combining marks, emoji, pictographic symbols, variation
selectors, private-use characters and all supplementary-plane characters.
Supported Unicode and script-specific marks remain. Empty entries are omitted.

Use one commit trailer for tester-facing wording:

```text
Release-Note: Feel new chat haptics and explore the internal developer menu.
```

Changes limited to `App/Resources/Info.plist` require an explicit trailer to
appear in notes, so delivery metadata does not become tester instructions.
Use a trailer to describe user-visible metadata changes such as URL handling.
`Release-Note: none` omits an app change. A trailer can describe a user-visible
revert or override an internal commit title. Include it in the final first-parent
merge or squash commit message; a trailer on a feature-branch commit does not
survive every merge method. Published notes stay unchanged on retries;
the publisher checks their version/build/source header before reusing them.
It uses a create-only localization API request because the CLI's high-level
`test-notes create` command can update existing text. If another client creates
notes concurrently, it reuses matching source-bound notes or stops for manual
review, without overwriting them.
Before signing, the workflow saves the exact prepared text and its source,
run, version, build and requested baseline in `prepared-notes.json`.
`notesBaseSHA` preserves the requested input; if it is unavailable or not an
ancestor, the saved text and GitHub link show the full-history fallback used.
A separate
immutable `testflight-notes-<build>` artifact must upload successfully before
signing or binary upload starts. A failed-job rerun restores that artifact from
the same workflow run. An explicitly unknown baseline stays unknown; retries
never regenerate notes from a different history range. The artifact lasts 14
days. If it is missing or expired, existing matching Apple notes can still be
reused when the saved upload receipt proves ownership; creating missing notes
or a new upload stops with recovery guidance.
The final text is retained in `what-to-test.txt` and read back from Apple.

## Build numbers and retries

The marketing version remains in `project.yml`. The long-lived delivery
workflow assigns `github.run_number + 1000` as the build number, reserving
`1001` and above for CI. Both targets use that number. A rerun keeps it; do not
use `github.run_attempt` or merge counter-only changes.

Queue entry order can differ from run-number order. Before signing a number
that has no Apple build or committed upload, the publisher checks the next
safe number across processed builds and uploads. A superseded number stops
with new-run instructions. A first attempt refuses an occupied number, even
if it contains matching notes.
A lower-numbered build can reconcile on a retry only when the saved upload
identity proves it belongs to that run.

Use **Re-run failed jobs** when Apple has committed the upload and it is
processing or complete. The publisher looks up the exact version and build,
then compares Apple's `buildUpload` relationship with the upload ID saved in
this run's release receipt. It restores that receipt from the most recent
available earlier attempt artifact, looking back at most 20 attempts. Only
that owned upload can reconcile without another upload. The original prepared
notes artifact preserves the selected change range even if processing timed
out before Apple received any notes. With the saved upload identity retained,
a retry on current main can restore a delivery receipt without another group
mutation. If the artifact containing that identity was lost or failed to save,
manual reconciliation is required even when distribution already finished.
Both the notes checkpoint and the upload receipt artifacts last 14 days.
Missing ownership evidence stops reconciliation even when matching notes exist.
If an upload returns an error after Apple may have accepted it, no returned ID
is available to prove ownership. Inspect that upload manually before starting a
new run; the publisher will not claim it or upload the same number again.

If main has advanced, the old rerun fails with recovery instructions; it does
not claim to have reconciled the earlier upload. Inspect the original build's
processing and group state in App Store Connect, then start a new TestFlight
run on current main after its iOS checks pass.

An `AWAITING_UPLOAD` reservation has no committed binary. The publisher cannot
safely resume it and stops with instructions to start a new workflow run and
build number. A failed or invalid binary also needs a new run and number.
Never use the same number for different source or files.

Do not reset the workflow's numbering. Before replacing the workflow, raise
the migration offset above every previous build number. Avoid uploading
builds outside this path. Renew expiring certificates and profiles, update the
protected inputs together, and validate a manual delivery before resuming
automatic publishing.

The workflow calls the CI-only publisher through this interface:

```sh
python3 scripts/testflight.py \
  --build-number NUMBER \
  --source-sha COMMIT \
  --output-dir OUTPUT_DIRECTORY
```

The command requires the protected CI environment. It is not a local sign-in
shortcut or a contributor prerequisite. [Source releases](releasing.md) keep
their separate verification and publication checklist.
