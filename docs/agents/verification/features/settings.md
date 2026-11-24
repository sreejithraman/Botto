# Settings and local data (`settings`)

Run on an owned iPhone or simulator with a disposable pairing. See the
[shared setup](../index.md#shared-setup-and-readiness). These checks are draft.

- `settings.appearance` — Change appearance and conversation preferences.
  Relaunch and check the choices were saved.
- `settings.developer` — Locate the developer tools in Debug or Internal
  builds and verify the public Release scheme excludes them.
- `settings.about` — Open About and check app information and license notices.
- `settings.forget` — Exercise Forget using a disposable saved pairing.
  Verify the old connection is no longer active and reconnect with a fresh link.
- `settings.storage-recovery` — Check a failed credential read in a supported
  test fixture. Verify it does not start work in an unintended connection.
