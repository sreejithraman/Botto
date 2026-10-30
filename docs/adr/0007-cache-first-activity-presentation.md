---
status: accepted
---

# Show cached content while revalidating in the background

Botto uses cache-first presentation for lists, counts, conversations, activity,
and previews. Show useful cached content immediately and keep background work
quiet while that content or a local action remains usable. Progress belongs to
an explicit action that must wait.

Keep the last useful result separate from refresh progress and failure. A
pending read supplies no evidence of failure. Communicate historical or
incomplete information when it affects how the user interprets the content.
This accepts qualified stale information in exchange for continuity during
revalidation; fresh results update the existing presentation in place.

Availability follows the same rule: unknown or pending connection and bot
activity stay neutral until evidence establishes unavailability. Sleeping and
offline cues require a failed or lost connection or explicitly unavailable
activity. Neutral presentation does not claim current idle activity or grant
live access.

Freshness describes presentation; authorization follows
[durable identity and live access](0003-durable-identity-live-access.md), and
recovery follows [uncertain mutation handling](0005-uncertain-mutations.md).
The [activity contract](../core-integration.md#cached-activity-presentation)
defines the activity-specific states and labels.
