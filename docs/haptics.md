# Botto haptics

Botto should feel responsive, soft, and a little alive. Everyday feedback should
make actions clear. Playful feedback should give the bots character at moments
people can recognize: a sheet landing, a bot asking for help, and work finishing.

The haptic vocabulary separates input, acceptance, reply completion, and celebration.
Pattern timings are candidates for comparison on a physical iPhone.

## Haptic vocabulary

Use the same meaning across every bot and screen. Choose the rhythm first;
strength should follow how often the event happens and how much attention it needs.
The names below describe the feel for design discussions, not interface labels.

| Meaning | Feel | Why |
| --- | --- | --- |
| Selection | **Tick**: one tiny, crisp step. | A selected value changed. Fast browsing stays precise. |
| Acceptance | **Tap**: one light, clean pulse. | An action was accepted. It does not promise that the bot finished its work. |
| Surface | **Cushion**: one quiet, rounded contact. | A deliberate sheet or panel arrived and settled into place. |
| Attention | **Knock**: two equal, soft taps with a clear gap. | The bot needs an answer. It should feel inquisitive rather than alarming. |
| Reply finished | **Done**: one small, upbeat pulse. | A verified turn ended normally. This says nothing about answer quality. |
| Celebration | **Ta-da**: three short, gently rising taps. | Something finished successfully. This is Botto's small celebration. |
| Stop | **Thud**: one short, firmer, damped pulse. | The requested work actually stopped. It should feel final without feeling punitive. |
| Caution | System warning feedback. | A visible result needs care, such as an uncertain submission. |
| Failure | System error feedback. | An action or turn definitively failed. Keep this familiar and distinct. |

Start with system selection, light/soft/medium impacts, and warning/error
feedback. Author Knock and Ta-da with Core Haptics when the intended rhythm needs
it. Cushion can start with a single soft impact; a custom engine is not required
for every playful moment. Do not layer a system success pattern under Ta-da.

Compare a 140–180 ms gap for Knock and accents near 0, 65, and 150 ms for Ta-da.
Knock stays level; Ta-da rises gently. These are relative design differences,
not a promise that people will distinguish them until tested.

## Event map

| Event | Pattern | Trigger and visible landmark |
| --- | --- | --- |
| Send, steer, or queue a message | Tap | A definite host receipt is accepted and the UI reflects admission. A button press alone is insufficient. |
| Submit an approval, denial, or answer | Tap | Hermes confirms the response. Denial is a valid choice and gets the same acknowledgment. |
| Copy text or finish a requested attachment import | Tap | The pasteboard write or import succeeds and Copied or the attachment chip appears. A picker cancellation stays quiet. |
| Choose an avatar shape, color, or chat | Tick | The user's choice changes the local selection. An avatar preview is a local choice, not a saved profile. |
| Open a selected sheet | Cushion | The actual sheet reaches its presented state. See the sheet map below. |
| A new actionable request arrives | Knock | Its card becomes visible in the active chat. A batch gets one knock; restored requests do not knock again. |
| A reply finishes normally | Done | A new verified successful turn reaction begins. A small cue marks the end of work without judging the answer or celebrating every reply. |
| Create a bot, save its profile, or complete connection setup | Ta-da | The requested operation is confirmed and its successful result is visible. New-bot creation gets one welcome celebration, shared with the completed flow. |
| Stop work | Thud | The host confirms the stopped state. An acknowledgment of a stop request alone is insufficient. A racing natural completion follows its actual outcome. |
| An action's result is uncertain | Warning | Show the uncertainty and recovery guidance. This does not mean the mutation failed or can safely be repeated. |
| A definite action or turn failure appears | Error | Show the failure and a recovery path. One cue per outcome, including repeated failures from separate deliberate attempts. |

Ordinary navigation, typing, scrolling, cached content loading, avatar breathing,
thinking loops, and tool progress stay quiet. Opening an old chat does not
celebrate its last reply. A disconnect in the background does not create an
error haptic while the user continues reading or drafting.

## Sheets and panels

Use Cushion for surfaces people deliberately bring forward. Its meaning is
physical arrival, so it plays even when the content can be read offline. It
does not claim that a network action succeeded.

| Surface in Botto | Proposed feedback |
| --- | --- |
| New bot sheet | Cushion on arrival. Ta-da only after confirmed creation. |
| Bot profile sheet | Cushion on arrival. Edit bot is a navigation destination inside this sheet, so it gets no second sheet cue. |
| Settings sheet | Cushion on arrival. Subpages and licenses stay quiet. |
| Connection sheet | Cushion when opened deliberately. Automatic recovery or an external route opening it stays quiet. Setup success has its own confirmed outcome cue. |
| Work details sheet | Cushion on arrival. Keep native feedback when changing between medium and large height; avoid a second custom tick. |
| Rich reply source or expanded preview | Cushion on arrival. Changing Source/Preview within the same presentation gets Tick if the selection changes. Background renderer completion stays quiet. |
| Setup prompt preview | Cushion on arrival. Copy uses Tap. |
| Chat overview | Cushion on opening, because it brings forward a distinct panel. It is an inline overview beneath the fixed header, not a bottom sheet. Choosing another chat uses Tick. |
| Native photo/file picker, share sheet, context menu, confirmation dialog, QR scanner | No added presentation haptic in the first version. Preserve native feedback and avoid doubling it. |
| Artifact reading pane | No generic sheet cue. It belongs to the workspace's reading layout, not the sheet presentation system. |

Normal dismissal stays quiet initially. A cancelled drag does not play an arrival
or dismissal cue. For a height change, play once at the committed detent, never
on every drag update, layout adjustment, or content-driven resize. Add a custom
detent cue only if the device check shows that native behavior leaves a gap.

