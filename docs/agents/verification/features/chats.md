# Choose independent chats with a bot (`chats`)

## User-facing description

Keep separate conversations with the same bot. Open the card picker from the
separate overlapping-cards button, create a chat, or choose which chat opens by
default. The tab overview is the only in-chat switching entry. The header
avatar/name control opens profile details without chats. Main remains the
host's canonical Bot Chat. A preferred opening chat is a local preference, not
a promotion or server rename.

Sub-features: bot-scoped cards and search, independent chat creation, remembered
and preferred selection, per-chat drafts and files, aggregated attention, cached
reading, and retirement of old actions.

## How to get to it

- `chats.e.header`: open a bot → overlapping-cards button in the header
  → the chat-pane tab overview beneath the fixed header. Use this picker for all in-chat selection.
- `chats.e.new`: overview → **New chat** in the bottom bar → independent chat.
  Search stays above the cards. The fixed chats button returns to the current chat. The overview
  contracts only the transcript into its card and expands the selected card on
  return. The same header stays fixed and usable; the composer fades out and in.
  The standard navigation scroll-edge treatment keeps status indicators legible
  over scrolling text.
  Unavailable card geometry and Reduce Motion use a fade. A missing idle
  thumbnail must not prevent a mounted pane from zooming.
- `chats.e.card`: picker → a chat card. Main appears first. Card context actions
  offer **Open by default** or **Use last opened chat**.
- `chats.e.attention`: inbox row context menu → **Needs you** → the exact waiting conversation.

## Interactive checks

Follow [shared setup](../index.md). Use ordinary Demo for visible card and input
checks, then an owned real host for persistence, live activity, and independent
history readback. Demo resets cannot prove durable drafts or preferences.
**Draft: native button-only and service checks support selected paths;
complete recipe execution remains unproved.** See the
[verification record](../../../verification.md) for tested paths, fixture
corrections and remaining limits.

Workflow `chats.choose`:

1. `.a1` Open a bot with no prior local selection, then open the overlapping-cards
   button. Expect Main selected. Search by a known title or excerpt, clear search, then
   select another card. Expect the correct title/history and selected card;
   Main stays first. Visit a chat, scroll to known content, allow interaction to
   settle, and reopen the picker. Expect its last-viewed viewport in the card.
   Expect the overview to fill the chat pane without a sheet handle. The same
   header and native Back stay visible and usable, and the composer fades. Open and close
   it repeatedly with the fixed chats button; filter out the current card and
   use that button again. The
   same draft, cursor and reading position must remain usable. Inspect entry and
   return in a recording, including Reduce Motion and rotation. The full-size
   transcript must stay covered while its card expands. Scroll and immediately
   open the overview; the mounted pane must zoom without waiting for an idle
   thumbnail. Text must remain sharp as it approaches full size. Switch to a
   different chat before its native viewport finishes mounting; only that
   destination may expand once it is ready.
   Every preview fills the same card ratio, cropping from the top-left without
   stretching. A native snapshot replaces the generated excerpt completely;
   no excerpt may show beside or behind it, including before an idle capture.
   Open the bot sheet from a filtered grid and dismiss it. The same grid and
   search must remain underneath. The footer count is plain text, with no Done
   checkmark. Close a non-Main tab using its X; closing another tab must not
   select it, and closing the current tab must keep the grid open. Returning to
   the cached replacement through its card or header must restore usable composing
   and sending. New chat must also work directly from that grid without opening
   the replacement first. Keep local drafts usable offline and after a failed
   attachment; stale return actions must not change a newer chat. Undo and
   Closed chats must reveal the same history and draft. Main and the last
   visible tab cannot close. Closed tabs stay closed across refresh and local
   restoration, but explicit attention navigation can reopen one. Closing is
   local to this device and must not stop work or delete a Hermes chat.
   Chats without a snapshot use cached excerpts with the transcript's bubble and
   text styling. Preview work must not open a chat or clear its unread state.
   Proof: screen and semantic captures at each transition.
2. `.a2` Choose New Chat and attempt repeated input while creation is pending.
   Expect one independent creation and bounded pending feedback. Repeat from a
   non-Main source and close it before creation completes. The grid must stay open,
   with no remote open of its cached replacement; completion retains the new
   card without selecting it or reopening the closed source. Refresh and
   reopen it. Proof: public session inventory, create-request count and exact
   stored identity. A lost creation reply reports uncertainty and never retries
   automatically; inspect the directory before choosing another creation.
   While creation is held, open the fixed profile control and edit a field.
   Release creation; the profile editor and its unsaved choices must remain.
   After closing Profile, the created chat must still be available. A new chat
   without a cached viewport must expand its own mounted view, without expanding
   the old chat image.
   A genuinely new blank live-only draft should have no unread badge; this must
   not manufacture a read acknowledgement or a reusable empty-history grant.
3. `.a3` Set an ordinary chat to Open by default. Leave, reopen the bot, then
   background and relaunch on a real connection. Expect that chat. Choose Use
   last opened chat, select another chat and repeat. Proof: fresh-process UI
   and independent local preference read. Main's server identity/title must
   remain unchanged throughout.
