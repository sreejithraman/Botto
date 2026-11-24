# Welcome and first run (`start`)

Use [shared setup](../index.md#shared-setup-and-readiness) and an owned fresh
profile. Draft until each selected path runs on its target.

- `start.first-run` — Open iOS with no pairing. Expect **Pair with your Mac**
  and **Explore the demo**. Relaunch and expect the same choices. With a saved
  setup whose vault is temporarily locked, restore access before retrying.
  Check that pairing recovery offers **Forget this connection** for older setup.
- `start.demo` — Explore the demo. Open the Main Space and another sample
  Space in the drawer. Send a sample message and verify only demo state changes.
- `start.setup` — On Mac, configure a provider and finish Botto first run.
  Choose a name and face. Verify the Main Space opens after first run, with
  the chosen name. Reopen with the saved pairing and check first run is skipped.
- `start.address` — Paste a fresh Mac pairing link. Check the destination
  review. Local HTTP requires explicit consent. Cancel without connecting.
- `start.qr` — Scan a fresh Mac QR on a signed physical iPhone. Compare the
  reviewed origin to the selected Mac route, then pair and open a Space.
- `start.external` — Open a fresh `t3code://pair` link from another app.
  Expect the same review before connection. Try an invalid link without
  leaving the current workspace.

[Setup](../../../setup.md) describes supported routes and signing.
