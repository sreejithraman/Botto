# BottoCore integration

`HermesBotService()` implements `BotService` on the main actor. The app supplies
connection persistence and a conversation workspace; the service owns live access.

Decision rationale: [direct Hermes access](adr/0002-direct-hermes-backend.md),
[durable identity and live access](adr/0003-durable-identity-live-access.md), and
[uncertain mutations](adr/0005-uncertain-mutations.md).

- Set `onEvent` before connecting. `.configuration(updated)` must synchronously save the entire updated connection to Keychain. A rotated native refresh token is consumed by the host; saving it is required even if its connection is no longer selected. On save failure, call `disconnect()` before returning. The core checks retirement immediately after this callback before using the access token. Do not log these events.
- The core owns reconnect attempts (1, 2, 4, 8, 16, 30 seconds). `.connected(info)` follows successful reconnect and selected-chat reattachment. `.disconnected(reason)` disables controls. Permanent identity/auth/protocol refusals stop retries. Explicit `disconnect()` cancels reconnect and closes only the client socket; server work continues. Call it for background, and reconnect/open on foreground. Do not reconnect on `.inactive` alone.
- `SessionIdentity` separates exact profile, lineage root, current stored transcript and proven aliases. `ExactID` compares UTF-8 bytes. `Conversation.id` remains the live RPC runtime; `storedID` is its durable transcript. `openChat` returns `OpenedConversation` with a non-Codable service-issued access value. All mutations take that access, never a raw cached Conversation. Capture app presentation intents before creating asynchronous tasks. Cache records use connection-scoped local chat UUIDs; cached requests cannot authorize actions.
- Calls return an error for lost mutation acknowledgments and never automatically repeat a write. `.uncertain` means possibly accepted: retain the draft, display the message, and inspect the refreshed conversation before another send. Authority submission UUIDs are saved before dispatch in Application Support, without text or credentials; this journal is not an outbox.
- Bot creation uses host model defaults and shared host credentials (`share_auth:true`). A nonempty `BotDraft.model` is refused because the interface lacks the required provider identity. SOUL instructions, name and emoji are saved. Current authority creation waits up to 45 seconds for the name in `/api/status.gateway_shared_with`, polling reads only. `model_inherited:false` also means a model was already seeded; `profiles.describe` confirms it before reporting a missing default. Partial creation reports a specific error; refresh the list before trying again.
- Unknown/credential/Desktop requests remain visible as `.unsupported`; never auto-answer or hide them. Approval choices come from the host. Batch clarification questions become separate cards. Multi-select can use a free-text answer until the UI supports choosing several labels.
- Both protocol adapters are selected by `gateway.ready.payload.session_authority`. Sidecar uses verified `close_on_disconnect:false`. Authority omits that key, negotiates `runtime.describe`, creates with advertised `gui`, uses durable submission IDs and current generation fences, and restores atomic `pending/prompts`. The `gui` source is accepted by both inspected implementations; Botto never writes Hermex's platform note.
- Password and native-refresh auth validate the reviewed origin, status/version and any public installation identity before credentials. Webapp may hide `install_id` before sign-in; Botto then requires authenticated `/api/status` identity and compares any saved pin before opening the workspace. In that case the reviewed origin is the credential-delivery trust boundary; installation pinning follows authentication. See [the identity decision](adr/0008-authenticated-installation-identity.md). Known versions below 0.21.5 are rejected. Explicit `version:unknown` is accepted for source installations; gateway capabilities are still validated. Only `CF-Access-Client-Id` and `CF-Access-Client-Secret` custom headers are allowed. Access credentials necessarily accompany `/api/status` to pass the proxy. Redirects are refused, including same-origin redirects. Use the final origin URL.
- Upload is scoped to the live service/connection/profile/stored chat. Pass complete returned `ChatAttachment` values unchanged to `send`, including optional `stagingID`. The service registry validates the unique token and complete descriptor. Unconsumed uploads survive ordinary A→B→A navigation and can use fresh A access; old A access itself is retired. Historical paths or decoded tokens alone grant nothing. Admission consumes only submitted tokens. Reconnect, incompatible stored-origin change and process restart require reattachment. Client limits are eight files, 25 MiB each and 50 MiB per prompt. Images are resized/re-encoded off-main; authority sends explicit per-prompt image references; sidecar uses its verified vision-tool text reference. File references are taken verbatim from `file.attach`.
- Native transport caps each history HTTP response (`GET /api/sessions/{id}/messages`) and WebSocket message at 96 MiB. Two 25 MiB images require 69,905,072 base64 bytes, leaving about 29 MiB for JSON, text and other rows. Other HTTP responses retain their 32 MiB ceiling; native sign-in separately validates a 128 KiB response limit. HTTP receipt checks delivered chunks before appending, regardless of missing or understated Content-Length. Full history reads request 100 rows per REST page; the inbox requests one 300-row window; both inspected hosts support row pagination (maximum 500), but a single image-bearing row cannot be divided this way. A response page or WebSocket snapshot above 96 MiB is refused before projection. These bounds do not guarantee restoration of arbitrary-length or arbitrarily image-heavy histories.

