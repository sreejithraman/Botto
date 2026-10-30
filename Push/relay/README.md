# Botto push relay

The Cloudflare implementation of [Botto push protocol v1](../PROTOCOL.md).
It authenticates installation-scoped lifecycle requests and forwards sealed
per-device previews to Apple Push Notification service. The relay cannot
decrypt previews and does not hold Hermes login credentials.

## Local checks

Requires Node 22.22+, npm, and a POSIX test host for owned process-group crashes.
From this directory:

```sh
npm ci
npm run check
npm run deploy:dry-run
```

The package lock pins the runtime and test tooling. Approved install scripts
belong to esbuild, workerd, and macOS's optional fsevents dependency. A dry run
bundles and validates configuration; it neither deploys nor proves APNs delivery.

`npm test` runs three checks:

1. Public HTTP lifecycle tests execute the production Durable Object in
   Cloudflare's local workerd runtime. Only external APNs fetches are replaced.
   Tests inspect recipient, headers, ES256 provider token, sealed payload,
   preferences, suppression, revocation ordering, cancellation, and retries.
   Deferred cases control application time and invoke the runtime's alarm helper
   through real HTTP/provider boundaries. They prove four-attempt exhaustion,
   queued expiry/cancellation/revocation, and in-flight generation replacement.
   The shared Python/Swift boundary fixture proves a legal large preview fits
   the complete APNs budget; an oversized contrast must cause no provider send.
2. A separate Node/Miniflare test runs the actual bundled Worker, shuts down the
   runtime with a queued rejection, restarts it using the same owned disk
   storage, and observes its persisted alarm submit the event. It restarts again
   to verify removal tombstones. Another case cancels/revokes queued retries,
   restarts, and observes no retry across the real first-retry interval, followed
   by accepted fresh-event controls. All provider credentials are disposable test
   keys; no requests reach Apple. Its temporary storage is removed afterward.
3. A separate process-crash harness runs the bundled Worker with disk storage
   and a parent-owned provider recorder. It kills the owned runtime after a
   claim, after provider acceptance, after a successful response, and after the
   receipt is committed while the caller's acknowledgment is held. Public replay
   must not initiate a second send during a six-second observation window.
   The response-to-receipt case uses a test-only public fetch/response adapter
   importing the unchanged bundle; the other cases use the raw entry. Restart
   always uses the raw entry. No private state is read or production hook added.

Crash receipts and independent provider journals are written under
`.artifacts/crash`. `duplicate` confirms deduplication, not provider acceptance.
An unresolved claim can conservatively lose an unaccepted alert; replay does
not guess whether the provider accepted it. These checks do not promise
exactly-once delivery or power-loss durability. The harness handles ordinary
termination and removes its owned process groups and temporary storage.

Tests isolate installations with random capabilities. They do not require a
Cloudflare account, Apple signing key, or physical device. They do not establish
an observed iPhone notification.

## Deployment

Choose a unique Worker name and an unused rate-limit namespace ID in the
Wrangler configuration, and review the allowed bundle IDs and environments.
The default allowlist is `com.sree.botto`
with sandbox and production targets; a separately signed fork must change the
bundle ID to its own Apple App ID. The private key must be authorized for the
chosen topic and environment.

The operator provisions Apple Push Notifications capability and app/extension
signing. Create an APNs token-authentication key and retain its `.p8` file
privately. Enter the matching Team ID, Key ID, and full PEM key as Worker secrets:

```sh
npx wrangler login
npx wrangler secret put APNS_TEAM_ID
npx wrangler secret put APNS_KEY_ID
npx wrangler secret put APNS_PRIVATE_KEY
npm run deploy
```

Wrangler prompts accept values privately; never place the private key in a
command argument, checked-in configuration, logs, or chat. A local development
`.dev.vars` can supply these names, but local tests do not need it. Never point
test installs at real users.

The first deployment creates the `INSTALLATIONS` SQLite Durable Object
namespace and the request-rate-limit binding. Keep the migration history on
subsequent deployments. Configure the deployed HTTPS URL on the Hermes plugin;
there is no assumed production endpoint in this repository. The phone enrolls
through its existing authenticated Hermes session, not with a relay capability.

Leave request/body/header logging and traces disabled. The Worker emits no
application logs. Cloudflare still processes delivery metadata. A custom domain
or external proxy must not collect authorization headers, device tokens,
request bodies, or platform secrets.

`GET /health` reports only liveness. Before offering the service, exercise a
signed sandbox app and a production/TestFlight installation with matching Apple
configuration. Observe host production, relay acceptance, APNs response, on-device
decryption/banner, and correct tap routing separately. Use a run-owned host and
device enrollment; remove that enrollment afterward.

