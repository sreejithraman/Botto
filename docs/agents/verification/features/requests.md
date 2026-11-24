# Answer requests and stop work (`requests`)

Use the [shared setup](../index.md#shared-setup-and-readiness). A Demo check
proves presentation and fixture state. For live proof, use a disposable T3
project and a harmless provider action that requires approval or input.
These checks are draft.

- `requests.approval` — Trigger an approval. Inspect the request in the
  originating Space, approve a harmless action, and observe its result. Repeat
  separately with denial. Verify a different Space does not act on the request.
- `requests.question` — Trigger a provider question with known choices.
  Submit a valid choice and verify the original turn resumes with it.
- `requests.recovery` — Interrupt the connection while a request is pending.
  Reopen the Space and verify its current status before attempting an answer.
- `requests.stop` — Start an interruptible turn in an owned Space. Stop it,
  then verify the final state from the same Space and T3 history.
