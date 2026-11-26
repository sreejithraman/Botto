# Open workspace files (`library`)

Use a disposable workspace with known files and named Spaces. These checks
are draft. Searching the Spaces drawer is [`inbox.find`](inbox.md).

- `library.navigation` — Open the Spaces drawer, return to the active
  conversation, and open Botto's page. Check the selected Space and draft on
  return.
- `library.outputs` — Put a known file in `outputs/` and open it from Botto's
  page. Check its bytes and name. Repeat with a file card from a conversation
  to establish originating Space ownership.
- `library.captures` — Open an original file, then reopen its capture if
  available. Compare bytes. Change the selected Space during a pending file
  preview and verify its result is retired.

Follow the [artifact](artifacts.md) and [rich replies](rich.md) recipes for
export and rendering.
