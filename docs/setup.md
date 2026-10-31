# Connect Botto to Hermes

Use the native Hermes backend where your bots already live. You need its final
HTTPS origin, Hermes sign-in, and a route the phone can reach. Reuse a running,
authenticated backend whenever possible. A QR code only fills in its address.

## Build and signing

Use macOS with Xcode 27.1 or later and an installed iOS Simulator runtime.
Botto supports iOS and iPadOS 18 or later and uses Swift 6. The checked-in
`Botto.xcodeproj` is ready to open; `project.yml` owns its generated settings.

For Simulator use, select the **Botto** scheme and an iPhone or iPad, then Run.
**Explore the demo** needs no Hermes server. Command-line checks can disable
signing, but unsigned runs do not establish native Keychain sign-in behavior.
Use a signed development build when testing real credential storage.

For a physical iPhone or iPad:

1. Use an Apple development team authorized for Push Notifications. Register an
   app identifier and its `.notifications` extension identifier for that team.
2. Set `BOTTO_APP_BUNDLE_IDENTIFIER` in `project.yml` to your app identifier and
   set your `DEVELOPMENT_TEAM`. The extension and shared push Keychain group
   derive from that value. Regenerate the project.
3. In Xcode, confirm automatic signing or supply matching profiles for both
   **Botto** and **BottoNotifications**. The app profile must authorize the
   `aps-environment` entitlement. Debug selects sandbox APNs; Release selects
   production.
4. Keep the app-private Keychain group first and the push group second in the
   app entitlements. The extension receives only the push group. Confirm the
   signed app and extension use the same expanded push group.

The source includes Push Notifications entitlements even when notifications
are unused. A profile without that capability cannot sign the stock device
build. The repository contains no reusable signing identity or provisioning
profile. Distribution requires your own signing and App Store Connect access;
follow [internal TestFlight delivery](testflight.md) for the protected GitHub
publishing path. Contributor builds and checks do not require those release
credentials.

