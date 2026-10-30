# Scheduled handoffs in Hermes chat

Botto presents a verified cron handoff as **Scheduled check · <job name>**, with
its original timestamp. **Show details** opens the original, selectable text
in a separate sheet. Bounded plain-text sections keep large payloads visible
at every text size; **Copy payload** copies the complete original text. The
sheet covers the transcript so incoming replies remain unread during inspection.
It does not render Markdown, load attachments, execute commands, or expand history. Conversation records retain the role, ID,
text, and timestamp. The useful assistant reply keeps its usual presentation.

## Classification and trust

The inspected Hermes sources are authority commit
`4a0eaf7989b6804319ddb94fa5d96c5a716080a1` and sidecar commit
`ca6782850432927f33df4775cb6dd45bb51460d2`. Both cron producers construct the
wrapper in `cron/scheduler_delivery.py`. Injected gateway turns persist
`display_kind: internal_notification`; that category also covers other machinery.
`gateway/session_transcript.py` exports the display fields on authority history.
The sidecar REST history also retains the persisted fields.

Botto requires **all** of the following:

- A user-role row with host-supplied `display_kind: internal_notification`.
- No attachments.
- The exact, anchored known wrapper, including the instruction and blank line.
- A nonempty single-line job name without quotes/control characters, within a
  bounded 1,024-character header, followed by a nonempty payload.

The isolated compatibility parser lives in
`Sources/BottoCore/Protocol/HermesMessagePresentation.swift`. Hermes does not yet
export cron-specific job identity here. The parser supplies the job name and
narrows the broad internal category; text alone never establishes provenance.
Missing metadata, unknown wrappers, quoted/fenced wrappers, ordinary cron
conversation, tool results, and unrelated background messages stay unchanged.
A human pasting the exact wrapper remains an ordinary user message.

History, reconnects, and completion-triggered live history refreshes all use the
same projection. Older Botto caches lack provenance and remain ordinary messages
until a fresh Hermes read supplies it. Botto never guesses metadata for old rows.
Existing profile/session/sequence fences still reject unrelated and duplicate
events.

## Silence and attention

Botto retains successful internal-turn silence results in its model and disk
cache without showing a bubble. It follows the gateway's whole-response marker
rule (`[SILENT]`, `SILENT`, `NO_REPLY`, `NO REPLY`, and the supported Chinese
forms), including short edge punctuation and whitespace normalization. It does
not apply the cron producer's looser prefix rule to chat replies. Prose that
mentions markers stays visible. `failed_turn` and error metadata keep failed
responses visible. Live streams with internal provenance hold possible marker
prefixes until they diverge or settle; failed completion unhides the response.
Approval requests and failure notes keep their existing controls and behavior.

Scheduled input rows and silent replies do not contribute to transcript unread
evidence, user/assistant previews, or automatic following. Details use a sheet,
so inspection does not resize history. A subsequent meaningful reply still
contributes to unread state and **Latest messages**. These transcript changes
do not themselves deliver OS notifications. Optional push now belongs to the
separate [notification feature](push-notifications.md); explicit scheduled-result
alerts remain deferred pending authoritative delivery semantics.

Directory rows expose physical message counts, previews, and activity times,
not an attention cursor. Botto cannot safely infer that an unopened chat's count
change came only from automation. Those directory-only updates remain
conservative. A full, identity-matched history read can prove that only quiet
rows were appended after already-read content; Botto records that evidence
without moving the user's meaningful-message seen cursor. Missing or stale
read evidence cannot dismiss unrelated unread activity.

## Remaining protocol gaps and smallest additions

No backend changes are included. Two small upstream additions would complete
the experience for every supported transport:

1. Persist a producer-owned descriptor such as
   `display_metadata.automation = {kind: "scheduled_job", job_name}` on the
   input row. Job/run/delivery IDs can be optional audit fields. Carry the same row ID, descriptor,
   text, and timestamp in the input/start event and unfinished-turn snapshot.
   Current cron `message.start` frames can have an empty payload; Botto must wait
   for history rather than invent a user row or infer provenance from a delta.
   The sidecar's text-only `inflight.user` likewise cannot prove provenance.
   Explicit success/silence outcome metadata on assistant rows would remove
   the need to interpret legacy markers and protect ambiguous historical errors.
2. Add a durable `last_attention_row_id` (or equivalent monotonic attention
   revision) to session-directory entries, advancing for meaningful replies,
   failures, and decisions, while ignoring routine scheduled input and silence.
   That lets an unopened/offline chat stay quiet without hiding real activity.

Until then, missing provenance remains visible, and opaque directory activity
can remain unread until verified by a full read. This is intentional preservation
of user messages and actionable events, not a blanket background-event filter.

## Reproduction

Use the DEBUG launch arguments `--demo --automation-demo` for a large safe
sample, a normal reply, a silent result, and an approval. The automated live
fixture uses `--automation-live-demo` with the existing UI-test file gates.
Neither fixture connects to Hermes or performs monitoring/restart work.

Core tests exercise parser/provenance, large payloads, silence/failure boundaries,
cache round trips, sidecar and authority live refresh, replay duplicates,
wrong-session events, reloads, and reconnects. App tests cover unread evidence,
full-read proof, and scroll decisions. UI tests exercise details, reply/approval
visibility, light/dark appearance, accessibility XXXL, and reading position
across a quiet live event followed by a meaningful reply.
