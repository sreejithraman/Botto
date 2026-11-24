# Pairing integration

The Mac's **Pair Phone…** window requests a new pairing link from its local
T3 Code process and uses the selected route's origin. LAN and Tailscale
typically use HTTP on a trusted network. Public routes use HTTPS and forward
traffic to the same T3 host.

## Review and exchange

The iOS app accepts a T3 pairing link from its scanner, paste field, or
`t3code://pair` deep link. It extracts the origin and credential, then renders
a destination review. HTTP requires explicit consent and a local address.
The pairing link is short-lived and single-use.

[T3PairingExchange](../Sources/BottoCore/Pairing/T3PairingExchange.swift) probes
the host and exchanges the credential at the reviewed origin. Requests reject
redirects. Keep credentials, access tokens, and ticket values out of screenshots
and logs. Use a fresh link to retry after expiration, consumption, or a change
of route.

## Connection and storage

The saved pairing holds the origin, access token, and expected environment.
The service verifies environment identity and mints a short-lived WebSocket
ticket before opening its T3 RPC connection. The iOS app stores the pairing
in Keychain. Demo uses a separate sample workspace. A new pairing can be tried
from Settings. Use a signed build for physical-device credential storage proof.

See [setup](setup.md), the [pairing tests](../Tests/BottoCoreTests/T3/T3PairingTests.swift),
and the [verification map](agents/verification/index.md#shared-setup-and-readiness).