When changing `project.yml`, use
[XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.46.0 and regenerate:

```sh
xcodegen generate
```

## 1. Run Botto

**Explore the demo** opens a labeled sample workspace without a server. Demo bots,
messages, uploads, and approvals do no real work. Leave through Settings → Leave
demo before using your own connection. Open the pinned **Canvas** bot to try
HTML, diagrams, and native file previews. Its PDF, text, image, and HTML files
are local samples that you can save or share without a Hermes connection.

## 2. Choose the native listener

Botto connects to Hermes Agent's own HTTP API and `/api/ws`. It does not need
`hermes-webui`, a mobile adapter, a relay, or a separate QR redemption service.
Use an origin such as `https://hermes.example.com`, without `/api`, a dashboard
path, query, fragment, or embedded credentials.

For an existing installation, use its configured native backend/gateway URL.
Keep its existing Hermes home, profiles, model configuration, and authentication.
Do not launch another Hermes process against the same storage just for Botto.

For a new standalone backend, official Hermes supports:

```sh
hermes serve --host 127.0.0.1 --port 9119
```

Configure authentication and reachability below before connecting. `serve` is
headless and skips the browser UI build. `hermes dashboard --no-open --host
127.0.0.1 --port 9119` uses the same backend with Hermes's own browser UI.
[Official command parser](https://github.com/NousResearch/hermes-agent/blob/4a0eaf7989b6804319ddb94fa5d96c5a716080a1/hermes_cli/subcommands/dashboard.py).

**Current gateway authority differs from standalone serve.** On the inspected
current Hermes revision, the running gateway owns a native listener and mounts
its canonical session authority there. Standalone `serve` does not establish
that authority merely by using a recent version. For this path, use the existing
gateway listener. On that revision, this host-side command reuses or ensures a
local runtime and returns its credential-free `endpoint.api_origin`:

```sh
hermes gateway ensure --json
```

It can start a runtime if none exists. Require `state: "ready"`; use the reported
origin's actual port as the tunnel target. The listener defaults to an ephemeral
port, so check again after a gateway restart and update the tunnel if it changes.
There is no verified `hermes gateway run --port` option. Older installations may
not have `gateway ensure`; use their existing deployment's native URL instead.
[Gateway discovery](https://github.com/NousResearch/hermes-agent/blob/4a0eaf7989b6804319ddb94fa5d96c5a716080a1/hermes_cli/gateway_runtime_cli.py),
[listener and authority mounting](https://github.com/NousResearch/hermes-agent/blob/4a0eaf7989b6804319ddb94fa5d96c5a716080a1/gateway/run_api.py).

Botto selects the authority or older sidecar protocol from the handshake, rather
than assuming a version number proves compatibility. The inspected boundaries
are authority Hermes `4a0eaf7` and sidecar Hermes `ca67828` / 0.21.5. Known versions
older than 0.21.5 are refused. These pins identify inspected contracts, not a
claim that every newer Hermes build is compatible. See the
[core integration](core-integration.md) for full revisions and limits.

## 3. Keep Hermes authentication and identity stable

Keep the host's existing Nous/OIDC provider if configured. Botto's **Continue in
browser** uses Hermes native sign-in when the host advertises `native_pkce`.
For a trusted-network or VPN password setup, the official basic provider reads
these settings in the active Hermes `config.yaml`:

```yaml
dashboard:
  public_url: "https://hermes.example.com"
  basic_auth:
    username: "your-username"
    password_hash: "PASTE-YOUR-GENERATED-HASH"
    secret: "PASTE-YOUR-PERSISTENT-RANDOM-SIGNING-SECRET"
```

Merge these keys into the existing configuration. Generate a password hash using
the Python environment of your Hermes installation; this prompts locally:

```sh
python -c 'from getpass import getpass; from plugins.dashboard_auth.basic import hash_password; print(hash_password(getpass("Hermes password: ")))'
python -c 'import secrets; print(secrets.token_hex(32))'
```

Put the first result in `password_hash` and the second in `secret`. Generate the
signing secret once and preserve it across restarts. Protect the config file and
do not put these values in this repository or a QR. Environment overrides include
`HERMES_DASHBOARD_BASIC_AUTH_USERNAME`, `_PASSWORD_HASH`, and `_SECRET` (with the
same `HERMES_DASHBOARD_BASIC_AUTH` prefix). A configured `_PASSWORD` overrides
the hash, so remove a stale override when rotating credentials. Upstream recommends
Nous/OIDC for internet-facing hosts and basic auth for trusted networks/VPNs.
[Official authentication configuration](https://github.com/NousResearch/hermes-agent/blob/4a0eaf7989b6804319ddb94fa5d96c5a716080a1/website/docs/user-guide/features/web-dashboard.md#usernamepassword-provider-no-oauth-idp).

Set `dashboard.public_url` to the exact external HTTPS origin entered in Botto.
Hermes checks the host/origin boundary even when a tunnel reaches a loopback
listener. Apply config changes through your existing service manager during a
safe restart. Preserve the Hermes root's `install_id` file as well as its config
and data when moving the installation; Botto uses that identity to detect a changed
host. [Origin boundary](https://github.com/NousResearch/hermes-agent/blob/4a0eaf7989b6804319ddb94fa5d96c5a716080a1/hermes_cli/web_server_boundary.py),
[installation identity](https://github.com/NousResearch/hermes-agent/blob/4a0eaf7989b6804319ddb94fa5d96c5a716080a1/hermes_cli/install_identity.py).

## 4. Make the origin reachable

An existing HTTPS endpoint over your VPN or private network is the shortest
path. The phone must join that network. `127.0.0.1` on a physical phone means the
phone itself, not your Mac. Use the host's reachable name or address.

For Cloudflare Tunnel, run `cloudflared` on the Hermes host and create a published
application route for a hostname you control, such as `hermes.example.com`.
Set its service URL to the **existing native listener**, for example
`http://127.0.0.1:9119` for standalone serve, or the port reported by the gateway.
Leave the route path empty. The phone uses `https://hermes.example.com`; loopback
HTTP is only the local tunnel-to-Hermes leg. Follow Cloudflare's
[official tunnel setup](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/get-started/create-remote-tunnel/).

Allow WSS upgrades to `/api/ws`. Any intermediate proxy must preserve the upgrade
and `Sec-WebSocket-Protocol` headers: Hermes authenticates the upgrade using a
single-use ticket carried in a subprotocol. Do not rewrite API paths or redirect
native requests to a different origin. Cloudflare supports proxied WebSockets;
check the zone's WebSockets setting if upgrades fail.
[Cloudflare WebSockets](https://developers.cloudflare.com/network/websockets/),
[Hermes upgrade contract](https://github.com/NousResearch/hermes-agent/blob/4a0eaf7989b6804319ddb94fa5d96c5a716080a1/hermes_cli/web_server_chat.py).

### Optional Cloudflare Access

Keep Hermes authentication enabled behind Access. Access controls entry to the
origin; Hermes still signs you in to your bots.

Create an Access service token and add a **Service Auth** policy that includes
that token for the application. In Botto's reviewed connection form, expand
**Advanced connection** and enter both the Cloudflare Access client ID and
client secret. Botto sends `CF-Access-Client-Id` and `CF-Access-Client-Secret` on
native requests, including the WebSocket upgrade. Keep both values separate from
the Hermes username/password or browser login.
[Cloudflare's agent authentication guide](https://developers.cloudflare.com/cloudflare-one/access-controls/authenticate-agents/),
[service-token lifecycle](https://developers.cloudflare.com/cloudflare-one/access-controls/service-credentials/service-tokens/).

The system authentication browser cannot attach those service-token headers.
For **Continue in browser**, the Access application also needs an interactive
login policy for your user. A service-token-only policy can let Botto's native
requests through while blocking the browser. Alternatively use password sign-in
on a suitably protected host, or a direct private origin where native browser
sign-in is reachable. Passing Access alone never creates a Hermes session.

No live Cloudflare tunnel or Access policy was configured or tested for this
setup guide.

## 5. Ask Hermes to help, or use an address

In Botto, choose **Connect your Hermes**, then **Copy prompt** or **Share**.
Send the text in the chat where you already use Hermes. **Preview prompt** opens the
complete instructions in a bottom sheet. Expand it to read more, then swipe down
to close it.

The prompt asks Hermes to inspect and reuse its existing native listener,
authentication, and network route. It asks before changing the host, with one
narrow exception: a QR-only dependency may be installed in a temporary isolated
environment. Once the origin is ready, Hermes must generate and deliver a QR
image, a phone-reachable HTTPS origin, and an **Open Botto** link. A missing QR
command calls for another local method. If generation or delivery fails, Hermes
reports the attempted methods and exact blocker alongside the address fallback.
It keeps credentials out of the reply and QR. The bundled
[versioned prompt](../App/Pairing/HermesSetupPrompt.swift) is the source of truth;
no downloaded installer or separate setup account is needed.

On the same phone, open the returned link or paste the origin. From another
screen, scan the QR; a QR image can also be imported. Some chat apps do not open
custom-scheme links, so keep the plain origin as a fallback. Join any network or
VPN Hermes identifies. Host-side checks cannot prove phone reachability or a
working Botto session; finish the sign-in and bot-message check below.

If your server is already prepared, use **Server address or connection code**
at the top of the screen.

1. Enter the origin, paste a connection code, or use
   **Scan connection QR**. The scanner also supports an image containing a QR
   and manual entry when a camera is unavailable or permission is denied.
2. Choose **Review destination** and check the displayed scheme, host, and port.
   Scanning or opening a link does not connect or replace saved credentials.
3. Enter your Hermes username/password and choose **Connect**, or choose
   **Continue in browser** for an advertised native provider. Add optional Access
   credentials under **Advanced connection** before either action.
4. Open a bot from the roster, or create one with a name, face, and short job.
   Send a message and wait for its reply. The host must have its model and tools
   configured; Botto uses the host's model defaults.

Supported non-secret address payloads:

```text
https://hermes.example.com
hermes://connect?url=https%3A%2F%2Fhermes.example.com
botto://hermes/connect?url=https%3A%2F%2Fhermes.example.com
```

Use plain HTTPS or the `hermes://connect` form inside Botto's scanner/paste flow.
Use Botto's `botto://hermes/connect` link for external app handoff. Botto does not claim
the generic `hermes` scheme for system routing. A code contains only the origin:
no password, service credential, session token, or webhook token. There is no
secret URL to redeem. [Pairing contract](pairing-integration.md).

Generate a payload locally with Python's standard library. Replace only the
example origin:

```sh
python3 - <<'PY' > /tmp/botto-connection.txt
import sys
from urllib.parse import urlencode
origin = "https://hermes.example.com"
sys.stdout.write("hermes://connect?" + urlencode({"url": origin}))
PY
cat /tmp/botto-connection.txt
```

Paste that text into Botto. If `qrencode` is already installed, display it as a QR:

```sh
qrencode -t ANSIUTF8 < /tmp/botto-connection.txt
# Or save an image for Botto's image importer:
qrencode -o /tmp/botto-connection.png < /tmp/botto-connection.txt
```

Python generates the URL payload, not QR pixels. Neither command configures a
host or grants access. No downloaded host helper is needed. The address code
does not expire; sign-in credentials and authorization attempts can expire.

For local development only, **Trusted local network → Allow an HTTP connection**
permits a private/local HTTP origin. HTTP carries sign-in and chat without TLS;
use it only on a network you trust. Botto does not accept public HTTP or silently
downgrade HTTPS.

## Recover a connection

- **Unreachable:** check the phone's VPN/network, external DNS/TLS, and tunnel
  target. Recheck the gateway's actual listener port after a restart.
- **Access login page, 401, or 403:** check both Access fields, the token's expiry,
  and its Service Auth policy. Renew or rotate the token in Cloudflare, then
  re-enter both current values in Settings → Connection details. If only the
  browser fails, allow interactive Access login for that browser leg.
- **Hermes login expired or password changed:** open Settings → Connection
  details and sign in again. Restart an expired browser attempt from Botto. Keep
  the host's signing secret stable to avoid invalidating sessions on restart.
- **Host identity changed:** verify DNS, tunnel target, and any server migration
  before signing in. Restore the original installation data if the change was
  accidental. For an intentional replacement, use Settings → Forget this
  connection, then review and sign in to the replacement. Forget removes local
  credentials, cached conversations, and drafts; copy any needed draft first.
- **Sign-in works but chat fails:** check the native listener and WebSocket
  forwarding, then consult the [protocol boundary](core-integration.md).
  A reachable status page alone does not prove a usable Bots connection.
- **Connection dropped while sending:** reconnect and inspect the conversation
  before sending again; an unacknowledged message may already have reached Hermes.

Offline history is for reading. Sending, uploads, and approval responses require
a live connection. Text drafts stay local; reattach uploads after restarting the
app. Closing Botto disconnects its client; the running host owns ongoing work.

## Developer checks and evidence limits

From the checkout root:

```sh
swift test
./scripts/check.sh
```

The script repeats the core checks and runs app tests on an available iPhone
Simulator. For the isolated real-Hermes host with a deterministic local model,
see [dev-host.md](dev-host.md) and `scripts/dev-host/`; it is separate from both
the in-app demo and your production server.

Host instructions were checked against official Hermes source at the revisions
in [core integration](core-integration.md) and official Cloudflare docs
on 2026-10-23. This guide does not claim a live remote connection, tunnel, device
sign-in, or distribution check. Runtime verification belongs to the delivery's
verification record.