AppStore's connection lifecycle owns the explicit candidate, connection event
lifetime, attachment recovery lifetime and displayed status. An interrupted
handshake retains its candidate until that attempt completes or retires; an
automatic recovery event cannot commit it. Startup and foreground waiting stay
neutral. Backgrounding, replacement and cancellation retire the attempt before
late results can publish. Saved setup and refresh-token rotation remain separate
durable facts: a retired screen can still owe a synchronous credential save.

## Inbox message previews

The inbox excerpt follows the chat that tapping the bot opens: preferred, last
selected, then Main. It uses `ConversationPreview` from typed user/assistant
messages. Silent replies, hidden rows, tools and routine internal scaffolding do
not replace the last readable message. Useful replies, attributed bot messages,
attachments and real failures remain eligible. Raw roster and directory preview
strings are inventory metadata, not display-ready latest-message evidence.

`recentConversationHistory(_:)` reads one newest window of at most 300 history
rows without attaching a chat, changing live access, or creating read
acknowledgment. `ConversationHistoryWindow` retains full typed messages and
reports whether older messages may exist. One response avoids joining offset
pages from different host states. Both pinned hosts cap the requested limit at
500; this read keeps the existing maximum of 300 rows, though an ordinary read
can now return more than the former first 100-row page. The workspace saves
these messages in the same transcript used by chat; the inbox derives its excerpt from that
transcript. Formatting and attachment descriptors survive the transition into
chat. An incomplete search or failed request preserves the saved content.
Legacy sidecar history cannot prove absence before a compressed tip.
A rejected window still publishes any duplicate raw IDs it observed for that
exact source. Book retains those disputes, and Library withdraws the affected
Search results and artifacts. This negative evidence cannot adopt a new tip or
resolve an existing dispute; ordinary read failures preserve cached content.
Library orders disputes against coherent identity reads for the exact stored
tip. A newer proof clears only its named IDs in both Library and Book, so later
seeds and live repetitions cannot restore an older claim. Live publications
repeat their last read's claims; they observe no new duplicate identities.
A roster read floor rejects stale rows and source observations, but still
retains their exact-source disputes and fences older scans. Seeding an absent
chat merges standing disputes without restoring its rows or directory presence.

A bounded window replaces the cached suffix when its first stable message
uniquely anchors in the same stored transcript and is not quarantined.
Partial same-tip windows preserve all prior identity disputes, including for
fetched rows whose conflicting occurrence may be outside the window. An
exhaustive single window resolves only IDs actually returned; absent prior
disputes remain. Attachments, foreground rereads and live deltas pass through
the same reconciliation before display, saving or Library admission.
`OpenedConversation.identityRead` and exhaustive `ConversationHistoryWindow.identityRead`
carry process-local `ConversationIdentityRead`
evidence for the exact profile, root and stored tip. Raw IDs are checked before
filtering; the proof lists stable projected IDs from that exhaustive response,
before replay adds any rows.
A complete authority snapshot or exhaustive first REST response can supply it;
separate moving offset pages cannot. Replay-added IDs and later incremental
publications gain no identity proof. This evidence resolves only its listed IDs,
never grants live access, and is independent of read acknowledgment and coverage. Without a join, chat shows the
newest window with an earlier-history notice. Coverage travels with `Conversation`,
including through attachment, live publications and persistence; only complete
history clears the notice. Replay completeness remains separate from durable
history coverage. A complete active-tip read can still acknowledge its matching
inventory when older sidecar compression segments remain unavailable. A full
window replaces cached history, including removed rows. Drafts and seen evidence
are independent of these cache writes; background reads can reveal unread
content but never acknowledge it. Older excerpt-only cache fields are ignored;
existing saved transcripts remain readable without a schema migration.

The workspace refreshes opening-chat history in the background, with at most
four concurrent lookups per batch. Live selected-chat publications update the
same transcript. Each attachment records its target, including delayed Search
and notification selection. It cancels an outstanding optional history read for that chat; fresh
optional reads wait until its attachment ends. Identity, connection,
opening choice, and exact retained-content checks reject stale completions.
Cached content remains available offline. The row uses the latest readable
message's timestamp.

## Read-only library

`WorkspaceLibrary` owns Artifacts and Search for one mounted workspace. It seeds
visited chats from saved history and restores its separate artifact index, then
reads each bot's directory and changed or unverified
`conversationHistory(_:offset:)` without attaching, acknowledging messages, or
changing drafts. The service verifies its current lineage proof, exact returned
profile/session, pagination, and connection before accepting each page. A page's
`isComplete` describes content fidelity; `nextOffset` independently identifies
older pages. Hidden rows can leave a projected page empty.
A new app process derives artifact projections locally from saved rows. Server
revalidation begins when Artifacts or Search opens. Pending online indexing
keeps usable results quiet. Settled partial coverage uses a neutral notice;
actual failures retain retry guidance.

Scanning publishes available results as it goes. The retained index holds at most
25,000 messages, 32 MiB of message text, and 1,000 chats across cache seeding and
refreshes. It favors the newest chats and fitting messages before building their
artifact projections. Each scan also bounds network work and reads at most 1,000
pages per chat. Partial, cancelled, and failed scans show a warning and merge
useful same-tip results within those limits. A changed stored tip retires the old
tip's artifacts. Strong unchanged complete summaries skip history reads; weak
summaries probe the newest page and keep older history visibly unverified.
Explicit refresh rebuilds history. Live transcripts and inbox windows publish `ChatTranscriptPublication` after
successful installation. It carries rows and read evidence without live access.
A window publishes only its fetched rows; an older prefix retained in chat does
not become a fresh read. Library coalesces local projection without additional
reads or changes to unread evidence. Windows preserve any known working tail
because history coverage does not establish that streaming has finished.

