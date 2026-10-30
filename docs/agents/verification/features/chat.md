# Converse, keep drafts, and read history (`chat`)

## User-facing description

Continue the selected conversation with streamed replies, selectable text,
Markdown/code, collapsed work details, local drafts, and offline cached reading.
Sub-features: sending, uncertain-send recovery, per-chat drafts, exact stored-chat reopen,
keyboard growth, automatic bottom following, and reading older messages.

## How to get to it

- `chat.e.row`: inbox bot row or pinned face → conversation.
- `chat.e.created`: successful **Create bot** → returned bot's conversation.
- `chat.e.composer`: **Message to <name>** (`chat-composer`) → **Send message**.
- `chat.e.history`: scroll `chat-transcript`; open a tool's named disclosure
  (Scout demo has **Research**) or **Conversation note**; use **Latest messages**
  when new messages arrive while reading older content.

## Interactive checks

Use [shared setup](../index.md), two distinct bots, sibling chats, and unique harmless messages.
Use the disposable real host for streaming and persistence; demo only schedules
a local fixed response. **Draft; complete workflows not executed here.**

Workflow `chat.send`:

1. `.a1` Wait for opening to settle. Type a unique message, tap Send, and attempt
   a repeated tap while pending. Expect one user message, Sending/Working text,
   streaming assistant content without animated text insertion, then settled
   content. Proof: timed captures and independent canonical host row/count.
2. `.a2` Edit draft text while an earlier send is pending. On acceptance expect
   only the submitted unchanged text to clear; newer text remains. Empty or
   whitespace-only draft without attachments must keep Send disabled. Proof:
   draft before/after and canonical sent value. Requires a controlled slow host.
3. `.a3` Interrupt an owned host connection before acknowledgment. Expect honest
   error/offline state and no automatic duplicate send. Restore connection and
   inspect canonical history before deliberate retry; reconcile zero/one stored
   user message with the receipt. Proof: error, fresh host history, retry count.

Workflow `chat.drafts`:

1. `.a1` Type distinct text in Milo and Scout, then in two chats with Milo; switch
   through the inbox and [chat picker](chats.md), then reopen. Expect every
   chat’s draft independently restored. Proof: composer values at
   each return. No send is needed.
2. `.a2` On a real disposable connection, type a unique draft, background to
   flush, terminate, and relaunch normally. Expect that exact draft only in its
   bot. Reauthenticate same verified account, then switch to a separate account;
   expect appropriate preservation and isolation. Proof: new-process composer
   plus redacted independent cache read of the draft field only.
3. `.a3` Relaunch with previously staged attachments. Text draft must persist;
   uploads must require reattachment. Demo recreates in-memory state and cannot
   pass persistence assertions. Proof: fresh composer/chip capture.

Workflow `chat.history`:

1. `.a1` Reopen a known bot by row, then separately after creation. Expect its
   selected stored conversation, ordered user/assistant messages, readable paragraph
   boundaries, headings, and horizontally scrollable code. Expand/collapse tool
   detail; expect useful text without executing rich content in tool/user/system
   roles. Proof: rendered and semantic captures compared with host history.
2. `.a2` Background/foreground, reconnect, and relaunch. Expect the same stored
   conversation without duplicate replay. Then make the owned route unavailable
   and relaunch from cache. Expect readable saved history and editable drafts
   without automatic connection banners. Attempt Send or an attachment action;
   expect contextual connection feedback, retained draft, and no network effect.
   Stale decisions must still require current host validation. Proof:
   independent REST/RPC stored ID and rows; fresh offline screen.
3. `.a3` Use an owned history fixture at the 100-row page boundary, long code,
   and structured images. Expect correct order/attachment identity or an honest
   bounded-response error. Histories exceeding the 96 MiB response budget are
   unsupported; do not treat row pagination as splitting a huge single message.
   Proof: fixture size, fresh host rows, rendered captures, error if applicable.

Workflow `chat.reading-position`:

1. `.a1` At newest messages open keyboard, grow composer to several lines,
   receive a reply, and rotate/resize. Expect bottom following and decisions
   above the composer without a hang. Proof: screenshots with visible bounds
   before/after, timed semantic response, and [requests](requests.md) checks.
2. `.a2` Scroll to a known older message, record its position, then open keyboard
   and receive new content. Expect that reading position retained and **Latest
   messages** exposed. Tap it; expect newest message/decision reachable. Run
   three equivalent cycles; retain each outcome. Proof: landmark bounds and
   screenshots/video, not only element existence.
3. `.a3` Repeat both flows at accessibility XXXL on small iPhone and iPad, with
   actual system Reduce Motion on/off. Expect readable text, reachable Send and
   Latest, instant jump with reduced motion, and no forced VoiceOver focus jump
   during streaming. Record focus order/announcements separately; AX snapshots
   do not prove VoiceOver behavior.

## Gotchas

Source: [ChatView](../../../../App/Views/ChatView.swift),
[composer](../../../../App/Views/ChatComposer.swift),
[MessageView](../../../../App/Views/MessageView.swift),
[AppStore](../../../../App/State/AppStore.swift).
[ConversationUITests](../../../../AppUITests/ConversationUITests.swift) cover
draft switching, history position, keyboard, and initial/largest-text decisions;
[verification](../../../verification.md) records earlier real-host reopen and
keyboard fixes. Those checks do not prove live Stop, huge histories, or all new
entry paths. WebKit content has separate [scroll obligations](rich.md); passing
plain-text scroll tests cannot clear diagram loading flashes.
