# Main Space and permanent Spaces (`chats`)

Use a disposable T3 project with a provider. Compare the observed behavior to
[the Space decision](../../../adr/0014-one-companion-auto-titled-chats.md).
These checks are draft.

- `chats.choose` — Open the Main Space, create a named Space, and create one
  without a title. Verify each opens independently. The unnamed Space can
  take its generated title after the first message.
- `chats.isolation` — Leave distinct drafts in two Spaces and run a turn in
  one. Switch between them and check that drafts, history, and work stay
  attached to their original Space. Archive an ordinary Space and inspect
  it under Archived. Check that the Main Space offers no archive action.
- `chats.recovery` — Relaunch or reconnect and verify the Main Space and
  named Spaces retain their titles and history. Exercise Main Space launch
  along with live working and approval-needed Spaces. Record which Space
  the client selects in each case.
