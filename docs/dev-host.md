# Disposable real Hermes host

This recipe starts a disposable host at `http://127.0.0.1:19119` using
official Hermes Agent commit
`4a0eaf7989b6804319ddb94fa5d96c5a716080a1`. It uses real Hermes password
authentication, profiles, canonical session authority, SQLite persistence,
admission receipts, streaming events, replay, and approvals. Only the LLM
provider is simulated. No existing user Hermes home or real credentials are
used. No remote model service is configured.

Use username **botto-test** and password **botto-test**. These are disposable local
test values. The iOS integration launch argument is:

```text
--fixture-server http://127.0.0.1:19119
```

This loopback address is suitable for an iOS Simulator on this Mac. A physical
phone cannot reach the Mac through its own loopback interface. A successful
host probe does not establish a working iOS connection.

## Run and reproduce

From the Botto checkout, run these commands in order. Requirements are `uv`,
Python 3.14 for Hermes, and an upstream checkout at the pinned SHA.
The manager itself also works with Python 3.11. For a first run, prepare the
checkout in an unused directory:

```sh
git clone https://github.com/NousResearch/hermes-agent.git /tmp/botto-protocol/hermes-agent
git -C /tmp/botto-protocol/hermes-agent checkout --detach 4a0eaf7989b6804319ddb94fa5d96c5a716080a1
```

If the checkout is elsewhere, pass `--source PATH` to `setup`.

```sh
python3 scripts/dev-host/host.py setup
python3 scripts/dev-host/host.py start
python3 scripts/dev-host/host.py status
/tmp/botto-runtime-current/venv/bin/python scripts/dev-host/smoke.py \
  --report /tmp/botto-runtime-current/smoke-result.json
```

`setup` reads the upstream checkout's revision, copies its source into the
private runtime directory, creates a uv venv, and installs that private copy
editably. It leaves the canonical source checkout untouched. Every resolved
dependency is pinned in `scripts/dev-host/requirements.lock`; the tested
environment is macOS arm64, CPython 3.14.8, and uv 0.10.0.

The first direct pip-style install exposed the upstream Pillow dependency
conflict. Setup explicitly applies upstream's own `[tool.uv]` overrides for
`Pillow==13.0.0` and `cryptography==50.0.1`. This preserves the upstream policy;
it does not downgrade Pillow. The source rejects wheel installs, so an editable
install is required. The exact installed package list is also saved as
`/tmp/botto-runtime-current/requirements-resolved.txt`.

For another isolated installation, pass `--runtime /tmp/botto-runtime-NAME` to
each manager command. Use `--source PATH` during setup if the canonical source
checkout is elsewhere. Do not run setup against a running runtime. Stop its
host first. `run` is the foreground alternative to `start`.

## Startup and isolation

The launched backend command is:

```sh
/tmp/botto-runtime-current/venv/bin/python \
  scripts/dev-host/gateway_entry.py
```

`gateway_entry.py` calls the ordinary upstream `gateway.run.main()` entry
point. Current upstream's gateway bootstrap invokes
`gateway.run_api.start_gateway_api()` with an ephemeral port and has no port
flag for this native listener. The launcher supplies only its `host` and
`port` arguments: `127.0.0.1` and `19119`. It does not replace the server,
authority, RPC dispatch, auth, agent, approval detector, or execution code.
This gateway-owned listener mounts the same official headless dashboard API.
A separate standalone `hermes serve` process would not establish the authority
path tested here.

The child receives an allowlisted environment. Its `HERMES_HOME` is
`/tmp/botto-runtime-current/hermes`; its fallback `HOME` is
`/tmp/botto-runtime-current/user`. Config, profile directories, locks, caches,
workspace, and temporary files all stay under this private runtime. Inherited
provider keys, auth state, proxy settings, and `HERMES_*` selectors are excluded.
The dummy OpenAI key is a local test value. The password provider and stable
disposable signing key are supplied only to this process.

The model config in `hermes/config.yaml` selects `provider: custom`,
`botto-local-deterministic`, `api_mode: chat_completions`, streaming, and a
128,000-token declared context. Current Hermes refuses contexts below 64,000.
The run-owned responder implements model listing,
nonstreaming completions, and SSE text/tool chunks plus usage and `[DONE]`.
Ordinary input produces `BOTTO_LOCAL_ACK …`. Input containing `BOTTO_APPROVAL`
requests the harmless terminal command `python3 -c "print('BOTTO_APPROVAL_OK')"`.
After approval, real Hermes executes it and the responder summarizes its real
tool result. Input containing `BOTTO_QUESTION` requests a note through Hermes's
clarify tool. Title generation is disabled; terminal and clarify toolsets are pinned.

The current provider port is preserved in `process.json` so cloned profile
configs keep working across restarts. A fresh runtime uses backend-port + 1
for its provider, normally `19120`. Both listeners bind only `127.0.0.1`.
The [sidecar recipe](dev-host-sidecar.md) uses a separate runtime and ports.

## Readiness and scope

Inspect the current run's `process.json` and `ready.json` before using its
ports or process IDs. A healthy status response is only the first check:

```sh
curl --noproxy '*' --fail --silent http://127.0.0.1:19119/api/status
BOTTO_TEST_HERMES_URL=http://127.0.0.1:19119 swift test --filter disposableAuthorityHostThroughPublicService
```

The opt-in Swift test creates a disposable profile and exercises the public
service. Keep its outputs outside source control and inspect the actual test
count and result. A run against this pinned fixture does not prove compatibility
with arbitrary Hermes releases, remote model providers, external PKCE/Access,
or the complete iOS interface. Record current results in the
[verification record](verification.md).

Named-profile setup has two important constraints:

- Newly created profiles become served asynchronously. Wait for their name in
  `/api/status.gateway_shared_with`, then attach a fresh socket. The normal
  profile watcher can take about 30 seconds; an immediate create can return
  `profile_mismatch` before publication.
- Carry `profile` on every named-profile session, prompt, receipt, replay,
  and approval call. A named-profile session ID does not select its authority.

The private source copy omits `.git` and has no packaged install stamp, so
upstream may report `version: unknown`. Record the pinned SHA and capability
handshake rather than assigning a fabricated release version.

## Teardown

Stop only the supervisor owned by this disposable runtime:

```sh
python3 scripts/dev-host/host.py stop
```

The manager checks the saved supervisor's command before signaling it.
Readiness is withdrawn before cleanup; `start` also checks current backend
health before accepting the marker. The supervisor observes gateway exit
without reaping its leader, drains that process
group, then reaps the child and stops its provider. This includes startup failure
and normal backend exit with a surviving descendant. Unconfirmed signal delivery
is reported on stderr; it does not skip the final bounded reap. It never
uses `hermes gateway stop`, kills a process by name, or targets an existing user
Hermes service. Runtime data remains available for inspection. After both
owned processes have exited, its owner may delete the disposable runtime
directories. Read the current `process.json` after each restart.
