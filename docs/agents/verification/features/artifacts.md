# Preview, save, and share files (`artifacts`)

On iOS, choose **Explore the demo**, open the Spaces drawer, and select
**Canvas**. Open a file card for `report.pdf`, `notes.txt`, `chart.png`, or
`report.html`. For live proof use a paired disposable T3 workspace, open the
owning Space, and use a file with known original bytes. These checks are draft.

- `artifacts.preview` — Open an original file card and verify the filename
  and content. Try text selection, PDF zoom, and a message with multiple
  attachments. Close the reader and confirm it returns to the same Space.
- `artifacts.save` — From **Actions**, choose **Save to Files** and select
  an isolated local folder. Reopen the saved file from Files and compare
  the actual bytes with the original. Exercise cancellation and a deliberate
  duplicate filename separately.
- `artifacts.share` — Open **Share** from **Actions** and verify the original
  file's name and type in the share sheet. Cancel and check that the reader
  and export actions are usable again.
- `artifacts.recovery` — Open a missing file and a file above the download
  limit in the owned workspace. Check the scoped error and retry. After a file
  loads, background and foreground the app and check that it stays readable.
- `artifacts.retirement` — Change Spaces during a delayed preview and
  confirm the old request cannot publish into the next Space. Start an export
  and open a fresh T3 pairing link. Check the reviewed destination and verify
  the old exporter closes. Cancel review without connecting.

[ArtifactExportUITests](../../../../AppUITests/ArtifactExportUITests.swift)
exercises Canvas file cards and exporter lifetime. The
[independent export readback](../../../local-checks.md) checks Files-provider
bytes. See [rich replies](rich.md) for inline preview behavior.
