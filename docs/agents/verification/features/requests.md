# Answer requests and stop work (`requests`)

## User-facing description

See what a bot needs, review the host's choices, submit a choice or clarification,
or ask the running bot to stop. Sub-features: approval/denial, persistent-choice
confirmation, free-text questions, unsupported desktop requests, pending feedback,
offline safety, recovery, and Stop.

## How to get to it

- `requests.e.attention`: inbox → waiting bot’s context menu → **Needs you**.
- `requests.e.chat`: open a bot while a request is pending or receive one while
  composing; cards appear in the transcript above the composer.
- `requests.e.stop`: working conversation → **Stop** beside working status.

## Interactive checks

Follow [shared setup](../index.md). Demo Milo offers **Allow once** / **Keep
draft**. The disposable host's `BOTTO_APPROVAL` prompt requests its documented
harmless command. Use only authorized local tools and run-owned profiles.
Questions, unsupported requests, persistent choices, and delayed completion need
appropriate host fixtures; none is supplied by ordinary Milo demo. **Draft.**

Workflow `requests.approval`:

1. `.a1` Enter via **Needs you** in Inbox and separately directly into a waiting chat.
   Expect title, full action detail, and exactly the host-offered choices, with
   all actions visible/hittable above composer. Repeat keyboard open and largest
   text. Proof: visible bounds, screenshot, semantic names, host pending payload.
2. `.a2` Choose **Keep draft** in demo, then deny a separate harmless live
   fixture. Expect request removal and no approved tool effect. Choose **Allow
   once** on a fresh live request; repeat tap while pending. Expect one answer,
   pending feedback, then host resolution and exactly one harmless tool result.
   Proof: UI transitions, fresh pending-request read and host execution receipt.
   Demo's **Understood. I’ll keep the draft here.** proves no real host denial.
3. `.a3` On a host-offered “always” choice, expect **Allow future actions?** with
   scope consequence text. Cancel: request stays, no persistent grant. Confirm on
   an authorized disposable scope only: expect the exact chosen grant on fresh
   host read. Proof: dialog, cancel/confirm outcomes, independent permission
   readback. Reset only that run-owned grant after proof.

Workflow `requests.question`:

1. `.a1` Trigger an actual host clarification. Expect its offered choices and
   **Write your answer** / **Submit answer**. Whitespace-only answer is disabled;
   trimmed nonempty response submits once and settles the same request. Proof:
   semantic controls, pending feedback, fresh host response/readback.
2. `.a2` Deliver unsupported request or approval with no supported choices.
   Expect **Continue on Desktop** or supported fallback guidance and no unsafe
   mobile answer path. Proof: host fixture and rendered controls. A fabricated
   state setter alone cannot prove public delivery of these states.
3. `.a3` Submit a free-text answer larger than 16,384 UTF-8 bytes. Expect
   **This answer is too long** with the byte limit, shortening guidance, and
   **Nothing was sent.** Show this feedback after submission is attempted;
   preserve the draft and pending request. Shorten the answer and deliberately
   submit again; expect one host answer. Exactly 16,384 bytes is allowed.
   Repeat with multibyte text: 4,096 🙂 characters fit; adding one ASCII
   character exceeds the limit. Keep empty-answer and host-offered-choice
   validation unchanged. Proof: error text, retained draft/request, and host
   frame count/payload. If acknowledgment is lost after a valid answer is sent,
   expect uncertain-result guidance and no automatic resubmission on reconnect;
   check the host before sending again. Core service regressions cover byte
   boundaries, rejection before writing, corrected retry, and lost acknowledgment;
   they do not prove rendered feedback or draft retention. For the real form,
   run `testLiveOversizedQuestionKeepsDraftUntilCorrectedSubmission` with a
   signed Simulator build and `TEST_RUNNER_BOTTO_UI_TEST_HERMES_URL` pointing to
   the [disposable authority host](../../../dev-host.md). Its deterministic
   `BOTTO_QUESTION` provider requests a note through Hermes's actual clarify tool.
   The test pastes oversized text, checks quiet drafting and retained input
   after rejection, then submits a corrected answer and checks the host reply.

Workflow `requests.recovery`:

1. `.a1` Drop the run-owned socket while awaiting a decision; reconnect and
   reopen. Expect the same current request restored with host choices. Relaunch
   offline from saved cache; expect no actionable stale request. Proof: fresh
   request identity from host plus offline/online captures.
   While disconnected, allow local question drafting and show connection
   feedback only after an answer is attempted. No permission confirmation or
   response may proceed offline; recovery requires deliberate submission against
   the current request. Preserve the response text during recovery.
2. `.a2` Hold an answer pending, interrupt or replace the connection via external
   Botto link, then release success/error. Expect no late mutation of the new
   workspace or dismissing its form; no automatic answer retry. A request already
   accepted remotely may remain resolved. Proof: new workspace identity and
   independent old host resolution/count, not a claim of remote rollback.

Workflow `requests.stop`:

1. `.a1` Start controlled long work. Expect Stop when the conversation reports
   active work. If disconnected, tapping Stop shows connection feedback and
   sends no command. Online, tap once and attempt repeat while **Stopping…**;
   expect bounded feedback and host cancellation, then no Stop when idle.
   Proof: status transition, host stop receipt, and fresh canonical turn state.
2. `.a2` Repeat with stop error/disconnection and late completion after Stop.
   Expect an honest error/actual host final state, no phantom new turn, no
   automatic resubmit, and no updates applied to a replacement workspace.
   Proof: timed UI and host terminal state. Demo task cancellation does not prove
   backend Stop; live Stop remains untested until a suitable fixture exists.
3. `.a3` On iPhone/iPad and accessibility XXXL, VoiceOver must name choices,
   consequences, busy/disabled state, and Stop. Preserve task-order focus while
   replies arrive; record async announcements and keyboard reachability. Reduce
   Motion must not change authorization or final outcomes. Proof: focus/spoken
   record and relevant screenshots.

## Gotchas

Source: [RequestCard](../../../../App/Views/RequestCard.swift),
[ChatComposer](../../../../App/Views/ChatComposer.swift),
[AppStore](../../../../App/State/AppStore.swift).
[Hermes service tests](../../../../Tests/BottoCoreTests/HermesServiceTests.swift)
exercise request validation and recovery through the public service boundary.
[Conversation tests](../../../../AppUITests/ConversationUITests.swift) exercise
demo decisions and include an opt-in harmless live approval while typing. The
live case skips without its host fixture. Backend smoke checks exercise approval
reconnect, not all public decision entries or live clarification/Stop. Approval
can run real tools; read success from the host rather than inferring it from a
card disappearing. Missing fixtures block assertions rather than removing them.
See [verification](../../../verification.md) for recorded checks and limits.
