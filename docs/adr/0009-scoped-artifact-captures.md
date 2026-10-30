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
