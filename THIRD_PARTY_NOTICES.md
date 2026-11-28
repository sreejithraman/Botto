# Third-party notices

Botto adapts request parsing, transcript reconciliation, attachment preparation,
shared avatar identity and appearance rules from
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
- `Features/Bots/BotPendingRequest.swift`: exact request identities and
  host-offered approval choices.
- `Features/Hermes/HermesConversation.swift`,
  `Features/Chat/HermesChatTurnCoordinator.swift`, `HermesTranscriptHistory.swift`:
  scoped events, replay recovery and durable transcript reconciliation.
- `Networking/Bots/BotAttachmentUpload.swift`: image preparation, host path
  validation and one-prompt attachment reference rules.
- `Models/MessageAttachment.swift` and `HermesMobileTests/HermesChatAttachmentTests.swift`:
  read-only transcript reference extraction, display names and presentation fixtures.
- `Features/Bots/BotProfileAppearance.swift`: shared palette, profile-ID defaults and adaptive color contrast.
- `Features/Bots/BotProfileEditor.swift`: merge/CAS and explicit image-clear contracts.

Botto's corresponding files are under `Sources/BottoCore`, `App/Design`, `App/State`,
`App/Views`, `App/Resources` and `Mac/Views`. No Hermex branding, plugins or third-party Swift packages were copied.

The sixteen stored expression names retain compatibility with earlier Botto
versions. The former eye geometries derived through Hermex from
[Bloub](https://github.com/jeremy-prt/bloub), by Jérémy Perret, are no longer used
by the renderer. Its historical MIT notice remains bundled in
[LICENSES/Bloub.txt](LICENSES/Bloub.txt), copyright (c) 2026 Jérémy Perret,
upstream revision `b4bb3c1b5f93c7b87a2e8d620f667c4093d97749`.

Shared classic avatar identity and preset values follow Hermes Desktop's
`apps/desktop/src/plugins/hermes-bots/avatar.tsx` and
`apps/desktop/src/lib/profile-color.ts` at Hermes Agent revision
`4a0eaf7989b6804319ddb94fa5d96c5a716080a1`.

Generated avatar identity adapts seed normalization, trait hashing, shape-band
selection, and color conversion from [Blobatar](https://github.com/Alain00/blobatar),
package version **2.0.0**, copyright (c) 2026 Alain, under the MIT License.
The full license is bundled in [LICENSES/Blobatar.txt](LICENSES/Blobatar.txt).
Botto draws its own face and body rather than bundling Blobatar's renderer.

All premade and custom drawn faces use [Open Bot Avatar](https://github.com/DominikScholz/open-bot-avatar)
v1, copyright (c) 2026 Dominik Scholz, revision
`3a5119877844165eebafe57d3100da475f67d0a8`. Botto vendors its DOM-free validator,
path/contour/volume code, motion, animator and renderer frame generation.
JavaScriptCore executes the local bundle; a native Canvas
paints the canonical frames with Botto's palette and status adaptations.
The complete MIT notice is bundled in [LICENSES/OpenBotAvatar.txt](LICENSES/OpenBotAvatar.txt)
and retained in [scripts/avatar-engine/upstream/LICENSE](scripts/avatar-engine/upstream/LICENSE).
[UPSTREAM.json](scripts/avatar-engine/UPSTREAM.json) records source hashes and the
pinned build tool. [build.py](scripts/avatar-engine/build.py) reproducibly builds
the engine bundle and canonical resting previews. No engine code downloads at runtime.

Inline Mermaid diagrams use the bundled official **Pele 1.9.0** distribution,
upstream commit `e7f092a4de147cc32210913c20e36eaa5fcd0ef1`.
[Pele](https://github.com/obsidianmd/pele) is copyright (c) 2026 kepano, under
the MIT license. Its distributed notice also includes the ISC license for
Lucide's `rotate-ccw` icon. The complete notice is in
[LICENSES/Pele.txt](LICENSES/Pele.txt) and Settings → Open-source licenses.
The bundled `pele-provenance.json` records package integrity, source pins,
checksums, and the controlled render options. No diagram scripts, fonts, or
assets download at runtime.

Botto's push relay retains its [MIT notice](Push/relay/LICENSE). Historical
project names in copyright notices identify the original authorship.

The macOS app uses [Sparkle](https://sparkle-project.org/) **2.9.6** for
signed in-app updates, licensed under the MIT License. The full notice is in
[LICENSES/Sparkle.txt](LICENSES/Sparkle.txt).
