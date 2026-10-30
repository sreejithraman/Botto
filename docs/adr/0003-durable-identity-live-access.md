---
status: accepted
---

# Separate durable chat identity from live access

Botto keeps durable chat identity separate from service-issued live access because
a cached conversation can outlive its connection or selection. Durable identities
support navigation and retained history. Mutations and in-chat network downloads require
current access bound to their originating connection and chat. The read-only
artifact library instead requires the connected service's own observed lineage
proof, checked before and after each history read or download. Cached identity
alone grants neither kind of access. This lets people browse another chat's work
without replacing the selected chat's live access. Returning to the same chat
or text cannot revive retired access, and an already-dispatched write settles
against its original source even if selection changes.

Contracts and lifecycle details: [core integration](../core-integration.md)
and [rich replies and files](../rich-content.md).
