# Botto verification map

Use these recipes to verify the T3 workspace and iOS demo. A recipe is draft
until its assertions run on the recorded target and revision. The
[verification record](../../verification.md) lists the checks actually observed.

## Capability inventory

| Feature | Recipe | Workflows |
| --- | --- | --- |
| Start | [Welcome and first run](features/start.md) | `start.first-run`, `start.demo`, `start.pair`, `start.address`, `start.qr`, `start.external` |
| Pairing | [Pairing and reconnection](features/auth.md) | `auth.access`, `auth.interruption`, `auth.recovery` |
| Space navigation | [Spaces drawer](features/inbox.md) | `inbox.find`, `inbox.activity`, `inbox.pins`, `inbox.navigation` |
| Library | [Workspace files and search](features/library.md) | `library.navigation`, `library.outputs`, `library.search`, `library.captures` |
| Spaces | [Main Space and permanent Spaces](features/chats.md) | `chats.choose`, `chats.isolation`, `chats.recovery` |
| Conversation | [Send, draft, and read](features/chat.md) | `chat.send`, `chat.drafts`, `chat.history`, `chat.reading-position` |
| Requests | [Answer and stop work](features/requests.md) | `requests.approval`, `requests.question`, `requests.recovery`, `requests.stop` |
| Bot | [Set up and inspect the companion](features/bots.md) | `bots.create`, `bots.interruption`, `bots.profile` |
| Avatars | [Choose a face and observe motion](features/avatars.md) | `avatars.edit`, `avatars.identity`, `avatars.motion`, `avatars.containment` |
| Uploads | [Attach files and photos](features/uploads.md) | `uploads.file`, `uploads.photo`, `uploads.paste`, `uploads.sent`, `uploads.budget`, `uploads.retirement` |
| Rich replies | [Read interactive replies and diagrams](features/rich.md) | `rich.read`, `rich.source-expand`, `rich.zoom`, `rich.boundaries`, `rich.scroll-lifetime`, `rich.cache` |
| Artifacts | [Preview, save, and share files](features/artifacts.md) | `artifacts.preview`, `artifacts.save`, `artifacts.share`, `artifacts.recovery`, `artifacts.retirement` |
| Settings | [Settings and local data](features/settings.md) | `settings.appearance`, `settings.developer`, `settings.about`, `settings.forget`, `settings.storage-recovery` |
| Haptics | [Choose haptics and feel feedback](features/haptics.md) | `haptics.preferences`, `haptics.chat`, `haptics.sheets`, `haptics.playground` |
| Notifications | [Encrypted push verification](features/notifications.md) | `notifications.setup`, `notifications.delivery`, `notifications.previews`, `notifications.routing`, `notifications.visibility`, `notifications.removal`, `notifications.recovery` |

Use stable workflow and assertion IDs in the evidence. An assertion ID appends
`.a1`, `.a2`, and so on to its workflow ID. Record
each selected assertion with the expected result,
observed result, and evidence. Use `passed`, `failed`, `blocked`, or
`untested`. A workflow passes after all its required assertions pass.

## Shared setup and readiness

- Use the checked-in project, **Botto** for iOS/iPadOS 18+ and **BottoMac** for
  macOS 15+. Record the revision, build, signing, platform, and launch arguments.
  Run the tests in the [local checks](../../local-checks.md) on an owned target.
- Use a fresh simulator or app profile for first-run checks. Preserve existing
  accounts, state, Keychain entries, and unrelated simulator sessions.
- On iOS choose **Explore the demo** for sample Spaces, or use the DEBUG
  `--demo` launch option. Demo exercises the client with in-memory sample
  state. A hosted test or demo run does not establish live-host persistence.
- Verify normal BottoMac first run in a dedicated macOS test account. A normal
  launch starts its server in that account's `~/.botto/t3-server`. Use an
  isolated account with a test provider so setup can create its own workspace.
- For iOS-only host checks, run a separate owned T3 instance using an explicit
  disposable data directory and project. Follow [setup](../../setup.md) to
  review the origin and connect. Open an actual Space and record the route
  and redacted environment identity.
- Use a signed device build when proving secure credential storage, physical
  QR scanning, or APNs. Use the Mac's reachable address for a physical phone.
  Test LAN, Tailscale, and an HTTPS tunnel as separate routes.

## Credentials, state, and proof

Keep tokens, tickets, pairing links, and private conversation data out of proof.
Use run-owned Spaces and files with unique names. Use 10 seconds for local
navigation, 15 seconds for local file preview, and a declared deadline for
a live host operation. Preserve the first unexpected result before retrying.

For durable claims, relaunch or refetch through a fresh client. For file export,
read the bytes independently from Files. For interrupted writes, inspect the
original Space before sending again. Use the same selected Space identity for
every readback.

Record target, revision, steps, and results. Retain logs or captures separately
from disposable state, then stop only the owned host or simulator. See the
[verification record](../../verification.md) for known limits.