## State and delivery guarantees

One Durable Object owns each opaque installation. It serializes lifecycle work
across asynchronous APNs calls, not just storage writes. Acknowledged removal
therefore fences all later sends for the removed generation. A request already
submitted to Apple can still arrive. Delayed registration writes cannot undo a
generation tombstone. Presence has its own monotonic revision, so a stale renewal
cannot restore a cleared visibility lease or invalidate queued target generations.

The Durable Object is the state adapter at the public command seam. Validation,
delivery policy, and APNs sending are independent modules. A future state adapter
must preserve registration/revocation, claim, duplicate, and expiry semantics;
replacing it with generic eventually consistent key/value access is unsafe.
Alarms implement durable scheduling; the sender module owns Apple authentication
and classifies provider results. The same public lifecycle tests apply to a
replacement adapter. No second cloud implementation is bundled here.

Each recipient has a durable receipt keyed by event, device, and generation.
Queued work and its alarm are committed together. The sender records a claim
before egress. A restarted unresolved claim becomes `unknown`, not a blind replay
of a possibly accepted message. Transient **rejections** retry at most three
times after the initial attempt (5, 15, and 45 second delays), subject to expiry,
current registration, preferences, and cancellation. A network timeout has an
ambiguous external outcome and is not automatically replayed. There is no
exactly-once or always-visible delivery guarantee.

The HTTP response includes per-target results: `accepted`, `duplicate`, `queued`,
`suppressed`, `revoked`, `expired`, `cancelled`, `invalid_target`,
`permanent_failure`, or `unknown`. Mixed results have top-level `accepted` and
the individual target outcomes. A 503 HTTP response means relay processing could
not be confirmed; retry the same event identity and ciphertext. A `queued` result
means the relay owns the durable retry. Identical IDs with changed content are
conflicts. APNs acceptance remains distinct from device display or reading.

## Limits and privacy

Initial enforced bounds, selected for a small accountless service:

- 32 KiB JSON write bodies; at most 32 event targets.
- 32 active devices and 128 lifetime device IDs per installation. Tombstones are
  retained to reject old registrations; rotate to a new installation deliberately
  if that lifetime bound is reached.
- 600 event submissions and 4,096 other lifecycle commands per fixed UTC hour
  per installation, including unsuccessful commands after schema validation.
- 512 retained recipient receipts and 512 unexpired cancellations per installation.
- One hour maximum reply/failure lifetime and five minutes for waiting requests,
  with a shorter host expiry honored. Presence leases last at most 90 seconds.
- The complete APNs JSON is at most 4,096 bytes; the producer falls back to
  routing-only ciphertext before admission. Decoder safety bounds are separate
  from that complete-payload decision; see the protocol. The host
  must split large multi-device submissions to remain within the HTTP body cap.
- 120 lifecycle requests per 60 seconds per connecting IP through Cloudflare's
  rate-limit binding. This is an abuse throttle, not a globally exact quota or a
  substitute for installation authorization. Review provider spending controls
  and service limits before public launch.

Receipt content, including encrypted preview material, is deleted after event
expiry plus ten minutes; alarms remove it without requiring another request.
Cancellation records expire after their bounded request lifetime. Device records
contain APNs tokens, bundle/environment, preferences, and bounded presence. Active
registrations remain until removal or token invalidation. Removal retains only a
generation tombstone; it cannot erase earlier payloads on recipients or at Apple.
The installation capability is verified at the Worker and removed before the
Durable Object request; it is never persisted.

The relay sees installation/device/event/chat digests, event category, timestamps,
message size, token, environment, and bundle identity. The preview body and exact
Hermes routing identity stay encrypted. Even when previews are disabled, retain
the host's routing-only ciphertext so tapping can open the correct chat; do not
strip it from the APNs payload.

## Sources and reuse

The relay code and Botto app are licensed under MIT. See this component’s
[LICENSE](LICENSE) and the [repository license](../../LICENSE).

The implementation is original against Botto's protocol. The design was informed
by [Hermex push](https://github.com/uzairansaruzi/hermex-push) and
[Bighelp](https://github.com/promptclickrun/bighelp); no donor implementation was
copied. Dependency licenses remain with their packages and must be included as
required when distributing artifacts.

Platform references: [Cloudflare Durable Objects](https://developers.cloudflare.com/durable-objects/),
[alarms](https://developers.cloudflare.com/durable-objects/api/alarms/),
[Workers tests](https://developers.cloudflare.com/workers/testing/vitest-integration/),
and [Apple notification requests](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns).
