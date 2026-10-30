# Third-party notices

Botto adapts native Hermes connection, gateway, profile creation, request parsing,
transcript reconciliation, attachment preparation, shared avatar geometry, appearance,
asset loading and sparse face motion algorithms from
[Hermex](https://github.com/uzairansaruzi/hermex), revision
`47809f2cd1f07bcbe592ee8960cf9c63e88b734c` (2026-10-22).

Copyright (c) 2026 Uzair Ansar. Licensed under the MIT License. The complete
notice and disclaimer are in [LICENSES/Hermex.txt](LICENSES/Hermex.txt).

Artifact downloads, native Quick Look presentation, temporary-file lifetime, and
ordered transcript file references also adapt Hermex's `HermesREST.swift`,
`QuickLookFilePreview.swift`, `TranscriptMedia.swift`, `FileReference.swift`,
`BotArtifact.swift`, and `BotArtifactPreview.swift`. These were inspected at the
revision above and `1a12ab2b90d7459c96c45598936b671af412c04f`. The same MIT notice applies.

Adapted source areas:

- `HermesMobile/Networking/Bots/BotProtocol.swift`: JSON payload representation.
- `Networking/Hermes/HermesConnection.swift`, `HermesGateway.swift`,
  `HermesREST.swift`, `HermesCall.swift`: direct authentication, ticket upgrade,
  request multiplexing, heartbeat and sidecar request contracts.
- `Features/Bots/BotCreator.swift`, `BotPendingRequest.swift`: canonical profile
  creation, exact request identities and host-offered approval choices.
- `Features/Hermes/HermesConversation.swift`,
  `Features/Chat/HermesChatTurnCoordinator.swift`, `HermesTranscriptHistory.swift`:
  scoped events, replay recovery and durable transcript reconciliation.
- `Networking/Bots/BotAttachmentUpload.swift`: image preparation, host path
  validation and one-prompt attachment reference rules.
- `Models/MessageAttachment.swift` and `HermesMobileTests/HermesChatAttachmentTests.swift`:
  read-only transcript reference extraction, display names and presentation fixtures.
- `Features/Bots/BotProfileAppearance.swift`: shared eight-shape paths, palette,
  profile-ID defaults, adaptive color contrast and static eye rendering.
- `Features/Bots/BotAvatarStore.swift`: bounded thumbnails and the desktop face-copy rule.
- `Features/Bots/BotProfileEditor.swift`: merge/CAS and explicit image-clear contracts.
- `Features/Bots/BotFaceMotion.swift`: seeded blink edges, bounded working poses,
  schedules and turn-owned beat lifetime. Interactive hero gestures were not copied.

Botto's corresponding files are under `Sources/BottoCore`, `App/Design`, and
`App/State`. No Hermex branding, plugins or third-party Swift packages were copied.

The sixteen rest-expression eye geometries adapted through Hermex derive from
[Bloub](https://github.com/jeremy-prt/bloub), by Jérémy Perret. Copyright (c) 2026
Jérémy Perret. The complete MIT license is bundled in [LICENSES/Bloub.txt](LICENSES/Bloub.txt),
verified against upstream revision `b4bb3c1b5f93c7b87a2e8d620f667c4093d97749`.
Botto does not include Bloub's interactive hero repertoire or assets.

Shared classic avatar identity and preset values follow Hermes Desktop's
`apps/desktop/src/plugins/hermes-bots/avatar.tsx` and
`apps/desktop/src/lib/profile-color.ts` at Hermes Agent revision
`4a0eaf7989b6804319ddb94fa5d96c5a716080a1`.

Generated avatar identity adapts seed normalization, trait hashing, shape-band
selection, and color conversion from [Blobatar](https://github.com/Alain00/blobatar),
package version **2.0.0**, copyright (c) 2026 Alain, under the MIT License.
The full license is bundled in [LICENSES/Blobatar.txt](LICENSES/Blobatar.txt).
Botto draws its own face and body rather than bundling Blobatar's renderer.

`Tests/BottoCoreTests/Fixtures/HermesAgent` contains sanitized captured fixtures
copied from Hermex, retaining its manifest and embedded capture revisions:
Hermes Agent `ca6782850432927f33df4775cb6dd45bb51460d2`, version 0.21.5.
The fixture license is the same MIT notice above.

Inline Mermaid diagrams use the bundled official **Pele 1.9.0** distribution,
upstream commit `e7f092a4de147cc32210913c20e36eaa5fcd0ef1`.
[Pele](https://github.com/obsidianmd/pele) is copyright (c) 2026 kepano, under
the MIT license. Its distributed notice also includes the ISC license for
Lucide's `rotate-ccw` icon. The complete notice is in
[LICENSES/Pele.txt](LICENSES/Pele.txt) and Settings → Open-source licenses.
The bundled `pele-provenance.json` records package integrity, source pins,
checksums, and the controlled render options. No diagram scripts, fonts, or
assets download at runtime.

`Tests/BottoCoreTests/Fixtures/AuthorityContract` contains Botto-authored synthetic
examples of the official Hermes authority contract inspected at
`4a0eaf7989b6804319ddb94fa5d96c5a716080a1`. Its manifest explicitly distinguishes
these examples from captured host traffic. The authority adapter is an original
Swift implementation of the documented JSON contract; no Python source was copied.

`Tests/BottoCoreTests/Fixtures/AuthorityCaptured` contains traffic captured by Botto
against the real gateway at that same official revision, with a deterministic
local model. Its manifest records the revision, capture date and removed fields.
These captures include durable history, streaming, tool execution and approval
recovery. They contain no authentication responses, cookies or WebSocket tickets.

The proposed native-session observer and explicit-profile installer patch in
`Push/upstream` modifies official Hermes Agent source at revision
`fcc26fbd9f1641755e49793d7ed608f3b7214c3d`. Its upstream MIT notice, copyright
(c) 2025 Nous Research, is preserved in
[Push/upstream/LICENSE](Push/upstream/LICENSE). The patch is a development
prerequisite for optional notifications, not a released Hermes capability.

Botto's push plugin and relay retain their existing MIT notices in
[Push/plugin/LICENSE](Push/plugin/LICENSE) and
[Push/relay/LICENSE](Push/relay/LICENSE). Historical project names in copyright
notices identify the original authorship and are preserved.
