# Choose avatars and observe motion (`avatars`)

## User-facing description

Recognize bots by their shared Hermes image or Botto's interpretation of their face, choose a shape/color,
and see restrained status motion. Sub-features: create-time choice, existing
Save/Cancel, metadata conflicts, image replacement/reload, deterministic defaults,
motion accessibility, and eye containment across every shape/expression.

## How to get to it

- `avatars.e.create`: **New bot** → **Avatar** → **Custom** → shape/color;
  submit using [creation](bots.md).
- `avatars.e.edit`: open a bot → header avatar/name capsule → avatar pencil → **Edit bot**.
- `avatars.e.reload`: after editor conflict/error → **Reload profile**; inbox
  pull-to-refresh requests fresh images. Reload is not an always-visible toolbar.
- `avatars.e.render`: inbox row/rail, conversation header, profile, creation
  preview, and picker shape tiles display faces at materially different sizes.

## Interactive checks

Follow [shared setup](../index.md) and [avatar contract](../../../avatars.md).
Use owned profiles with no appearance, drawn metadata, saved photo, marked desktop
face-copy, and unreadable image. Save may clear a server image; capture its owned
fixture first. **Draft; complete recipes were not live-proven here.**

Workflow `avatars.edit`:

1. `.a1` Open existing editor; expect Save disabled until deliberate selection.
   If Avatar shows **Match the name**, choose **Custom** to reveal the grids.
   Choose **Hexagon shape** and Teal (IDs `avatar-shape-hexagon`,
   `avatar-color-teal`), Save (`save-bot-profile`), reopen. Expect **Hexagon · Teal**.
   Choose Circle, Cancel, reopen; expect prior saved look. Repeat default and
   create-time choice. Proof: UI captures, fresh profile RPC metadata and app
   relaunch for real host persistence. Demo reopen proves only in-memory state.
2. `.a2` With a saved image, choose a face. Expect replacement explanation before
   Save, then new face and cleared image with unrelated metadata preserved.
   Repeated pending Save must not issue another mutation. Proof: warning,
   pending/settled state, fresh metadata revision and image read, mutation count.
3. `.a3` Open the cached profile/editor offline and choose a shape/color. Expect
   usable local controls and no passive image spinner or connection notice.
   Attempt Save; expect contextual connection feedback and retained selection.
   Background/foreground and recover the same workspace; expect the draft
   retained and no automatic save. Retry deliberately against current metadata.
   Proof: draft captures and host save count/revision; uncertain prior writes
   still require Reload.

Workflow `avatars.conflict`:

1. `.a1` Open editor, modify appearance from another authorized fixture client,
   then Save old selection. Expect honest conflict/error and Reload required,
   preserving unrelated host fields. Tap **Reload profile**, choose again, Save.
   Expect new revision and intended face. Proof: fresh host metadata before and
   after, error/reload captures. Never automatically retry uncertain writes.
2. `.a2` Hold save/reload pending; replace connection or open connection review,
   disconnect, then release old success/error. Expect retired editor cannot save
   into replacement or publish stale UI; close and reopen from current bot.
   Proof: workspace identity and independent old/new host reads. Metadata update
   and image clearing are separate operations; partial success must stay honest.

Workflow `avatars.identity`:

The opt-in `AvatarUITests.testLiveSharedIdentityAndCustomColorPreservation` and
`testLiveMatchNameKeepsShapeAndDoesNotRestoreColorOnShapeEdit` require a signed
build for Keychain access. Give the runner
`BOTTO_UI_TEST_AVATAR_URL` (xcodebuild: `TEST_RUNNER_BOTTO_UI_TEST_AVATAR_URL`).
Prepare owned fixtures titled **Avatar Preset** (Cloud, a classic preset, custom),
**Avatar Sun** (`blobatar:botto-avatar:sun`, custom)
and **Avatar Custom** (Cloud, `hsl(30 40% 50%)`, custom), each with a canonical
Bot Chat. Use an isolated disposable host; the test changes the custom fixture
to Hexagon and the preset fixture to Triangle with automatic color. This opt-in
is separate from the general Hermes integration URL.

1. `.a1` Read owned profiles containing a classic HSL preset, a custom HSL or
   RGBA color, and pinned Blobatar Nub/Sun recipes. Expect Botto's regular preset
   shades, faithful custom color, and recognizable generated shape families with
   Botto's eyes. Opening and cancelling the editor must preserve the raw shared
   recipe and custom color in an independent host read.
2. `.a2` Change only the custom profile's shape, Save, and read Hermes afresh.
   Expect the new classic shape, exact original color string, retained unrelated
   metadata, and the new revision. On a generated profile, expect the conversion
   explanation. Nub/Sun require a classic shape before choosing a color; choosing
   and saving a classic face replaces the recipe deliberately.