Canonical admission synchronously withdraws ambiguous IDs, changed producers,
and retired tips within the retained budgets. It keeps only projections still
bound to unchanged rows and revokes affected capture consumers before returning.
Coalesced discovery enriches current canonical rows; it never reinstalls a queued
snapshot. Local accepted versions fence older directory/history responses; an
per-chat projection version rejects detached work when that chat's canonical
rows or working tail change, including shared-budget eviction. Unrelated chat
updates do not restart it. Gallery capture publication waits asynchronously for
that version's path provenance; a pending commit rolls back before retrying,
without holding the cache actor. Valid historical readers retain their own admission.
Each gallery reader also awaits its own current provenance before returning;
a ready historical peer cannot release that reader. Canonical records start with
an explicit empty or retained Search projection. Only the detached projector
parses their text.
Every history page applies known ambiguity before projection or the next read.
Partial reads discover the final merged, bounded messages. Cold
history seeds coalesce off MainActor and complete before restore/scan readiness.
Known working tails survive inert reseeding; refresh can add older rows without
replacing those tails or certifying complete coverage.
Complete directory absence is a bounded, hidden cache row. Inert history seeds
cannot undo it; a current directory observation or proven service read can.
Failed history checks invalidate reusable summary/head certificates and persist
partial coverage until a current check succeeds.

`ArtifactCache` owns a separate disposable SQLite index and captured files on a
private actor. Its per-mount session includes the saved connection UUID and
exact origin, installation, username, and provider bytes. It persists bounded
inert transcripts and inline source; discovery runs off MainActor. Accepted live
updates omit unsettled assistant tails until completion. Legacy saved chat
history already clears working state; seeding that history cannot recover
whether a syntactically closed tail was still streaming. Shared originals are
keyed by profile, root, stored tip, producing message, path, and source revision;
thumbnails add the original digest and decoder parameters. Original and
thumbnail budgets are 256 MiB and 32 MiB; encoded metadata and its physical
database footprint have a 40 MiB allowance. Individual originals stay within
25 MiB. Missing or corrupt blobs miss; locked or unknown databases remain intact.
The saved-history writer and version remain unchanged. Conversations add a
backward-compatible optional ambiguity field.

REST `display_content` sets the text a row shows. For retained rows,
`ChatMessage.canonicalText` keeps the unprojected response text when its bytes
differ, and every retained-text budget charges both. This includes commentary or think blocks removed or redacted
from the display projection, even for chats only scanned or previewed. Those bytes
stay in local history and caches; rendering and discovery use display text.
Hidden and model-only rows are omitted. A tool-call row with an empty projection
and no images is also omitted, so none of its canonical bytes are retained.

A source revision hashes the retained unprojected text in place of `text` and
encodes every other field exactly, so ordinary rows keep their keys. A display-only
change keeps a capture when those producer fields are unchanged; a canonical edit
gets a new one. Full-message and history-head revisions and the quiet-append
prefix proof compare both texts. Read state follows displayed attention content,
so a standalone canonical-only change does not mark a chat unread.
Raw authority `session.resume` and REST rows share a key only when their extracted
unprojected text and remaining producer fields agree. On the 4a0eaf79 authority
pin, REST `inline_images=false` flattens list content differently from raw resume
parsing, so text-part and image rows can keep separate keys and offline captures.
This pre-existing split adds no cross-key reuse. Authority display stays raw until
the deferred projection work lands.

Page reads before canonical retention saved display text alone. Nothing ties
those captures to a stored row, so they stay under their own keys and that row
needs one online capture. This adds no migration, fallback, or second lookup.

