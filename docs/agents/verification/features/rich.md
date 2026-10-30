# Read interactive replies and diagrams (`rich`)

## User-facing description

Read native assistant prose around inline HTML, SVG, and offline Pele Mermaid
previews; inspect source or expand. Sub-features: local HTML interactivity,
diagram types, mixed prose/code, streaming fences, bounded failure/source
fallback, isolated resources, and stable reading while previews leave/return.

## How to get to it

- `rich.e.demo`: welcome → **Explore the demo** → scroll to the **Canvas** row.
  Scroll up from newest content to **Launch dashboard**,
  Mermaid diagram, SVG, and ordinary code.
- `rich.e.host`: open a connected bot whose assistant reply contains complete
  `html`/`htm`, `mermaid`, or `svg` fenced blocks.
- `rich.e.controls`: **Show HTML source** / **Show Mermaid source** / **Show SVG
  source** (visible title Source); **Expand HTML preview** / **Expand Mermaid
  diagram** / **Expand SVG preview**. Done is labeled **Close <format> source**
  or **Close <preview title>**; expanded preview also offers Source.
- `rich.e.zoom`: rendered Mermaid/SVG → **Zoom diagram** or pinch → pan;
  **Fit diagram** resets the view and is disabled when already fitted.
  These controls are separate from Expand.

- `rich.e.cache`: DEBUG launch `--demo --diagram-cache-demo` → Canvas. This
  replaces only Canvas's messages with 24 assistant rows and six diagrams for a
  repeatable lazy-row traversal. Ordinary Demo retains its mixed rich replies.

## Interactive checks

Use [shared setup](../index.md), [rich-content contract](../../../rich-content.md),
ordinary Canvas for public paths, and owned host fixtures for formats absent
from Canvas. Renderer-test fixtures support diagnosis but cannot pass the host
reply entry. **Draft; complete public recipe sequences not proved here.**

Workflow `rich.read`:

1. `.a1` Open Canvas normally, spend six seconds at newest text/files, scroll
   back to HTML. Expect native prose before/between/after previews, an actual
   styled dashboard, and **Add review**. Tap once; expect counter `0` → `1`
   with `reviews` label. Proof: actual rendered pixels and current semantic
   nodes; accept exact grouped `1 reviews` or separate `1` and `reviews`
   nodes, according to the observed native hierarchy.
2. `.a2` Read Canvas Mermaid flowchart and SVG; expect actual distinct diagram
   pixels, not just loading/title/source. Scroll ordinary code horizontally;
   expect selectable unexecuted source. Repeat from an owned live assistant
   reply with flowchart, sequence, mindmap, architecture and Unicode labels.
   Proof: reply source/role and screenshot per type, zero required remote loads.
3. `.a3` Observe incomplete fences during streaming, then completion; expect
   selectable source until complete. Submit the same fences as a user message,
   or receive in tool/system detail; expect no execution. Proof: role/source,
   source/preview transition and actual pixels. Missing host fixture blocks this
   entry even when parser tests pass.

Workflow `rich.source-expand`:

1. `.a1` For HTML, Mermaid and SVG separately, tap Source; expect original source
   readable/selectable in its sheet and proper close action. Close; tap Expand;
   expect larger functioning preview. From expanded view choose Source, then
   close. Proof: source compared with fixture and screenshots at each state.
2. `.a2` Repeat with accessibility XXXL, light/dark, small iPhone and wide iPad,
   including rotation. Expect Source/Expand/Done reachable without clipping,
   bounded preview height and readable prose. Enable actual Reduce Motion;
   expect usable static/reduced motion rendering. VoiceOver must reach native
   prose, preview controls and source without trapping focus in WebKit. Proof:
   screenshots, semantic controls and spoken/focus-order record.

Workflow `rich.zoom`:

1. `.a1` Use tall SVG with explicit dimensions and no viewBox, then a TB Mermaid
   with known first/last labels. At actual 320/420-point widths, inline and in
   constrained Expand, enlarge with Zoom and separately pinch; pan to both ends.
   Expect readable first/last content, not cropped first-viewport pixels. Source
   must remain canonical. Proof: actual labeled captures before/after pan and
   native gesture observations. Static rasters have bounded fine detail; do not
   claim unlimited vector fidelity from these fixtures.
2. `.a2` Choose Fit, then scroll the outer chat away and back three times. Expect
   the complete fitted diagram, usable conversation scrolling and no reloading
   just for zoom/reset. Source/Expand/Done stay reachable, including VoiceOver
   and large text; labeled controls provide an alternative to pinch. Proof:
   visible boundaries, native focus/actions and document-lifetime trace. New
   source, appearance, viewport or owner must not reuse mismatched pixels.
   In automation, position the image and both controls inside the visible
   transcript before checking them. A visible Source header alone is not
   enough. Use bounded drags with a terminal hold to avoid inertial overshoot;
   check the disabled Fit control's visibility separately from tappability.
   Check native toolbar Source by tapping both ends of its 44-point target;
   its visual pill can report smaller bounds. Keep 44-point bounds checks for
   the custom inline, Zoom, and Fit controls.

Workflow `rich.boundaries`:

