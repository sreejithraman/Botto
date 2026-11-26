# Answer requests and stop work (`requests`)

Use the [shared setup](../index.md#shared-setup-and-readiness). Demo exercises
visible controls and local state. For live proof use a disposable T3 project
and a harmless provider action that requires approval or input. Draft.

## Approvals and questions

1. `requests.approval.a1` — Open the pending approval in its originating Space.
   Verify the offered choices and their enabled state. Switch Spaces and check
   the second Space has its own request controls.
2. `requests.approval.a2` — Approve a harmless action and verify one result
   from its original turn. Repeat separately with denial. Read the outcome
   from the original Space.
3. `requests.approval.a3` — When the provider offers a lasting grant, inspect
   **Allow future actions?** and cancel. Verify the request stays pending.
   Confirm separately in an authorized disposable scope and check the grant
   at the host.

1. `requests.question.a1` — Trigger a provider question with known choices.
   Submit one offered answer and verify that the original turn resumes with it.
   Where a free-text answer is offered, try whitespace and a nonempty answer.
2. `requests.question.a2` — Deliver a request that requires T3 Code. Verify the
   message directs the reader to the host and that the unsupported action has
   no submission control.
3. `requests.question.a3` — Use a hosted fixture that returns a definite
   validation rejection, including **This answer is too long**. Verify the
   pending request and typed draft survive. Correct the answer and confirm a
   deliberate retry uses a fresh operation and submits once. The
   [native form test](../../../../AppTests/NativeTranscriptRequestContinuityTests.swift)
   exercises the rendered retry behavior with a fixture.

## Connection recovery and Stop

1. `requests.recovery.a1` — Interrupt the T3 connection with a request
   pending. Check the state against the originating Space after reconnecting.
   Keep the local answer draft through disconnection. Only submit a current
   request after recovery.
2. `requests.recovery.a2` — Hold or lose acknowledgment for an answer, then
   reconnect or switch the paired workspace. Confirm there is no automatic
   resubmission, and compare the original host's result before retrying.
   Check that an old completion cannot dismiss the new workspace's form.
3. `requests.stop.a1` — Stop a running turn in an owned Space and attempt a
   repeat while Stop is pending. Verify the terminal state from T3 history.
4. `requests.stop.a2` — Interrupt the connection during Stop, then compare
   the real terminal outcome after reconnecting. Check that no resend or
   late result is applied to a replacement Space.
5. `requests.stop.a3` — Repeat with large Dynamic Type and VoiceOver. Record
   labels, busy and disabled states, focus order, and how Stop becomes reachable.

The [workspace retry tests](../../../../AppTests/ConversationAnswerRetryTests.swift)
cover rejected and uncertain answers. Live provider behavior requires separate
proof through the same T3 Space.