During restoration, `MetadataAdmission` distinguishes inert seeds, passive
positive windows, and rows requiring a recovery guard. This provenance survives
ordering-fence eviction and prevents an old book seed from replacing accepted
rows. A positive window alone defers guarding unread saved metadata until
reconciliation. Exclusions inherited from an unreconciled seed, changed known message
revisions, producer changes and authoritative updates require a guard. Promoting
admission to that state marks metadata dirty even when the canonical rows stay
identical, so the guard reaches disk before retirement. Canonical retention records
required guards before discarding rows or exclusions. Lost evidence also leaves
bounded scope hashes until a complete source read checks the scope; overflow
withholds uncertain partial Library admissions across the scope. Chat history can still display its fetched
rows. Only a check of that exact scope releases its hold; completing restoration
for other chats does not. An evicted scope with no saved row keeps Book seeds
and partial publications gated. A coherent source read releases its scoped hold
only when the retained messages match the complete producer proof. Overflow
remains conservative until the cache owner is retired. Each retained scope also
keeps its loss time, so a read started before eviction cannot release it. Retrying
an already-held saved hint keeps that time; only a new loss of canonical producer
or exclusion evidence advances it. The shared admission path applies this check to Library scans. SQL absence alone
cannot certify a held partial record. The writer journals held canonical scopes
but keeps their guards until a qualifying check; directory observations and
incomplete pages cannot clear them. A complete scan reconciles its checked
metadata before finishing its save. Saved-row and negative-hint receipts cannot
release a lost-scope hold, even when their source, fence and retained content
match. They stay deferred until a qualifying source read releases that hold.
Loss checks on incoming passive rows apply to producer publications and scan
pages; rejecting an older SQL revision in favor of an accepted current row does
not discard fresh evidence.
Restoration rechecks saved rows against guards created during its own awaits and
merges their exclusions as hints. Duplicate saved IDs remain identity disputes.
Accepted rows survive retry behind the visibility gate; a successful SQL read
can release them when it proves no saved source exists for their chat.
A hold withholds a read's rows, never its disputes. A withheld dispute advances
the chat's existing acceptance fence and retains quarantine without proving a
source or lifting the hold. Older scans yield, and proofless reads cannot clear it.
Directory absence removes rows while retaining same-tip disputes. Quarantine
does not observe directory presence, so recording a dispute cannot reopen a chat.
Hint admission reports either an installed source or a deferred result. Only
installed sources receive restoration receipts. A deferred hint keeps its scope
pending while independent saved peers continue loading. Hidden hints rank after
chat rows in the shared retention budget; a checked saved row can release its
inert seed gate. Different-tip hints stay pending until current source
proof preserves the old tip as retired. Retry treats discarded scopes as negative
hints even when their earlier journal write failed, before admitting SQL bodies.
Saved-state reconciliation settles each retained chat independently. Its checked
result binds the source, acceptance stamp and canonical content version; a changed
or evicted record must be checked again. An absent saved row or an installed row
can release that chat's metadata gate while another hint stays deferred. A proven
current tip first retires a different saved tip through negative-hint admission.
Later updates and retries retain the checked chat's state until canonical eviction;
they do not wait for unrelated chats or withdraw it for its own pending save.
A legacy index without retirement proof retains the Book's cached tip choice and
records the displaced saved tip as retired. Explicit saved retirement still
outranks an inert older Book; fresh source proof keeps its separate precedence.

Before attempting changed metadata rows, the cache atomically records their
scoped invalidation hashes outside SQLite. A successful replacement clears its
entry. After a failed database write, seed and restore withhold that chat's old
index and completeness certificate until current history is checked and saved;
other chats and captured original bytes remain available. Recovery keeps
hidden, row-free source hints and quarantined old row IDs, so a fresh
successor can retire the old tip without exposing its content or letting a
partial directory update restore it.
It reserves at most 256 KiB within the metadata allowance and treats unreadable
or future recovery records as untrusted. It cannot promise restart recovery when the filesystem itself cannot
record the invalidation; that failure remains explicit. It does not change
selected-chat history or grant network access.
Configuration quarantine lasts until that cache is discarded or pruned.
Unknown recovery formats remain untouched and unavailable.

An observed bot roster records a scoped restriction even before saved chat IDs
can be read. The restriction survives SQLite recovery because an unreadable old
chat book can later reappear. Checked SQLite replacements can admit their own
chat; cached book text cannot inherit that permission, and reentry alone cannot
revive withdrawn siblings. A later omission revokes the profile's checked rows.
The existing recovery ledger owns these bounded records; original captures and
current service authority remain separate. On quota exhaustion, metadata
withholding starts with the affected namespace, expands to its configuration only
if needed, and uses the existing global marker only when narrower protection
cannot fit. An unwritable filesystem still prevents a durability guarantee and
keeps the explicit save failure. Unsaved roster restrictions intersect and gate
saved-row and book admission immediately. Library retry can save the pending
evidence without treating cached labels as observed membership. Successful
admission fences older restoration and seed work; fresh accepted reads remain.
An unrelated row's acknowledgment cannot replace the restriction during seeding.
Failed-recovery reseeding preserves admitted fresh rows and their dirty writes.
Eligible queued book requests adopt the saved admission fence, while active
work stays fenced. Deferred seed writes resume after reconciliation.

Core marks local inflight, optimistic and streaming occurrences with
`ChatMessage.transientID`. A current exact occurrence can use selected-chat file
access, while library discovery, Search references and durable capture keys
require stable row identity. A later persisted-row receipt clears the transient
token. Missing legacy metadata stays decodable; `inflight-user` without a token
is not a stable or current occurrence.
The actual submit and steer producers attach that token when they publish a
local row. Message ID prefixes alone cannot distinguish local Core rows from
durable rows supplied by another provider, including Demo.

Transcript cards carry their exact producing message into capture lookup;
whole-chat path deduplication is reserved for the gallery. Decoded covers use
the same producer digest, and explicit reload invalidates cover requests.
Reader loads and exports serialize; the native presenter pins the output's
captured file until its completion or cancellation.

Chat and Library readers share `ArtifactPreviewModel` as their lifecycle owner.
Its state owns the active read task, last useful file, read failure, native output
and export failure. Reload retains the prior file; read and output states are
exclusive. Matching attempt and output IDs fence late callbacks. Finish drops
ownership before cancellation and is terminal. Reader adapters retain their
distinct source/access checks and recheck them before admitting downloaded bytes.
After admitting a request, the model synchronously prepares its captured download
closure before creating a task. Queued chat reads cannot renew access from a
later connection recovery.

