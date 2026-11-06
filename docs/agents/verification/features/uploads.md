# Attach files and photos (`uploads`)

## User-facing description

Add files or library images to a bot's draft, or paste them into the composer,
remove staged attachments, and send them into the selected conversation.
Sub-features: system Files/Photos pickers, native paste, thumbnail tiles,
per-tile progress, budgets, attachment-only send, the sent deck, and retirement
when the originating conversation or connection changes.

## How to get to it

- `uploads.e.file`: ready conversation → **Add attachment** → **Choose a file**.
  Several files can be chosen at once.
- `uploads.e.photo`: ready conversation → **Add attachment** → **Photo library**.
  Up to the remaining attachment budget can be selected at once.
- `uploads.e.paste`: long-press the composer → **Paste**. Copied images and files
  stage as attachments; text and links stay text; a mixed paste does both.
- `uploads.e.stage`: thumbnail tile in the scrolling row → **Remove <filename>** or
  **Send message**. There is no capture-camera action in this composer. A file
  still attaching has its own tile with an activity ring (`composer-pending-attachment`).
  Its **Cancel <filename>** stops that item; **Cancel All**
  (`composer-cancel-attachment`) appears for two or more.
- `uploads.e.sent`: a sent message with several attachments, or one local
  thumbnail, shows `sent-attachment-stack`, a fanned deck. Swipe through it, or
  tap a card (**Open <filename>**) for the preview. Thumbnails show images, a PDF's
  first page, or a text excerpt. They use a bounded memory cache; eviction or
  relaunch can replace them with named tiles. So do encrypted, malformed and other
  file types.

## Interactive checks

Use [shared setup](../index.md), run-owned local files and photo-library fixtures
with known original/prepared bytes, two bots, and a disposable host. Upload can
write remotely before Send; removing a chip is not remote file deletion. Retain
only harmless fixture names/content. **Draft; no complete recipe run here.** See
the 4 November 2026 [verification record](../../../verification.md) for what ran.

Workflow `uploads.file`:

1. `.a1` Open Files via the menu, choose a known PDF and text file, and watch each
   tile's ring until it clears. Expect a tile per file straight away, its real
   content once read, no duplicate import, and Send disabled until all settle.
   Cancel picker on a separate attempt; expect no new tile/upload.
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

Workflow `uploads.paste`:

1. `.a1` Copy a photo (Photos → Share → **Copy Photo**) and a file (Files), then
   paste each. Expect one tile with the source name and type and no Allow Paste
   prompt until **Paste** is chosen. Include a file with no extension. Paste text,
   a link and rich text alone, then each with an image; expect the text in the
   draft, and a tile only for the image. Proof: tiles, draft, host file bytes.
2. `.a2` Paste several Files items, past the budget, while offline and while an
   attachment is busy. Expect the budget message, connection feedback, or "Wait
   for the current attachment to finish." with the draft intact.

Workflow `uploads.sent`:

1. `.a1` Send three photos and a PDF. Swipe the deck both ways and drag vertically
   from it; expect a card tucking behind the next and transcript scrolling. Tap a
   card; expect that attachment's preview and `artifact-page`. Swipe across photo
   and PDF pages. Proof: recording frames and the "N of M" label.

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
Copying from another app backgrounds Botto, which ends the connection and asks to
reattach anything staged before it left. A tile's **Cancel <filename>** stops that
file and keeps the rest of the batch; a tile whose frame has already gone shows
"Cancelling" until it settles. Check the remaining tiles before sending. Reader page turns keep the batch running while the composer stays
exposed; a reader that hides the chat interrupts it. A same-chat access change
also interrupts it and shows a notice. Cancelling an import leaves the chat busy until a
frame already sent settles, because the frame cannot be recalled. Attachment frames
get a deadline scaled to their size at 64 KB/s, and a queued call's deadline starts
once the frames ahead of it settle. A host that pings over a non-loopback socket still drops a
frame that takes longer than its keepalive (about 40 seconds by default).
