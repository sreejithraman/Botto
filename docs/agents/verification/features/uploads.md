# Attach files and photos (`uploads`)

## User-facing description

Add a file or library image to a bot's draft, remove staged attachments, and
send them into the selected conversation. Sub-features: system Files/Photos
pickers, preparation/upload feedback, budgets, attachment-only send, and
retirement when the originating conversation or connection changes.

## How to get to it

- `uploads.e.file`: ready conversation → **Add attachment** → **Choose a file**.
- `uploads.e.photo`: ready conversation → **Add attachment** → **Photo library**.
- `uploads.e.stage`: staged chip → **Remove <filename>** or **Send message**.
  There is no capture-camera action in this composer.

## Interactive checks

Use [shared setup](../index.md), run-owned local files and photo-library fixtures
with known original/prepared bytes, two bots, and a disposable host. Upload can
write remotely before Send; removing a chip is not remote file deletion. Retain
only harmless fixture names/content. **Draft; no complete recipe run here.**

Workflow `uploads.file`:

1. `.a1` Open Files via the menu, choose a known text file, wait for **Attaching…**
   to finish. Expect one removable named chip and no duplicate import while
   pending. Cancel picker on a separate attempt; expect no new chip/upload.
   Proof: picker/stage snapshots and host upload count.
2. `.a2` Remove the chip; expect it absent from the unsent message. Reattach,
   send with unique text, then reopen canonical conversation in a fresh app
   process. Expect the exact file association and text on the intended bot.
   Repeat attachment-only Send. Proof: UI, fresh host history and downloaded
   byte hash compared with source fixture via public artifact read.

Workflow `uploads.photo`:

1. `.a1` Open Photo library; select a known image, wait for preparation/upload,
   then send. Expect image attachment card, usable aspect/content, and correct
   association after canonical reopen. Proof: Photos choice, staged/sent image,
   public readback compared with prepared bytes; original compressed input may
   change during supported image preparation.
2. `.a2` Cancel selection, use unreadable/failed transferable fixture, and vary
   library access state where supported. Expect no phantom chip, clear read
   error when appropriate, and usable menu after recovery. Proof: permission
   state, error and retry captures. Missing physical/library setup blocks these
   paths; parser fixtures cannot prove native Photos delivery.

Workflow `uploads.budget`:

1. `.a1` Stage owned fixtures at limits: up to eight files, 25 MiB per file,
   50 MiB total; separately attempt ninth, over-file, and over-total input.
   Expect accepted supported files and clear budget error for rejected input,
   no partial rejected chip, no Send during preparation. Proof: exact byte/count
   manifest, UI and host upload/readback counts.
2. `.a2` Include compressed image whose prepared size differs from input and
   two pending imports. Expect conservative reservation until actual prepared
   size is known, no over-budget race. Fail an upload then deliberately retry;
   expect error and no duplicate staged result. Proof: timing, prepared byte
   counts and independent host association. Needs controlled preparation/failure.

Workflow `uploads.retirement`:

1. `.a1` Hold Files read, Photos read, and host upload separately. While pending,
   leave the conversation, select a sibling chat, open a different bot, background, or replace/reconnect
   the workspace. Release the old operation; expect no bytes/chip/error published
   into the new owner. Proof: both bot identities, before/after snapshots and
   independent host file/message association. Repeat success and late error.
2. `.a2` Complete a staged upload, select a sibling chat, and return. Expect the
   unconsumed file still sendable only in its original chat. Then restart with
   staged uploads and a text draft. Expect only durable text restored; reattach
   before sending. Offline drafting stays usable. Choose an attachment source
   or attempt Send; expect connection feedback then, without opening a picker,
   uploading bytes, or clearing text. A pending chat open may temporarily disable
   network actions. Proof: fresh-process composer and host history.
3. `.a3` On small iPhone and iPad at accessibility XXXL, expect Files/Photos
   cancellation, Remove, and Send reachable around keyboard and chips. VoiceOver
   must name attachment/removal and busy/error states. Reduce Motion must not
   change upload ownership or budgets. Proof: screenshots and focus/spoken record.

## Gotchas

Source: [ChatComposer](../../../../App/Views/ChatComposer.swift),
[AppStore](../../../../App/State/AppStore.swift),
[AttachmentLimits](../../../../Sources/BottoCore/AttachmentLimits.swift).
[Verification history](../../../verification.md) records small-iPhone Files
upload, host acknowledgment and canonical reopen, and core network round trips
against both backends. Native state tests cover stale destinations and budgets;
they do not prove all public picker cancellation/replacement paths. Actual
Photos permissions and structured native-image history remain partly unproved.
An old upload may already exist remotely after cancellation; require no wrong
message association, not an unsupported promise of deleting the uploaded file.
