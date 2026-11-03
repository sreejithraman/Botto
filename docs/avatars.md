# Hermes avatars

Botto shares avatar identity through the Hermes profile's `hermes-bots` metadata,
then draws every vector face through the pinned Open Bot Avatar engine and
one native Canvas painter. A purple cloud stays a purple cloud across clients; the drawings and purple shades can
differ. Viewing an avatar never rewrites its saved recipe or color.

Classic faces retain the eight shared shape names. Automatic classic faces
follow the Hermes Desktop profile-ID shape and hue rules, with the primary profile's purple
squircle exception. The visible hue uses Botto's familiar palette.
This follows the accepted [identity and rendering decision](adr/0001-local-avatar-palette.md).

All ten Hermes shape families have premade Open Bot Avatar v1 definitions in
`HermesAvatarDefinitions.json`. Each family maps one-to-one to its existing
identity. Classic, automatic, default and Blobatar selection rules stay intact;
viewing existing profiles needs no metadata migration or model request. The
canonical silhouettes can differ from the earlier local outlines.

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

A readable saved Hermes image takes precedence over a drawn face, except for a
matching static preview that Botto exported from that face.
Botto displays saved PNG, JPEG, and WebP avatars from Hermes, including uploaded
or generated art. Hermes pets are saved as static 96 × 104 PNG thumbnails;
Botto preserves their transparency and aspect ratio. The animated pet sprite
sheet is not the profile avatar. Botto currently has no pet picker or avatar-image
upload controls. Custom drawn characters use the generation workflow below.

`BotAvatar` and `AppBotAvatar` support `fitsBody: true` for layouts that align
the drawn outline or fitted image bounds. The chat header and pinned rail align
those bounds at the top. The header's name follows the actual body height;
the pinned rail keeps a fixed slot so its captions also line up.

Hermes Desktop can save a 160 × 160 PNG copy of a drawn face. Botto draws that
face itself so its eyes can move. A 160 × 160 image explicitly marked as a
photo stays an image. Unsupported or unreadable images fall back to the face.

Saving a custom character also uploads a transparent 512 × 512 PNG of its
canonical resting pose through `profiles.set_asset`. Hermes Desktop and other
image-capable clients can show that character without understanding its recipe.
Botto stores the PNG SHA-256 as `bottoPreviewSHA256` in the shared look and ignores
only those exact image bytes, keeping the recipe animated. Explicit photos and
different replacement bytes still take precedence, including 160px replacements
with a retained marker. The editor keeps its image-replacement explanation until
a completed read confirms the derived preview; pending, failed and invalid reads
do not suppress it. Canceled rechecks stay unconfirmed until another successful
read. Color edits regenerate the
PNG; selecting a preset or Match the name removes the derived image and marker.
Existing custom recipes gain a PNG on their next deliberate avatar Save. There
is no background migration or extra model request. Other clients control when
they refresh cached images. The static export uses light
surface eye contrast for translucent custom colors.

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

Editing a Blobatar avatar explicitly replaces its recipe with a classic face;
the editor explains this before saving. Nub and Sun are displayed for generated
avatars. Choose a classic shape before changing their color. Simply opening or
cancelling the editor keeps the original generated recipe.

Selecting a face for a bot with a saved image replaces that image. The editor
explains this before saving. Botto rereads the profile, preserves unrelated
metadata, and uses Hermes's metadata revision when saving. An observable
change made by another client requires Reload before saving again.

Metadata and image upload/clearing are separate host operations. Hermes has no image
revision or atomic compare-and-swap for image bytes. Botto reports partial or
uncertain outcomes and never retries a save automatically. Another client's
image upload racing with image replacement cannot be made atomic by Botto.
An operational renderer failure before any write keeps the staged choice ready
for a deliberate Save. If metadata was already saved, partial-save recovery
still requires Reload.

## Create a character

Open **Edit bot → Create a character**, describe an object or creature, and tap
**Generate character**. Hermes creates an original outline rather than selecting
a preset. Complex descriptions become simple silhouettes. The preview uses the same canonical volume and motion as premade faces. Choose a color, generate again, or Save. Cancel
discards the draft. Demo offers a labeled sample cat rather than model generation.

Generation does not change the saved avatar or add messages to the bot's chat.
One request runs per bot. Cancel, prompt changes, editor dismissal and connection
replacement discard late results. A failed regeneration keeps the prior preview
and description. Model requests and profile writes are sent once. Temporary
local validation or preparation failures retry the existing definition twice,
after 250 and 500 ms. Cancellation and connection replacement stop recovery.
Persistent renderer failures report a drawing error without blaming the model
response or the chosen shape.

This requires Hermes session authority with `llm.oneshot` and an existing bot
chat. It uses the selected chat's route when it belongs to that bot, otherwise
the bot's Main chat. The dedicated `botto_avatar` task normally uses the bot's
model, including Codex when configured. Host auxiliary overrides and fallbacks
still apply; the response carries no final provider identity. Older sidecar
hosts cannot establish the required route and receive an update-host message.
Generation has a 75-second request-local timeout and never stops the live chat.

