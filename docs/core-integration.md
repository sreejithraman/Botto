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
- Native transport caps each history HTTP response (`GET /api/sessions/{id}/messages`) and WebSocket message at 96 MiB. Two 25 MiB images require 69,905,072 base64 bytes, leaving about 29 MiB for JSON, text and other rows. Other HTTP responses retain their 32 MiB ceiling; native sign-in separately validates a 128 KiB response limit. HTTP receipt checks delivered chunks before appending, regardless of missing or understated Content-Length. Botto requests 100 rows per REST page; both inspected hosts support row pagination (maximum 500), but a single image-bearing row cannot be divided this way. A response page or WebSocket snapshot above 96 MiB is refused before projection. These bounds do not guarantee restoration of arbitrary-length or arbitrarily image-heavy histories.

## Inbox message previews

The inbox excerpt follows the chat that tapping the bot opens: preferred, last
selected, then Main. It uses `ConversationPreview` from typed user/assistant
messages. Silent replies, hidden rows, tools and routine internal scaffolding do
not replace the last readable message. Useful replies, attributed bot messages,
attachments and real failures remain eligible. Raw roster and directory preview
strings are inventory metadata, not display-ready latest-message evidence.

`conversationPreview(_:)` reads up to three latest pages of 100 history rows,
without attaching a chat, changing live access or creating read acknowledgment.
It uses the host's display metadata and display content on a temporary projection;
canonical transcripts stay intact. A complete search found a readable message or
exhausted history. An incomplete search or failed request preserves the saved
excerpt. Legacy sidecar history cannot prove absence before a compressed tip.

The workspace refreshes opening-chat excerpts in the background, with at most four
concurrent lookups per batch. Live selected-chat publications supply their own
preview. Cached excerpts remain available offline; read identity, connection,
opening choice and newer transcript checks reject stale completions. Preview
reads never change unread or seen evidence. The row uses the message timestamp
when a projected message is available.

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
Explicit refresh rebuilds history. Accepted workspace transcripts feed a
coalesced local projection after successful installation, without library reads
or changes to unread evidence.

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

Before attempting changed metadata rows, the cache atomically records their
scoped invalidation hashes outside SQLite. A successful replacement clears its
entry. After a failed database write, seed and restore withhold that chat's old
index and completeness certificate until current history is checked and saved;
other chats and captured original bytes remain available. Recovery keeps
hidden, row-free source hints and quarantined old row IDs, so a fresh
successor can retire the old tip without exposing its content or letting a
partial directory update restore it.
It reserves at most 256 KiB within the metadata allowance and compacts overflow to
configuration quarantine and treats unreadable or future recovery records as
untrusted. It cannot promise restart recovery when the filesystem itself cannot
record the invalidation; that failure remains explicit. It does not change
selected-chat history or grant network access.
Configuration quarantine lasts until that cache is discarded or pruned.
Unknown recovery formats remain untouched and unavailable.

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
A complete history read also retains bounded IDs of removed rows, so later
partial reads and saved history cannot restore them. Accepted rows or complete
history can restore those IDs; known removals do not invalidate complete coverage.
At cold restore, conflicting same-ID content or a seed-only row absent from an
independently saved complete index has no verifiable revision order: Library
quarantines that row until fresh accepted or complete evidence resolves it.
Legacy records without removal metadata carry no known removals. Seeds remain
partial, and missing evidence cannot clear a known quarantine. Observed tip
changes keep a bounded retired-stored-ID set, including through a failed history
read and cold restore from an older chat book. A fresh service-proven source can
restore a retired tip. Current network source proof outranks older persisted tip
retirement during startup; an inherited snapshot does not. Message exclusions and
retired stored IDs share the retained count and byte limits. Unrelated rows and
captures remain available. Derived gallery provenance changes reconcile capture
consumers in the same actor turn as canonical changes.

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
Roster withdrawal includes working chats and invalidates their observations
synchronously. Seed, restore and every scan await check the roster revision;
a joined forced refresh uses the latest observed roster. Reentry needs fresh
read evidence. Recovery admits a checked saved row without creating a new write
guard. If both initial storage and guard admission fail, bounded acceptance
stamps withhold changed or evicted rows when the same mount retries storage.
Correctly associated history failures carry known duplicate IDs even when
another row or pagination field is malformed. Head probes and full scans
quarantine those IDs before further publication or suspension.
