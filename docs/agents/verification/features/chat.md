# Converse, keep drafts, and read history (`chat`)

Open a Space from the drawer or sidebar. Use
[shared setup](../index.md#shared-setup-and-readiness). Use a disposable T3
workspace with two Spaces for live streaming and durable history. These checks
are draft.

- `chat.send` — Send a unique message while observing streaming and tool
  details. Check the exact row in the originating Space. Interrupt an owned
  connection before acknowledgment and read the owner's history before retrying.
- `chat.drafts` — Leave different drafts in two Spaces, switch between them,
  then relaunch with the same saved pairing. Verify each text draft returns to
  its original Space. Break the connection while editing and verify the draft
  stays available for deliberate retry.
- `chat.history` — Reopen a known Space and compare visible history to the
  producer's rows. Read across an older page and inspect ordering, attachment
  identity, and collapsed tool details.
- `chat.reading-position` — Scroll to older content while a turn streams.
  Check that reading position stays stable until **Latest messages** is chosen.
  Repeat while opening the keyboard and with large Dynamic Type.

Use the [request](requests.md), [upload](uploads.md), and [rich](rich.md)
recipes for their additional assertions.
