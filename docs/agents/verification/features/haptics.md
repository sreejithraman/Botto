# Choose haptics and feel chat feedback (`haptics`)

## User-facing description

Choose quiet or playful touch feedback for accepted actions, finished replies,
requests, selected sheets, and milestones. **Done** is a small cue that a reply
finished normally; it does not judge the answer. **Ta-da** belongs to milestones
such as creating a bot, saving its profile, and completing setup.

## How to get to it

- `haptics.e.settings`: Settings → **Touch** → **Haptics** and **Pulse while streaming**.
- `haptics.e.chat`: open a bot and send, answer a request, or stop controlled work.
- `haptics.e.sheet`: open Settings, New bot, bot profile, work details, or a rich reply preview.
- `haptics.e.playground`: Debug/Internal Settings → **Developer menu** → **Haptics playground**.

## Interactive checks

Follow [shared setup](../index.md) and the [haptic map](../../../haptics.md).
Use supported physical iPhones to judge sensation and timing. Record device,
OS, app revision, haptic mode, system settings, and the actual event beside each
observation. Use an owned disposable host for confirmed mutations and a
controlled streaming/request fixture. Demo and the playground do not prove host
admission or cancellation. **Draft; physical tactile quality and complete
workflow acceptance remain unproven.**

Workflow `haptics.preferences`:

1. `.a1` Start with an owned fresh preference domain. Expect **Playful** selected
   and **Pulse while streaming** off. Choose Off, Subtle, and Playful, then
   relaunch normally after each. Expect the selected mode and streaming choice
   to persist without replaying old feedback. Off disables the streaming switch
   and suppresses all Botto-generated haptics. Proof: visible selected values,
   fresh preference readback, and device observation.
2. `.a2` Compare the same events in Subtle and Playful. Expect quiet single
   selection/acceptance cues in both; Playful adds the knock and milestone
   flourish. A normal reply finish stays a small Done in both. Keep all visible
   and accessible outcomes with Off or unsupported hardware. Proof: event log,
   tactile notes, and actual VoiceOver focus/value checks.
3. `.a3` Keep streaming off during a long reply, then deliberately enable it for
   another. Expect sparse pulses only for new answer text in the visible active
   chat, at least 320 ms apart. Thinking and tool updates stay quiet. Cover the
   chat, switch chats, background, and change preference mid-reply; expect pulses
   to stop and no queued replay on return. Proof: timed event requests plus
   physical observation. Restore the run's preference changes.

Workflow `haptics.chat`:

1. `.a1` Hold a send acknowledgment, then release acceptance. Expect no admission
   cue while merely pending and one Tap after confirmed acceptance. Repeat a
   separate accepted send. Complete a normal live turn; expect one small Done,
   never Ta-da. Copy and confirmed attachment import acknowledge their own
   successful outcomes; cancellation stays quiet. Proof: host receipts, visible
   outcomes, identified feedback requests, and tactile notes.
2. `.a2` Deliver a new actionable question or approval to the active chat.
   Expect one Knock for its arrival; repeated publication and restored history
   stay quiet. Submit an authorized choice or answer and await host acceptance;
   expect Tap, including intentional denial. Stop controlled work; expect Thud
   only after both acknowledgment and a verified stopped outcome, in either
   arrival order. Idle alone or a pending Stop does not prove cancellation.
   Proof: current request/host outcome, event identities, and physical timing.
3. `.a3` Exercise definite failure and uncertain acknowledgment separately.
   Expect Error for definite failure and Warning with uncertainty guidance for
   an ambiguous result; neither supplies false acceptance or automatic retry.
   Cover or replace the chat/connection while an operation is pending and release
   its old result. Expect no stale cue on the new surface. Reconnect, replay the
   same outcome, and return from background; expect no duplicate or late cue.
   Proof: original/current ownership, host readback, visible recovery, and event
   requests. A refreshed access grant for the same visible reader must not
   suppress its otherwise confirmed acknowledgment.

Workflow `haptics.sheets`:

1. `.a1` Deliberately open each selected sheet and chat overview. Expect one
   quiet Cushion at presentation, without a second button-tap cue. Dismiss and
   reopen; expect one new cue, while ordinary dismissal stays quiet. Profile
   editor navigation, Settings subpages, and repeated view appearance must not
   invent another presentation. Proof: presentation identities, timed screen
   recording, and physical observation.
2. `.a2` Drag a work-details sheet between supported detents, reverse a drag,
   and trigger content/rotation layout changes. Expect native detent feedback
   without a doubled Botto cue, no per-drag pulse, and no false dismissal cue for
   cancellation. Native photo/file pickers, share sheets, context menus, and
   confirmation dialogs receive no added Botto presentation haptic. Proof:
   recorded gestures, playback requests, and physical comparison.
3. `.a3` Deliver a reply outcome while a sheet covers its chat, then close it.
   Expect no underlying Done/Knock or deferred replay. A confirmed action inside
   the sheet can acknowledge its own result. Repeat with Reduce Motion enabled:
   feedback follows the reduced presentation and never waits for a removed
   animation. Proof: system setting, surface ownership, and timed observations.

Workflow `haptics.playground`:

1. `.a1` Open the Debug/Internal playground, audition every vocabulary item, and open the
   sample sheet in Subtle and Playful. Expect the existing avatar renderer to
   show the selected reaction, Done to remain small, and Ta-da to occur only
   when Celebration is explicitly auditioned. No live message, bot, or profile
   mutation may occur. Proof: visible controls/reactions and no host mutations.
2. `.a2` Compare twenty sends, repeated sheets, and rapid avatar choices on a
   supported iPhone. Check that Knock and Ta-da are distinguishable and quiet
   feedback remains comfortable. Turn Off, background during a flourish, and
   exercise an engine interruption/reset with an owned diagnostic fixture.
   Expect cancellation, no old-event replay, and later valid feedback or a
   quiet system fallback. Proof: device/OS/settings, tactile notes, and lifecycle
   playback requests. A missing physical target blocks these feel assertions.

## Gotchas

[Haptics tests](../../../../AppTests/HapticsTests.swift),
[chat feedback tests](../../../../AppTests/ConversationHapticTests.swift), and
[presentation tests](../../../../AppTests/HapticPresentationTests.swift) verify
requested output and lifecycle behavior, not sensation. Simulator recordings
cannot prove tactile strength, latency, comfort, or pattern recognition.
Push notifications and native system feedback have separate preferences; Off
governs Botto-generated playback. See the [verification record](../../../verification.md)
for actual checks and remaining limits.
