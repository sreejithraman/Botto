# Choose avatars and observe motion (`avatars`)

## User-facing description

Recognize bots by their shared Hermes image or Botto's interpretation of their face, choose a shape/color,
and see restrained status motion. Create an original drawn character through Hermes.
Sub-features: character generation/preview, create-time choice, existing
Save/Cancel, metadata conflicts, image replacement/reload, deterministic defaults,
motion accessibility, canonical volume, and eye containment across premade and generated faces.

## How to get to it

- `avatars.e.create`: **New bot** → **Avatar** → **Custom** → shape/color;
  submit using [creation](bots.md).
- `avatars.e.edit`: open a bot → header avatar/name capsule → avatar pencil → **Edit bot**.
- `avatars.e.generate`: **Edit bot → Create a character** → description → **Generate character**.
  Demo offers **Preview sample character** instead of calling a model.
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
   Save, then new face and either a derived PNG for a custom character or a cleared
   image for a preset, with unrelated metadata preserved. With a preview marker,
   hold or fail the image read: expect the explanation until exact bytes confirm
   the derived preview. Revalidation must restore that conservative explanation. Background/cancel
   during the read must not restore an older confirmation.
   Repeated pending Save must not issue another mutation. Proof: warning,
   pending/settled state, fresh metadata revision and image read, mutation count.
3. `.a3` Open the cached profile/editor offline and choose a shape/color. Expect
   usable local controls and no passive image spinner or connection notice.
   Attempt Save; expect contextual connection feedback and retained selection.
   Background/foreground and recover the same workspace; expect the draft
   retained and no automatic save. Retry deliberately against current metadata.
   Proof: draft captures and host save count/revision; uncertain prior writes
   still require Reload.
4. `.a4` With a controlled local validation failure, Save a staged custom face.
   Expect bounded local recovery before any avatar mutation. If it still fails,
   retain the choice and allow deliberate Save without Reload. Repeat with
   metadata saved before avatar validation fails; expect partial-save recovery
   to require Reload. Proof: typed error, retained draft, counted writes and
   fresh metadata. This exception never replays uncertain host writes.

Workflow `avatars.generate`:

1. `.a1` Open an owned bot with an existing chat on a session-authority host.
   Enter a non-preset character description and Generate. Expect one pending
   action with Cancel, followed by a named moving character preview. The host's
   saved avatar and chat history stay unchanged before Save. Choose a color,
   Save, then refetch through a fresh client. Expect the exact custom recipe and
   color plus a 512px PNG whose SHA-256 matches `bottoPreviewSHA256`; expect
   Desktop to display the PNG and Botto to animate the recipe. Relaunch offline
   and expect the same character. Change color and verify new image bytes and
   marker. Proof: native captures,
   request counts, independent metadata/history read and cache restoration.
2. `.a2` Generate again, cancel while pending, edit the prompt, dismiss, or
   replace the connection before a delayed result returns. Expect no late result
   to replace a newer preview or write an avatar. Duplicate Generate must not
   create another request. A provider error, malformed output or timeout retains
   the description and previous preview for deliberate retry. The active chat
   remains usable throughout. Proof: visible state and counted host effects.
3. `.a3` Save a custom character, then change its shape through another client.
   Expect the new classic shape on refresh. Change only its color in Botto;
   expect the custom outline preserved. Opening/cancelling a future or malformed
   recipe preserves the exact stored value with a local fallback. Proof: fresh
   raw metadata, native preview and existing conflict checks.
4. `.a4` Fail local rendering once after a valid model reply. Expect the same
   character to reach preview with exactly one model request. Persistent local
   failure reports a renderer error and keeps the previous preview. Cancel or
   replace the connection during local recovery; expect no late result or
   further rendering attempts. Proof: controlled fault, geometry identity,
   model-request count and workspace ownership.

`AvatarUITests.testCustomCharacterPreviewColorSaveAndCancel` covers the labeled
demo preview, color, Save/reopen and cancelled shape replacement. It does not
prove model generation or host persistence. `AvatarGenerationModelTests` and
`AvatarGenerationStoreTests` cover retirement, retry, workspace fences and disk
cache restoration. `AvatarGenerationTests` cover the public service's request
isolation, timeouts and invalid results. The opt-in
`disposableHostGeneratesAndPersistsACustomAvatarWithoutChangingChat` uses
`BOTTO_TEST_HERMES_AVATAR_URL` with the [disposable host](../../../dev-host.md)
to prove one-shot generation, save, fresh-client read and external replacement.
Its deterministic model does not establish character quality on real Codex.
`CustomAvatarLayoutTests` prepare canonical frames and check actual native painting
for all ten premade families and official custom examples, including arcs, side
views, Happy marks, containment and shared resting bounds. `OpenBotAvatarEngineTests`
compare the bridge against independent pinned Node reference frames. Complete recipe and
real-provider evaluation remain draft until all assertions are exercised.

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
   and image upload/clearing are separate operations; partial success must stay honest.

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
   canonical eyes and volume. Opening and cancelling the editor must preserve the raw shared
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
   a matching Botto PNG to keep the custom recipe animated, and face fallback
   for unreadable/unsupported image. A different replacement image or a marked
   photo must still win, including a different 160px PNG with an old preview marker.
   A same-size marked photo
   remains an image. Proof: actual pixels and independent image/metadata read.
