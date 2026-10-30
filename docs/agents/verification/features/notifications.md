# Encrypted push notifications (`notifications`)

Full product acceptance is **draft** until a signed physical-device run proves
the complete path. Read [shared setup](../index.md#shared-setup-and-readiness),
[push setup](../../../push-notifications.md), and the verification record.

## Entry points

- `notifications.e.settings`: Settings → Notifications; choose the bot.
- `notifications.e.setup`: Check host support, configured Install plugin or
  owner manual fallback, Enable notifications, and system permission.
- `notifications.e.preferences`: event and encrypted-preview preferences.
- `notifications.e.devices`: Paired devices → Remove device confirmation.
- `notifications.e.test`: Send test notification with an available chat target.
- `notifications.e.tap`: banner/Notification Center, including cold start.

## Workflows

`notifications.setup`:

1. `.a1` Check a host without the plugin/observer. Expect actionable unsupported
   feedback and usable ordinary chat.
2. `.a2` Confirm/cancel a configured immutable-source installation; exercise
   failures and loaded-version/restart-required readback. Expect no moving-ref
   installation or automatic interruption. Verify the manual path separately.
3. `.a3` Deny/recover iOS permission, then enroll successfully. Independently
   read host/relay registration metadata without printing tokens or keys.
   Hold a pre-enrollment status response until enrollment succeeds; expect no
   false retirement and continued token reconciliation.
4. `.a4` Repeat for a named profile. Expect separate keys and actual event
   production; uninstalled/new profiles must not inherit readiness.

`notifications.delivery`:

1. `.a1` On a signed phone with Botto backgrounded and then terminated, produce
   a reply, actual waiting approval/question, and failed turn. Observe host
   production, relay processing, APNs acceptance, decryption, and banner
   separately. Repeat sandbox and TestFlight/production with matching identities.
2. `.a2` Run quiet automation, subagent completion, interrupted work, and a smart
   approval that never waits. Expect no false completion/waiting alerts.
3. `.a3` Exercise several turns and two devices. Expect independent preferences,
   correct grouping, and no repeated alert from ordinary event replay.

`notifications.previews`:

1. `.a1` Inspect redacted provider/relay evidence: ciphertext and permitted
   metadata only, no plaintext, host credentials, or decryption keys. Confirm
   local decryption requires no host fetch.
2. `.a2` Toggle iOS Show Previews and Botto previews. Expect system privacy honored,
   generic text when disabled, and retained encrypted tap routing.
3. `.a3` Exercise lock/unlock, first unlock after reboot, tampered ciphertext,
   missing keys, and extension expiry. Expect safe fallback and no invented route.
4. `.a4` On a signed build, save a fresh connection and pairing. Independently
   inspect their access-group attributes without printing secret values. Expect
   private app credentials, explicit shared pairing storage, and an extension
   that can read the pairing but cannot query the connection credential.

`notifications.routing`:

1. `.a1` Tap distinct bot/chat alerts from foreground and cold start. Expect the
   saved installation, exact profile, and verified canonical chat; preserve drafts
   and perform no reply/approval automatically.
   Deliver a tap while the initial roster is loading; expect navigation after
   authoritative publication rather than treating temporary absence as invalid.
   Hold push status for the tapped profile, including while Push Settings selects
   another profile. Expect no navigation before authoritative pairing status.
   Repeat with remote removal and a failed read; removal rejects the destination,
   while a failed read retains the intent for ordinary recovery beyond delivery expiry.
2. `.a2` Rotate compression and tap an older alert. Expect fresh directory
   resolution and rejection of ambiguous aliases/retired workspace results.
   Return a new canonical root with host-proven lineage to the directory root.
   Expect the displayed bot and workspace to commit the accepted attachment
   together. An unrelated root must preserve the previous chat instead.
3. `.a3` Lose host access, tap, then reconnect. Expect explicit recovery and the
   retained destination. A removed/different pairing cannot establish a server.
   Tap before delivery expiry and recover after expiry; expect the authenticated
   intent to survive. Expired-at-tap, removed-pairing, and replacement-host
   controls must not navigate.
   Fail the roster/directory read, then recover through ordinary refresh or
   automatic socket reconnection. Expect one successful navigation without a
   second tap or explicit connection setup. A newer picker choice cancels the
   retained intent; backgrounding must not initiate another connection.
   Remove the pairing during held directory and chat-open reads without a socket
   transition. Expect no post-removal selection/open or late snapshot/action-grant
   publication. Repeat with authoritative remote removal and an unchanged-pairing
   success control; replay late stream data from the rejected open too.
   Repeat across two profiles. Expect a rejected attempt to preserve the displayed
   bot and prior chat/preference; a successful attempt selects the destination bot.
   A newer user choice wins, and a deliberate ordinary chat open still works.
   Reject a still-authorized cross-profile directory/open on the host while the
   socket stays online. Expect the prior bot/chat/preference and editable cached
   draft, no restored old action grant, and later successful notification recovery.
4. `.a4` Resolve a request elsewhere before tapping. Expect current state without
   stale enabled decisions or automatic mutation replay.

`notifications.visibility`:

1. `.a1` Keep the chat visible longer than a lease interval. Expect renewal and
   suppression only there; cover/switch/background it and verify clear/expiry.
2. `.a2` Hold renewal, clear visibility, then release stale work. Expect serialized
   updates and revision fences; other devices remain independent.

`notifications.removal`:

1. `.a1` Remove another owned device and this device. Expect independent keys
   and no newly initiated send after acknowledged remote revocation.
2. `.a2` Race removal with delayed enrollment, queued/in-flight sends, retries,
   and restart. Expect durable tombstones and explicit ambiguous outcomes;
   already-submitted Apple messages may still arrive.
   Repeat an enrollment whose acknowledgment was lost after receipt cleanup.
   Expect no revival of the removed device or encryption for its former key.
3. `.a3` Disable/forget offline. Independently verify keys removed and only
   nonsecret pending removal retained. Reconnect to confirm cleanup. Fail secure
   storage separately; expect no false local removal or forget success.
   Hold enable's permission/token work during Forget and release it after local
   removal; expect no new key, pairing, or automatic enrollment after reconnect.
4. `.a4` Replace token/device and enroll deliberately. Expect app/environment
   isolation and no revival of old generations. Push removal must not claim to
   revoke full Hermes credentials.
5. `.a5` Remove a device remotely, refresh its status, relaunch, and resume with
   unchanged and changed tokens. Expect the owner-removed pairing to stay off.
   Separately retire only its provider target: an unchanged token stays retired;
   a verified new token may recover the still-authorized pairing.

`notifications.recovery`:

1. `.a1` Replay/reorder events, resolve requests before/after queuing, and return
   after expiry. Expect deduplication, cancellation, and no obsolete backlog.
2. `.a2` Restart the actual relay with a transient rejection queued. Expect durable
   retry with authorization/expiry rechecked; invalid tokens retire the correct
   target, and unknown send outcomes remain explicit.
   Exhaust known retries and expire/cancel/revoke queued work; expect bounded
   provider attempts and no stale retry. Hold a provider response while replacing
   its target; expect no ciphertext substitution onto the newer generation.
3. `.a3` Send unauthorized, conflicting, oversized, and over-limit requests.
   Expect rejection without provider sends or secret-bearing logs.
4. `.a4` Check support before producer initialization in default and named
   profiles. Expect a truthful unsupported state without poisoning later setup.
5. `.a5` Hold a replacement host's roster and release old token work. Expect no
   enrollment or preview-key dispatch through the replacement connection.
6. `.a6` With unreadable saved connection data and readable pairing storage,
   choose Forget saved setup. Expect local keys removed, nonsecret pending
   remote cleanup retained, and confirmed credential deletion. Push-vault
   failure must still block false local-removal success.
7. `.a7` Keep an idle producer loaded while another caller drains a slow backlog.
   Expect support to stay available beyond the heartbeat lease without a new
   native event, delivery to resume after lock contention, and unsupported status
   after unload. Removal must still wait for started egress before acknowledgment.
8. `.a8` Make relay response bytes arrive within each socket timeout but beyond
   the total request budget. Expect retryable failure within that budget, continued
   producer readiness, and no detached request after removal acknowledgment.
   Unload during the request and terminate its owner separately; requests must
   still expire. A fast response succeeds, and redirects remain refused.

Automated checks use the public relay contract, existing native entry points,
independent crypto fixtures, and real supported Hermes events. Record absent
hardware, credentials, deployment, or upstream release as blocked; none is
substituted by a simulated banner. Focus and permission can affect presentation.
