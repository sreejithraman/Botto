---
status: accepted
---

# Retain artifact captures within their saved connection

Botto keeps a disposable artifact index and captured file bytes separate from
saved chat history. Its namespace includes the saved connection ID and exact
server, installation, username, and provider bytes: native Hermes credentials
provide no stable account subject, so dropping the connection ID could share
private captures between distinct logins with empty usernames.

A capture remains useful offline; it does not establish the current contents
of a mutable host path or grant network access. Explicit reload uses current
service authority, while new source occurrences receive separate capture keys.
Confirmed Forget removes that connection's captures without changing the
failure boundary for credential removal.

Failed index writes withhold the affected saved index on restart. A bounded
invalidation record lives outside SQLite so a database lock cannot preserve an
old completeness claim. It keeps original captures and unrelated chats intact;
successful checked replacements clear only their matching write invalidation.
The ledger has a separate lock from SQLite. Canonical changes synchronously
record a bounded atomic guard before joining a pending SQL writer. This adds a
small filesystem write to admission; it avoids losing changes behind a blocked
database. Write tokens remain runtime-only and carry no host revision or access authority.
Repeated dirty versions reuse the durable identity guard without another file
write.
Committed eviction and deletion retain guards so an older chat book cannot
resurrect rows. Capture rollback removes only guards created by that transaction,
after confirmed SQL rollback, while preserving prior or newer canonical guards.
Speculative eviction rejects guard overflow before quarantining unrelated data.
Cold book seeds stay hidden until saved index reconciliation completes. Overflow
withholds affected metadata until its cache is discarded. Unreadable recovery
state fails closed, with a visible save or recovery warning.

Active leases can record withdrawals while startup SQL maintenance is pending or
failed. Cleanup captures bounded guard/token state when queued and removes only
unchanged prior guards; a new active lease's guards survive that cleanup. SQL
reads and writes still wait for maintenance, and retired leases cannot journal.
First in-flight metadata writers participate in withdrawal, including canonical
roster pruning. Bounded runtime acceptance fencing uses operation stamps and a
discard watermark so forgetting an ID cannot make a stale read look unchanged.

Transient transcript occurrences carry a local token. Current service authority
can read their attachments, but those tokens never identify saved captures or
Search references. An identified durable row replaces that provenance. Legacy
messages remain decodable; the reused `inflight-user` placeholder cannot certify
a durable occurrence.

A deliberate library entry or refresh retries failed startup storage and saved
index reconciliation within the same mount. Retries serialize; they preserve
withdrawal guards, fresh read evidence and retired-lease fences. Failed recovery
admission retains bookkeeping only for current, persisted or in-flight owners.
After an unknown initial index and failed guard admission, the existing bounded
acceptance fence conservatively rejects changed or evicted saved rows on retry.
It does not establish durability while the filesystem cannot record a guard.
Successfully checked saved rows replace temporary recovery hints without
creating a speculative write guard.

Observed roster membership gates canonical admission, asynchronous scan/restore
completion and seed installation. Whole-bot withdrawal includes working tails;
cached labels do not establish roster membership. A new roster invalidates old
scan admission, and a joined forced pass reads the latest roster.

Observed membership is also retained as an account-scoped restriction in that
same bounded ledger. Reading SQLite cannot retire it: an unavailable old chat
book may become readable later. Pending restrictions intersect; later roster
reentry alone cannot revive old content. A checked SQLite replacement can admit
its own chat through an atomic journal receipt. Book seeds never inherit that
receipt, and a later omission revokes the profile's receipts. Original captures
remain independent of metadata admission.

Failed roster admission retains the intersection of unsaved observations.
It withholds excluded saved rows and book seeds immediately. Library retry can
save that existing evidence; cached labels cannot change membership. A later
real observation also retries it, even with unchanged membership. Its save
warning remains until admission succeeds. Successful admission fences older
restore and seed work while preserving fresh accepted reads. A row's acknowledgment
clears only that row's guard; it cannot replace newer recovery state for its peers.
An eligible queued book request follows the new admission fence; active and
already-stale work keeps its prior fence. Inert seeds preserve existing admitted
rows. Deferred seed writes remain pending until reconciliation makes them eligible.

Ordinary guards and checked receipts share a bounded chat-identity budget;
namespace records have a separate bounded count. All records and profile hashes
share the existing recovery byte budget. Overflow first withholds only the
affected namespace. If that marker cannot fit, the cache compacts its configuration,
then uses the existing global withholding marker as a last resort. Speculative
capture eviction still rejects overflow before mutating SQL. These metadata blocks
preserve original captures and require explicit cache cleanup to retire. Current
and reopened libraries report the recovery failure.

A successful write clears only its registered revision after SQL readback; a
superseded writer cannot register that old revision again after suspension.
Namespace checkpoint IDs preserve newer restrictions and receipts across queued
cleanup. Ledger version 2 reads version 1 guards; supported older readers withhold
metadata on the unknown version. No recovery record grants host read or mutation
access.