1. `.a1` Deliver owned assistant fixtures at/over 128 KiB UTF-8 HTML/SVG,
   16 KiB Mermaid and 100 flowchart/agentflow edges. Add malformed SVG/Mermaid,
   unsupported diagram/plugin and long Unicode source. Expect bounded render or
   honest failure with Source available; over-limit source remains native code.
   Proof: source byte/edge manifest, error/source capture, responsive app.
2. `.a2` On a disposable controlled host, deliver attempts at remote resource,
   navigation/download, parent bridge, cookie/storage access and infinite script.
   Expect no Hermes secrets/native bridge/file/network access, no modal escape,
   and bounded failure with readable source. Retain controlled endpoint request
   counts and screen/log evidence. Source injection into a component supports
   sandbox checks but does not prove reply projection and UI wiring.

Workflow `rich.scroll-lifetime`:

1. `.a1` On first public Canvas entry record visible diagram readiness and
   loading transitions. Then perform three planned newest-text/offscreen/return
   cycles with equivalent pauses; capture continuous video and semantic states.
   Once a matching diagram has rendered and remains eligible within the current
   presentation and cache budget, return should show stable content without
   distracting loading flashes, blank replacements or layout jumps. Proof must
   show actual diagram pixels and loader presence for every cycle; parsing or
   screenshot-at-rest alone is insufficient.
2. `.a2` While HTML is active, open Source/Expand, close, background/foreground,
   switch bots, and replace connection review; then revisit from its real owner.
   Expect stale execution retired, old completion unable to revive a replaced
   view, stable measured layout and fresh usable preview when reopened. Record
   local counter behavior; document isolated-document reset rather than require
   counter persistence. Proof: timed visual states and lifetime/component logs.

Workflow `rich.cache`:

1. `.a1` In the opt-in 24-row/six-diagram fixture, render all six diagrams through
   normal scrolling, then make three full newest/oldest return cycles that
   recreate lazy rows. Expect matching retained pixels and measured height on
   return, zero known-result loading/blank flashes, and no extra document for a
   hit. Proof: target-message-aware video, actual Start/Done pixels, row/document
   lifetime trace, exact source/layout/epoch and managed byte/count peaks. A
   short return that never destroys the owner cannot pass this assertion alone.
2. `.a2` Traverse a longer fixture whose decoded images exceed the budget.
   Expect bounded charged images plus capture reservations, actual eviction,
   recent eligible hits and an honest older-result miss. Keep native view-held
   image storage charged after lookup eviction and until release. Proof:
   lifecycle/accounting trace and actual pixels before/after miss and hit. Do
   not enlarge the budget or count source text as a rendered diagram.
3. `.a3` Change source, width, theme and motion settings separately; open another
   bot, reopen the same bot, enter/cancel connection review, and retire recovery
   or workspace identity. Expect no mismatched pixels or late capture revival.
   Return to unchanged offline cached reading within a valid owner; expect usable
   local rendering. Proof: exact owner/input trace, actual visible result and
   source comparison. Secret rotation alone must not merge distinct accounts.
4. `.a4` Induce controlled memory pressure and hold/release native captures and
   drawing views. Expect revocation without immediate refill loops, conservative
   charge until native ownership drains, and progress after new activation or
   available capacity. Keep Source reachable while busy. Independently use two
   HTML previews; expect local counters and existing execution/retirement limits,
   with no static-cache render cap applied to HTML. Proof: actual native output,
   reservation/drain trace, current UI and counter values. These stress fixtures
   support the public scroll workflow; they do not replace it.

## Gotchas

Inline rendering and automatic HTML-file previews use quiet source/file-card
fallbacks while pending. Check first visibility and repeated scrolling without
passive Loading labels or spinners. Explicit Expand and Retry may show progress;
actual failures remain visible. Authority revocation still retires executable
content. A static fallback alone does not prove the eventual preview rendered.

Source: [AssistantReplyBody](../../../../App/Views/AssistantReplyBody.swift),
[RichReplyBlockView](../../../../App/Views/RichContent/RichReplyBlockView.swift),
[renderer](../../../../App/Views/RichContent/RichContentRenderer.swift),
[ReplyContent](../../../../Sources/BottoCore/ReplyContent.swift).
[Renderer tests](../../../../AppTests/RichContentRendererTests.swift) support
offline bundled Pele, source/limits, sandbox behavior, delayed attachment,
sequence/architecture selection, pixels and retirement.
[RichChatUITests](../../../../AppUITests/RichChatUITests.swift) exercise HTML
interaction and Source/Expand. These checks support their selected paths;
they do not pass every format, target, entry point or accessibility assertion
in this recipe. See [verification](../../../verification.md) for recorded
checks and limits.

Lazy-row recreation and capacity/epoch misses need separate observations.
A short same-owner return cannot establish that a reconstructed row reused its
rendered result. Keep the under-budget return and legitimate-miss controls in
`rich.cache`; inspect actual readable content, not only source text or a colored
region. Native retained-result tests supplement the real scrolling workflow.

SVG animation and JavaScript freeze after rendering; HTML remains live.
Rasters are capped at 1024 pixels on their longest axis, so dense or tiny labels
can lose detail. Preserve readable-content assertions and inspect both ends of
tall content. Component screenshots do not establish actual pinch, system
Reduce Motion, VoiceOver, or every live-host format. Local prelaunch stalls
remain infrastructure outcomes, separate from product assertions.
