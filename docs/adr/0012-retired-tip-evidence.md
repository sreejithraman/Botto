---
status: accepted
---

# Preserve retired-tip evidence when cached rows leave

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
