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
Native proposal cards and workflow result delivery need separate proof
when the pilot UI is built. This check does not exercise existing scheduled
Routines.