4. `.a4` In Main with an empty composer, drag left across the composer. Expect
   Main to remain selected after the drag settles. Then use the overlapping-cards button to select Weekend plan and Main in turn. Expect each card to open its
   own title/history. Proof: actual drag, settled title and picker transitions.
   `testEmptyComposerDragKeepsChatUntilHeaderPickerSelection` covers this public
   regression. Selected native checks cover this drag and picker path;
   complete recipe execution remains draft.
5. `.a5` Type, select text, move the cursor, use supported multitouch editing,
   scroll vertically and scroll attachment chips. Open attachment and Send
   controls separately. Expect normal editing, scrolling and control behavior.
   System Back remains native, including its edge gesture; rich-diagram zoom
   remains unchanged. Inspect accessibility actions: Previous Chat and Next
   Chat must be absent. Proof: actual editing/control results, navigation and
   zoom, plus accessibility action inspection. Do not require a rightward
   composer drag to stay in the conversation; it may invoke system Back.
6. `.a6` Select cards at accessibility text sizes and on iPad. Expect readable
   titles, selected/default/unread/status names and reachable controls. Inspect
   VoiceOver focus separately; an accessibility snapshot alone does not prove
   spoken interaction.

Workflow `chats.isolation`:

1. `.a1` Use the header picker to type different drafts and stage files in A
   and B. Return A→B→A through that picker, send only A, and edit A while its
   acknowledgment is held. Expect only A's exact submitted revision/files to
   clear; newer text and B's state remain. Proof:
   per-chat UI, source receipt, independent history and attachment readback.
2. `.a2` Make A await an approval while B runs. Leave for the inbox, use Needs
   you, and answer A once. Expect exact A routing and tool effect, with B still
   independent. Deliver a repeated request ID in another chat using a controlled
   fixture; a stale A action must not answer B. Proof: public pending identities,
   answer counts and independent tool results.
3. `.a3` Hold opening, creation, upload and answer completions separately. Switch
   chats or open connection review before releasing success/error. Expect no
   stale navigation, chip, request action or dismissal of the replacement form.
   A host-acknowledged source action remains acknowledged without resubmission.
   Repeat with rich and artifact callbacks; old preview authority must retire.
   Proof: rendered owner, new form, mutation counts and origin readback.
4. `.a4` Reject an oversized question answer before dispatch, then deliberately
   submit a corrected answer. Expect no first write and one corrected write.
   Old queued attempts and uncertain outcomes must not resubmit. Proof: visible
   error and current request, captured attempt IDs and independent answer count.
5. `.a5` Read A, select B, then add content to A from another client. Refresh the
   picker. Expect A's unread badge and newer available summary. Displaying only
   stale cached A must not clear that badge. Open the current A history and
   display the new content; only then should it clear. Proof: both card states,
   fresh server history and independently decoded persisted read evidence.
   Include a source-shaped hidden-row or compacted-history case. Inventory
   counts are opaque active-tip metadata, not displayed message counts. A new
   complete read must follow the matching inventory observation; cached repaint
   or later metadata alone cannot acknowledge it.
6. `.a6` In the selected live chat, send a message and read its completed reply.
   Refresh the picker and return to the transcript. Expect the read reply to
   clear the chat's unread badge after any required complete reread. Preserve
   a newer draft, keyboard focus and scrolled-back reading position. Open the
   picker while a controlled reread is held; it must stay open, and completion
   alone must not acknowledge covered content. Proof: visible card/transcript,
   exact source mutation count, ordered read evidence and independent cache.

Workflow `chats.recovery`:

1. `.a1` On a real connection, background to flush distinct whitespace-bearing
   drafts, selected/preferred chat and history. Relaunch; inspect an independent
   cache read as well as UI. Expect exact per-chat restoration. Previously
   staged files require fresh attachment authority after process restart.
2. `.a2` Make the owned route unavailable and reopen cached chats. Expect
   readable history and editable drafts without passive connection notices.
   Attempt creation, sending, uploading, or a decision; expect connection
   feedback at the attempted action and no mutation. Restore the route; expect
   the same proven stored chat, retained question drafts, and fresh request
   actions. Require a deliberate retry; recovery must not replay an attempt.
   Proof: fresh-process UI, public identity readback and zero offline mutations.
3. `.a3` Load an owned legacy cache with orphan drafts/history, then separately
   corrupt and unknown-version files. Expect lossless migration of valid data;
   unresolved history stays readable without guessed server identity. Invalid
   bytes remain preserved with an honest warning, not overwritten by an empty
   cache. Proof: independent before/after bytes and new-process UI.

## Gotchas

Cards show known inventory; incomplete directory/activity information must stay
distinct from current activity. Pending activity checks stay quiet; historical
working/waiting observations use Previously working/Previously waiting and expose
the last check time to accessibility. Failed checks preserve historical observations;
Activity unavailable requires a failed or ambiguous check without a prior observation.
Unknown activity is not idle or offline. Sidecar empty chats can be
live-only until their first prompt; cached metadata alone never grants an empty
history exception. Switching never closes or stops server work.

A staged upload's path is a server identity, not permission to send it. Preserve
the complete returned attachment, including its staging token. Old history and
restored descriptors do not authorize a staged send. Removing a chip does not
promise remote file deletion.

Related recipes: [chat text/history](chat.md), [requests](requests.md),
[uploads](uploads.md), [inbox](inbox.md), [rich content](rich.md), and
[artifact retirement](artifacts.md). Component policy tests and direct host
scripts support boundaries but do not prove the integrated native workflows.
