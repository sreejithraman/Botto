# Welcome and first run (`start`)

Use [shared setup](../index.md#shared-setup-and-readiness) and an owned fresh
profile. Draft until each selected path runs on its target.

- `start.first-run` — Open iOS with no pairing. Expect **Pair with your Mac**
  and **Explore the demo**. Relaunch and expect the same choices. With a saved
  setup whose vault is temporarily locked, restore access before retrying.
  Check that pairing recovery offers **Forget saved setup** for the older setup.
- `start.demo` — Explore the demo. Open the Main Space and another sample
  Space in the drawer. Send a sample message and verify only demo state changes.
- `start.pair.a1` — Paste a fresh Mac pairing link and check the origin
  shown before connecting. Enable HTTP explicitly for a trusted local route.
- `start.pair.a2` — Pair an owned workspace that needs first-run setup.
  Choose a name and face and verify the Main Space opens with the chosen
  name. Relaunch to check first run is skipped after setup has been saved.
- `start.pair.a3` — Open BottoMac with no configured model provider.
  Name the bot and choose its face first. Then follow the provider guide
  and verify the new companion and Main Space.
- `start.address` — Repeat address review with a fresh link and an invalid
  input. Verify a canceled review leaves the current workspace available.
- `start.qr` — Scan a fresh Mac QR on a signed physical iPhone. Compare the
  reviewed origin to the selected Mac route, then pair and open a Space.
- `start.external` — Open a fresh `t3code://pair` link from another app.
  Expect the same review before connection. Try an invalid link without
  leaving the current workspace.

[Setup](../../../setup.md) describes supported routes and signing.
