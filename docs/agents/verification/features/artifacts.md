# Preview, save, and share original files (`artifacts`)

## User-facing description

Open a message file card in a retained native reader, save original bytes to
Files, or share them. Appropriate plain/source text uses a selectable text
reader; PDF and images use Quick Look. Sub-features: user/assistant references,
PDF zoom, text encoding, empty/unsupported files, retry, captured conversation
ownership, export lifetime, and interruption by external connection review.

## How to get to it

- `artifacts.e.demo`: **Explore the demo** → Canvas → **Open report.pdf**,
  **Open notes.txt**, **Open chart.png**, or **Open report.html**. Canvas has a
  notes card in a user message as well as bot file references.
- `artifacts.e.host`: open an actual user/assistant file card in its original
  connected conversation. Explicit `MEDIA:`, `@file:`, `file://` or server-path
  Markdown references can project cards; ordinary web links/code stay text.
- `artifacts.e.preview`: card → preview (`artifact-preview`). The file header
  offers **Close** (`artifact-done`), **Full screen / Exit full screen**
  (`artifact-toggle-expanded`) and **Actions** (`artifact-actions`). Open Actions
  for **Save to Files** (`artifact-save`) or **Share** (`artifact-share`). A load
  error offers **Try Again** (`artifact-retry`).

## Interactive checks

Use [shared setup](../index.md), ordinary Canvas and known byte fixtures from
[DemoBotService](../../../../App/Demo/DemoBotService.swift). For a real host use
owned files and record expected hashes before tapping. Save only to an isolated
local provider folder; Share only to a local authorized target. These actions
can persist/send data beyond preview lifetime. This recipe includes unverified
provider/error cases; the evidence below records only the sequences actually
run. See [rich replies](rich.md) for inline HTML, a different preview path.

Workflow `artifacts.preview`:

1. `.a1` Tap each Canvas card, including user and assistant entry, separately.
   Expect native preview and usable Close, expansion and Actions → Save/Share. Assert actual PDF **Canvas
   demo** page content, notes text **All sample files stay on this device.**,
   chart's three colored bars, and meaningful HTML preview or honest unsupported
   state with original-byte export. Proof: screenshots/hierarchy per format.
   Read actual text from its TextView value or rendered pixels, rather than
   assuming that text must appear as StaticText.
2. `.a2` Pinch PDF to zoom; expect visibly larger actual page/text bounds, then
   Close returns to the same chat. Open again from the original card. Proof:
   before/after pixels and bounds, reopened content. A `canPreview` result or
   existing sheet is insufficient to prove rendering.
3. `.a3` Open owned empty and unsupported files. Expect **Empty File** or
   **Preview Unavailable**, with export available and no endless loader. Repeat
   long Unicode/combining-mark filenames; expect sanitized private leaf names
   without crash/path escape and original bytes preserved. Proof: UI and fresh
   independent exported-file inspection (also required by save workflow).
4. `.a4` On iPad or an owned Simulator, open a file, then resize the workspace
   through narrow and wide layouts. Expect the same file and exact draft. Wide space pairs chat and
   file; narrow space gives the file a readable width. Zoom and scroll the PDF,
   use Full screen then Exit full screen, and require the useful viewport to survive.
   Browse Bots, then select a bot to open its chat. Selection must retire the
   old file, including when reopening the same bot. There is no Return action. Proof: actual native layouts, rendered content, viewport
   bounds, draft values and reachable controls; session identity alone is not
   enough. Record shared-screen resizing separately if available.
5. `.a5` In a long text file, select a distinctive passage, scroll into the
   document, and change reader width, text size and Full screen/Exit full screen. Expect
   the same useful passage and selection after reflow, with no duplicated or
   reassigned text. Test supported BOM encodings and invalid/unsupported input
   separately. An unavailable preview must still export the exact original
   bytes. Proof: actual selected passage, viewport and independent byte read.

Workflow `artifacts.save`:

1. `.a1` Tap Save to Files, inspect provider UI, then cancel using its actual
   Cancel control or native sheet-dismissal gesture. Expect same usable
   preview with no export-failed alert. Reopen exporter; expect usable picker
   again. Proof: presentation/cancel/reopen captures. Cancellation is not save.
2. `.a2` Choose a run-owned provider folder/name and complete Save. Wait for
   provider completion; dismiss preview, relaunch/reopen the provider independently
   (Files app or fresh provider URL read). Expect exact expected bytes/hash,
   filename/type and zero-byte file where applicable, surviving preview cleanup.
   Proof: provider location, fresh read bytes/hash, success state. Reading
   `botto-artifact-*` temp files cannot pass this assertion.
