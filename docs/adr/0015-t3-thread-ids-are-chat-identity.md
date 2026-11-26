---
status: accepted
---

# Use T3 thread IDs as chat identity

Hermes could change a chat's identity under Botto. Compaction moved a chat to a
new stored tip, sessions could branch, and a history read could refuse some rows.
Botto modeled that drift with version disputes, retired tips, partial
directories and local journal repair, so it would not trust a row that might
belong to another version.

T3 has none of that. Each Space is a thread whose ID never changes, a directory
read always covers the whole project, and T3 neither refuses rows nor keeps a
local journal that might need repair. Botto now uses the T3 thread ID as the
chat identity and no longer models identity drift. A Space missing from a
directory read is gone from the host. The identity type still has separate
root, stored and alias fields. Folding them into one ID changes saved bindings
and notification targets, so it is left for a separate decision.

Two safety rules stay because T3 can still trigger them. A transcript that repeats
a row ID marks those rows ambiguous and withdraws their actions. Live access is
still a revocable grant that is retired on every reconnect or change of
selection ([durable identity, live access](0003-durable-identity-live-access.md)).

Older saved chats still load. Keys only the removed machinery wrote, the disputed
row list and a request's queue ID, are ignored when read. A dispute saved by a
Hermes build no longer hides its row. That data lives only in the cache of a
Hermes connection, and no Hermes connection can be used any more.

This supersedes [retired-tip evidence](0012-retired-tip-evidence.md) and
[returning versions](0013-returning-versions-follow-the-host.md).
