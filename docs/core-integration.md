# BottoCore integration

BottoMac and iOS share the Swift package in [Sources/BottoCore](../Sources/BottoCore/).
Both use [T3BotService](../Sources/BottoCore/T3/T3BotService.swift) with a paired
origin and environment. iOS also has an in-memory demo. The app depends on
the shared [conversation service contracts](../Sources/BottoCore/Domain.swift)
for history, active access, mutations, file reads, and presentation.

## Transport and projection

[T3PairingExchange](../Sources/BottoCore/Pairing/T3PairingExchange.swift) probes
the origin, exchanges a short-lived pairing credential, and mints a WebSocket
ticket. [T3RPCClient](../Sources/BottoCore/T3/T3RPCClient.swift) encodes requests
and consumes unary replies and streams. The shared JSON value retains unknown
fields for forward-compatible decoding. [T3ProjectionMapper](../Sources/BottoCore/T3/T3ProjectionMapper.swift)
projects shell and thread events into Space summaries and conversation updates.

## Workspace and Space identity

A connected bot has a T3 project and a workspace folder with `bot.json`,
`SOUL.md`, `MEMORY.md`, `skills/`, and `outputs/`. The Main Space is the
thread referenced by `bot.json`. Other Spaces are durable threads in the same
project. Their visible titles can change without changing their identities.
See [the Space decision](adr/0014-one-companion-auto-titled-chats.md) for creation,
restoration, and the static prompt contract.

Pairing is scoped to an origin and T3 environment. The service resolves thread
identity within that environment and project. The selected conversation owns
a revocable [access grant](../Sources/BottoCore/ConversationContracts.swift)
for sending, answering requests, uploading, and reading files. Changing selection
or connection retires that grant. Durable history and local presentation state
do not confer mutation access.

## Files and history

T3 is the source of thread history. Botto projects visible rows and retains
the conversation identity through pagination. File cards distinguish references
from delivered outputs. A live fetch uses the owning Space and T3's signed asset
endpoint. Keep local captures associated with the source occurrence and its
revision. See [rich replies and files](rich-content.md) and
[scoped artifact captures](adr/0010-scoped-artifact-captures.md).

## Live avatar activity

Native views derive work cues and reactions from the active Space's projection.
Keep the idle, in-progress, and action-needed presentation distinct. Avatar
assets share a preset catalog and renderer. See [avatars](avatars.md#refresh-and-motion)
and [haptics](haptics.md).

## Contributor checks

Run `swift test --filter T3` for T3 transport, pairing, projection, and service
fixtures. Run `swift test --no-parallel` for the complete package. Use the
[verification map](agents/verification/index.md) for the app entry points and
the [verification record](verification.md) for observed results.
