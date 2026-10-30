# Find bots and track attention (`inbox`)

## User-facing description

Find and open persistent bots, see which need attention, and keep favorites
close. Sub-features: a scrollable roster, loading/empty/offline states,
activity sampling across known chats, unread marks, local pins, and compact/wide navigation.

## How to get to it

- `inbox.e.roster`: connect or explore demo → bot list. Return using Back
  on compact layouts or the sidebar on wide iPad.
- `inbox.e.attention`: a waiting row’s context menu → **Needs you**.
  The former `inbox.e.search` and `inbox.e.filter` entries are retired.
- `inbox.e.pin`: a row context menu → **Pin bot** / **Unpin bot**, named
  accessibility **Pin** / **Unpin** action, or conversation header → profile →
  **Pin close at hand** / **Pinned close at hand**. Pinned rail also offers Unpin.

## Interactive checks

Use [shared setup](../index.md), demo for ordinary entries, and owned host
profiles with idle/working/waiting states for live activity. **Draft; not run as
complete recipes.** Pins and unread state are local, not host metadata writes.
Select list rows by `bot-row-<profileID>` and pinned faces by
`pinned-bot-<profileID>` in automation. Spoken labels can change with unread
state, content, and text size; keep checking those labels separately.

Workflow `inbox.find`:

1. `.a1` Open the roster and scroll through its rows. Expect every bot to be
   reachable without a heading, search field, or all/attention filter tabs.
   A row highlights only while pressed; no previous bot stays selected. There
   is no Return to chat action. Open a row; expect its preferred chat. Return and open a waiting row’s
   **Needs you** context action; expect its exact waiting chat even when another
   chat is preferred. Proof: row, context-menu, and conversation captures.
2. `.a2` Pull to refresh an isolated empty roster; expect loading then
   **Meet your first helper.** with **Create a bot**. With cached bots, automatic
   reconnect and polling must not show Connecting or Updating. Offline browsing,
   pins, and New bot stay usable. With no cached roster, loading or reconnect
   guidance remains useful. Proof: state captures; missing empty/waiting fixtures
   block those assertions.

Workflow `inbox.activity`:

1. `.a1` Produce harmless activity on an unselected run-owned bot. With inbox
   visible, wait up to one ten-second sampling interval plus the declared host
   operation bound. Expect known chat activity to update Working/Needs you text.
   A pending check stays quiet; an actual failed or ambiguous check preserves
   historical activity, or shows Activity unavailable when no observation exists.
   Completing a sibling’s work must clear its stale Working
   or Needs you state on the next valid sample. Preview/time and unread marks
   reflect observed conversation updates; activity sampling alone does not
   imply that an unseen transcript was read. Repeat pull-to-refresh and
   background/foreground return. Proof: host event time and settled row captures.
2. `.a2` Select and read chat A while sibling B remains unread. Return to the
   roster. Expect the bot’s unread dot to be clear and B’s picker mark to remain.
   Switch to unread B; its dot follows B until B is displayed. New content in A
   must not light B’s dot. A different **Open by default** choice must not override
   the currently selected chat’s dot. After selecting another bot or relaunching,
   expect the dot to follow the saved opening choice (preferred, last selected,
   then Main). Preserve seen markers across background/relaunch; later host
   content in that chat makes it unread again. Repeat offline with cached chats:
   switching the dot’s source must not acknowledge unseen directory evidence.
   Repeat with an idle authority chat whose old replay entries have expired:
   complete history and a snapshot covering the replay head must clear its dot.
   Active or incomplete reads must preserve unread evidence.
   Proof: row and picker states, fresh-process roster and independent read-marker
   and canonical latest-message readback. Do not claim push notifications or
   real-time global event delivery.
3. `.a3` Keep Botto's inbox visible and use another client on the disposable host
   to create an ordinary chat for an existing bot. Repeat with an already-idle
   chat and one waiting for approval. Within one ten-second sampling interval
   plus the declared host-operation bound, expect the bot's chat count and
   Needs you state to reflect the new chat without opening that bot. Completing
   the remote request must clear waiting on a later sample. An unchanged roster
   performs bounded metadata probes, with full directory reads limited to changed
   profiles. Preserve cached drafts, selection, and unread evidence. Proof:
   second-client creation/transition times, inbox captures and separate counts
   of metadata probes and full directory reads. Legacy live-only chats require
   persisted inventory before profile-owned discovery is possible.
4. `.a4` Hold an initial activity read while cached bots and chats remain visible.
   Expect useful content without Activity unavailable or background progress.
   Release the read; expect current status to replace the earlier presentation
   in place. Disconnect, then relaunch from a cache containing a successful
   working/waiting observation. Expect Previously working/Previously waiting
   with the observation time in its accessibility label, and no live Needs you
   action from cached activity. Fail a refresh and retry successfully: retain
   the saved observation, drafts, and selection until fresh activity arrives.
   Proof: held-read captures, independent cache readback and fresh-process UI.

Workflow `inbox.pins`:

1. `.a1` Pin/unpin a bot through each entry above from equivalent state. Expect
   row and rail to agree; unpin must override a host-default pin locally. Open
   the pinned face; expect the correct conversation. Proof: context/action,
   rail, and header captures for each entry.
2. `.a2` Background normally and relaunch on the same real connection. Expect
   pin overrides restored from durable local state. Independently inspect the
   run-owned cache or fresh launch; host metadata must remain unchanged.
   Proof: fresh pin read and public profile readback. Demo reset is not proof.

Workflow `inbox.navigation`:

1. `.a1` On small iPhone, open a row, return, and open a different pinned face;
   repeat on wide iPad, then resize/rotate with a selected bot. Expect one
   matching header/history and selection, readable sidebar/detail widths, and
   no duplicate presentation. Proof: snapshots/screenshots on each target.
2. `.a2` Set accessibility XXXL. Expect stacked rows with no pinned rail,
   and every bot still reachable by list. Test long names/preview and offline
   reconnect at this size in light/dark. VoiceOver must announce bot identity,
   status, unread state, and named pin actions in useful order. Proof:
   screenshots, semantic values, and VoiceOver record. Reduce Motion must not
   change selection or refresh outcomes.
   For a cached rich reply, expect a short prose preview in the row's spoken
   label instead of full HTML, code, diagrams, or file directives. Preserve bot
   name, time, status, unread/selection, and the row's open action. Raw HTML uses
   a generic preview label. Check a content-only reply and long Unicode text too.
   The automated rich-label fixture adds `--rich-inbox-demo` to
   `--demo --demo-offline` so the cached roster contains the full rich reply.

## Gotchas

Source: [InboxView](../../../../App/Views/InboxView.swift),
[RootView](../../../../App/Views/RootView.swift),
[AppStore](../../../../App/State/AppStore.swift),
[LocalHistory](../../../../App/State/LocalHistory.swift).
[Verification history](../../../verification.md) supports some phone/iPad and
largest-text checks; it does not prove every roster/attention/pin sequence here.
Polling only runs while connected inbox is visible; Hermes has no guaranteed
global event for every other bot's in-memory request transition. Cached roster
and transcript status is sanitized on load; separately saved activity observations
are historical presentation and cannot authorize work or live attention.
