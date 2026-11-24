# Encrypted push notifications

Botto can send optional encrypted notifications from a paired Mac to iPhone.
Space messages and request responses still travel directly over the existing T3
connection. Botto's notification relay and Apple's APNs carry the alerts. The Mac owner
operates the relay using their own authorized Apple signing team (W6-D2).

## T3 Spaces

BottoMac subscribes to the stock T3 Orchestrator v2 shell and Space streams
through its existing loopback connection. Stock T3 Agent Awareness publishes
through the T3 Cloud relay, and routine webhooks trigger work on the server.
Botto uses the local streams for outbound alerts, so a T3 Cloud account and
changes to upstream T3 are unnecessary.

- The Mac watches live Spaces in its Botto project even when the window is
  closed. The engine must be awake. The v2 Space shell reports completion,
  including a routine run, once no background work holds it open. Stopped
  runs and monitor progress wakes while the monitor is active stay quiet.
  Supported pending requests alert for approvals and questions. Child
  questions meant for the coordinating agent stay quiet. Resolving, cancelling, or expiring a request cancels queued
  relay delivery. Work that completed before observation started stays quiet.
  Recent snapshots can recover events across a socket reconnect. Event and
  request IDs stay stable across duplicates. Mac-to-relay submission is
  best-effort, and the relay handles provider retries after admission.
- The Mac issues a five-minute, device-specific notification code. The iPhone
  checks it against its saved T3 environment and project. The code authenticates
  and encrypts registration over LAN or Tailscale TCP. An APNs token, its
  environment and bundle ID go to the Mac, which registers the device using
  the existing [Botto relay protocol](../Push/PROTOCOL.md). Each device has a
  monotonic registration generation. The Mac keeps the relay credential and
  registration state in an owner-only file under `~/.botto/t3-push/`.
- The Mac encrypts the Space title, a short event label, and the exact project
  and Space IDs separately for each device. Only the delivery metadata,
  opaque IDs and ciphertext go to the relay. The iOS service extension uses
  the existing shared Keychain and AES-GCM envelope to render the preview.
  Chat text, tool arguments and T3 credentials stay off the relay.
- iOS suppresses foreground banners for the Space currently on screen.
  A tap decrypts the original envelope and checks the current T3 pairing
  before opening the exact Space from the canonical directory. Opening the
  Space needs the original Mac to be reachable. The tap never answers a
  request or opens a different Space if its destination was deleted.

### Owner-operated setup

Have a Cloudflare account with Workers access, an Apple Developer team that can
sign Botto for the test iPhone, and a Mac and iPhone that can reach each
other over LAN or Tailscale. Choose the app bundle ID, Apple signing team, and APNs environment
before configuring the relay. The APNs provider inputs are the Team ID, Key ID,
and private `.p8` key authorized for that bundle ID and environment.

