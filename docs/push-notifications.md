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
  alerts cover supported approvals. Secret and link cards open in T3 Code. Resolving, cancelling, or expiring a request cancels queued
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