3. `.a3` Select a classic shape and explicit color, then the **Auto** color swatch and
   Save. Expect the chosen shape, no color override, and preserved unrelated
   metadata in a fresh host read. Reopen and change only the shape; expect the
   color to remain automatic. Cancel a later color edit and confirm no change.
   Explicit white values, including `#ffffff`, must draw white in light and dark
   appearance. **Match the name** in the Avatar menu still resets both shape and color.
4. `.a4` Give an owned profile an unrecognized color such as `aliceblue`, then
   change only its shape. Expect Save/reopen to succeed and a fresh host read
   to retain the exact color. On a profile with legacy `sigil-4`, change only
   color; expect the raw shape to remain `sigil-4`. Cancel subsequent edits
   and confirm no write. Local fallback previews must be explained.

Workflow `avatars.images`:

The opt-in `AvatarUITests.testLiveForeignValueEditsAndSavedImageCancel` uses
four additional owned fixtures: **Avatar Foreign Color** (Cloud, `aliceblue`),
**Avatar Foreign Shape** (`sigil-4`, `#123456`), **Avatar Pet** (transparent
96 × 104 PNG, `imageKind: photo`), and **Avatar Image** (256 × 256 JPEG, photo).
The first two receive one edit each; image fixtures are opened and cancelled.
Record fresh metadata revisions and asset-byte hashes before and after.

1. `.a1` Open each fixture. Expect saved photo precedence, deterministic default
   when no look exists, drawn desktop face-copy only under documented marking,
   and face fallback for unreadable/unsupported image. A same-size marked photo
   remains an image. Proof: actual pixels and independent image/metadata read.
2. `.a2` Replace owned image bytes without metadata revision change; pull to
   refresh. Expect refreshed image; ordinary refresh after cache age also
   revalidates. Use slow image read plus another refresh; expect usable roster
   and eventual fresh image without losing current reads. Proof: known image
   hashes, timed screenshots and fresh host bytes; record cache-age precondition.

Workflow `avatars.motion`:

1. `.a1` Watch ordinary drawn faces across inbox/header: expect sparse independent
   blinking. Start controlled work; header motion may run up to 30 seconds, then
   settle while working text remains. Saved images/picker stay still and message
   layout does not move. Proof: timed video through 40 seconds and landmark bounds.
2. `.a2` Enable actual system Reduce Motion and foreground the app; expect drawn
   faces still. Background/inactivate and return; no inactive animation ownership
   may leak. Restore setting afterward. Proof: settings/readback and video.
   DEBUG `--reduce-motion` supplies component coverage, not system preference proof.
3. `.a3` Disconnect while cached bots and a chat remain visible. Expect closed
   eyes, a gentle vertical squish and a static no-signal cue on drawn faces;
   saved images stay still with the same cue. Check 30/32 pt headers, 56 pt rows,
   pinned bots and every shape for eye clearance and clipping. Existing row,
   pinned-bot and header accessibility values must say Offline without adding
   focus targets. Recover; expect that value and cue to clear, current activity
   to resume, and drafts to remain without automatic sends. With Reduce Motion
   or an inactive scene, expect a static sleeping pose and visible cue.
   Proof: native captures, timed motion, accessibility values and recovery checks.

Workflow `avatars.containment`:

1. `.a1` Render Triangle plus all eight shared shapes in row, rail, header,
   profile, and picker. Exercise supported expressions/blink/working extremes.
   Expect eyes contained inside each silhouette with readable identity;
   capture actual visible pixels, not only path-coordinate math. Test small and
   large faces, including Cloud, Drop and tall Pill expressions. Proof: screenshots
   or frames with shape/expression/size labels and overflow inspection.
2. `.a2` Repeat editing/rendering on small iPhone/iPad, light/dark, accessibility
   XXXL and Reduce Motion. Expect selected shape/color labels and Save/Cancel
   reachable. VoiceOver must communicate identity and selected choices without
   decorative eyes entering focus. Proof: screenshots and actual spoken/focus order.

## Gotchas

Source: [picker](../../../../App/Views/BotAvatarPicker.swift),
[editor](../../../../App/Views/BotProfileEditor.swift),
[BotAvatar](../../../../App/Design/BotAvatar.swift),
[geometry](../../../../App/Design/BotAvatarGeometry.swift),
[motion](../../../../App/Design/BotFaceMotion.swift).
[AvatarUITests](../../../../AppUITests/AvatarUITests.swift) exercise creation,
Save/Cancel, and largest-text selection. Component geometry and motion checks
support containment and timing; they do not establish physical-device,
VoiceOver, every appearance entry, or a 30-second real-model turn. Inspect native
iOS containment and the actual system Reduce Motion behavior separately. See
[verification](../../../verification.md) for recorded checks and limits.
