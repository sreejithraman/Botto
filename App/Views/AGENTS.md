# UI behavior

## Deferred loading feedback

Show loading when it blocks the user's current intent. Keep background
connection, refresh, and optional preview work quiet while useful content or a
local action remains available.

- Keep cached lists, conversations, downloaded files, and local drafts usable
  during connection recovery. Allow typing and local form choices offline.
- Let users attempt an action that needs a connection. Show Connecting or
  reconnect guidance beside that action when the connection blocks it. Clear
  this feedback after recovery; a later disconnect needs a new action attempt.
- Keep useful content or a static fallback visible during refresh and inline
  preview rendering. Do not replace it with a spinner or announce routine work.
- Show progress for an explicit action that must wait, such as connecting in
  setup, opening uncached content, sending, uploading, creating, saving, or
  expanding a preview. Keep real errors and a usable retry or cancel path.
- Prevent duplicate pending actions. Preserve drafts after failure. Do not
  queue or replay sends, approvals, creation, or saves after reconnection;
  require a deliberate retry against current state.
- Preserve account, workspace, conversation, and stale-result checks. Keeping
  local content visible does not authorize new network work or stale actions.

Check quiet background work, an attempted blocked action, failure and retry,
and recovery without lost drafts or duplicate effects when changing these flows.
