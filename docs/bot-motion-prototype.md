# Avatar playground

Drawn avatars use Playful motion in production. The Debug/Internal
playground retains comparison styles and local activity controls for iteration.
All samples and live avatars use `App/Design/BotAvatarMotion.swift`; sample controls
live in `App/Demo/BotMotionPrototype.swift`.

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
| Idle | Quiet breathing, sparse blinks and occasional eye movements. |
| Thinking | Shared work rhythm, upward gaze and a warm glowing lightbulb. |
| Working | Hops, rocking, double bounces, scoots, stretch/tuck and wiggles. |
| Using tool | Shared work rhythm, open watchful eyes and a wrench. |
| Error | One expansion and damped shake, then wide eyes and a circular speech cue. |
| Needs you | Pondering head tilts, thoughtful glances and a tilted question bubble. |
| Replying | Shared work rhythm with conversational gaze. |
| Finished | One tucked full somersault, sparkles and a soft landing into idle. |
| Unavailable | Closed eyes with three independently rising, fading z marks. |

Original retains the earlier sparse-blink/working-sway baseline. Attentive keeps
the body rigid with smaller lifts, Soft deforms gently, and Playful adds emphasis.
Production uses Playful. Preview Reduce Motion and inactive scenes remove
timelines while preserving still semantic cues. Saved images and picker previews
stay still. Activity cues keep the same base size at equal avatar size; their
positions adapt to the face's eye bounds.

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

The six work phrases rotate over 22.8 seconds with bot-specific ordering. The
completion reaction lasts 1.85 seconds. Its final angle remains unwrapped during
late style blending to avoid an extra turn. Motion changes blend from the visible
pose over 0.24 seconds; cues crossfade over 0.18 seconds. Timelines sample up to 30Hz.
Energy use and physical-device feel have not been measured.

## Verification

`BotFaceMotionTests` cover pose timing, static rendering and the completed turn's
orientation during late style changes. `BotAvatarPresentationTests` cover shared
clocks, aggregate precedence, reaction identity and lifetime. BottoCore's
`ConversationActivityTests` exercise both Hermes adapters through captured
transport fixtures, including replay, tool overlap, stale generations and
same-chat rereads.

Simulator checks exercised all nine activities, all ten shapes, Replay, size
changes, Reduced Motion, developer navigation and the isolated demo. An actual
demo reply produced one completion reaction; stopping a longer streamed reply
produced none. A signed Debug build was installed on an iPhone and the
playground was confirmed visible. These observations do not establish physical
animation timing, exhaustive containment, VoiceOver, iPad or energy behavior.
