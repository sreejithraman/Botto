# Pairing and reconnection (`auth`)

Use an owned T3 host and the [pairing guide](../../../pairing-integration.md).
Keep pairing links and credentials out of evidence. Use a signed build for
secure-storage readback. These are draft checks.

- `auth.access` — Pair at the reviewed origin, open a Space, then relaunch.
  Expect the same environment and Space history. Retry a consumed or expired
  link separately and expect a request for a fresh link.
- `auth.interruption` — Cancel destination review, then interrupt a pairing
  attempt on a disposable host. Verify the incomplete attempt does not
  replace a working saved connection. Repeat with an origin that redirects
  and expect failure without asking the redirected host for credentials.
- `auth.recovery` — Interrupt the link to a paired host and reopen it.
  Verify history and the selected Space after reconnection. For a changed
  origin, generate and review a fresh link. Confirm the expected environment
  before using any saved identity.
