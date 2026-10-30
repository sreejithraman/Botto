# Encrypted push notifications

Optional push uses a Hermes plugin, Cloudflare relay, APNs, and Botto's
notification extension. Chats and decisions still use direct authenticated
Hermes connections. The design is recorded in
[ADR 0009](adr/0009-optional-push-delivery.md). This feature is experimental;
signed physical-device background delivery remains unverified.

## Prerequisites and setup

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

## Privacy and recovery

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

## Evidence

The [verification record](verification.md) owns observed outcomes and limits.
Native fixtures, independent encrypted fixtures, workerd tests, and the patched
real-host smoke prove different segments. None alone establishes signed
physical-device background delivery.
