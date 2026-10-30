# Pairing integration

Pairing passes a server address into a review form. It performs no networking and
never replaces an existing configuration. Only a user action on the reviewed form
starts authentication. Use the native Hermes backend (`hermes serve`); no WebUI,
adapter, relay, or QR redemption endpoint is required.

Decision rationale: [address-only pairing](adr/0006-address-only-pairing.md).

## Address and scanner

`PairingAddress.parse(_:allowInsecureHTTP:)` accepts an HTTPS origin, HQ's exact
`hermes://connect?url=…` scanner/import format, and Botto's
`botto://hermes/connect?url=…` external format. It decodes the destination once,
normalizes the host and root slash, and rejects paths, credentials, queries,
fragments, duplicate/unknown wrapper fields, malformed escapes, and inputs over
4 KiB. Enter IDNA hostnames in their ASCII form.

Present `PairingScannerView { text in … }`. Its callback fires once across camera,
paste, manual entry, and photo import. The parent dismisses it, parses the text,
and fills a pending form. Show scheme, host, and port before any connection.
Keep saved credentials separate from the pending address. Never log raw input.

External `onOpenURL` handling must accept only the `botto` scheme and then call the
same parser. Do not register or externally route HQ's generic `hermes` scheme.
Ignore `botto-signin://done` in the pairing importer: it belongs to an active
authentication session and conveys no authorization itself.

Default `allowInsecureHTTP` to `false`. Set it only from a visible trusted local
network choice. Both the parser and core reject public HTTP origins. Do not
infer consent from a hostname or retry a failed HTTPS request over HTTP.

The simulator and unsupported devices expose paste/manual/photo paths. Camera
denial exposes those paths plus a Settings button. Photo import uses the system
Photos picker and Vision QR recognition; it requests no full photo-library access.

## Browser sign-in

Call from the reviewed form's cancellable task:

```swift
let configuration = try await BrowserSignIn.authenticate(
    serverURL: reviewedURL,
    connectionHeaders: accessHeaders
)
```

Cancel that task when the form goes away or its destination changes. Keep one
attempt per form. The attempt has a 180-second total deadline, an ephemeral
loopback listener bound only to `127.0.0.1`, at most four sockets, and a five-second
socket deadline. Completion, failure, timeout, and cancellation close its resources.

Before opening the system browser it probes `/api/status` and
`/api/auth/providers`, requires `native_pkce`, and captures `install_id` when public. It
generates fresh random state/verifier, uses S256, and asks Hermes to return to
`http://127.0.0.1:<ephemeral-port>/callback`. The receiver accepts one matching GET
with one code/state pair and the expected Host header. It bounces to
`botto-signin://done` to close `ASWebAuthenticationSession`. Wrong state, unknown or
duplicate fields, other paths/methods, malformed requests, and replay are refused.

The native exchange rechecks any public `install_id` before redeeming, POSTs JSON to the
same origin's `/auth/native/token`, and checks `/api/auth/me` using the transient
access token. When the signed-out response hides identity, it reads authenticated
`/api/status` with that token and requires a nonempty installation ID, matching
any ID observed during the attempt. It rejects every native HTTP redirect,
including same-origin ones. See [the identity decision](adr/0008-authenticated-installation-identity.md).
It returns `ConnectionConfiguration` with the install ID, user ID, refresh token,
provider, Access headers, and an empty password. It does not persist or return the
access token. The app owns Keychain storage, connection testing, and save actions;
the core owns refresh and saving each rotated refresh token before using it.

## Cloudflare

Use the tunnel's final HTTPS origin. Native probes, token redemption, and identity
requests carry only the validated `CF-Access-Client-Id` and
`CF-Access-Client-Secret` connection headers. Store these with the connection's
secrets, outside QR payloads. Unknown headers, header injection, and duplicate names
with different casing are rejected.

The system authentication browser cannot attach these service-token headers.
An Access application protected only by service tokens can pass native probes and
still block the browser. Its owner must allow an interactive Access login for the
browser, or use a reachable origin with a suitable browser policy. A redirected
native probe fails explicitly; Botto does not forward credentials to Access login
or another origin. Ephemeral browser sessions may require signing into Access
again. Neither tunnel setup nor Access policy changes are part of pairing.

## Parent-owned project settings

- Include all `App/Pairing/*.swift` in the iOS target and link `BottoCore`.
- Register `botto` and `botto-signin` under `CFBundleURLTypes` / `CFBundleURLSchemes`.
  The authentication session watches `botto-signin` itself; ordinary app URL routing
  must not redeem a completion URL.
- Set `NSCameraUsageDescription`, for example: “Scan a Hermes server connection
  code to fill the address for review.”
- For LAN hosts, supply `NSLocalNetworkUsageDescription` and verify the prompt on
  a phone. Explicit local HTTP also needs an appropriate ATS configuration. Keep
  HTTPS as the default; choose the narrowest applicable local-network exception.
- Retain `LICENSES/Hermex.txt` in the distributed app's notices. Browser/loopback
  flow attribution is present in the adapted source headers.

## Verification

`swift test --filter pairing` covers the exact upstream HQ fixtures, Botto/plain
origin parity, invalid inputs, HTTP consent, callback validation, capability
probes, install changes, expired codes, identity mismatch, origin pinning, header
handling, task cancellation, one-use redemption, and explicit exchange cleanup
with scripted HTTP. The S256 request uses the known vector from
[RFC 7636 Appendix B](https://www.rfc-editor.org/rfc/rfc7636.html#appendix-B).

Physical camera scanning, permission prompts, VoiceOver, a real Photos import,
live browser/loopback handoff, iOS suspension, the 180-second UI timeout, and real
Access policy behavior need device verification. Cold/warm external-link routing,
Xcode compilation, Keychain persistence/rotation, and a live Hermes connection
through `gateway.ready` and chat require their own checks. Scripted HTTP checks
do not establish live sign-in.
