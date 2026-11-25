# Verification

## T3 workspace checks

Use the [verification map](agents/verification/index.md) for current setup and
acceptance. The T3-only code has separate proof for the Swift package, hosted
iOS workspace and Demo, and BottoMac. Run these command checks on the revision
being reviewed.

- `swift test --filter T3` and `swift test --no-parallel`
- iOS `build-for-testing` and hosted T3 workspace, Demo, and launch tests on an
  owned simulator
- BottoMac tests on macOS

Signed physical iPhone pairing over LAN, Tailscale, or a public HTTPS tunnel
and background APNs delivery require their own evidence.

## Open questions

- `ConnectionVault` reads, updates and deletes without an access-group filter.
  Apple documents that [search, update, and delete then cover every entitled group](https://developer.apple.com/documentation/security/ksecattraccessgroup).
  The entitlements put the private group first, which scopes new items but not
  those other operations. No collision or credential exposure has been seen.
  Settling it needs a signed, disposable item with the same service and account
  in both the private and the shared group; unsigned builds and injected storage
  cannot show it.

Results for the earlier Hermes-based app are in Git history (this file before
the T3-only cleanup).
