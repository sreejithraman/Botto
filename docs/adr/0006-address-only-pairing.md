---
status: accepted
---

# Keep pairing addresses separate from authentication

Botto's pairing QR codes and connection links describe a Hermes origin, with
destination review before authentication. Codes contain no credentials, and
parsing neither connects nor replaces a saved connection; sign-in uses the
reviewed host's authentication flow. This keeps credentials out of shared codes
and preserves explicit destination choice, at the cost of a separate sign-in
step instead of treating possession of a code as authorization.

Current connection requirements are documented in [setup](../setup.md).
Payload and authentication contracts: [pairing integration](../pairing-integration.md).
User flow: [connection setup](../setup.md).
