# Preview, save, and share files (`artifacts`)

On iOS, choose **Explore the demo**, open the Spaces drawer, and select
**Canvas**. For live proof, use a paired disposable T3 workspace and open
a file with known bytes from its owning Space. These checks are draft.

## Preview

1. `artifacts.preview.a1` — Open `report.pdf`, `notes.txt`, `chart.png`, and
   `report.html` from Canvas, including the card on a user message. Verify each
   filename, content, and available export actions. Read text from its actual
   native view.
2. `artifacts.preview.a2` — Zoom the PDF and verify the actual page bounds
   change. Close the reader, confirm the same Space is visible, then reopen.
3. `artifacts.preview.a3` — Open controlled empty and unsupported files. Verify
   the status and original-byte export. Include a long Unicode filename and
   compare the resulting filename and bytes through an independent read.
4. `artifacts.preview.a4` — Resize the iPad reader where the layout permits it.
   Check the original file, useful viewport, and draft across sizes. Open a
   different Space and verify the old reader retires.
5. `artifacts.preview.a5` — Select a distinctive passage in a long text file,
   scroll, and resize. Check the selection and passage after reflow. Try a
   supported BOM encoding and an unsupported format separately.

## Save and share

1. `artifacts.save.a1` — From **Actions**, open **Save to Files**, cancel, and
   reopen. Verify the original preview and the reopened picker stay usable.
2. `artifacts.save.a2` — Save to an isolated Files folder. Reopen the file
   from Files and compare the actual bytes with the original. Save again
   under the same filename and verify **Keep Both** ends the save once.
3. `artifacts.save.a3` — With an unavailable provider fixture, check the
   error, empty destination, and usability of the preview after failure.
4. `artifacts.share.a1` — Open **Share**, verify the file offered, and cancel.
   Check that the reader and export actions are usable again.
5. `artifacts.share.a2` — Share once to an authorized local destination.
   Independently compare the delivered bytes after the preview is closed.

## Recover and retire

1. `artifacts.recovery.a1` — Open a missing, oversized, or offline file.
   Check the scoped error. Restore a readable file on the same host and
   use **Try Again**. Compare the resulting bytes.
2. `artifacts.recovery.a2` — Open a workspace-file reference and confirm
   the request uses the originating Space. Verify that ordinary web links
   and code examples are shown as text rather than file downloads.
3. `artifacts.retirement.a1` — During a file read, Quick Look, or a Save or
   Share sheet, open a fresh T3 pairing link. Verify address review closes
   the old presentation. Cancel without connecting.
4. `artifacts.retirement.a2` — Change Spaces during a delayed file read and
   release the old result. Confirm the old file does not open in the new
   Space. Separately background a completed preview and check that the
   reader and its actions work through same-Space recovery. Inspect the
   owned temporary file after all readers finish.
5. `artifacts.retirement.a3` — Repeat on iPhone and iPad with large text,
   Reduce Motion, and VoiceOver. Check accessible action names and focus
   when returning to the Space.

[ArtifactExportUITests](../../../../AppUITests/ArtifactExportUITests.swift)
exercises Canvas file cards and exporter lifetime. The
[independent export readback](../../../local-checks.md) checks Files-provider
bytes. See [rich replies](rich.md) for inline preview behavior.