2. `.a2` Replace owned image bytes without metadata revision change; pull to
   refresh. Expect refreshed image; ordinary refresh after cache age also
   revalidates. Use slow image read plus another refresh; expect usable roster
   and eventual fresh image without losing current reads. Proof: known image
   hashes, timed screenshots and fresh host bytes; record cache-age precondition.

Workflow `avatars.motion`:

1. `.a1` Watch ordinary drawn faces across inbox/header. Expect canonical Idle
   motion and independent profile blink phases. Start controlled work and switch
   through Thinking, Working, Tools and Replying; expect canonical Thinking,
   meaningful cues and no restarted work clock. Verify one successful somersault
   and one failure shake from live outcomes, with no replay on reopening. Saved
   images/picker stay still and message layout does not move. Proof: timed video,
   live event identity and stable layout landmarks. A static fixture cannot prove
   outcome provenance or foreground frame scheduling.
2. `.a2` Enable actual system Reduce Motion and foreground the app; expect drawn
   faces still. Background/inactivate and return; no inactive animation ownership
   may leak. Restore setting afterward. Proof: settings/readback and video.
   DEBUG `--reduce-motion` supplies component coverage, not system preference proof.
3. `.a3` Disconnect while cached bots and a chat remain visible. Expect closed
   eyes and a static no-signal cue on drawn faces;
   saved images stay still with the same cue. Check 30/32 pt headers, 56 pt rows,
   pinned bots and every shape for eye clearance and clipping. Existing row,
   pinned-bot and header accessibility values must say Offline without adding
   focus targets. Recover; expect that value and cue to clear, current activity
   to resume, and drafts to remain without automatic sends. With Reduce Motion
   or an inactive scene, expect a static sleeping pose and visible cue.
   Proof: native captures, timed motion, accessibility values and recovery checks.

Workflow `avatars.containment`:

1. `.a1` Render all ten premade families plus official Cat, Mug and an arc-based
   definition in row, rail, header, profile and picker. Exercise canonical Idle,
   Thinking, Happy, side turns, stored expression mapping, sleeping eyes and all
   status cues at small and large sizes. Expect recognizable family identity,
   canonical depth and contained eyes. Compare native fixed-frame painting with
   pinned engine output; inspect actual pixels, holes, fill rules, curves, slice
   ordering and projected eye visibility. Header, rail and picker must agree on
   resting bounds. Verify cold previews become complete live assets without a
   blank face; cancellation and rapid status/geometry replacement must reject
   stale frames. Proof: labeled captures, reference inputs, raster comparison,
   contour/cue overlap checks and request ownership evidence. Engine JSON parity
   alone does not prove native painting or UI alignment.
2. `.a2` Repeat editing/rendering on small iPhone/iPad, light/dark, accessibility
   XXXL and Reduce Motion. Expect selected shape/color labels and Save/Cancel
   reachable. VoiceOver must communicate identity and selected choices without
   decorative eyes entering focus. Proof: screenshots and actual spoken/focus order.

## Gotchas

Source: [picker](../../../../App/Views/BotAvatarPicker.swift),
[editor](../../../../App/Views/BotProfileEditor.swift),
[BotAvatar](../../../../App/Design/BotAvatar.swift),
[geometry](../../../../App/Design/BotAvatarGeometry.swift),
[native painter](../../../../App/Design/BotAvatarNativeFrame.swift),
[render ownership](../../../../App/Design/BotAvatarRenderModel.swift), and
[canonical engine](../../../../Sources/BottoCore/OpenBotAvatarEngine.swift).
[AvatarUITests](../../../../AppUITests/AvatarUITests.swift) exercise creation,
Save/Cancel, and largest-text selection. Component geometry and motion checks
support containment and timing; they do not establish physical-device,
VoiceOver, every appearance entry, real-provider character quality, or
foreground/offscreen energy behavior. Inspect native iOS containment and the actual system Reduce Motion behavior separately. See
[verification](../../../verification.md) for recorded checks and limits.
