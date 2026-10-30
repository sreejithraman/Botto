# Hermes avatars

Botto shares avatar identity through the Hermes profile's `hermes-bots` metadata,
then draws it with Botto's own outlines, eyes, expressions, and motion. A purple
cloud stays a purple cloud across clients; the drawings and purple shades can
differ. Viewing an avatar never rewrites its saved recipe or color.

Classic faces use the eight shared shapes. Automatic classic faces follow the
Hermes Desktop profile-ID shape and hue rules, with the primary profile's purple
squircle exception. The visible hue uses Botto's familiar palette.
This follows the accepted [identity and rendering decision](adr/0001-local-avatar-palette.md).

Hermes Desktop's twelve HSL preset colors map to Botto's regular red, orange,
yellow, lime, green, mint, teal, blue, indigo, purple, magenta, and pink. Choosing
one in Botto saves its canonical Hermes preset value. Known older palette values
also map by color family. A value identical to a preset is treated as that preset;
the shared metadata does not record how the color was chosen.
All twelve preset colors use dark eyes. Custom colors keep automatic eye contrast.

Other supported custom colors keep their color and opacity. Botto reads hex,
RGB/RGBA, and HSL/HSLA color notation; CSS expressions such as `var()` and
`color-mix()` are not supported. Unsupported values remain intact in metadata
and use the local rendering fallback.
Explicit white, including `#ffffff`, stays white in both appearances.
Shape-only edits retain an unrecognized saved color. Color-only edits retain
an unrecognized saved shape. Botto explains when it uses a local preview;
choosing a new shape or color explicitly replaces that field.

Blobatar 2 recipes retain their seed and optional silhouette pin. Botto derives
the same shape family and interprets the generated hue in its regular palette.
The ten families are round, organic, boxy, capsule, nub, cloud, droplet, hexagon,
sun, and triangle. Botto does not reproduce Blobatar's exact contour variations,
eyes, generated tones, or decoration. Unknown future recipes remain intact in
the cache and conflict checks rather than being discarded.

A readable saved Hermes image takes precedence over a drawn face.
Botto displays saved PNG, JPEG, and WebP avatars from Hermes, including uploaded
or generated art. Hermes pets are saved as static 96 × 104 PNG thumbnails;
Botto preserves their transparency and aspect ratio. The animated pet sprite
sheet is not the profile avatar. Botto currently has no pet picker, avatar-image
upload, or avatar-generation controls.

`BotAvatar` and `AppBotAvatar` support `fitsBody: true` for layouts that align
the drawn outline or fitted image bounds. The chat header and pinned rail align
those bounds at the top. The header's name follows the actual body height;
the pinned rail keeps a fixed slot so its captions also line up.

Hermes Desktop can save a 160 × 160 PNG copy of a drawn face. Botto draws that
face itself so its eyes can move. A 160 × 160 image explicitly marked as a
photo stays an image. Unsupported or unreadable images fall back to the face.

## Choose a face

New bots start with **Match the name**. The Avatar menu switches between that
mode and **Custom**. Match the name hides the shape and color grids and uses
Hermes’s automatic face. Custom reveals the shared shape and color picker.
Switching back to Custom in the same editor restores its unsaved choices.
Automatic appearance follows the Hermes profile ID; changing a visible bot
name preserves that identity.

For an existing bot, open the header overview and its avatar’s pencil. **Edit
bot** includes name, description and the same Avatar menu. Save applies explicit
changes; Cancel leaves Hermes unchanged. Description is the short profile
introduction, separate from behavioral instructions in SOUL.md.

Within Custom, the first color swatch, **Auto**, removes only the color override, keeping the
chosen shape. Shape-only edits preserve the saved color, including values Botto
cannot preview. Unsupported shared values stay intact until deliberately edited.

Editing a generated avatar explicitly replaces its recipe with a classic face;
the editor explains this before saving. Nub and Sun are displayed for generated
avatars. Choose a classic shape before changing their color. Simply opening or
cancelling the editor keeps the original generated recipe.

Selecting a face for a bot with a saved image replaces that image. The editor
explains this before saving. Botto rereads the profile, preserves unrelated
metadata, and uses Hermes's metadata revision when saving. An observable
change made by another client requires Reload before saving again.

Metadata and image clearing are separate host operations. Hermes has no image
revision or atomic compare-and-swap for image bytes. Botto reports partial or
uncertain outcomes and never retries a save automatically. Another client's
image upload racing with image clearing cannot be made atomic by Botto.

