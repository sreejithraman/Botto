---
status: accepted
---

# Separate durable chat identity from live access

Botto keeps durable chat identity separate from service-issued live access because
a cached conversation can outlive its connection or selection. Durable identities
support navigation and retained history; mutations and downloads require current
access bound to their originating connection and chat. Returning to the same chat
or text cannot revive retired access, and an already-dispatched write settles
against its original source even if selection changes.

Contracts and lifecycle details: [core integration](../core-integration.md)
and [rich replies and files](../rich-content.md).
