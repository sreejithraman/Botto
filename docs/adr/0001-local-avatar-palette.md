---
status: accepted
---

# Share avatar identity with Botto's own rendering

The rendering implementation below was extended by
[ADR 0011](0011-custom-avatar-recipes.md): all drawn faces now use the pinned
Open Bot Avatar engine with native painting. Its canonical rendering and motion
replace the former local drawing code and eye animation. The shared identity,
palette and deliberate-edit decisions in this ADR still apply.

Botto shares Hermes avatar identity: the same supported shape family and a
recognizable color family. Botto owns the outlines, proportions, eyes, expressions,
and motion so those identities fit its visual design. A purple cloud remains a
purple cloud without requiring the same drawing.

Classic presets and generated Blobatar hues use Botto's clear, regular palette;
the muted-palette direction was rejected. Other supported custom colors retain
their color and opacity, including literal white. A value equivalent to a known
preset receives preset treatment because shared metadata records no provenance.

Viewing or cancelling preserves the raw shared recipe and color metadata.
Deliberate edits write shared equivalents and preserve untouched custom or
unrecognized values; [avatar editing and automatic-color rules](../avatars.md#choose-a-face)
define those operations. Exact Blobatar contours, generated tones, and decoration
are optional fidelity work. This rendering freedom does not justify selecting a
different supported shape family or using the wrong seed.

Shared identity and edit contracts: [avatar guide](../avatars.md).