`downloadArtifact(_:in:)` is a read-only library operation. It requires a current
connection and service-observed identity proof before and after the bounded
authenticated download; cached `SessionIdentity` values do not grant authority.
It preserves selected-chat access. Workspace replacement retires the library
and pending reads. Completed original bytes remain usable offline while their
library item remains current. Ordinary capture hits require their current
semantic owner and no network capability. Cache misses and explicit reloads
retain the appropriate strict service proof, including selected-chat access for
in-chat readers. Concurrent gallery, thumbnail, and in-chat consumers share one
original request; cancelling a consumer does not cancel its peers. If a selected
reader’s access retires, a surviving library reader can continue through its own
authorized loader. An error from a still-current loader is returned without
automatically retrying through every peer. Confirmed
Forget revokes cache sessions before serialized purge, and successful startup
setup reads prune unreachable connection IDs. Failed credential removal keeps
the existing cache usable. Inline previews keep the existing renderer sandbox.

Library result navigation deliberately opens the exact originating lineage,
including sibling chats. It never falls back to a bot's preferred chat when that
result is unavailable. Bots, Artifacts, and Search retain separate presentation
state; hidden Bots content cannot acknowledge messages or accept editor actions.
Library opening commits bot selection, chat selection, and its saved last selection
in one actor turn after a current successful attachment. A pending attempt keeps
the original cached chat and draft while retiring its old action grant. Failure
or cancellation reattaches the original with fresh authority only while that attempt still owns
navigation. If reattachment also fails, the original draft stays editable without
reviving the retired grant. Newer navigation and connection changes fence cleanup.
Bot, picker, and library intents claim their navigation request before queued
work or directory lookup. Library lookup, attachment, and recovery share that
owner. A superseded request cannot commit or recover over a newer intent; if
the newer lookup fails too, its own recovery keeps the original draft usable.
Creation keeps its separate mutation reservation: a newer navigation request
does not undo an authorized creation or discard its valid receipt. Only its
optional automatic opening requires the creation's navigation claim to remain
current. An attention lookup likewise rechecks its claim before opening a chat.
Every bot selection write supersedes older in-flight writes, even when it leaves
the exact bytes unchanged or writes nil. An unchanged selection keeps its
presentation; canonically equivalent but byte-distinct IDs are different bots.
A pending Library selection yields to any newer selection write.
An authenticated notification tap claims navigation when admitted, before any
reconnect, roster or status wait, so older navigation that finishes during those
waits cannot replace it. The tap outlives connection and workspace changes; if
recovery retires its claim, the retained tap claims again. Every newer intent
cancels the tap when admitted: bot entry, creation, picker and chat-creation
captures, and direct selection writes. Notification opening settles bot selection
inside its attachment commit, before the chat, its saved selection or its grant
is published. A superseded or failed tap keeps the prior chat and draft editable
without reviving a retired grant. If it interrupted an unsettled bot opening,
the selected chat offers Retry. That action starts a fresh ordinary opening and
cancels the retained tap; it never replays the superseded opening.
Bot creation returns its published profile with its original workspace, connection
and socket-recovery lifetime. Its optional opening keeps that authority across
selection callbacks and sheet dismissal. A transient inactive scene still
acknowledges success without replaying creation. Ordinary bot entry resolves the
current preferred or canonical chat; Library results retain their exact originating
lineage contract.
Compact navigation derives its column from the current task presentation and
live selection in the same update. A root cover retains the native column;
uncovering projects the current task without waiting for an attachment update.
Accepted notifications settle the scene's tab, reader, pending Library opening,
root cover and chat surface in the accepting actor turn. Root owns the weakly
registered presentation receipt. A newer deliberate sheet or connection choice
cancels a held tap; closing that sheet does not replay it. A connection attempt
can dismiss only the connection choice it started from.
Foreground reconnect captures its restoration intent before refreshing the
roster and directories. Its later restoration must still own that intent;
it cannot replace a newer library lookup. If the newer lookup fails or is
cancelled before attachment, it can freshly restore the original chat's access.

## Cached activity presentation

The workspace persists the last successful `ActivityObservation` with its check
time, independently of inert transcripts, live access, and refresh state.
`ActivityPresentation` supplies the inbox and chat picker with these states:

- Unobserved activity stays quiet while a check is pending or no observation exists.
- Current observations drive live attention and show **Working** or **Needs you**;
  idle stays quiet.
- Restored observations and observations from a retired connection are historical.
  They show **Previously working** or **Previously waiting**, with the check time
  in the accessibility label; historical idle stays quiet.
- Failed or ambiguous checks retain the last successful observation and its time.
  They show **Activity unavailable** only when no prior observation exists.

Roster reads publish ordered activity samples in one `activityBatch` event so the
workspace can update its observable state once. Individual `activity` events still
apply immediately; no observations wait across an asynchronous roster read.
Activity sampling never acknowledges unread content or grants action authority.
See [cache-first presentation](adr/0007-cache-first-activity-presentation.md)
for the shared decision and its trade-off.

## Live avatar activity

`OpenedConversation.activity` carries optional, non-Codable `ConversationActivity`:
a motion lineage, current work phase and stable start times, plus a newly observed
`TurnReaction`. These presentation facts never enter `Conversation` or the saved
chat book. Existing exact identity, replay epoch and contiguous sequence gates
admit events before projection. Tool IDs track overlapping work; text chunks and
thinking hints change phase without restarting the work clock.

