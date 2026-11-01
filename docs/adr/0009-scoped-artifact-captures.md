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
quarantines the configuration until its cache is discarded. Unreadable recovery
state fails closed, with a visible save or recovery warning.

Active leases can record withdrawals while startup SQL maintenance is pending or
failed. Cleanup captures bounded guard/token state when queued and removes only
unchanged prior guards; a new active lease's guards survive that cleanup. SQL
reads and writes still wait for maintenance, and retired leases cannot journal.
First in-flight metadata writers participate in withdrawal, including canonical
roster pruning. Bounded runtime acceptance fencing uses operation stamps and a
discard watermark so forgetting an ID cannot make a stale read look unchanged.
