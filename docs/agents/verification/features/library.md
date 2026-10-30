# Browse artifacts and search chats (`library`)

## User-facing description

Bots and Artifacts share the main tab group. Search is a separate destination
using the system search role. Artifacts keeps each file or preview connected to
its bot and chat. Library reads leave the selected chat, drafts, and unread state
alone. These recipes are draft until their complete assertions run.

## Entry points

- `library.e.tabs`: connect or explore demo → Bots / Artifacts / Search.
- `library.e.artifact`: Artifacts → output card → native reader.
- `library.e.search`: Search → query → bot, chat, message, or artifact result.

Use [shared setup](../index.md). Demo includes Milo's sibling chats and Canvas's
files and inline visuals. Run-owned live hosts are required for real HTTP,
partial-history and connection-loss assertions.

Workflow `library.navigation`:

1. `.a1` Open Bots, Artifacts, then Search. Expect two main tabs and a separate
   Search control on supported iPhone systems; older systems keep native tabs.
   Open a bot on compact iPhone: tabs must hide while reading chat and return
   with native Back. On wide iPad, preserve the Bots sidebar/detail layout.
2. `.a2` Scroll Bots, open a chat, type a draft, return, and switch tabs.
   Reopen the bot: expect the exact draft and useful roster position. Typing
   into Search or scanning history must not mark a different chat read.
   Preserve Artifacts filters and the Search query through tab round trips.

Workflow `library.outputs`:

1. `.a1` Open Artifacts. Expect delivered files, identified generation results,
   and complete HTML/SVG/Mermaid previews. Each card identifies its bot and chat.
   Code examples, generic tool logs and ordinary URLs must not become outputs.
   Filter by bot/type; clear filters to restore the list. Include references:
   expect user inputs and other local file links, visibly labelled Reference.
   Delay an older history page after one usable artifact appears. Expect that
   card to stay usable and the background scan to stay quiet. An empty initial
   load shows progress. After completion, incomplete coverage uses neutral
   wording; actual read failures and interrupted scans keep their retry guidance.
2. `.a2` Open a file without changing the selected chat. Preview the correct
   bytes; use Actions → Save to Files and Share. Apply the independent durable
   readback requirements in [artifact export](artifacts.md). Close the reader:
   expect the same library/filter. Open an inline preview: expect isolated
   rendering, Source and Expand, and export of its original source.
3. `.a3` From a reader, choose Open chat. Expect its exact originating chat,
   including a sibling whose bot has another preferred chat. A missing result
   must show an error, without silently opening Main.
4. `.a4` Disconnect during a pending read, refresh, or download. Expect useful
   results retained with an honest partial/offline warning and a deliberate
   retry. Complete a download before disconnecting: original bytes remain
   readable/exportable. Replace the connection: retire the old library, reader,
   and callbacks. A late old response cannot publish into the new workspace.

Workflow `library.search`:

1. `.a1` Search for a bot, a sibling chat title, message text, and a file name.
   Expect grouped results from available history. A result opens its matching
   bot/chat/file. Message results show bot avatars and readable chat excerpts,
   with the query highlighted; image artifacts show cached covers. A message
   tap reveals the exact occurrence and its highlighted text in the native
   chat, including older rows and matches deep inside tall prose or code.
   Check actual visible glyphs, including horizontally scrolled code, without
   a corrective swipe. Keep the draft, full content and normal Latest control.
   A missing, ambiguous, hidden, changed-tip or no-longer-matching occurrence
   shows an error without silently opening another row. Empty queries offer recent chats; no matches show a useful
   empty state. Refine a query with over 50 message matches; the limit is visible.
2. `.a2` Cancel a slow chat open or leave Search while it is pending. Expect no
   late navigation back into that old result. Repeat after connection change.
   Failed/incomplete scans must not claim that the entire host has no matches.
   Repeat cancellation and failure after directory lookup, during attachment.
   Return to Bots: expect the original chat, saved selection, and editable draft.
   A newer bot choice must survive late cleanup. If restoring the connection
   fails too, keep local editing usable and leave network actions unavailable.
   Cancel during attachment, immediately open another result, and delay its
   directory lookup until the old attachment drains. The newer result must win;
   repeat with its lookup failed or cancelled and expect the original editable
   chat. A queued older bot or picker action must not dispatch over that lookup.
   Start a new chat or attention lookup, then open a library result before the
   older request finishes. Expect the newer destination to win. A completed
   creation must still appear in its originating bot's chat list, even when its
   automatic opening was superseded.
   During foreground reconnect, delay one profile's directory refresh and
   start a newer library lookup in another profile. Finish the reconnect refresh
   first: its automatic restoration must not replace that lookup. Repeat with
   the newer lookup failed or cancelled; expect fresh access to the original
   chat and its exact retained draft and saved selection.
   Also fail that original attachment while the socket remains online. Expect
   local draft editing to work, sending to remain unavailable, and retired
   access to stay rejected.
3. `.a3` Exercise light/dark, largest text and compact/wide layouts. Cards,
   filters, Search, reader actions and Back remain reachable. Check VoiceOver
   names, bot/chat provenance, reading order and return focus separately.

Workflow `library.captures`:

1. `.a1` With a run-owned service, index two chats with complete versioned
   summaries. Return through Bots and Artifacts without changing history.
   Expect a directory check and zero repeated history reads. Open the same
   original twice: expect identical bytes and one download. Open its thumbnail
   and in-chat reader concurrently; cancel one reader and expect the others
   to finish from that same download.
2. `.a2` Reopen an independent app/cache instance offline. Expect retained
   file bytes, inline source, provenance, and partial-coverage warnings without
   directory, history, or download calls. Cached content grants no send access.
   Complete a new output in the selected chat: expect it in Artifacts without
   a library history scan. Check settled output after streamed updates.
3. `.a3` Change a chat tip or producing source revision. Expect a distinct
   capture, while an unchanged source keeps its captured copy. Pull to refresh
   forces history checks. Change the host file at the same path; ordinary
   reopen keeps the copy, and Reload from Bot captures the new bytes. Fail
   Reload and expect the previous reader and export bytes to remain usable.
   Missing summary versions require a newest-page probe and an older-history
   freshness warning. Failed or truncated reads must not certify completeness.
4. `.a4` Repeat with another saved connection, installation, profile, and
   canonically equal but byte-distinct identity. Expect no cross-scope captures.
   Failed credential removal keeps current captures usable. Confirmed Forget
   retires readers immediately and removes captures; reopen with the same
   configuration ID and expect a miss. Force cleanup failure, then retry:
   expect fail-closed acquisition until cleanup succeeds.
5. `.a5` Use small injected cache budgets to evict old rows and originals.
   Corrupt or remove a blob: expect a miss. Lock the database or give it an
   unknown schema: expect retained files left intact and useful current chat
   content, without a destructive reset. Check original, thumbnail, encoded
   metadata, and physical-store bounds separately.

## Evidence and limits

Source: `WorkspaceTabs`, `ArtifactsView`, `WorkspaceSearchView`, `WorkspaceLibrary`,
`ArtifactCache`, `ArtifactDiscovery`, and the read-only `BotService`
history/download seams. The bounded index and file captures persist separately
from saved chat history. A path in history does not guarantee its host file
still exists or retains the captured contents.
Source/parser and lifecycle tests support these recipes without proving every
device, export-provider, outage, or accessibility assertion.