A reaction requires an observed live start and a matching explicit successful or
failed terminal status. Authority additionally requires a nonempty matching
admission and execution generation. Queued cancellations, interruption, unknown
status and replayed/restored events do not create success. Actual socket reset
retires motion lineage; ordinary same-runtime/epoch canonical refresh preserves
it. The app workspace retains an accepted reaction's original time through that
refresh, independently of rotated mutation access. No new network subscription
or background multi-chat phase observation is introduced.

`ConversationActivity.signal` identifies a newly admitted live turn start, answer
text chunk, request arrival, or explicit stopped outcome. Snapshot and replay
reconstruction never create these signals. Publication consumes each signal;
its identity lets the foreground reader suppress duplicates and hidden results.
The service retains operation-scoped Stop evidence from newly received socket
events across its automatic refresh. It checks the captured session, connection,
selection, execution generation, and known admission, then requires canonical
idle state covering that event's sequence. Fetched replay cannot supply this
evidence. The workspace combines the stopped signal with the matching Stop receipt
and consumes hidden results before requesting feedback. Reply completion uses the existing verified
turn reaction and says nothing about answer quality. See [haptics](haptics.md).

## Multiple conversations

`conversations(profile:)` reads Main and ordinary chats. `createConversation`
omits a title: a title can mean resolve-existing on the authority host. Main is
the canonical Bot Chat and remains separate from Botto’s local preferred opening
selection. Directory paging advances fixed requested offsets, deduplicates proven
lineages and reports partial reads. Full inventory reads are distinct from
lightweight activity sampling. Ambiguous sidecar runtime ownership stays unknown.

The inbox loads current bots' directories once per connection. Later roster reads
check one creation-ordered metadata window per catalogued profile (`limit=1`,
plus host pin backfills). A changed filtered total or an uncovered lineage/tip
emits `.conversationDirectoryChanged` and refreshes only that profile through
the existing directory path. Unchanged streaming metadata does not rescan full
inventories. Failed or malformed probes retain previously covered facts and retry
on a later roster read. A legacy live-only chat becomes discoverable after the
host persists it; unknown runtime keys do not establish profile ownership.

Directory invalidation retires the profile's pending read in both core and app.
Request identities prevent an old completion from clearing a replacement read;
connection and presentation fences still protect newer chats and live access.

Switching detaches the exact authority subscription without an end reason. It
never sends sidecar `session.close`, Stop or a cancellation of server work. The
service retains private provenance for newly created empty sidecar chats, which
may not yet exist in REST. A cached live-only flag cannot authorize a history-404
exception. Explicit stored targets remain stored targets during recovery.

Mutation receipts identify the original source and operation after a positive
host acknowledgment, even if selection changed while the reply was pending. A
local journal failure after admission is `needsLocalRepair`; do not resend that
message. Lost acknowledgments remain uncertain, with no automatic mutation retry.
The app clears only the submitted source draft revision and unique staged IDs.

`OpenedConversation.readEvidence` is optional runtime evidence from a complete
read. It carries the exact inventory summary observed before that read, for the
same verified profile, lineage root and stored tip. Inventory counts describe
physical rows in the active tip; they cannot be compared with projected message
counts or compacted history length. The workspace acknowledges a matching
observation only after current live display. Directory callbacks, cached history,
incremental publications and access rotation do not create that evidence. Missing
or changed metadata stays conservative; later metadata cannot enrich an earlier
read retroactively. This is causal ordering, not an atomic server revision.
For an idle authority chat, complete history and an atomic snapshot watermark
covering the replay head also prove the read when old replay entries have expired.
Active chats still require complete replay to account for unfinished content.

When a visible selected chat needs newer evidence, the workspace can perform one
same-chat read per distinct returned-directory observation. It waits for captured
actions, imports and artifact consumers to settle. The new read retires old
actions, artifacts and renderers; it preserves the draft and visual selection.
Only a subsequent current display can acknowledge the result. Failed or
incomplete reads do not retry the same observation automatically. This reuses
the existing directory queries and adds a full selected-chat read when needed,
not inventory polling for each streamed token.

## Coverage boundary

Authority contracts: official Hermes `4a0eaf7989b6804319ddb94fa5d96c5a716080a1`. Sidecar captured fixtures: official Hermes `ca6782850432927f33df4775cb6dd45bb51460d2` / 0.21.5. Donor algorithms: Hermex `47809f2cd1f07bcbe592ee8960cf9c63e88b734c` (MIT).

The fixture manifests preserve their capture source and filtering rules.
`AuthorityCaptured` contains a disposable real-gateway capture;
`HermesAgent` contains upstream's captured 0.21.5 data; `AuthorityContract`
contains explicitly labeled synthetic edge cases. Historical fixture bytes
retain their original capture names. These fixtures support protocol tests,
not complete product acceptance of the current revision. See the
[verification record](verification.md) for recorded checks and limits.

The opt-in live test creates a new disposable profile each run. It runs only
when `BOTTO_TEST_HERMES_URL` is set; optional user/password environment values
override fixture defaults. `BOTTO_TEST_CAPTURE_PATH` optionally exports filtered
session traffic, never auth HTTP or tickets. Use it only on a disposable host,
following the [authority](dev-host.md) or [sidecar](dev-host-sidecar.md) recipe.
The runtime's owner is responsible for teardown.

