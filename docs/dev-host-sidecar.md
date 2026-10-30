# Real Hermes 0.21.5 sidecar

This recipe starts the standalone native backend at
**http://127.0.0.1:19121** with
username **botto-test** and password **botto-test**. The deterministic local provider
listens at **127.0.0.1:19122**. Both sockets bind only loopback. The sidecar uses ports separate from the
authority-host recipe on port 19119.

This is official Hermes source at exact Hermex pin
`ca6782850432927f33df4775cb6dd45bb51460d2`, not a simulated Hermes server.
The pinned `/api/status` reports **0.21.5**. The source declares that version;
no release identity was fabricated. Only the OpenAI-compatible model provider
is simulated, using the existing `mock_provider.Handler` without modifying it.

## Reproduce and inspect

From the Botto checkout, run in order:

```sh
python3 -B scripts/dev-host/sidecar_host.py setup
python3 -B scripts/dev-host/sidecar_host.py start
python3 -B scripts/dev-host/sidecar_host.py status
/tmp/botto-runtime-sidecar/venv/bin/python -B scripts/dev-host/sidecar_smoke.py
```

Do not rerun setup while the sidecar is running. `run` is the foreground
alternative to `start`. An occupied port fails startup; the scripts never stop
or replace another listener. The scripts require `uv`, `curl`, and Python 3.13
for Hermes. The live venv uses CPython 3.13.16; the manager uses Python 3.11.9.
Setup downloads Python through uv if needed and installs only into this venv.

Source archive:

```text
https://codeload.github.com/NousResearch/hermes-agent/tar.gz/ca6782850432927f33df4775cb6dd45bb51460d2
SHA256: 82579cb54f79350176105ad5721cb19d5284a25b4b8cd67b16d4bfd91c54e7cf
```

Setup verifies that digest, extracts into `/tmp/botto-sidecar-source`, and
installs editably. It also checks every extracted regular file against the
archive. No source patch or Git operation is required.
`sidecar_dependencies.py` pins the tested package versions. They include the optional boto3 imports that upstream
otherwise installs lazily on a first turn. The complete installed lock is
`/tmp/botto-runtime-sidecar/requirements.lock`. Inspect that run-owned lock
when checking the installed environment.
No AWS provider, account credentials, or remote model endpoint is configured.

The actual source-supported backend command is:

```sh
/tmp/botto-runtime-sidecar/venv/bin/hermes serve \
  --host 127.0.0.1 --port 19121 --isolated
```

The pinned `hermes_cli/subcommands/dashboard.py` documents that `serve` runs
the same backend as dashboard with `headless_backend=True`, skips the SPA build,
and opens no browser. Its `tui_gateway/ws.py` sends `gateway.ready` with
`change_events`, `heartbeat`, and `replay_epoch`, without `session_authority`.
This recipe uses that unmodified standalone path. No gateway daemon is needed for
these sidecar sessions.

The child environment is allowlisted. `HERMES_HOME` points to
`/tmp/botto-runtime-sidecar/hermes`; fallback `HOME` points to
`/tmp/botto-runtime-sidecar/user`. Config, profiles, state DBs, locks, workspace,
caches, and temporary files stay inside this runtime. Inherited provider keys,
proxy variables, and `HERMES_*` selectors are excluded. The dummy OpenAI key and
stable password signing secret are disposable fixture values. The config selects
`custom`, `botto-local-deterministic`, streaming chat completions, a declared
256,000-token context, and the local provider URL. Title generation and Tirith
are disabled. No user Hermes directory or real credentials are used.

## Readiness and scope

Inspect the current run's `process.json` and `ready.json` before using its
process IDs. Check the backend independently, then run the opt-in Swift probe:

```sh
curl --noproxy '*' --fail --silent http://127.0.0.1:19121/api/status
BOTTO_TEST_HERMES_URL=http://127.0.0.1:19121 swift test --filter disposableAuthorityHostThroughPublicService
```

The sidecar may report `gateway_running:false`, `gateway_mode:none`, and
`overall:degraded` while its headless native backend is usable. This fixture
intentionally omits the separate messaging/cron gateway daemon. Verify password
login, the capability handshake, a canonical chat and live socket; a status
response alone does not establish readiness.

Legacy navigation preserves the returned stored ID for durable navigation and
the runtime ID for live calls. This differs from the current authority's session
identity and admission receipts. The service selects the adapter from the real
handshake despite the opt-in test's historical method name.

The fixture uses real Hermes with a deterministic model. It does not establish
compatibility with arbitrary sidecar versions, remote providers, an iOS UI,
external sign-in, or the complete acceptance matrix. A physical phone cannot
reach this Mac through its own loopback URL. Keep results scoped in the
[verification record](verification.md).

## Stop only this sidecar

When this runtime's owner finishes testing:

```sh
python3 -B scripts/dev-host/sidecar_host.py stop
```

The script checks the saved supervisor's command, signals only that supervisor,
and lets it drain its own backend process group and provider. It does not use
`hermes serve --stop`, match processes by name, or touch the current authority
host. Runtime data and the pinned source remain for inspection. Its owner may
delete `/tmp/botto-runtime-sidecar` and `/tmp/botto-sidecar-source` after both sidecar
processes exit.
