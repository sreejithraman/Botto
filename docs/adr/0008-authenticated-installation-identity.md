---
status: accepted
---

# Verify hidden installation identity after sign-in

Hermes Webapp deliberately hides `install_id` from signed-out `/api/status`
responses. Botto checks public identity before credentials when available;
otherwise it authenticates at the reviewed origin and requires authenticated
identity before opening the workspace. In that case, the reviewed origin is the
credential-delivery trust boundary: installation pinning cannot precede sign-in.
Missing or changed authenticated identity still rejects the connection, and
redirect rejection and refresh-token persistence remain in force.

This follows the [upstream signed-out status contract](https://github.com/NousResearch/hermes-agent/commit/fd9ff2a0cdcb162cae83c6755da17c5f74290d3c),
without inventing an identity or requiring the server to expose private metadata.
