# Settings and local data (`settings`)

Run on an owned iPhone or simulator with a disposable pairing. See the
[shared setup](../index.md#shared-setup-and-readiness). These checks are draft.

- `settings.appearance` — Change appearance and conversation preferences.
  Relaunch and check the choices were saved.
- `settings.developer` — Locate the developer tools in Debug or Internal
  builds and verify the public Release scheme excludes them.
- `settings.about` — Open About and check app information and license notices.

## Forget the paired workspace

Open **Settings → Forget this connection**. For an older saved setup, open
**Forget saved setup** from welcome. Use run-owned drafts, cache markers, and
known Mac Space history to verify the effect.

1. `settings.forget.a1` — Open the confirmation and cancel. On fresh relaunch,
   verify the original pairing, draft, cached history, and pins are still present.
2. `settings.forget.a2` — Confirm **Forget on this device**. Verify welcome and
   the absence of the saved pairing and its owned cache markers after relaunch.
   Record presence or absence only for Keychain data.
3. `settings.forget.a3` — Refetch the Mac's Space history independently. Pair
   again using a fresh link. Verify the Mac's Spaces and history are still
   available and the old local draft and pin overrides are cleared. Release a
   held old file read and verify it cannot update the new workspace.

## Recover local storage

1. `settings.storage-recovery.a1` — Use a secure-store fixture to make the saved
   setup unreadable. Verify welcome offers **Retry saved setup** and
   **Forget saved setup**, with the stored pairing and its caches preserved.
   Restore access and retry. Verify the original workspace opens.
2. `settings.storage-recovery.a2` — Inject a failed save, removal, or readback
   during replacement or Forget. Verify failure feedback and preservation
   of the mounted workspace while the operation is unconfirmed. After an
   unsuccessful removal, check the original stored pairing. If removal
   succeeds and readback fails, inspect saved-state presence independently
   before retrying. Separately force a history save failure while entering
   Demo or backgrounding. Verify the warning and the original pairing,
   selection, and draft. Restore storage, retry, and read the latest draft
   through a fresh store.
3. `settings.storage-recovery.a3` — Place old run-owned cache markers beside an
   unrelated file, directory, and symlink. Commit replacement or Forget.
   Compare fresh directory listings to verify cleanup is limited to
   unreachable owned connection caches.

[History transition tests](../../../../AppTests/AppStoreHistoryTests.swift)
and [T3 workspace tests](../../../../AppTests/T3WorkspaceTests.swift) cover
injected failures and launch recovery. Use a signed physical iPhone for
actual Keychain lock and unlock proof.
