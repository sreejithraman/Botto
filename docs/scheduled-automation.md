# T3 routines

In BottoMac, open the Botto inspector and choose **Routines** to view or manage
scheduled work. Choose a schedule and prompt. A routine runs in its linked
Space. If it needs a new Space, Botto creates one with the routine's name.
Deleting the routine leaves its Space and history available.

The host runs schedules and stores their state. The native client reads the
routine and thread state through T3. Use a disposable workspace and a harmless
prompt to check that a routine starts and its output appears in the intended Space.

See the [T3 service](../Sources/BottoCore/T3/T3BotService.swift) and the
[Mac inspector](../Mac/Views/MacBottoInspector.swift).
