# Native Hermes producer smoke test

`native-smoke.py` exercises an ordinary native Hermes gateway with Botto's real
plugin. Only the language-model provider and the final relay receiver are local
fixtures. The gateway, password login, profile routing, canonical sessions,
durable prompt admission, human waits, and plugin discovery use Hermes code.

This proves the **Hermes → plugin → encrypted relay submission** segment. It
does not prove Cloudflare, APNs acceptance, notification extension execution, or
a physical-device banner/tap. Those need their own recorded acceptance results.

## Prerequisites

- An official Hermes checkout at the exact base commit recorded by the
  [observer patch](../upstream/README.md).
- Hermes's supported Python environment, prepared through its official package
  manager with its runtime/test dependencies. The script does not install into
  or modify that environment.
- The observer patch and this checkout's plugin code.
- OpenSSL and Git, an available loopback native-API port, and a fresh private
  runtime directory. No Apple key, Cloudflare token, remote model, or user host
  configuration is used.

From the Botto checkout:

```sh
/path/to/hermes/.venv/bin/python Push/scripts/native-smoke.py \
  --source /path/to/hermes \
  --runtime /tmp/botto-runtime-push-34-unique \
  --port 19239 \
  --report .artifacts/push-native-host-result.json
```

The runtime must be new and named `/tmp/botto-runtime-push-*`; the script refuses
to reuse an existing directory. Choose a different port if another process owns
the default. The source checkout is read-only: the script archives the pinned
base, applies the delivered patch to the private copy, and records both the base
commit and patch SHA-256. It also records the imported observer module path to
prove the child uses that private copy rather than a different editable install.

## What runs

The runner creates default and named `push-research` profiles with independent
plugin storage. It uses the existing deterministic provider and gateway listener
launcher, with allowlisted environment values, private homes/workspace/cache,
and disposable local password authentication. It installs the actual plugin
files in each profile and configures its persistent relay origin through the
owner CLI before starting the gateway.

The recording relay is HTTPS on loopback. A run-owned, one-day certificate is
trusted only through that child environment's `SSL_CERT_FILE`; TLS verification
stays enabled. Its private key stays inside the mode-0700 runtime, mode 0600.
The receiver validates installation capability hashes and the encrypted event
shape. It never implements APNs delivery or accepts preview plaintext.

Required observed checks include:

- Password login and native authority capability handshake.
- Authenticated, profile-scoped plugin status and independent device enrollment.
- Enrollment retry preserving its operation result and generation.
- Native reply completion after the viewing socket disconnects, in both profiles.
- Independent AES-GCM decryption of the captured preview, exact profile/canonical
  chat coordinates, and rejection with the wrong key.
- Real approval and question waits while disconnected, followed by exact native
  responses and matching relay cancellation requests.

The JSON receipt contains outcomes and safe routing metadata, not login
responses, cookies, capabilities, preview keys, or ciphertext bodies. Temporary
SQLite stores contain fixture keys; treat the runtime as private even though
all values are disposable test data. Gateway logs can contain fixture prompt
text and are retained under the private runtime.

## Teardown and limits

The runner starts one owned gateway process group and two loopback servers. Its
`finally` path drains that group and shuts down both servers on success, a
test failure, or a normal SIGINT/SIGTERM/SIGHUP interruption. The receipt records
the supervisor PID and whether the gateway stopped. It never stops
a host by name or touches an existing user's Hermes service. Preserve receipts
and logs before deleting only that run's private runtime.

Source-level upstream tests separately cover compression lineage, failures,
quiet automation, unknown outcomes, and isolated plugin dispatch. This live
smoke must not be presented as runtime coverage for those cases unless it
actually executes them. Likewise, an encrypted recording-relay request cannot
stand in for a real APNs response or visible notification.
