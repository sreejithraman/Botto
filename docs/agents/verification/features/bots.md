# Create a bot and inspect its profile (`bots`)

## User-facing description

Name a persistent helper, give it a job and shared avatar, then open its
conversation. Inspect the bot's identity, model if supplied, and host ownership.
Sub-features: starter prompts, create validation, roster publication, interrupted
creation, profile details, pin, and avatar-editor entry.

## How to get to it

- `bots.e.toolbar`: inbox → **New bot**.
- `bots.e.empty`: empty connected inbox → **Create a bot**.
- `bots.e.profile`: conversation header avatar/name capsule → avatar pencil → **Edit bot**.
  **Edit bot** opens within the overview sheet and changes the name, description
  and [avatar](avatars.md). Cancel returns to the overview without saving. Pinning remains an [inbox action](inbox.md).

## Interactive checks

Use [shared setup](../index.md). Demo creation has no server effect and resets.
Real creation writes a host profile; use a unique owned name and inspect/remove
only its fixture through approved host management after retaining proof. Botto has
no delete-bot UI. **Draft; complete recipes were not run here.**

Workflow `bots.create`:

1. `.a1` Open each creation entry from equivalent empty/nonempty roster state.
   Expect New bot with name, **A little job to do**, the **Avatar** menu, Cancel,
   and disabled **Create bot** for empty/whitespace-only name. Try each starter
   on a fresh draft; expect its job and a suggested name only if name was empty.
   Proof: screenshots/field values. Cancel before submission must create nothing.
2. `.a2` Enter a unique name/job; choose Custom in Avatar, then choose a shared shape
   and color or **Match the name** in the Avatar menu. Tap Create once, attempt a repeat while
   pending. Expect **Making your bot…**, disabled repeat/cancel, roster containing
   the created bot, and its canonical conversation opening once. Proof: UI
   transitions plus independent public profiles/history read of exact ID,
   instructions, and appearance; no invented model-selection control.
3. `.a3` Background/relaunch and refetch the real roster/profile; expect the
   same durable bot and canonical chat. Simulate create failure before commit,
   then roster-read failure after create on isolated fixtures. Expect actionable
   error or **Your bot was created, but Botto couldn’t load it in the inbox…**;
   refresh before retrying creation. Proof: host profile count/readback and UI.
4. `.a4` Open New bot while offline or reconnecting. Prepare a name, job, and
   avatar without a connection warning. Tap valid Create; expect contextual
   connection feedback and retained form. Reconnect; expect no automatic create.
   Retry deliberately; expect exactly one created bot with the prepared values.
   Proof: form captures and independent create count/profile readback.

Workflow `bots.interruption`:

1. `.a1` Use existing DEBUG `BOTTO_UI_TEST_BOT_GATE` fixture through
   [NewBotUITests](../../../../AppUITests/ConversationUITests.swift): separate
   run-owned marker directory with `create.hold`, then `refresh.hold`, then
   `open.hold` on independent launches. Start Create via the UI and wait for
   `<operation>.started`; system-open the replacement Botto link in the same
   scene, review destination, release only that hold, wait for `.returned`.
   Expect the replacement form and destination to remain; old completion cannot
   navigate or dismiss it. Proof: captures after release and marker counts.
2. `.a2` For create/refresh holds, Cancel connection review after old completion;
   expect inbox without late chat navigation, one create call, and no open call.
   For open hold expect reviewed form retained. Repeat with normal current
   presentation: expect create/open/dismiss succeeds. Proof: UI plus
   `create.calls`/`open.started` as appropriate. Marker files support timing;
   public sheet navigation is still the assertion entry.
3. `.a3` Repeat retirement against a controlled live host if available, including
   disconnect and late error/success. Expect no automatic re-create or stale
   presentation update; independently inspect whether a profile was already
   created. Proof: host count/ID and UI. Cancellation cannot undo remote creation.

Workflow `bots.profile`:

1. `.a1` Open the bot overview and its avatar pencil from an existing and newly created bot. Expect correct name,
   description, image/face, actual host, and read-only model only when supplied.
   Save or Cancel returns to the same bot overview. Closing the overview returns to the same conversation. Proof: profile and canonical host
   identity readback; [avatar](avatars.md)/[pin](inbox.md) recipes own mutations.
2. `.a2` Repeat create/profile on small iPhone and iPad with long Unicode name
   and multiline job, accessibility XXXL, keyboard, and light/dark. Expect
   reachable controls and readable content. VoiceOver must name fields, selected
   avatar, disabled Create, and profile navigation. With Reduce Motion on,
   selection and creation outcomes stay the same. Proof: screenshots and actual
   focus-order record.

## Gotchas

Source: [NewBotView](../../../../App/Views/NewBotView.swift),
[BotProfileView](../../../../App/Views/BotProfileView.swift),
[AppStore](../../../../App/State/AppStore.swift),
[DemoBotService](../../../../App/Demo/DemoBotService.swift).
The gate deliberately ignores cancellation to represent already-started work;
normal Demo has no hold. Remove only run-owned marker files. Historical native
and UI evidence in [verification](../../../verification.md) supports creation
and three presentation interruptions. Existing UI tests cover selected interruptions, but
do not prove this entire first-run/empty/live/persistence recipe. Host-side
cancellation remains unproved. A published profile is required before navigation;
an RPC return alone cannot establish the inbox is ready.