## Remaining coverage and interface limits

- Source pins and fixture coverage are specific to the authority and sidecar
  recipes above. The public service selects the adapter from the actual
  capability handshake; do not describe arbitrary Hermes releases as tested.
- Native refresh rotation and Cloudflare headers have boundary tests. External PKCE and real Cloudflare Access tunnels require separate live verification. Authenticated HTTP 401 is surfaced with reconnect guidance; writes are not retried automatically.
- Stop and clarification routing have simulated boundary tests. A fixture reconnect does not establish gateway process-restart recovery. Background/iOS interaction, real model providers, authority restart/unknown-admission recovery and long compacted histories still need broader interoperability testing.
- A truncated authority replay ring can omit unfinished text that has not reached durable history. Botto restores the available durable rows and current prompts; later stream events or completion restore the remaining text. It cannot reconstruct bytes the host no longer supplies.
- The submission journal retains up to 500 identities without prompt text or credentials. It is not an offline outbox or a user-facing receipt inspector. Unknown admissions exposed by the host remain visible and require Desktop resolution.
- Unknown and credential requests are unsupported cards. The Domain interface has no secret-entry, model/provider catalog or multi-select response type. Those features need deliberate interface additions before exposing them in the UI. In-chat artifact downloads use captured live access and the authenticated bounded transport; see [rich replies and files](rich-content.md).
- Authority does not include true one-shot server request envelopes in its snapshot. During automatic recovery, Botto retains previously seen envelopes as unsupported reminders and consumes replayed/live cancellations. They cannot authorize an answer from cached state. A process relaunch cannot recover request parameters the host does not publish; use Desktop for those requests.

## Existing profile edits

`updateProfile` edits the shared bot title and description without renaming the
profile ID. It rereads the profile and rejects changes to fields the editor is
about to overwrite. Title writes merge fresh appearance metadata and use its
namespace revision. Hermes does not expose a description compare-and-swap;
a concurrent description write after that read remains a server limitation.
Profile sections and avatar image clearing are independent operations. A
partial or unconfirmed save requires reload and a deliberate new save; recovery
never replays the mutation.

### Message results in Search

Search captures one occurrence and its query. The current Library projection
validates the captured result; normal chat attachment then resolves the same
profile, root, stored tip and unique byte message ID before selection commits.
The attached native presentation must contain the query. Different history
projections and in-place edits can preserve the occurrence, but hidden content,
missing matches, ambiguous IDs and changed stored tips cannot substitute a row.
No cached text enters the live transcript.

Search indexes the same role-specific native text segments used by the
occurrence resolver. Assistant Markdown is readable text; user and bot-sender
text remains literal. Preview source and file directives stay artifact results.
Derived searchable segments are prepared with artifact discovery off the main
actor and reused until the retained message revision changes. A newer accepted
row replaces that occurrence’s content even when it removes a suffix; partial
or inert history cannot restore deleted accepted content.

Core read publications carry a runtime-only monotonic start instant captured
before resume/history. Source evidence is included when the preceding service
observation still matches the published tip. Incremental publications omit both.
A read can replace newer library knowledge
only when it began after that observation; switching stored tips also requires
matching service-observed source evidence. Incremental rows can advance a matching
prior canonical row within the currently observed tip. Inherited rows cannot clear
newer removal, ambiguity, or tip retirement. These runtime facts are not persisted
host revisions or mutation authority. Missing provenance remains conservative. Positional
or invalid raw IDs remain visible in chat but cannot identify actions, Search
jumps, or durable captures; legacy saved IDs follow the same rule.

Saved chat history and the artifact index persist independently. Inert reseeding
preserves raw ambiguity evidence and never replaces an indexed same-ID revision.
A complete history read retains bounded IDs of removed rows, so later partial
reads and saved history cannot restore them. Current accepted rows can prove
presence without proving uniqueness. Safe accepted edits replace prior
revisions, and unchanged live updates retain complete coverage. Partial pages
preserve indexed revisions, absent older rows and known revision uncertainty.
During pending recovery, conflicting same-ID revisions remain unverified;
revision protection records only incoming rows equal to the canonical revision.
Repeating a partial publication cannot resolve uncertainty, including after a
cold reopen. An accepted transcript read or complete history replacement can
resolve revisions without clearing actual identity disputes.

Known ID disputes need coherent, message-specific identity evidence to resolve.
A history-page producer supplies optional `ConversationIdentityRead` only after
checking raw identities in an exhaustive first response. Library consumes that
proof; completeness, source ID sets, and multi-page scans cannot create it.
A multi-page scan can replace ordinary cached content but cannot clear a known
dispute. Fresh pages protect only admitted canonical revisions during restoration even
when they lack identity-resolution proof; that evidence never releases the
metadata gate or clears an actual dispute. An ID absent from a coherent read
stays disputed. Recovery hints carry
unverified saved revisions separately from known ID disputes: a fresh accepted
revision can supersede the former, while the latter needs identity evidence.
Exact stored-tip binding and existing freshness fences apply to both. The saved
index preserves these sets separately. Its legacy unavailable field encodes their
union so older app versions continue to withhold uncertain rows.
Seeds omit repeated Book rows without a standing dispute instead of deriving a
new claim from them. Book corrections use the normal save path; a crash before
that flush can conservatively retain a dispute. Attached chat display retains
its last read's ambiguity until its next read, independently of Library results.

