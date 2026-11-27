# Pairing integration

The Mac's **Pair Phone…** window requests a new pairing link from its local
T3 Code process and puts every available route in its code: LAN, then
Tailscale, then a saved HTTPS tunnel. The first available route is the primary
one that older phone builds pair with. The window lists each route, marks the
ones in the code while a code is shown, and says why any other is unavailable. LAN and Tailscale
typically use HTTP on a trusted network. Public routes use HTTPS and forward
traffic to the same T3 host.

## Review and exchange

The iOS app accepts a T3 pairing link from its scanner, paste field, or
`t3code://pair` deep link. It extracts the credential and every route, then
renders a destination review that lists them. The link's own origin is the
primary route; [further routes](../Sources/BottoCore/Pairing/PairingRoutes.swift)
ride beside the credential in its fragment, where older builds ignore them.
Each route must pass the pairing address rule: HTTP requires a local network or
Tailscale address and explicit consent, which covers exactly the HTTP routes
shown. A route that fails is dropped. The pairing link is short-lived and
single-use.

[T3PairingExchange](../Sources/BottoCore/Pairing/T3PairingExchange.swift) probes
each allowed route, HTTPS routes first, and exchanges the credential once, at
the first one that answers. T3 accepts the credential and the resulting token at
any of the Mac's addresses, so one pairing serves them all. Only an exchange
that couldn't be sent moves on to the next route. Once the exchange was sent,
only a usable token or T3's own refusal of the credential (401 with its
`auth_invalid` body) has a known outcome. Anything else, such as a timeout, a
relay's error, a 500, a token Botto can't use, or the app going to the
background mid-exchange, means the code may already be spent. During a running
app session a code counts as sent from before the exchange until the exchange shows it
never left the phone, and Connect stays off until a cancelled exchange settles.
A spent or refused code leaves the review and the form, in every case: after
an ambiguous reply, a refusal, a cancelled exchange, or Change address after a
failed connection. Entered again, it isn't sent, and the phone asks for a fresh
link. Across launches, T3 enforces the code's single-use limit. A link with
more routes than Botto accepts is refused at review with its own message. Requests reject
redirects. Keep credentials, access tokens, and ticket values out of screenshots
and logs. Use a fresh link to retry after expiration, consumption, or a change
of route.

## Connection and storage

The saved pairing holds its routes, the route that last worked, the access
token, and the expected environment. Setups saved with one route connect as
before. Each connection tries every HTTPS route before any plain HTTP one, so
the token isn't sent over HTTP while a secure route answers. Within each group
the route that last worked comes first, then the rest in pairing order (the Mac
lists LAN, Tailscale, then its HTTPS tunnel). Each route's probe has an idle
limit: 15 seconds for HTTPS, which may relay through another service, 5 seconds
for a direct LAN or Tailscale address, and the usual 30 seconds for the last
route. The service verifies environment identity before it sends the token. A
route that answers but can't mint a WebSocket ticket, open the T3 RPC
connection, return a `server.getConfig` naming the same environment, or list
its projects counts as failed, and the next route is tried before anything in
the workspace is written. That includes a relay's own 401 or 403. Only T3's own
refusal of the token (401 with its `auth_invalid` body) ends the search. When
no route connects, the error names each route tried and what happened there.

A re-pairing keeps the saved setup's ID, history and file cache when a route
already saved for that setup confirms the same environment, project and
workspace. It connects only through routes approved in the new review. If
the old primary was left out, the app keeps its exact address as part of the
local file-cache key. When only a new route can confirm the workspace, the
app connects as a new setup with its own ID and fresh history.

The current history may be saved before Keychain is updated, just as it is
during regular use. A re-pair to a different workspace prepares the new
history under a separate ID before saving credentials and only prunes the
old setup after that save succeeds. The iOS app stores the pairing in
Keychain. Demo uses a separate sample workspace. A new pairing can be tried
from Settings. Use a signed build for physical-device credential storage proof.

See [setup](setup.md), the [pairing tests](../Tests/BottoCoreTests/T3/T3PairingTests.swift),
and the [verification map](agents/verification/index.md#shared-setup-and-readiness).
