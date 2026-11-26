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

## Update, 27 November 2026

The Hermes submission journal and gateway linked above were removed with the
Hermes engine. T3 keeps no local journal, so a receipt no longer reports one that
needs repair ([T3 thread IDs are chat identity](0015-t3-thread-ids-are-chat-identity.md)).
The rule against automatic replay still holds.
