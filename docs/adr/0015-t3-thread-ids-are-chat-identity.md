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
read has no partial or warning result, and T3 neither refuses rows nor keeps a
local journal that might need repair. Botto now uses the T3 thread ID as the
chat identity and no longer models identity drift.

A directory is Botto's current inventory of the Spaces it can list, not proof of
what exists on the host. T3 leaves workflow-step threads out on purpose. When
another client archives a Space, T3 can drop its active shell and publish the
directory before the archive refresh lists it again, so for a moment the Space
is missing while its thread still exists. A Space missing from a directory is
therefore only unavailable in Botto: it keeps its record, cached messages and
draft, loses its activity and any live access it holds, and becomes available
again when a later directory lists it.

The identity type still has separate root, stored and alias fields. Folding them
into one ID changes saved bindings and notification targets, so it is left for a
separate decision.

Two safety rules stay because T3 can still trigger them. A transcript that repeats
a row ID marks those rows ambiguous and withdraws their actions. Live access is
still a revocable grant that is retired on every reconnect or change of
selection ([durable identity, live access](0003-durable-identity-live-access.md)).

Older saved chats still load. Keys only the removed machinery wrote, the
disputed row list and a request's queue ID, are ignored when read. A row a
Hermes build saved as disputed used to show as plain text with its actions
withheld; it now shows as an ordinary row with its actions. That data lives only
in the cache of a Hermes connection, and no Hermes connection can be used any
more.

This supersedes [retired-tip evidence](0012-retired-tip-evidence.md) and
[returning versions](0013-returning-versions-follow-the-host.md).
