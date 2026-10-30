# Verification

Botto 0.1.0 was checked on 30 October 2026 with Xcode 27.1. Native observations
below use an iPhone 17 Pro Simulator running iOS 26.5. These results describe
the checked source and workflows, not every supported device or server.

## Automated checks

- BottoCore: 371 package tests and the MainActor-default compatibility build passed.
- Development tooling: 41 Python tests passed, including export exclusions,
  signing-file and symbolic-link refusal, version consistency, project-name
  normalization, and rejection of accidentally tracked relay credentials.
- The complete native contributor run passed 580 tests, with no failures and
  two opt-in transcript measurement tests skipped. It includes rich-file
  exposure and rendering, file installation, notification storage and removal,
  stale status results, header layout, and retained native workspace state.
- Fifteen distinct signed UI workflows passed. They cover setup prompt copy,
  native Share and preview dismissal; large text; bot creation; separate chats
  and draft restoration; live approvals and questions; profile access; interactive
  HTML; PDF rendering and zoom; and Save to Files with reopening in Files.
- Independent local-provider readback confirmed the uniquely named exported file
  contains the exact 80-byte sample, with SHA-256
  `ab2d37c15d4277807c8d7c9ac788d680ce95645b07a1d0e61ee34005a2b41cce`.
  This complements the UI Save and reopen evidence; a preview cache is not a
  durable export.
- The optional notification plugin passed 42 Python tests. The relay passed
  TypeScript checking, 24 Vitest cases, two bundled restart tests, and four
  process-crash scenarios. A local Wrangler dry run passed; no relay was deployed.

## Live Hermes workflows

A disposable host used official Hermes source at
`4a0eaf7989b6804319ddb94fa5d96c5a716080a1`. Local deterministic model responses
avoided external model credentials. Authentication, profiles, SQLite history,
authority events, uploads, downloads, and tool execution used real Hermes code.

The public Connect screen completed password sign-in, loaded the host inbox,
and sent and received a chat message. Service-level probes verified reconnect,
persisted history, cross-client chat discovery, uploaded file and image bytes,
and recovering and resolving a pending approval. Signed UI checks created bots,
approved a harmless local command, and corrected an oversized question response
without losing its draft. Forget returned to welcome without requiring the
optional notification plugin on an unpaired host.

Demo entry, both language and costume directions, Settings credits, and bundled
licenses were observed. The README's three 1206 × 2622 captures show the running
app with sample data and normalized status bars. Their metadata contains color
space and pixel dimensions, with no location or account data.

## Public source audit

The export inventory, authored documentation and comments, fixture provenance,
image pixels and metadata, and local links were reviewed. All 57 included
Markdown documents were read. All 39 external reference URLs responded
successfully during the check. No production credential, private conversation,
personal endpoint, or personal image metadata was identified in that snapshot.

Gitleaks 8.30.1 reported the two documented public encryption-fixture keys.
They are intentional synthetic vectors, not deployment credentials. Export
checks exclude local environments, signing material, development records and
execution logs. Original third-party notices and immutable upstream patch and
source pins remain intact. Repeat the audit after any source or media change.

## Limits

- Hosted CI results are available in the [iOS workflow](https://github.com/sreejithraman/Botto/actions/workflows/ios.yml).
  Release tags must point to a commit with a successful run.
- Physical APNs delivery remains unverified. It requires Apple provisioning,
  the documented Hermes observer and optional plugin, and an operator-hosted
  relay. Local component tests do not prove delivery or a device banner.
- This run does not establish iPad or minimum-iOS-18 runtime acceptance,
  VoiceOver coverage, physical camera or Photos behavior, external browser/OIDC
  sign-in, Cloudflare Access, or performance and energy results.
- The local deterministic model exercises Hermes interoperability. It does not
  establish behavior across every external model provider or Hermes revision.

See [Contributing](../CONTRIBUTING.md) for repeatable checks, the
[verification map](agents/verification/index.md) for workflow assertions, and the
[release checklist](releasing.md) for source publication requirements. A recipe
records required coverage; it is not a passing result by itself.
