# Hermes plugin for Botto notifications

This MIT-licensed plugin produces per-device encrypted notifications from a
Hermes profile. Hermes mounts its HTTP routes behind the host's existing
authentication. The relay receives APNs tokens, opaque delivery identities,
event kind, timing, and encrypted previews; it receives no Hermes credentials,
preview plaintext, or preview keys. The first relay deployment is Cloudflare.

## Required host support

The ordinary plugin/package/dashboard APIs have a v0.22.5 baseline. **That is
not a supported minimum for the complete notification feature.** Full production
requires the versioned native-session observer in [the upstream addition](../upstream/README.md)
and native-backend/profile verification. The current source pin plus patch is a
development prerequisite until the observer is available in an upstream release.

`register(ctx)` checks the supported `ctx.native_session_events_version == 1`
capability. It subscribes to `on_native_session_event` and never patches private
runtime functions or guesses canonical identities from legacy hooks. Status is
unsupported when the observer is missing, the plugin is not loaded, its runtime
heartbeat has expired, or its relay origin is unconfigured. Installing files
does not prove the running gateway has loaded them.

The observer uses canonical native chat/prompt identity and committed outcomes.
Meaningful successful replies, authoritative failures, and actual waiting
approvals/questions produce alerts. Silent outcomes, subagent work, and stopped
turns stay quiet. An `unknown` terminal outcome can use the failure preference
category, but its text explicitly says the outcome is unknown. It never claims
success or failure. A resolved request cancels unsent waiting alerts.

## Install and configure

Install the plugin subdirectory from the actual published repository using an
immutable commit ref, after reviewing dependency/install confirmation. The
repository URL and commit are release inputs; do not substitute an unrelated
project's relay or install from a moving branch.

```sh
hermes --profile PROFILE plugins install REPOSITORY_URL/Push/plugin --ref FULL_COMMIT_SHA --enable --yes-deps
```

The plugin's manifest declares its actual Python dependencies. The dependency
prompt and Hermes's normal package preparation remain authoritative. Do not
force a rejected installation. If activation reports `restart_required`, wait
for running work to finish and use the owner's actual service restart procedure;
do not automatically interrupt active work or re-exec the dashboard process.

Set the nonsecret plugin setting `relay_url` to the deployed HTTPS relay origin,
or provide `BOTTO_PUSH_RELAY_URL` to that profile's running service. Another option
is this owner CLI, using the Hermes Python environment and plugin install path:

```sh
PYTHONPATH=/absolute/path/to/installed/plugin python -m botto_push --profile PROFILE configure https://YOUR_RELAY_ORIGIN
```

When using a named profile, run the command in that profile's Hermes environment
or explicitly pass its owned data directory with `--data-dir`. Configuration
must target the same profile as the producer. Reload the plugin after changing
its running service configuration. Support stays unavailable until the loaded
producer uses the configured relay; its status explains when reload is needed.
Only HTTPS origins without credentials,
query, fragment, or path prefixes are accepted. Recording-relay smoke tests use
an owned HTTPS certificate trusted only by the disposable test service.

Normal plugin discovery is per profile. Install and enable the plugin separately
for every producing profile and reconcile new profiles deliberately. Root
dashboard discovery is not evidence that hooks are installed in every profile.

## Host HTTP contract

Hermes mounts `dashboard/plugin_api.py` under `/api/plugins/botto-push`, with the
existing owner authentication and authenticated profile scope. The plugin does
not create another password verifier or standalone public server. Do not mount
the router without the host's authorization dependency.

- `GET /status`: protocol/plugin version, observer capability, relay origin,
  installation ID, and safe device metadata. `capabilities` is a map such as
  `{"native_session_events":1}`. No key, bearer capability, or APNs token is
  returned. All bounded device records remain visible, including completed owner
  removals. Each has a `state`: `active`, `pending`, `rejected`, `relay_retired`,
  or `removed`. The last two are inactive; `pending_removal` separately reports
  whether an owner removal still lacks remote acknowledgment.
- `POST /devices`: version, operation UUID, random device ID, required integer
  `expected_generation`, APNs token,
  bundle/environment, preferences, optional device label, optional new preview
  key, and optional visible canonical destination/expiry. The destination must
  match the authenticated profile. A first enrollment uses expected generation
  zero and needs a 32-byte key. Existing updates require the current known
  generation, preventing a delayed request from rolling back a newer pairing.
  Returns installation ID, device ID, generation, preferences, and `accepted`,
  `pending`, `rejected`, or `revoked` state. Only `accepted` confirms an enabled
  delivery path. Retry the same unchanged operation UUID safely. Relay-retired
  targets stay revoked for an unchanged APNs token, even with a new operation.
  A verified changed token with the current generation may recover routine token
  rotation. Owner-removed device IDs can never enroll again; deliberate
  re-enablement creates a new random device ID and preview key.
- `POST /devices/{id}/remove`: version and operation UUID. Keys are removed
  locally, queued targets retired, and a higher-generation relay tombstone
  requested. Even an unknown device ID creates a permanent, bounded tombstone
  and requests real remote revocation, fencing a delayed initial enrollment.
  `revoked` confirms remote acknowledgment; `pending` does not.
- `POST /devices/{id}/test`: version and canonical destination, with optional
  operation UUID. The profile must previously have observed that exact
  destination through a real supported native event. Otherwise run a real chat
  turn first. A test is encrypted on the host and respects delivery preferences.
  Submission is not proof that iOS displayed a banner.