## Refresh and motion

Image reads run separately from roster publication, with at most three active
reads. Unchanged roster refreshes keep existing reads alive. Images revalidate
on the next roster refresh after 60 seconds; pull-to-refresh or **Reload profile**
requests a fresh read sooner. If a read is already running, that request queues
one fresh read after it.

Drawn faces use the approved lively motion across inbox rows, pinned bots,
chat headers and bot overviews. Idle stays quiet, with sparse blinks, small eye
movements and breathing. Thinking, Working, Using tool and Replying share six
movement phrases and one work clock. Needs you ponders with a question cue;
unavailable closes its eyes while z marks rise and fade. Offline uses the same
closed eyes with a static no-signal cue. Both sleeping poses gently squish with
the shared breathing rhythm. A verified successful
live turn triggers one somersault and returns to idle. A verified failed turn
expands and shakes without changing the bot's color.

Activity cues use four corner anchors tuned to each shape's contour. Thinking
cues sit at the upper left, attention and sleeping cues at the upper right,
the wrench at the lower right, and completion sparkles at the lower left.
Small avatars keep cues large enough to read and reserve extra clearance from
the eyes. The wrench head overlaps the body, with its handle hanging outside.
The offline cue uses the upper-right anchor and the same minimum cue size.
Offline status also appears in the existing inbox row, pinned-bot and header
accessibility values; decorative drawing does not add another focus target.
Speech-bubble cues have a canvas-colored outline to separate them from similar
avatar colors in both appearances.

`AppBotAvatar` is the shared saved-bot view. `AppStore.avatarPresentation` asks
the conversation workspace for a profile aggregate or selected-chat presentation;
views do not interpret Hermes events or own work clocks. Aggregate waiting takes
priority over working. Rich phases refine only the matching live selected chat;
profile reactions require current aggregate idle, so a waiting or working sibling
is not hidden by a completed turn. The app's offline connection selects the
sleeping offline presentation before resolving chat activity. A saved connection
starts as `.connecting` before the first render; the startup task then attempts
the connection. Startup, reconnecting, and historical activity while connected
use a neutral idle face without claiming current idle status. Opening a chat
keeps that chat's observed activity and work clock until its live attachment is
ready; it does not borrow activity from a sibling. Explicitly unavailable activity
uses the sleeping pose. Historical activity keeps its existing labels.
This follows [cache-first presentation](adr/0007-cache-first-activity-presentation.md).
Regression coverage must include the first presentation from saved setup,
pending activity, successful recovery, and confirmed failure.

The service publishes nonpersistent `ConversationActivity` on `OpenedConversation`.
The workspace retains a reaction's original identity and time through ordinary
same-lineage refreshes. Reopening a view samples elapsed time instead of replaying
it. Connection/selection changes retire transient reaction facts. Snapshot/replay,
cancellation, queued settlement and unknown outcomes never create celebrations.
A turn already running when reattached needs a new live start before its outcome
can trigger a reaction; coarse working still displays normally.

Saved images and picker previews stay still. Saved images receive the same
static offline cue without moving or changing their pixels. Reduce Motion and inactive scenes
remove animation timelines while preserving static activity cues. No message
layout moves with the face. Energy use has not been measured.

## Developer playground

Debug builds expose **Settings → Developer menu → Avatar playground**. The tool
shows all ten activities, all ten shape families, three representative bots,
header/inbox sizes, a size slider, Replay and Reduce Motion controls. The isolated
demo exercises the same production presentation and renderer without connecting
to Hermes. The ordinary demo emits a complete reply at once; the performance
fixture also exercises a real chunk-driven Replying phase.

Launch Debug with `--developer-menu` to open the menu without setup, or
`--bot-motion-lab` to open the playground directly. Developer destinations are
kept in `DeveloperMenuView` and excluded from Release. See the
[playground guide](bot-motion-prototype.md) for comparison controls and evidence.

Botto's classic geometry, eye expressions, image rules, and motion adapt pinned
Hermex source `47809f2cd1f07bcbe592ee8960cf9c63e88b734c`. Classic identity rules
follow Hermes Desktop at `4a0eaf7989b6804319ddb94fa5d96c5a716080a1`; generated
identity follows Blobatar 2.0.0. See the bundled licenses and
[third-party notices](../THIRD_PARTY_NOTICES.md).
