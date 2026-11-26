# T3 routines

On iPhone or iPad, open **Spaces**, tap your bot at the bottom, and choose
**Routines**. On Mac, press **⌘I** to open the Botto inspector, then choose **Routines**.

Choose a schedule and prompt. A Routine runs in its linked Space. If it needs a
new Space, Botto creates one with the Routine's name. Deleting the Routine leaves
its Space and history available.

The host runs schedules and stores their state. The native client reads the
routine and thread state through T3. Use a disposable workspace and a harmless
prompt to check that a routine starts and its output appears in the intended Space.

See the [T3 service](../Sources/BottoCore/T3/T3BotService.swift), the
[iPhone and iPad panel](../App/Views/T3/BottoPage.swift), and the
[Mac inspector](../Mac/Views/MacBottoInspector.swift).