The saved `shape` is an opaque `botto-path:1:` recipe containing a bounded JSON
Open Bot Avatar v1 definition: version, id, name, body path and eye placement.
Botto bundles the [canonical model-neutral prompt](https://github.com/DominikScholz/open-bot-avatar/blob/3a5119877844165eebafe57d3100da475f67d0a8/skills/generate-avatar/references/system-prompt.md)
verbatim. The reference validator accepts the full v1 path language, including
relative commands, arcs and shorthand, within its complexity and containment
limits. The Swift transport value only bounds data size and checks structure;
canonical validation runs before generation preview, saving and live rendering.
Color edits keep the recipe; classic shape choices and **Match the name** replace
it. Future or malformed recipes remain intact and use the usual canonical family
fallback until deliberately replaced. This is a geometry definition, not arbitrary
SVG/XML import or raster image generation.

The pinned engine runs in private JavaScriptCore workers away from the main
thread. A bounded registry isolates each definition and depth, so new geometry
does not queue existing warm frames. Twelve resident playback VMs retain active characters; two temporary preparation
VMs keep new previews progressing even when playback is full. Canceled demand
leaves the queue, while shared work stays available to its remaining callers. A native Canvas paints
its ordered slices and eye marks with Botto's existing palette, opacity and contrast
rules. Warm frames carry matrices and eye values, not SVG strings. Bundled canonical
resting previews keep premade faces visible during cold preparation. Generated
previews wait for native path preparation before becoming selectable. A changed
character never borrows the previous character’s frame. Activity changes retain
the current pose while the next frame arrives; native reaction clocks advance
independently of geometry work. Header, rail and picker use the same canonical resting bounds.
Live runtime ownership lasts through mood changes and ends when a character
leaves or stops animating. Extra active definitions keep their canonical still
preview until a playback slot is released. Idle preset tiles use baked frames
without preparing a VM. The pinned rail creates cells lazily and reserves two
caption lines to keep its height steady. There is no WebView or second
preset/custom drawing engine.

Custom characters animate in compatible Botto clients. Other Hermes clients may
show a default face; they do not yet share this drawing format. Any later shape
edit from another client replaces the custom recipe. See
[the recipe decision](adr/0011-custom-avatar-recipes.md).

## Refresh and motion

Image reads run separately from roster publication, with at most three active
reads. Unchanged roster refreshes keep existing reads alive. Images revalidate
on the next roster refresh after 60 seconds; pull-to-refresh or **Reload profile**
requests a fresh read sooner. If a read is already running, that request queues
one fresh read after it.

Drawn faces use the reference engine's Idle, Thinking and Happy moods. Thinking,
Working, Using tool, Replying and Needs you select Thinking. Verified completion
briefly selects Happy with one native somersault, then returns to the saved mood.
Verified failure adds one expansion and shake. The sixteen stored expression
names remain compatible: excited, happy, laughing and proud select Happy;
attentive, wary, confused and curious select Thinking; the others select Idle.
Sleepy, unavailable and offline close the canonical eyes. Unavailable shows z
marks; offline shows a static no-signal cue. These narrow status adaptations do
not add a second base blink, gaze or breathing schedule.

Each visible avatar owns one sequential frame request loop and a stable profile
time offset, so bots sharing a family need not blink together. Canceled or replaced
requests cannot publish stale frames. Cues derive attachment points from the
actual canonical contour. Thinking uses a lightbulb, tools a wrench, waiting a
question and errors an exclamation cue. Existing inbox, rail and header
accessibility values carry status; decorative painting adds no focus target.

A live renderer failure retains the last complete frame and retires that
instance before retrying with a fresh identity. Two retries wait 250 and 500 ms;
persistent failure leaves the still frame until the view's playback task restarts.
Cancellation and retired ownership stop recovery. Still rendering does not retry.
Temporary preparation failures also retry the requested definition twice while
a safe face remains visible. Only a canonical invalid-definition result selects
the family fallback for playback. The model records that fallback's actual
identity separately from the requested character. Late preparation cannot replace
a newer selection or revive retired playback.

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
stop frame loops while preserving static activity cues. No message
layout moves with the face. Energy use has not been measured.

## Developer playground

Debug and Internal builds expose **Settings → Developer menu → Avatar playground**. The tool
shows all ten activities, all ten shape families, three representative bots,
header/inbox sizes, a size slider, Replay and Reduce Motion controls. The isolated
demo exercises the same production presentation and renderer without connecting
to Hermes. The ordinary demo emits a complete reply at once; the performance
fixture also exercises a real chunk-driven Replying phase.

Launch Debug with `--developer-menu` to open the menu without setup, or
`--bot-motion-lab` to open the playground directly. Developer destinations are
kept in `DeveloperMenuView` and excluded from public Release builds. See
[developer tools](developer-tools.md) for Internal/TestFlight build selection and the
[playground guide](bot-motion-prototype.md) for controls and acceptance requirements.

Botto's image and editing rules adapt pinned
Hermex source `47809f2cd1f07bcbe592ee8960cf9c63e88b734c`. Classic identity rules
follow Hermes Desktop at `4a0eaf7989b6804319ddb94fa5d96c5a716080a1`; generated
identity follows Blobatar 2.0.0. See the bundled licenses and
[third-party notices](../THIRD_PARTY_NOTICES.md).

The vendored Open Bot Avatar validator, volume, motion, animator and prompt are
pinned at `3a5119877844165eebafe57d3100da475f67d0a8` under MIT. See
[scripts/avatar-engine](../scripts/avatar-engine/README.md) for source hashes,
regeneration and independent Node parity fixtures. `BotAvatarEngine` supplies
both premade and generated frames; no external script downloads at runtime.