3. `.a3` With a supported read-only/unavailable provider fixture, attempt Save.
   Expect honest error, no partial output, and preview still usable for deliberate
   retry. Proof: error and independent provider directory read. If unavailable,
   record a provider/harness blocker. Do not claim this from cancellation tests.

Workflow `artifacts.share`:

1. `.a1` Tap Share. Expect a native activity sheet offering the file; use current
   hierarchy (Copy may be a **Cell**, not Button). Cancel/Close; expect original
   usable preview, no error and no external delivery. Proof: activity/cancel/
   return captures and authorized target state if present.
2. `.a2` Repeat, complete a permitted local share, then independently read the
   recipient output. Expect original bytes and one delivery. Keep preview file
   alive until the reader completes, then release owned readers. Proof: target
   readback/hash and reader completion; presentation alone is not delivery proof.

Workflow `artifacts.recovery`:

1. `.a1` Open a missing file, disconnected route, and over-25-MiB artifact from
   isolated host fixtures. Expect clear load error/no export for unavailable
   bytes. Restore a readable same-owner file and tap Try Again once; expect
   correct bytes. Proof: source size/hash, error and successful independent read.
2. `.a2` Tap a server `file://` or path reference. Expect download from captured
   Hermes conversation, never local iPhone filesystem access. Ordinary web links
   and code examples must not become native artifact reads. Proof: public host
   request owner/path and UI projection, with private paths redacted.

Workflow `artifacts.retirement`:

1. `.a1` Separately during download, Quick Look, Share, and Save picker, system-
   open the nonsecret replacement Botto link into the existing scene. Expect
   **Connect Hermes** review, no old export controls, and Cancel returning to
   chat without resurrecting retired preview/export. Do not submit new login.
   Proof: each stage before/after and settled view after cancellation.
2. `.a2` Repeat pending-download retirement by switching bot, reopening same bot,
   reconnect/recovery, backgrounding, and changing connection. Release ignored
   old success/error; expect no late file/spinner or wrong-owner retry. Separately
   complete a download before connection loss: preview, Save, and Share must stay
   usable through same-account recovery/backgrounding while the selected
   canonical conversation is unchanged. Setup review, account/workspace changes,
   selection changes, or a different canonical conversation revoke presentation.
   An existing export reader may finish only with its original bytes. Inspect owned temp
   directory after all readers release; expect its removal and unrelated files
   intact. Proof: timed captures, owner IDs, private-path existence/readback only.
3. `.a3` On small iPhone/iPad at accessibility XXXL and light/dark, expect native
   preview/export controls reachable without clipped sheet/popover. With actual
   Reduce Motion and VoiceOver, preserve navigation, sensible names/order and
   return focus. Proof: screenshots and actual focus/spoken record.

## Gotchas

Source: [ArtifactPreview](../../../../App/Views/ArtifactPreview.swift),
[text reader](../../../../App/Views/ArtifactTextReader.swift),
[model](../../../../App/State/ArtifactPreviewModel.swift),
[ArtifactCard](../../../../App/Views/ArtifactCard.swift),
[AppStore](../../../../App/State/AppStore.swift).
[ArtifactPreviewTests](../../../../AppTests/ArtifactPreviewTests.swift) support
private-byte lifetime/sanitization and owner cancellation/late completion.
[ArtifactExportUITests](../../../../AppUITests/ArtifactExportUITests.swift) now
cover Save cancellation, reopening, and a uniquely named completed Save followed
by an independent Files-app reopen. Broader file/provider cases require
separate verification.
[Provider readback](../../../../scripts/verify-artifact-export.py), invoked by
`scripts/check.sh`, reads the saved original from the exact simulator's local
Files provider and compares the independent 80-byte fixture and SHA-256. Retain
both UI and `.artifacts/artifact-export-receipt.json`; neither replaces the other.

Files pickers differ by OS version and provider. Use the actual native
dismissal path when no Cancel button exists. Wait for the provider root and
filename field before editing. When verifying completed export, reopen the
exact item in its provider directory; Recents search can hide a saved item.
Dismiss any existing Quick Look document before entering the chosen directory.

A completed UI Save and an independent provider-byte readback prove different
parts of the workflow. Preserve both. A single successful text export does not
pass every format, third-party/offline provider, interruption, or retirement
assertion. Keep proof outside disposable provider and temporary directories.
See [verification](../../../verification.md) for recorded checks and limits.