Every write is bounded to 32 KiB and rejects unknown fields, duplicate JSON keys,
invalid identities, and unsupported versions. Responses use `Cache-Control:
no-store`. The [shared protocol](../PROTOCOL.md) owns the relay contract and
cross-language encryption envelope.

## Durable state and device removal

The documented `plugin_data_dir("botto-push")` API resolves the active profile on
each entry. The supported `get_active_profile_name()` facade supplies genuine
profile identity even before the lifecycle producer first loads. A status read
cannot persist a placeholder profile owner. Outside a known Hermes context,
initializing new explicit storage requires `--profile`; it asserts identity and
does not switch the process's active Hermes profile. Real stored/context owner
mismatches remain errors. Runtime state lives outside the updateable plugin tree.
SQLite transactions serialize shared dashboard/plugin state. The directory uses
mode 0700, the database/dispatch lock mode 0600, and a cross-process POSIX file
lock serializes outbound work. Host verification currently targets POSIX hosts;
Windows locking and ACL behavior are not verified.

The installation capability and per-device preview keys are generated pairing
state in that protected database, not operator provider credentials. They are
never printed or returned by status/CLI listings. Outbox entries contain sealed
previews and public relay metadata, not preview keys or plaintext. Removing a
device clears its key immediately. Backups of this directory contain sensitive
pairing state and must have equivalent access restrictions.

Registration/key/token/preference changes advance a device's generation.
Visibility-only updates retain it and use an independently increasing revision,
so stale retries cannot restore an older visible-chat lease. The relay caps a
lease at 90 seconds. Stable event identities and persisted ciphertext survive
host restarts. New device generations never receive ciphertext created for an
older key/generation.

Owner-removal tombstones do not expire when operation receipts are collected.
An exact lost-ack retry can confirm the current state without registration or
visibility changes or relay egress when its expected generation is immediately before the current one and
its target, preferences, and key match. For a request omitting the key, the
durable latest transition must prove it retained that key. Any stale difference,
additional generation advance, or owner removal rejects the retry. The immutable
registration request is retained separately from visibility, so requeueing an
uncertain registration cannot change its original generation's relay contents.

Outbound work retries known transient relay failures up to eight attempts with
bounded backoff. Normal registrations/events expire within an hour; removal
work is retained for seven days, and its local tombstone remains explicit if
remote confirmation is still missing. An explicit removal retry requeues that
tombstone. Requests and replies use their shorter event expiry. The relay owns
its own APNs retry classification; an HTTP acknowledgment is not an exactly-once
delivery guarantee.

Each HTTPS attempt runs in a request process using the current Python interpreter.
Its ten-second budget covers DNS, TLS, headers, and the bounded response body after
process creation. Python's [process timeout](https://docs.python.org/3/library/subprocess.html#subprocess.run)
kills and waits for the request before dispatch can unlock. The request also has
its own POSIX alarm if the host exits. Tokens and payloads pass through stdin,
without shell commands or credential arguments. A timeout retains the existing
idempotent retry contract; it does not prove whether the relay accepted the request.

Limits per profile: 32 owner-authorized devices (including relay-retired targets),
128 total device/tombstone records, 1,024
pending operations, 4,096 event receipts, 4,096 operation receipts, 4,096 live
request cancellations, and 1,024 known destinations. Operation receipts expire
after a day; event/cancellation receipts are cleaned by expiry. Exhaustion
returns an explicit limit error rather than silently evicting active pairings
or unresolved removal evidence.

Use the owner CLI to inspect safe metadata or remove a lost device:

```sh
PYTHONPATH=/absolute/path/to/installed/plugin python -m botto_push devices
PYTHONPATH=/absolute/path/to/installed/plugin python -m botto_push remove DEVICE_ID
PYTHONPATH=/absolute/path/to/installed/plugin python -m botto_push drain
```

Removing push enrollment does not revoke that device's Hermes login credentials
or erase old notifications. A device retaining full owner access could authorize
a new pairing; revoke its host credentials separately when it is lost or
compromised. Already-submitted APNs messages cannot be recalled.

## Local checks

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements-test.txt
.venv/bin/python -m unittest discover -s tests -v
```

The suite covers the mounted authenticated HTTP boundary, idempotent enrollment,
profile isolation, durable removal/restart, independent device keys, encrypted
routing-only previews, queue retry/expiry, true wait cancellation, quiet and
unknown outcomes, host display titles, and removal ordering around an in-flight
send. Additional regressions cover status-before-register in default/named
profiles, permanent unknown/known removal, receipt-expiry replay, generation
preconditions, and changed-token-only retirement recovery. The public synthetic encryption fixtures are suitable for independent
CryptoKit compatibility checks. Their fixed keys and nonces are test data only.
They use the Botto v1 additional-data prefix and are regenerated with Python
`cryptography` AESGCM over the stored canonical plaintext; the boundary fixture
also checks the complete Botto APNs payload size.

These tests do not prove the upstream hook's native runtime coverage, a deployed
Cloudflare relay, Apple credential authorization, or an iPhone banner. The
project's native host smoke and signed-device acceptance checks provide those
separate observations.

## License

MIT. See [LICENSE](LICENSE) and Botto’s [repository license](../../LICENSE).
These licenses do not supply Apple credentials, a hosted relay account, or
third-party service rights.
