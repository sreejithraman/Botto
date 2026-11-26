# Encrypted push verification (`notifications`)

This checklist applies when the T3 push integration and signing are available.
See [encrypted push](../../../push-notifications.md). A package crypto test
covers the envelope only. Signed delivery requires a configured relay and
a physical iPhone.

- `notifications.setup` — Enroll an owned device and confirm the expected
  workspace and environment.
- `notifications.delivery` — Trigger completion, approval, and question
  events with the app backgrounded. Verify each authorized alert arrives.
- `notifications.previews` — Check enabled previews and the generic alert
  used when a preview key is unavailable.
- `notifications.routing` — Tap an alert from cold and warm launches. Verify
  it opens the exact saved environment, project, and Space.
- `notifications.visibility` — Check foreground behavior when the originating
  Space is visible and when a different Space is open.
- `notifications.removal` — Remove one test device's enrollment and check
  it stops receiving alerts while another enrolled device remains active.
- `notifications.recovery` — Rotate or replace an owned registration and
  recover from an interrupted enrollment without reusing expired credentials.
