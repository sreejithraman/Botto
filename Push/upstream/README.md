# Proposed Hermes notification prerequisites

`native-session-events.patch` adds a generic native-session observer to official
Hermes at base commit `fcc26fbd9f1641755e49793d7ed608f3b7214c3d`.
It also adds an explicit-profile dashboard installer for confirmed host changes.
It is a proposed upstream contribution, **not a released Hermes capability**.
The accompanying upstream MIT license retains Nous Research's notice.
Botto's plugin must report native event production unsupported until it detects
this contract in the running host. A version number by itself is insufficient.

The patch supplies the missing canonical identity, real prompt linkage, and
settled outcome/presentation metadata needed by Botto notifications without runtime
monkeypatches. The concrete consumer remains the standalone Botto plugin; no Botto
networking, keys, tokens, or third-party service enters the Hermes core tree.

## Applying and checking

Use a disposable official Hermes checkout at the exact base. The patch is
included for review and testing; it is not a released upstream dependency.

```sh
git rev-parse HEAD
git apply --check /absolute/path/to/native-session-events.patch
git apply /absolute/path/to/native-session-events.patch
python -m pm.build_env --source . --out .venv --group dev --group test
HERMES_PYTHON="$PWD/.venv/bin/python" scripts/run_tests.sh \
  tests/gateway/test_native_session_events.py \
  tests/hermes_cli/test_native_session_events.py \
  tests/agent/test_plugin_stream_hooks.py \
  tests/hermes_cli/test_plugin_api_compat.py \
  tests/hermes_cli/test_plugin_host.py \
  tests/gateway/test_authority_turn_error_surface.py \
  tests/gateway/test_settlement_off_loop.py \
  tests/gateway/test_managed_worker_clarify_timeout.py \
  tests/gateway/test_session_authority_cancel_settlement.py \
  tests/hermes_cli/test_profile_plugin_install.py \
  tests/hermes_cli/test_dashboard_plugin_routes_secret_scope.py -q
.venv/bin/python scripts/check
```

The environment build is fresh; do not regenerate over an existing disposable
environment without following Hermes's package-manager instructions. Restart
only an owned test host to load the patched code. This patch does not authorize
restarting a personal or shared gateway.

## Public contract

Automatic setup uses `POST /api/dashboard/agent-plugins/install-profile` with
the existing dashboard authentication. Its install body requires an explicit
`profile` alongside `identifier`, immutable `ref`, `force`, and `enable`.
The host resolves that profile before installer/config/activation work and
returns its name as `profile`; Botto requires a matching successful acknowledgment.
Empty/current/missing profiles fail before installation. The legacy install
endpoint retains its launch/effective-profile semantics. Botto never falls back
to it when the new endpoint is unavailable; use the explicit-profile CLI instead.

The installer tests drive the actual authenticated HTTP handler and real Git
clone, pinned installation, and enablement with a harmless temporary plugin.
They assert target configuration and files, untouched other-profile files/config,
invalid-profile rejection and ordinary authentication. No installer is mocked.

Plugins register `ctx.register_hook("on_native_session_event", callback)` and
probe `getattr(ctx, "native_session_events_version", 0) == 1`. The isolated
plugin host carries the same numeric property. A separately loaded dashboard
backend can inspect the documented public constant
`hermes_cli.plugins.NATIVE_SESSION_EVENTS_VERSION`.

The callback receives an `event` dictionary with these v1 fields:

| Field | Contract |
| --- | --- |
| `v` | `1` |
| `type` | `turn.completed`, `turn.failed`, `turn.interrupted`, `turn.unknown`, `request.waiting`, `request.resolved` |
| `event_id` | Stable SHA-256 digest over profile, canonical root, execution generation, admission, event type, and optional prompt ID |
| `profile_id` | Served profile label, including `default`; never a host filesystem path |
| `root_id` | Canonical authority root |
| `stored_id` | Actual current physical compression tip |
| `turn_id` | Native admission identity |
| `execution_generation` | Exact positive generation of the started turn |
| `request_id` | Native prompt ID for waiting/resolved pairs, otherwise null |
| `kind` | `reply`, `failure`, `approval`, or `question` |
| `meaningful` | Visible attention disposition; false for interrupted and proven quiet successful turns |
| `is_subagent` | Explicit stored-session source classification, never guessed from text |
| `title` | Served profile label, bounded to 160 UTF-8 bytes; the plugin may choose its own authenticated display name |
| `preview` | Owning-profile redacted text, bounded to 1,024 UTF-8 bytes |
| `created_at` | Capture time in Unix seconds |
| `expires_at` | Request events only: timeout-capped expiry shared by waiting/resolved pair |

`turn.unknown` belongs to failure-category attention but retains the explicit
preview “The turn's outcome is unknown.” It must never become a successful or
definitively failed turn. `request.resolved` cancels earlier queued request
alerts even though its `meaningful` flag is false.

## Production integration

Terminal events originate after canonical authority settlement, independently
of attached viewers, including initialization failures. The managed-worker loss
path emits unknown only after committing that uncertainty. Prompt events come
from actual native pending controls, including managed-worker prompt settlement;
smart approvals and mere clarify tool attempts are not waiting events. Queued
unstarted cancellations are not completed execution events.

Successful silence requires host-owned automation provenance or the turn's
explicit muted-presentation policy. An ordinary human message/response merely
containing a silence marker cannot classify a turn as quiet. Approval previews
are a generic “Approval needed”; commands, arguments, answers, passwords, raw
failure diagnostics, and conversation history do not enter the observer preview.

Callbacks use the existing bounded per-consumer dispatcher with copied payloads
and an explicitly bound owning-profile context. Observing does not mark the
session viewed/delivered and cannot change committed execution. The dispatcher
is best effort, not a durable event journal; a blocked consumer may lose queued
observations. The plugin must persist accepted work promptly and reconcile
canonical state. Local safe/ignore-user-config policies withhold profile-plugin
observations. This is not a source-to-device exactly-once promise.

## Evidence

The initial dedicated real-authority completion test failed against the
unmodified base because no native observer event was emitted. The same test
passed with the patch. Dedicated tests exercise disconnected completion across
compression, failure/interruption/quiet distinctions, actual prompt IDs and
resolution, managed prompt settlement, immutable per-consumer destinations,
real plugin discovery/profile scope, isolated-host capability propagation, and
a real lost managed worker on macOS (POSIX process path).

Final commands and results are recorded in `verification.txt`. Historical
execution logs remain in the drafting history and are not included in source
releases. Reproduce checks with the commands above. No real APNs
send, production gateway, phone, or iPad was used for this upstream slice.
No upstream release containing this proposal was established.