1. In your Apple Developer account, use explicit App IDs for Botto and the
   embedded BottoNotifications extension. Enable Push Notifications on the app
   ID. The default IDs are `com.sree.botto` and `com.sree.botto.notifications`.
   If your team uses its own IDs, set `BOTTO_APP_BUNDLE_IDENTIFIER` in
   [project.yml](../project.yml) and regenerate the Xcode project. Select the
   same team for both targets and refresh their provisioning profiles as
   needed. Verify the signed app and extension have the same expanded push
   Keychain group, `$(AppIdentifierPrefix)$(BOTTO_APP_BUNDLE_IDENTIFIER).push`.
   Keep the app's private group first in its entitlement. [Apple capability
   setup](https://developer.apple.com/help/account/identifiers/enable-app-capabilities/)
2. Choose the build and relay environment. A signed Debug build uses sandbox
   APNs with the `development` entitlement. Internal and Release use production
   APNs with the `production` entitlement. Use an APNs key authorized for
   the selected environment and app bundle ID. The relay has one APNs key
   configuration per Worker. If your keys are environment-specific, use a
   separately configured Worker for each environment. [Apple APNs
   authentication](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns)
3. Follow the [relay deployment guide](../Push/relay/README.md) in
   `Push/relay`. Choose a Worker name and rate-limit namespace ID. Set
   `ALLOWED_BUNDLE_IDS` to the app's bundle ID and `ALLOWED_ENVIRONMENTS` to
   the environment your key covers. Use Wrangler's secret input for
   `APNS_TEAM_ID`, `APNS_KEY_ID`, and `APNS_PRIVATE_KEY`. Keep the key in
   your private credential storage and leave request logging disabled.
   Record the deployed HTTPS origin and check `GET /health` for Worker
   liveness.
4. Set that HTTPS origin on the Mac and relaunch BottoMac.

   ```sh
   defaults write com.sree.botto.mac T3PushRelayURL -string 'https://your-relay.example'
   ```

   If you chose a custom app bundle ID, use that ID with `.mac` appended
   as the defaults domain.

   A Mac bridge keeps its registrations bound to one relay origin. For a
   planned move to another Worker, turn off notifications on the paired
   phones and confirm removal while the previous relay is reachable. Quit
   BottoMac and archive its owner-only `~/.botto/t3-push/` state before
   changing the origin. Relaunch and enroll again.
5. Wake Botto and install the signed iOS build. Pair the phone with the Mac
   in Botto. In Mac Settings, copy a LAN or Tailscale code under **Phone
   notifications**. Allow TCP port 3775 on that private route. Use that
   direct route for enrollment and token updates when chat uses an HTTP-only
   tunnel.
6. On the iPhone, open **Settings → Notifications**, turn on **Space
   notifications**, paste the code, and allow iOS notifications. The toggle
   reflects relay confirmation. Turning it off retires local preview and tap
   access. When the Mac is unreachable, Botto saves the pending removal and
   retries on return. Alerts already submitted to Apple can still appear
   with generic text. If the Mac's address changes, copy a fresh code on
   the same Mac and use **Update Mac Address** on the iPhone to recover the
   existing pairing or finish a pending removal. To turn off pairings from a
   previous Mac, use **Turn Off Notifications from Other Macs** in Settings.
   Forgetting the connection retires local notification access for all
   saved Mac pairings.

### W5 physical acceptance

Use a signed build on a physical iPhone and record the build, APNs environment,
and test results with W5. Use harmless test content in two distinct Spaces
so a tap that opens the wrong Space is visible.

1. Confirm enrollment on the chosen private route. Leave the Mac engine awake
   and keep the Mac reachable from the phone for taps.
2. With Botto backgrounded, complete a run in a Space different from the one
   last shown. Observe the actual iPhone alert and tap it into the exact Space.
   Repeat with a scheduled routine and a terminated app.
3. Trigger a pending approval and a pending question while Botto is in the
   background. Observe the alerts, tap each into its own Space, and confirm
   Botto shows the current request without answering it. With that Space
   visible, confirm another alert for it stays quiet.
4. Turn off notifications on the test device and confirm removal. Put
   Botto in the background, trigger a new event, and confirm the device
   gets no alert. Record observed delivery,
   decrypted preview, exact routing, and removal separately.

Automated proof covers the local WebSocket observer, encrypted loopback
registration and relay payloads, and exact iOS routing on cold and warm
entry. Physical background and terminated APNs delivery remain unverified.

## Hermes

Hermes uses its own plugin and the same encrypted APNs contract. The design is
recorded in [ADR 0009](adr/0009-optional-push-delivery.md). Signed physical
delivery for Hermes also remains unverified.

### Hermes prerequisites and setup

1. Use the supported native observer in the [upstream contribution](../Push/upstream/README.md).
   This is **not a released Hermes capability**. Until it lands upstream, use
   the exact documented development base and patch in an owned test runtime.
   A version string alone does not establish support; the plugin checks the
   running observer contract.
2. Follow the [relay deployment guide](../Push/relay/README.md). Provision the
   Worker, Durable Objects, alarms, app/environment allowlist, and APNs secrets.
   The repository contains no production relay endpoint or Apple credentials.
3. Follow the [plugin guide](../Push/plugin/README.md) for each producing Hermes
   profile. Normal lifecycle discovery is profile scoped: installing only for
   the default profile does not cover other bots or future profiles. Configure
   the real HTTPS relay origin on the host.
4. Configure an Apple signing team authorized for Push Notifications, app and
   extension bundle IDs, provisioning, and the shared Keychain group. Project
   settings derive that group from the signing prefix and app bundle ID.
   Debug uses sandbox; Release uses production. Regenerate the project after
   changing its source configuration.
   Keep the app-private Keychain group first in the app entitlement and the
   explicit push group second. The extension receives only the push group.
   Apple uses the first group for unqualified credential additions; see
   [Keychain access groups](https://developer.apple.com/documentation/security/ksecattraccessgroup).
5. For automatic installation, publish an authorized plugin source and immutable
   commit, then set `BOTTO_PUSH_PLUGIN_SOURCE` and `BOTTO_PUSH_PLUGIN_REF` in the app
   build. An unconfigured build offers the owner-operated manual path. Install
   or update only after confirmation; restart deliberately when running work
   can be interrupted.
   Automatic setup requires the proposed explicit-profile installer contract.
   Botto sends the selected profile in the install body and verifies the returned
   profile. Older hosts use manual setup; Botto never retries the unscoped installer.
6. Open Settings → Notifications, select the bot, check host support, and enable
   notifications. Respond to the contextual iOS permission prompt. Repeat for
   other bots and set their event/preview preferences.
7. Run the [acceptance recipe](agents/verification/features/notifications.md)
   using a signed physical device. A submitted test does not establish a banner.

Botto uses the [MIT License](../LICENSE). The plugin and relay also retain
their directory-level MIT notices. Forks use their own Cloudflare account and
authorized Apple identity. The [protocol](../Push/PROTOCOL.md) keeps callers
independent of Workers bindings; another backend still needs adapters and
behavior verification.

### Hermes privacy and recovery

The host encrypts a bounded bot name and excerpt separately for each device.
The extension decrypts locally using device-only Keychain storage; it does not
fetch text from Hermes at delivery time. With previews disabled, ciphertext
still carries routing but has empty preview text. iOS Show Previews controls
system visibility. Missing keys, failed authentication, inaccessible Keychain,
or extension expiry leave a safe generic alert.

The relay handles tokens, opaque IDs, event category, timing, expiry,
preferences, and ciphertext. It holds neither decryption keys nor Hermes
credentials. Encryption does not hide delivery metadata or conceal decrypted
presentation from the local operating system.

Actual visible chats renew bounded suppression leases for that device. Other
devices keep their own policy. Alerts expire; resolved requests cancel queued
delivery. Every tap reads current canonical host state. An already-submitted
Apple notification may remain stale. Opening the chat still requires LAN/VPN/
tunnel access and authentication; an offline host cannot produce new events.

Removal retires the push target and excludes its keys from future previews
without re-pairing other devices. Local keys are removed before remote
confirmation; an unreachable relay leaves explicit nonsecret pending-removal
state. Secure-storage failure prevents claiming local removal. Removal cannot
erase old content or revoke Hermes owner credentials. A lost device retaining
valid owner access could intentionally enroll again; revoke that host grant
when handling a compromised device.

If Apple or the relay retires a target, Botto stops showing that pairing as
enabled. Turn it off for this device, then enable it again to establish a fresh
device ID and key. A changed Apple token can recover a still-authorized pairing
automatically; a device removed by its owner stays removed. Other devices keep
their pairings.

### Hermes evidence

The [verification record](verification.md) owns observed outcomes and limits.
Native fixtures, independent encrypted fixtures, workerd tests, and the patched
real-host smoke prove different segments. None alone establishes signed
physical-device background delivery.
