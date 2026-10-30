# Domain conventions

Botto uses one domain glossary across the app and BottoCore:

- [GLOSSARY.md](../../GLOSSARY.md) defines the shared vocabulary.
- [docs/adr/](../adr/) records settled decisions. Read the ADRs relevant to the
  area before proposing a change; avatar work includes
  [Botto's local palette](../adr/0001-local-avatar-palette.md).

Use glossary terms in code discussions, tests, issues, and PRs. Resolve new or
ambiguous terms against the existing model and update the glossary when their
meaning is settled. Keep definitions free of implementation details. Add an ADR for a
consequential trade-off that needs its rationale preserved. If a proposal
contradicts an ADR, name the conflict and resolve it explicitly before changing
the decision. Use the next available ADR number; retain superseded decisions.

Read technical contracts alongside the vocabulary when they apply:

- [Core integration](../core-integration.md) for service ownership, chat identity,
  mutation access, and protocol boundaries.
- [Pairing integration](../pairing-integration.md) and [setup](../setup.md) for
  connection, authentication, and host reachability.
- [Avatars](../avatars.md) for shared identity, image precedence, edits, and motion.
- [Rich replies and files](../rich-content.md) for rendering and artifact behavior.

These guides own implementation details and evidence. The glossary owns names;
ADRs own decision rationale. Source and live observations can reveal a stale
guide; surface the discrepancy and update the affected owner.
