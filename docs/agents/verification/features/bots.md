# Set up and inspect the companion (`bots`)

Start the normal BottoMac entry point from the isolated test account in
[shared setup](../index.md#shared-setup-and-readiness). Record the model and
app revision. These checks
are draft.

- `bots.create` — Start BottoMac with a configured provider. Name the
  companion and choose its face. Verify the Main Space initially uses the
  chosen name and read the saved avatar again from a fresh connection.
- `bots.interruption` — Stop or disconnect a disposable host during
  onboarding. Restore the connection and verify that completing first run
  reopens the same workspace with a Main Space.
- `bots.profile` — Open the Botto inspector. Read the name, appearance,
  model, and project folder. Change the bot's name after setup and verify
  the Main Space keeps its existing title.
