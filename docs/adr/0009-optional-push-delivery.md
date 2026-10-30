---
status: accepted
---

# Add optional push delivery beside the direct Hermes connection

The design uses a plugin on the Hermes host to produce notification
events, a separate relay to forward them to APNs, and Botto to register devices
and handle notification taps. Chats and actions continue through Botto's direct,
authenticated Hermes connection. The host remains authoritative when an alert
is opened.

This narrows [ADR 0002](0002-direct-hermes-backend.md): its exclusion of an
additional mobile relay allows an optional service for notifications.

Botto, its plugin, and its relay use the MIT license, with preserved upstream
notices. The source includes deployment instructions for operators using their
own Apple signing and push credentials. An operator-configured relay is a
prerequisite for the experimental push feature; the source release does not
provide or promise a hosted service.

The first deployment targets Cloudflare Workers, with Durable Objects owning
authoritative registration/delivery state and alarms for deferred work.
This follows the closest peer implementations and keeps the initial deployment
compact. API Gateway, Lambda, and DynamoDB were the AWS alternative; an existing
AWS operating preference could favor that choice. No latency, reliability, or
cost advantage has been measured for Botto.

Keep these seams reusable:

- The versioned relay HTTP contract and encrypted envelope use platform-neutral
  values, so Botto and the Hermes plugin need no Cloudflare bindings or object IDs.
- Validation and delivery policy operate on domain values independently of the
  Workers runtime and storage representation.
- A state adapter owns registration, revocation, delivery claims, deduplication,
  and expiry checks. Its interface expresses the required atomic operations
  and ordering, rather than exposing generic key/value access.
- A scheduling adapter owns durable retries and expiry wakeups. Cloudflare
  alarm details stay inside its implementation.
- An APNs sender adapter owns provider authentication, requests, and response
  classification; credentials stay in the deployment's secret configuration.

Build the Cloudflare adapters first. Another deployment can replace state,
scheduling, and sending adapters while preserving the caller contracts. Any
replacement must verify the same registration/revocation ordering, retry,
deduplication, and expiry behavior. Changing hosts still requires that adapter
work and verification; the Cloudflare implementation is not a general-server
deployment recipe.

The first version requires no separate Botto account or subscription. Existing
Hermes access authorizes enrollment of paired devices; the relay authenticates
paired installations and enforces service limits. Each deployment's operator
owns its credentials, service configuration, and operating costs.

Push may require a newer minimum Hermes version than ordinary chat. Prefer
supported upstream hooks and contribute missing hooks upstream rather than
maintaining patches to private runtime internals. Select and verify the minimum
version during integration; ordinary chat retains its existing supported hosts.

Encrypted notification previews are required in the first version. A
generic-only release does not meet the intended experience. Previews show the
bot's name and a bounded message excerpt; approvals/questions show a short
description and open Botto for full details. The host encrypts preview content,
and the device decrypts it locally. The relay receives neither preview plaintext
nor decryption keys. A generic alert remains the fallback when decryption is
unavailable.

Preview visibility follows iOS Show Previews, with an additional Botto preference
to always hide preview content. Each device has a separate notification pairing
and encryption keys. Removing one device stops future delivery to it and
excludes it from decrypting future previews without requiring other devices to
pair again. Removal does not erase previews or keys already held by that device.

Initial alerts cover finished replies, waiting approvals/questions, and turn
failures, with separate preferences for each category. Silent automation and
subagent completions stay quiet. Explicit scheduled-result alerts are deferred
until their authoritative delivery semantics are verified.

Botto guides plugin setup, with confirmation before host installation or updates
and a manual-command fallback. A device actively displaying the affected chat
suppresses its own banners; other devices follow their own preferences. Initial
notifications open the correct chat and refresh host state; replying and
approving stay inside Botto. Old alerts expire, and resolved requests cancel
queued sends. Tapping an already-delivered alert still checks current state.

Implementation and deployment requirements live in the [notification guide](../push-notifications.md)
and [shared protocol](../../Push/PROTOCOL.md). The [verification record](../verification.md)
tracks observed results separately from this architectural decision.
