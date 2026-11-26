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

## Try a Routine that asks before each run

Enable **Workflows** on your T3 Code host, then reconnect Botto. In **Routines**,
add a Routine, turn on **Ask before each run**, and choose its time, days, and
an existing Space. Review the schedule, Space and prompt. The Routine stays off
until you tap **Turn on**.

At the scheduled time, the Space asks whether to run it. Choose **Run** to send
the approved prompt in that Space, or **Skip** to leave the Space as it is.
A question that goes unanswered for 24 hours is skipped. Use **Active** to
pause or resume future starts. A question that's already open can still be
answered after pausing. If the host refuses deletion while a run is unfinished,
finish that run and try again.

## Workflow pilot verification

The pilot targets a single-owner T3 environment. Each paired device acts for
that owner. Botto must match the connected environment and project against the
Routine it installed before showing a run or answering a question. T3 v0.1.12
grants read and answer permissions across the environment, so the pilot does
not support shared multi-operator hosts.

On Apple Silicon with Node.js 22.4 or newer and Python 3.9 or newer, run the proof from the
repository root:

```sh
node scripts/check-t3-routine-workflows.mjs
```

The check uses the released v0.1.12 engine from Botto's bundle script. It
starts T3 on loopback with a temporary home and UTC, then removes the engine
data on exit. Allow up to four minutes for it to cross a real scheduled time. An
approved fixture and an inert proposal have the same fixed time and weekday.
The approved fixture starts once after the engine restarts. The proposal
remains inert over its due time and is installed only when the check takes
the explicit approval path. The check waits for the scheduler to record the
proposal's next date, then checks for an unexpected run. It discards the
response to a committed installation and checks the source and registered
version before considering the installation complete.
Pausing replaces the schedule with a version that skips manual starts and
keeps the outstanding run's version until it can finish.

The check uses Botto's default pairing exchange for the owner. Installing a
definition uses the existing `terminal:operate` permission. Enabling
Workflows uses `settings:write`. Reading back the installed source uses
`filesystem:read`. The default pairing exchange already grants both. A session with
`orchestration:read` can read a run. Answering uses
`orchestration:operate`, the same permission used to act in ordinary
threads. The check confirms that an orchestration operator can already send to
and rename threads in both test projects. Read-only access cannot answer, and
the proof's Botto-side project filter rejects the other project's run. T3 still
accepts that answer directly from an operator.

The workflow returns a sample result after a durable question and uses no
provider credentials. The ordinary-message check verifies admission only.

To run the separate Swift lifecycle test against the same disposable engine:

```sh
node scripts/check-t3-routine-workflows.mjs --native-routine
```

It opens a seeded Space, turns on the proposal, reconnects, waits for a real
scheduled question on the native client's stream, pauses, answers **Skip**,
and deletes the Routine. It also reads back the existing scheduled tasks and
Space. The scheduled question and Skip run don't require a provider login.
Capturing a provider-backed result requires a configured model on the disposable host.
