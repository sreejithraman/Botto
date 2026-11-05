---
status: superseded
---

# Preserve retired-tip evidence when cached rows leave

## Current decision

On 4 November 2026 Sree narrowed PR 24 and moved this contract to a follow-up
session. The decision below never landed on `main`. Its source stays on
`archive/pr24-durable-recovery-cf430b3`.

Negative evidence now lasts as long as its retained row, the existing restoration
holds and Book's own claims. [Core integration](../core-integration.md) owns that
contract. The removal also leaves Library free of indefinite proof-gated withholding
and retired-stored-ID ledger state.

These cases are deferred:

- A dispute held only by an evicted Library row. Book's claim survives, but a row
  budget that drops it leaves Library no record of the dispute.
- Retired stored IDs after their row is evicted or storage fails.
- A retired tip that returns, whether or not its row survived. It follows `main`'s
  source rules and needs no separate identity proof. Its old disputes do not return
  with it until a later Book seed.
- A dispute that no longer fits after restoration finishes. It no longer holds its
  scope.

Sree accepted `main`'s behavior for these cases in this delivery. This records a
scope choice. It measures no frequency and accepts no wider security claim.
[Returning versions](0013-returning-versions-follow-the-host.md) settles them.

## Original decision

Library rows are disposable. Identity disputes and retirement evidence constrain
what later rows may become Search results or artifacts. Treating both as ordinary
cache content lets eviction or directory reentry erase that constraint.

Library owns admission and ordering. A negative-only publication or Book seed can
narrow the same tip without proving source authority or directory presence. A
returning retired tip needs its own coherent identity read; merely observing its
source does not suffice. Proof for a replacement cannot resolve the older tip's
message disputes.

The existing recovery guard carries a row's raw retired stored IDs after eviction
or deletion. Its next checked saved row carries those IDs again. The optional
ledger field reads older records without changing SQLite. Older builds ignore
the field, so downgrade does not preserve these guarantees.

The runtime mirror shares the evidence count and byte limits. When detailed
evidence cannot fit, the existing bounded scope hold withholds Library rows until
a qualifying read. Recovery rereads preserve evidence already known in memory.
Journal overflow retains the existing coarse recovery block and warning. A
failed journal write cannot guarantee survival across a crash.

This favors retaining identity uncertainty over Library availability. A long
returning tip without an exhaustive identity response may remain unavailable in
Library without expiry. Fetched chat history still works. Unrelated retained
chats remain usable unless a coarse recovery block necessarily includes them.
