# Encrypted push notifications

Botto can send optional encrypted notifications from a paired Mac to iPhone.
Space messages and request responses still travel directly over the existing T3
connection. Botto's notification relay and Apple's APNs carry the alerts. The
relay operator and Apple signing team are the remaining deployment decision
(W6-D2).

## T3 Spaces

BottoMac subscribes to the stock T3 Orchestrator v2 shell and Space streams
through its existing loopback connection. Stock T3 Agent Awareness publishes
through the T3 Cloud relay, and routine webhooks trigger work on the server.
Botto uses the local streams for outbound alerts, so a T3 Cloud account and
changes to upstream T3 are unnecessary.

- The Mac watches live Spaces in its Botto project even when the window is
  closed. The engine must be awake. A terminal `run.updated` record with
  status `completed` is the v2 completion signal, including a routine run.
  Supported pending `runtime-request.updated` records alert for approvals
  and questions. Resolving, cancelling, or expiring a request cancels queued
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

### Configure a Mac and iPhone

1. An operator provisions the existing [relay](../Push/relay/README.md), an
   authorized Apple APNs key and the bundle ID and environment allowlist. The
   iOS app and extension need matching signing and shared push Keychain
   configuration. Debug uses APNs sandbox. Internal and Release use APNs
   production.
2. Set the HTTPS relay origin on the Mac and relaunch Botto. The bridge keeps
   its registrations bound to that relay origin.

   ```sh
   defaults write com.sree.botto.mac T3PushRelayURL -string 'https://your-relay.example'
   ```

3. Wake Botto and pair your phone with this Mac using the existing T3 pairing
   flow. On the Mac, open Settings and copy a LAN or Tailscale notification
   code under **Phone notifications**. Allow TCP port 3775 on the chosen
   private route. An HTTP-only tunnel can serve chat but cannot forward the
   registration connection. Enrollment and token updates require the phone to
   reach the Mac directly.
4. In Botto on the iPhone, open **Settings → Notifications**, turn on
   **Space notifications**, paste the code, and allow iOS notifications.
   The toggle reflects relay confirmation. Disabling immediately retires the
   local preview and tap authority. If the Mac is unreachable, Botto saves
   pending removal and retries when the app returns and can reach the Mac.
   APNs messages submitted before removal can still appear as generic alerts.

### Verification

The Swift tests drive the T3 observer with WebSocket frames, including a
completion from a Space that the user has not opened. The BottoMac tests drive
registration over loopback TCP against a relay fixture and decrypt the actual
relay submission with the phone's preview key. The iOS tests cover matching
and missing Space IDs, tampered envelopes, cold launch, and foreground visibility. This is
automated proof of the local and encrypted contracts. Physical background and
terminated delivery through Apple remains unverified.

For physical-device proof in W5 or the signing follow-up, use a signed build
and the matching relay allowlist and APNs credentials. Pair a physical iPhone,
enable notifications, background or terminate Botto, then complete a Space
run (including a routine) and trigger an approval and question. Check the
delivered banner and tap each alert into its originating Space. Remove the
pairing and check that later events stop producing alerts.

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
