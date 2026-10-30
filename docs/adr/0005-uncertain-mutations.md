---
status: accepted
---

# Reconcile uncertain mutations without automatic replay

A lost acknowledgment can hide a successful send, approval, creation, or save,
so Botto surfaces uncertainty and never automatically replays that mutation.
Recovery reconnects and reads current host state while preserving the user's
draft and operation context; another mutation requires a deliberate action
against current state. This accepts recovery friction to avoid duplicate effects,
and keeps the durable submission journal as an identity record rather than an
offline outbox or a promise of exactly-once execution.

Contract and recovery rationale: [core integration](../core-integration.md).
Implementation evidence: [gateway failure handling](../../Sources/BottoCore/Networking/HermesGateway.swift)
and [submission journal](../../Sources/BottoCore/Networking/HermesSubmissionJournal.swift).
