---
status: accepted
---

# Store custom drawn faces as shape recipes

Botto stores validated character geometry in the existing shared `shape` value
as a versioned `botto-path:1:` recipe wrapping an
[Open Bot Avatar v1 definition](https://github.com/DominikScholz/open-bot-avatar/blob/3a5119877844165eebafe57d3100da475f67d0a8/docs/avatar-contract.md).
This extends the rendering decision in
[ADR 0001](0001-local-avatar-palette.md): compatible Botto clients render the
custom silhouette. Save also publishes a static PNG for other Hermes clients.
Any client's later shape edit replaces the recipe. A separate geometry field
could survive that edit and unexpectedly override the new shape.

Generation uses session-bound Hermes `llm.oneshot`, outside chat history and
without changing the selected chat's access. The dedicated `botto_avatar` task
normally borrows the bot's model; Hermes overrides and fallback policies still
apply. The endpoint cannot prove strict provider pinning. Preview stays local
until the existing explicit Save and metadata revision check.

Botto adopts the full pinned Open Bot Avatar v1 contract, validator, volume,
motion and animator at `3a5119877844165eebafe57d3100da475f67d0a8`. It bundles
the canonical generation prompt without a private path-language restriction.
The Swift value provides bounded transport and storage; the canonical engine
validates semantics at generation, save and render boundaries.

Every face uses this engine: ten premade v1 definitions map one-to-one to Hermes
shape families, preserving existing default, classic and Blobatar identities,
colors and shared metadata. Existing avatars need no migration or generation.
Image-capable clients display the exported resting pose for custom faces.
Botto identifies its own derived PNG by the `bottoPreviewSHA256` byte hash, so
that asset does not override the live recipe. Explicit photos and different
replacement bytes retain image precedence. The 512-pixel export avoids Desktop’s
160-pixel face-copy suppression. The metadata CAS precedes the asset upload;
these operations are not atomic, so partial outcomes require Reload and a
deliberate retry. Old recipes are exported only on the next avatar Save.

Private JavaScriptCore workers prepare volume and normalized paths away from
the main thread. Definition/depth ownership isolates warm frames from cold
preparation; twelve resident playback VMs, two temporary preparation VMs and one
validator bound work. Active runtimes keep their lease between frames; excess
playback waits on a canonical still preview. Temporary preparation keeps new
previews usable at full playback capacity, and queued work retires with its last
consumer.
This trades separate VM heaps for frame responsiveness; device memory remains
a verification requirement. One native Canvas painter consumes canonical ordered slices, matrices
and eye marks. It retains Botto's palette/opacity rules and factual status cues.
Canonical Idle, Thinking and Happy own ordinary motion; narrow native adapters
supply sleeping eyes and verified one-shot outcomes. No parallel flat renderer
or private Swift path validator remains. Bundled resting frames cover cold
preparation; all fitted layouts share canonical resting bounds.

The MIT source, prompt, hashes and reproducible bundle builder live under
`scripts/avatar-engine` and `Sources/BottoCore/Resources`. Arbitrary SVG documents
and raster tracing remain separate workflows. Native raster and workflow
acceptance require their own recorded proof; engine parity alone is insufficient.