Cache admission uses typed inputs for accepted transcripts, complete replacements,
partial history, inert seeds, checked saved rows, recovery hints, quarantine,
source observation and directory absence. Coverage, exclusions and resolving
proof derive from that input. Partial history and hints have no resolving-proof
field; row ordering uses a separate merge policy.

Restoration owns a state machine: unstarted, restoring, finished with either
reconciliation or retry needed, and retired. An active attempt carries its task,
identity and previous outcome, preserving persistence eligibility while retrying.
Concurrent restores join that attempt. Only its matching completion can settle
it; retirement ends ownership before cancellation and immediately ends loading.
Seeding, projection, identity evidence and metadata eligibility remain independent.

Startup restoration tracks accepted revisions and identity evidence separately.
When saved metadata cannot load, verified coherent results can appear in Library
while metadata writes wait for its negative evidence to be reconciled. Unchanged
reseeding retains that display proof, including across freshness shortcuts.
Presentation filters each message, artifact and Search entry by verified ID, so
a later unverified row cannot hide verified results or gain artifact admission.
Directory membership and partial scans cannot release metadata reconciliation.
Recovery hints merge missing exclusions even when a fresh result already exists.
Quarantine and hidden-row overlap inspect every retained ID, including uncertainty
and removal records, so rejected pages cannot lose disputes held only in hints.
Fresh changes still record durable recovery guards before SQL is available;
the writer retains gated dirty identities and revisions and saves only eligible
rows. Successful reconciliation schedules the deferred save. A dispute absent
from the fresh read therefore survives persistence and a cold reopen.
Legacy records without removal metadata carry no known removals. Seeds remain
partial, and missing evidence cannot clear a known quarantine. Observed tip
changes keep a bounded retired-stored-ID set, including through a failed history
read and cold restore from an older chat book. A fresh service-proven source can
restore a retired tip. Current network source proof outranks older persisted tip
retirement during startup; an inherited snapshot does not. Message exclusions and
retired stored IDs share the retained count and byte limits. Unrelated rows and
captures remain available. Derived gallery provenance changes reconcile capture
consumers in the same actor turn as canonical changes.

Negative evidence lasts as long as its retained row, the existing restoration
holds and Book's own claims. Eviction or storage failure can lose a row's
disputes and retired stored IDs. A tip that returns afterward follows the
ordinary source rules above, and Library promises neither to remember it nor to
withhold it until proof. The stronger contract is
[deferred](adr/0012-retired-tip-evidence.md).

The scene owns a short-lived focus receipt with the actual attached message
revision. The native controller reveals a measured glyph range and retains its
reading landmark. Native Text paints complete content and query highlights; a
transparent text-layout overlay measures only the focused text. Covering an
already exposed transcript cancels a pending reveal; initial inactive mounting
can still receive its first reveal. Dragging, Latest, owner replacement or
navigation retires the receipt. Its display
attributes grant no action authority.

Metadata recovery guards serialize independently of SQLite. Each changed row
gets a runtime-only local write token before the SQL writer check; checked replacement clears
only that token. Deletion and quota eviction retain bounded scoped guards. Cold
book seeds remain unavailable to Search, gallery and capture admission until the
saved index has reconciled their removal, ambiguity and retired-tip evidence.
A failed initial SQLite open can still record guards in the writable ledger.

The library versions canonical roster withdrawals before another history await
and includes its first in-flight metadata writer in durable invalidation. Its
acceptance fence retains at most twice the injected chat budget (minimum two
entries); seed/scan operations hold a small stamp. An evicted version leaves a
watermark that rejects uncertain stale results. Repeated updates to a retained
ID do not invalidate an unrelated read. This is runtime state, not host revision
or mutation authority. Startup cleanup checkpoints preserve newer active-lease
guards while SQL readiness and retirement still gate cache reads and writes.

Only an observed roster changes membership; cached bot names supply labels.
Refresh callers must state which evidence they carry; offline tab entry never
upgrades cached labels to observed membership.
Before the first observed roster, reconnecting tab reads retain saved results
without scanning membership or certifying freshness. The first observation
invalidates revalidation even when its labels match the cached labels; an
observed empty roster remains authoritative.
Roster withdrawal includes working chats and invalidates their observations
synchronously. Seed, restore and every scan await check the roster revision;
a joined forced refresh uses the latest observed roster. Reentry needs fresh
read evidence. Recovery admits a checked saved row without creating a new write
guard. If both initial storage and guard admission fail, bounded acceptance
stamps withhold changed or evicted rows when the same mount retries storage.
Correctly associated history failures carry known duplicate IDs even when
another row or pagination field is malformed. Head probes and full scans
quarantine those IDs before further publication or suspension.
Rejected pages also carry at most 100 raw stable IDs. Their overlap with retained
rows is quarantined even if the conflicting occurrence was on an earlier page.
An oversized page withholds all retained references in that chat because its
complete overlap cannot be enumerated within that limit. No rejected content is
admitted, and unrelated chats and captured original bytes remain available.
