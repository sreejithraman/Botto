# Avatar playground

The Debug/Internal playground uses the same pinned Open Bot Avatar engine and
native Canvas painter as production. Its local activity controls live in
`App/Demo/BotMotionPrototype.swift`. Preset families and generated characters
share one renderer; the earlier comparison styles are removed.

## Open it

In Debug or Internal, open **Settings → Developer menu → Avatar playground**. Done returns
to the menu.
The menu and playground are excluded from public Release builds. See
[developer tools](developer-tools.md) for the Internal scheme and TestFlight setup.

For a standalone session without a connection, launch the Botto scheme with
`--developer-menu`. `--bot-motion-lab` remains a direct playground entry.
The standalone menu has **Back to app**; it starts the normal workspace only
when pressed. The Settings entry uses the normal back button to return to Settings.
No account or host is needed. The playground's demo owns isolated connection
storage and an injected DemoBotService; it never changes the connected workspace.

## Play with motion

Tap an activity card or use the Activity menu. Replay restarts local samples.
Thinking, Working, Using tool and Replying keep one work clock when switching
phases. The size slider compares 30–96pt faces; the gallery also shows native
56pt inbox rows, a 30pt header and all ten shape families.

| Activity | Performance |
| --- | --- |
| Idle | Canonical Idle mood with independent profile time offsets. |
| Thinking | Canonical Thinking with a lightbulb cue. |
| Working | Canonical Thinking. |
| Using tool | Canonical Thinking with a contour-attached wrench. |
| Error | One expansion and shake, then an exclamation cue. |
| Needs you | Canonical Thinking with a question cue. |
| Replying | Canonical Thinking. |
| Finished | Brief Happy mood, one tucked somersault, then the saved mood. |
| Unavailable | Closed canonical eyes with rising z marks. |
| Offline | Closed canonical eyes with a static no-signal cue. |

Preview Reduce Motion and inactive scenes stop frame loops while preserving
static semantic cues. Saved images and picker previews stay still. Attachment
points derive from projected canonical contours at every size. Canonical mood
easing owns ordinary transitions; native status reactions do not replace its
blink, gaze, volume or base motion.

## Follow activity

Try in demo opens the isolated sample workspace. Inbox, pinned and chat avatars
use the same shared presentation path as connected bots. The ordinary demo
performs generic work then emits its complete reply and one success reaction.
The performance fixture adds real chunk-driven Replying. Samples never pretend
to invoke a tool or produce a real error.

In a connected workspace, the selected live chat can expose thinking, tools,
reply text and verified outcomes. Other chats use current coarse observations.
Profile aggregates keep waiting/working sibling precedence. Successful admission,
idle snapshots, Stop, cancellation, disconnect and restored replay never count
as successful execution. Reactions carry original time/identity across ordinary
refreshes, and view recreation does not restart them. See [avatar ownership and
live signal limits](avatars.md#refresh-and-motion).

The completion reaction lasts 1.85 seconds and never repeats from an idle
snapshot. Each visible instance requests at most one frame at a time, normally
up to 30Hz. Offscreen, inactive and reduced-motion instances have no repeating
frame loop. Cold preparation runs off-main with canonical resting previews;
warm frames reuse immutable native paths. Energy use and physical-device feel
require separate measurement.

## Verification

`BotFaceMotionTests` cover narrow reaction timing, reduced-motion policy and
stored-expression mood mapping. `BotAvatarLayoutTests` cover palette, image
precedence, fitted bounds and cues. `CustomAvatarLayoutTests` prepare actual
canonical assets and paint fixed frames for all ten families and official custom
examples, including arcs, side views, Happy eyes and containment.
`OpenBotAvatarEngineTests` compare the Swift bridge with independently generated
Node reference frames. Test coverage is not a claim that these checks passed
for the current snapshot.

`BotAvatarPresentationTests` and BottoCore's `ConversationActivityTests` retain
ownership of work clocks, aggregate precedence, verified outcomes, replay and
stale-event behavior. Complete acceptance must also exercise the real playground,
replay and interrupted states, every family at header/row sizes, saved images,
actual system Reduce Motion, scene transitions, VoiceOver and a live verified
outcome. Historical observations of the earlier renderer do not prove the
canonical renderer. Record current results in [verification](verification.md).
