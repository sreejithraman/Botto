---
status: accepted
---

# Let a returning chat version follow the host

Hermes can move a chat back to an older stored tip. Deleting a compressed chat's
newest segment does it, and so does restoring a snapshot. A restore can also give
an existing row number new text on a tip that never changed. Botto can't tell
these cases apart from a normal read, and no response shows that rows match what
Botto saw earlier.

Library therefore follows the tip the host names now. A returning tip is treated
as current and read fresh. Botto keeps negative evidence as long as its retained
row, the restoration holds and Book's own claims. It does not promise that
evidence survives eviction or storage failure; a later read finds any problem
still on the host.

This favors Library availability over remembered identity doubt. A proof gate
would keep long chats out of Library, because a chat too long for one response
can't pass it, and it still wouldn't detect a reused row number. The cost is
bounded: Library is read-only, row identity stays within its chat, opening a
result checks the current host again, and reloading a file uses current access.
The worst expected result is a stale Search snippet or artifact card in the right
chat until an explicit refresh.

Every hold needs an exit that works at any chat length: a qualifying read, a
retry or the next launch. A blocked or undecodable ledger has no such exit. No
read or retry clears it. Forgetting a connection clears only that connection's
block, a global marker can outlast that, and an undecodable ledger stays until
its file is removed. Saved metadata stays withheld at restore, as
[retained captures](0010-scoped-artifact-captures.md) requires, but rows this
launch reads appear in Library.

Three limits remain while blocked. A saved row stays hidden until a read that
isn't partial covers it. A chat held during recovery, by eviction or a late
write, waits for the next launch. A block that starts mid-launch leaves rows
already reconciled in place. A failed read of the saved index keeps its holds,
because a retry can still succeed.

This decides what [retired-tip evidence](0012-retired-tip-evidence.md) deferred.
If real Hermes output shows duplicate row IDs, withholding those rows durably is
the next step. It would hide a row, not a chat.
