# Sign in and recover a connection (`auth`)

## User-facing description

Connect to an owned Hermes host with password or native browser sign-in, optional
Cloudflare Access headers, saved credentials, and deliberate recovery.
Sub-features: reviewed destination, native PKCE, refresh/reconnect, cancelled or
replaced sign-in, same-account reauthentication, and changed-host rejection.

## How to get to it

- `auth.e.connect`: welcome → **Connect your Hermes** → review address →
  **Username** / **Password** → **Connect**.
- `auth.e.browser`: reviewed destination → **Continue in browser**.
- `auth.e.access`: reviewed destination → **Advanced connection** →
  **Cloudflare Access client ID** and **Cloudflare Access client secret**.
- `auth.e.recover`: inbox → **Settings** → **Reconnect** or **Connection details**;
  offline inbox also exposes **Reconnect**. A normal saved-setup launch and
  foreground return are separate automatic reconnect entries.

## Interactive checks

Follow [shared secure setup](../index.md), [destination review](start.md), and
[host setup](../../../setup.md). Use an owned disposable account, signed build,
known install identity, and a harmless bot. **Draft; recipe sequences were not
run here.** Do not use fixture login injection to claim public sign-in proof.

Workflow `auth.password`:

1. `.a1` On the reviewed disposable origin, securely enter approved credentials
   and tap **Connect**. While pending, attempt another tap. Expect connecting
   feedback and one attempt, then a usable roster/canonical chat on the intended
   host. Repeat with a Webapp that hides `install_id` before sign-in: expect Botto
   to fetch and verify authenticated identity before opening the workspace.
   A missing or mismatched authenticated identity must reject the connection.
   Proof: redacted settled UI, host identity, and auth/connection counts.
2. `.a2` From signed-out isolated state, submit a designated invalid password.
   Expect an actionable error and no replacement of previously saved setup.
   Correct it and connect once. Proof: error, settled roster, fresh setup read.
3. `.a3` Background normally, terminate, relaunch without fixture arguments,
   then open the bot. Expect saved sign-in and durable history on the same host.
   Proof: fresh process/host readback, not the old screen.
4. `.a4` On small iPhone and iPad with accessibility XXXL, keyboard and actual
   Reduce Motion, expect reviewed origin, credentials, Advanced fields, errors,
   Connect/browser and Cancel reachable. VoiceOver must name secure fields and
   busy/error states in task order without disclosing values or trapping focus;
   browser return must restore useful native focus. Proof: redacted screenshots
   and actual spoken/focus-order record. Repeat on browser entry separately.

Workflow `auth.browser`:

1. `.a1` At a host advertising `native_pkce`, choose **Continue in browser**;
   complete approved Hermes login through the system authentication browser.
   Expect return through native callback, native exchange, and usable inbox.
   Include signed-out status without `install_id`; expect the authenticated
   status read to establish identity before returning the saved configuration.
   Proof: redacted browser/native milestones and authenticated host identity.
2. `.a2` Background/foreground and restart the app. Expect saved refresh
   credential reuse without a new password prompt. Inspect the new authenticated
   session and canonical chat through a fresh read; retain no tokens.
3. `.a3` Cancel browser login, then start a new attempt; expire an attempt using
   a disposable fixture. Expect cancellation or useful expiry error, then one
   usable new attempt. Old callbacks must not authenticate a replacement form.
   Proof: cancellation/error/retry capture and host attempt ownership.

Workflow `auth.access`:

1. `.a1` With an authorized Access application, enter both fields under
   **Advanced connection** and sign in. Expect native HTTP and WebSocket access,
   plus separate Hermes authentication. Use redacted server-side receipt of
   header names and authenticated socket readiness as proof, never field values.
2. `.a2` Try one missing field, expired service token, and denied Access policy
   on disposable fixtures. Expect actionable failure with no accidental connected
   state. Correct both fields through Connection details and retry deliberately.
   Proof: redacted errors and fresh native connection readback.
3. `.a3` Run browser sign-in with an interactive Access policy, then demonstrate
   service-token-only policy limitation. System browser cannot attach native
   service headers. Expect the former to return and the latter to remain blocked
   until policy is fixed; do not count native success as browser success.

Workflow `auth.interruption`:

1. `.a1` Hold a disposable password/native exchange pending, tap **Cancel**,
   then release the old response. Expect no late connection or saved credential
   overwrite. Proof: replacement/return snapshots, host attempt log, fresh
   durable setup read. A controlled public-flow delay fixture is required.
2. `.a2` Repeat by system-opening another Botto connection link and by leaving the
   scene. Expect only the current reviewed destination to own the presentation;
   release old success and old error separately. Neither may dismiss or connect
   the replacement. Proof: captures after release and independent setup read.

Workflow `auth.recovery`:

1. `.a1` Disconnect the run-owned host route, observe offline cached reading,
   restore it, and use each reconnect entry. Expect online roster/history without
   duplicate sends. Repeat foreground and normal-launch recovery. Proof: outage,
   recovery states and canonical host history.
2. `.a2` Reauthenticate the same account/origin/install/provider through
   Connection details. Expect a fresh connection identity while drafts/cache
   remain scoped to that verified account. Change account or install identity
   on an isolated host; expect no cross-account history or silent trust of the
   changed installation. Proof: before/after account/install identity and fresh
   cache/host readback. Use [local lifecycle](settings.md) for intentional forget.
3. `.a3` Induce refresh/storage failure only with owned fixtures. Expect honest
   offline/recovery UI and preserved prior credentials/cache, including late
   rotation after retirement. Retry after fixing the prerequisite. Proof: error
   and independent saved-setup read; no token values.

## Gotchas

Source: [ConnectionView](../../../../App/Views/ConnectionView.swift),
[BrowserSignIn](../../../../App/Pairing/BrowserSignIn.swift),
[AppStore](../../../../App/State/AppStore.swift),
[vault](../../../../App/State/ConnectionVault.swift),
[header policy](../../../../Sources/BottoCore/Networking/HermesHeaderPolicy.swift).
Core header and native state tests support filtering, rotation, cancellation,
and cache preservation. They do not establish production Access/OIDC behavior.
Those paths remain blocked until account, policy, credential access, and secure
delivery are established. Browser cancellation cannot revoke an already issued
server session; it must fence late local effects. See
[verification](../../../verification.md) for recorded checks and limits.
