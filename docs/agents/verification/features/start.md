# Welcome, demo, and destination review (`start`)

## User-facing description

Start a separate sample workspace or review the Hermes origin before sharing
credentials. Sub-features: first launch, demo enter/leave, typed/pasted address,
copy/share setup instructions, trusted local HTTP, live QR, QR image, manual scanner fallback, and external link
review that preserves the current workspace.

## How to get to it

- `start.e.welcome`: normal empty-data launch → **Connect your Hermes** or
  **Explore the demo**.
- `start.e.address`: Connect → **Hermes server address or connection code** →
  **Review destination**. The form also has Paste.
- `start.e.setup`: Connect → **Copy prompt**, **Share**, or **Preview prompt**.
  The prompt opens in a bottom sheet; a downward swipe closes it. Copying is optional.
- `start.e.scanner`: Connect → **Scan connection QR**. Scanner paths are camera,
  **Import QR Image**, or **HTTPS address or connection code** → **Review Address**.
  Dismiss the scanner sheet with the system dismissal gesture; it has no named
  Cancel toolbar button at this baseline.
- `start.e.external`: open
  `botto://hermes/connect?url=https%3A%2F%2Freplacement.example` through the system
  into the existing scene. `hermes://connect?url=…` is accepted inside Botto's
  paste/scanner flow, not registered as a system handoff scheme.

## Interactive checks

Use [shared setup](../index.md), a run-owned empty profile for first run, and
nonsecret payloads from [setup](../../../setup.md). No host is required until
sign-in. **Draft; all complete sequences below are untested in this map run.**

Workflow `start.first-run`:

1. `.a1` Launch normally from independently confirmed empty container/Keychain.
   Expect welcome, both primary actions reachable, and no saved-setup error.
   Proof: isolation record, screenshot, and semantic snapshot.
2. `.a2` Repeat on small iPhone and iPad at accessibility XXXL; scroll the
   introduction. Expect Connect and demo actions reachable above safe areas.
   VoiceOver must encounter the greeting, tagline, and clearly named actions without a trap.
   Proof: screenshots and spoken/focus-order record on each target.

Workflow `start.demo`:

1. `.a1` Tap **Explore the demo** once, then attempt a repeat while opening.
   Expect one labeled sample roster with Milo and Canvas; no network connection
   or server mutation. Proof: roster/banner capture and run-owned host log where
   a host is present. The DEBUG `--demo` shortcut cannot pass this entry check.
2. `.a2` Open Canvas, return to inbox → **Settings** → **Leave demo**. Expect
   welcome or the previously saved connection; demo content must not replace
   that connection's cache. Fresh normal relaunch must load the prior durable
   setup, if seeded. Proof: before/after captures and fresh-launch readback.

Workflow `start.address` (repeat from equivalent state through typed and Paste):

1. `.a1` Enter `https://hermes.example.com`, plain origin with trailing slash,
   then each supported `hermes://connect` and `botto://hermes/connect` payload.
   Tap **Review destination**. Expect normalized scheme, hostname, and explicit
   port where supplied under **Reviewed server**, with credentials still
   unsent. Tap **Change address** to return. Proof: each reviewed destination
   snapshot and no auth attempt in a disposable host log.
2. `.a2` Try a URL with `/api`, query, fragment, embedded credentials, malformed
   port, or extra connection-code parameters. Expect a local actionable error
   and no authentication. Proof: input category and error capture, no secrets.
3. `.a3` Try the disposable loopback HTTP origin. Expect rejection until
   **Trusted local network** → **Allow an HTTP connection** is enabled, then
   **Trusted HTTP connection** on review. Public HTTP must still be rejected.
   Proof: both errors and accepted local destination; do not submit credentials
   to example domains.

Workflow `start.setup`:

1. `.a1` Open Connect from welcome. Tap **Copy prompt**, repeat once, and
   independently read the Simulator clipboard. Expect the complete bundled
   prompt, visible copy confirmation, and a copy announcement for VoiceOver.
   Copying must keep the address form and current connection unchanged. Proof:
   semantic snapshot, clipboard comparison with
   [the versioned prompt](../../../../App/Pairing/HermesSetupPrompt.swift), and
   spoken announcement when VoiceOver is available.
2. `.a2` Open **Share**. Expect the system share sheet containing
   the same text. Dismiss without choosing a recipient; expect the same form
   and typed address. Open **Preview prompt**, expand the sheet and scroll through it, then swipe down
   to close it. Reopen and dismiss again; the typed address must remain. Expect readable, selectable complete instructions. Proof:
   share-sheet, preview, and retained-input snapshots. Do not send to a real
   recipient during verification.
3. `.a3` Without copying, enter an HTTPS origin and review it; return with
   **Change address**. Open the scanner and dismiss it. System-open a returned
   `botto://hermes/connect?url=…` link, then review. Expect all paths to remain
   usable, with sign-in pending and no automatic connection. Proof: address,
   scanner, and external-link review snapshots. Repeat Copy/Share and preview
   at accessibility XXXL on small iPhone and iPad; controls must remain reachable
   without clipped labels or horizontal scrolling.

The prompt's host-side execution is a separate integration check: use an owned
Hermes host, inspect preservation of its identity/config and routes, and finish
phone sign-in and a bot reply. Prompt copying alone cannot pass that check.

Workflow `start.qr` (camera, image, and manual entries are distinct obligations):

1. `.a1` Scan a single supported address QR on capable hardware. Expect exactly
   one reviewed destination and no automatic login. Deny camera permission;
   expect fallback guidance and **Open Camera Settings** where denied. Proof:
   permission state, camera/fallback captures, destination snapshot.
2. `.a2` Import a single-code image; expect review. Import no-code, multiple-code,
   unreadable, and over-20-MiB image fixtures; expect useful errors without a
   connection. Record actual fixture bytes; use an image larger than the limit,
   not merely large dimensions. Proof: each error and input fixture manifest.
3. `.a3` With camera unavailable, enter/paste a code in the scanner and choose
   **Review Address**; expect the same destination. Dismiss scanner while an
   image read is pending; late delivery must not replace the user's later
   destination. Proof: before/after semantic snapshots and bounded wait.

Workflow `start.external`:

1. `.a1` From an existing conversation, separately from Settings and New bot,
   system-open the nonsecret Botto link above without relaunching. Expect one
   **Connect Hermes** sheet; tap **Review destination** and inspect the target.
   Existing connection must remain unchanged until explicit sign-in succeeds.
   Proof: original identity, replacement form, and disposable host auth log.
2. `.a2` Tap **Cancel**; expect the prior workspace/conversation and no saved
   replacement. Relaunch normally and independently read the prior setup.
   Repeat invalid-link input; expect an error, not silent destination change.
   Proof: cancel/relaunch snapshots and durable identity readback.

## Gotchas

Source: [OnboardingView](../../../../App/Views/OnboardingView.swift),
[ConnectionView](../../../../App/Views/ConnectionView.swift),
[setup instructions](../../../../App/Views/HermesSetupSection.swift),
[scanner](../../../../App/Pairing/PairingScannerView.swift),
[BottoApp](../../../../App/BottoApp.swift),
[PairingAddress](../../../../Sources/BottoCore/Pairing/PairingAddress.swift).
[Pairing tests](../../../../Tests/BottoCoreTests/PairingTests.swift) support parser
rules, not camera or Photos acquisition. Physical camera assertions are blocked
without capable hardware. Demo and unit tests do not establish first-run
isolation or scanner late-completion behavior. Restore only this run's changed
permission/settings state. See [verification](../../../verification.md) for
recorded checks and limits.
