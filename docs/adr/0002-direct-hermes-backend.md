---
status: accepted
---

# Connect directly to Hermes's native backend

Botto uses Hermes's authenticated HTTP and WebSocket backend, following the
direct route introduced by Hermex 2.0, without a WebUI dependency or a relay for
chat traffic. Hermes owns execution, models, tools, and scheduled work; Botto owns
mobile presentation, connection credentials, drafts, and cached reading.
This keeps Botto focused on the user's existing bots and lets server work continue
when the phone closes, while making native-protocol compatibility Botto's responsibility.

[ADR 0009](0009-optional-push-delivery.md) permits an optional notification relay.
It carries encrypted previews through APNs; chats and actions use the direct
Hermes connection.

Current connection requirements are documented in [setup](../setup.md).
Contracts and compatibility evidence: [core integration](../core-integration.md).