The sheet owner emits one presentation event. Do not add a second tap to the
button that opens it or fire from repeated `onAppear` callbacks. SwiftUI and
UIKit transcript presentations must follow the same policy. Use a reliable
presentation completion or committed-selection signal; do not guess a delay to
simulate a landing. If a native transition cannot expose the needed landmark,
use one quiet onset cue and describe it as the sheet lifting instead.

## Playful moments

The fun comes from the connection between touch and what the bot does on screen.
A common vocabulary lets those moments build a recognizable character.

- **A quiet done.** A verified reply completion gets one small pulse alongside
  the existing avatar completion reaction. It does not vibrate through the
  somersault or add a second landing celebration. Ta-da belongs to explicit
  milestones such as creating a bot, saving its profile, and finishing setup.
- **A polite knock.** The question cue and request card appear with the same
  gentle double tap. Persistent waiting and repeated question-mark motion stay
  silent.
- **A soft cushion.** Important sheets feel like a light object settling into
  the hand. The feel stays the same across profile, creation, and reading tools.
- **An avatar plip.** In Playful mode, compare a slightly rounder single selection
  pulse for a new shape against the ordinary Tick for a color. Keep both single
  and short enough for rapid browsing. Picker previews stay still, and neither
  cue implies that the avatar was saved.
- **A welcome.** Confirmed bot creation reuses Ta-da as the new face appears.
  Returning to the inbox or reconnecting never repeats the welcome.

Keep typing texture as a separate experiment: Pulse while streaming, off by
default. If enabled, use sparse, low-strength ticks at least 320 ms apart only
while new answer text arrives in the visible active chat. Stop immediately on
inactivity, coverage, chat changes, interruption, or preference changes. It is
not a timer, a pulse for every token, or feedback for reasoning and tools.

## Preferences and playback rules

Offer one Haptics choice: **Off**, **Subtle**, or **Playful**. Proposed default:
Playful. Subtle keeps the event meanings with restrained single impacts and
system success/warning/error patterns. Playful adds Knock, Ta-da, and the avatar
selection accent. Off suppresses all Botto-generated playback. Pulse while
streaming is a separate switch, default off, unavailable while Haptics is Off.

These settings govern app feedback; push notification permissions and system
control feedback remain separate. Native controls keep their own selection
feedback; add Tick only where a custom control needs it. Do not add per-bot settings or random pattern
variants in the first version. No sound is added by this proposal.

Every event needs an identity and one playback owner. Gate playback to the
active scene and the surface the user is using. Consume hidden or stale events
without replaying them later. Covered chats do not knock or celebrate under a
sheet. Explicit actions inside that sheet can still acknowledge their results.

When events collide, preserve the meaningful outcome rather than stacking
patterns: error or warning takes priority over celebration, and a confirmed
creation celebration replaces a coincident dismissal or receipt cue. New direct
input can cancel a decorative flourish. Drop superseded accents instead of
queuing late vibrations. Coalescing never suppresses the visible result.

Reduce Motion keeps useful haptics and aligns them to the reduced visual
sequence. A static reply completion can receive Done immediately; it must not wait
for a removed somersault. Unsupported hardware continues without touch feedback.
Engine interruptions, resets, and preference changes stop pending patterns;
recovery never replays an old event. If custom playback fails on a device that
supports system feedback, use a single soft impact for attention and system
success for celebrations. Reply finished keeps its single soft pulse. Never delay the action to restart the engine.

## Implementation and tuning

Keep semantic events separate from pattern playback. The workspace already owns
confirmed mutations and identified live turn reactions. The presenting view
owns sheet arrival and current visibility. Neither should infer success from a
loading flag becoming false. Confirmed chat events go directly to playback after
current-reader checks, so a view redraw cannot replace a warning with a streaming
tick. Sheet presentation remains owned by its SwiftUI or UIKit presenter.
See [the live activity contract](core-integration.md#live-avatar-activity) and
[avatar motion](avatars.md#refresh-and-motion).

Debug and Internal builds expose **Settings → Developer menu → Haptics playground**. Compare
Subtle and Playful, open a real sheet, and play the vocabulary with an avatar
reaction without sending messages or changing a live bot. The controls share
the app's saved haptics preferences. See [developer tools](developer-tools.md)
for Internal/TestFlight build selection.

On a physical iPhone, compare the quiet patterns over twenty sends, repeated
sheet openings, and rapid avatar selection. Check that Knock and Ta-da are
recognizable without looking. Verify repeated outcomes, cancelled presentation,
detent drag reversal, errors, uncertainty, replay, chat switching, background
return, and all preferences. Test unsupported hardware and engine recovery.
Record device and OS; a Simulator or recording cannot establish tactile quality.

Apple's [haptic guidance](https://developer.apple.com/design/human-interface-guidelines/playing-haptics)
supports short, consistent, optional feedback with clear causes. The event
choices and playful patterns here are Botto's proposed design.

The app comparisons came from public source in
[Hermex](https://github.com/uzairansaruzi/hermex/blob/5dc5e2ff1b5db9d15e302983b073f0a831ee97e1/HermesMobile/Features/Chat/ChatHaptics.swift),
[Hermes Conduit](https://github.com/kaishi00/hermes-conduit/blob/03d991ca97fb815b1c3aca6c6ce69042db366528/Conduit/Services/Haptics.swift),
and [Vory](https://github.com/matt0975/vory/blob/8cbb8a07bed1c61ab4565819701c6c8f81da523c/Vory/Chat/ImageTranscode.swift).
