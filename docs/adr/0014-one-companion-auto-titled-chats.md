---
status: accepted
---

# Talk to one companion in a main space and lasting spaces

A T3 bot used to open on a channel list with a mandatory `#general`, and every
new channel had to be named first. That copied a team chat tool onto a single
companion. The first replacement went too far the other way: every thread became
an equal, auto-titled chat under Today, This week and Earlier, and launch showed
a blank page. It cost nothing to start a chat, but chats read as disposable, and
nothing tied them together.

Botto now organizes one companion's T3 threads as **spaces**. A space is a
permanent place for an ongoing part of someone's life. Spaces have plain names,
carry no `#`, and are never grouped or expired by age.

## Main space

Each bot has one main space, the anchor of the list and the coordinator over
the others. Connecting adopts the thread in `bot.json`'s `mainThreadID`. If there
is none, or the host deleted it, connecting creates one titled with the bot's
name and `titleRenamed`, so T3 keeps that name. The user can rename it like any
other space, and renaming the bot leaves it alone. It cannot be archived from
Botto; if another client archives it, the next connection restores it. A main
space still titled `#general` by an older build takes the bot's name once.

Creation needs a model. A host without one still connects, shows the new-space
page, and gets its main space when models are next read. A failed creation never
fails the connection.

## Other spaces

The list shows the main space, pinned spaces, every other live space by recent
activity, then a quiet Archived link. A new space can be named up front, which
sets `titleRenamed`, or left unnamed, which sends T3's untitled wire title and a
`titleSeed` with the first message. Launch opens a space waiting on the user,
else one Botto is busy in, else the main space. A routine without a space gets
its own, named after it.

## A static prompt and live lookup

Botto's generated `AGENTS.md` and `CLAUDE.md` depend only on the bot's name and
description. They teach Botto to find and act on spaces with T3's thread tools
(`t3_thread_list`, `t3_thread_search`, `t3_thread_read`, `t3_thread_send`,
`create_threads`, `t3_thread_update` and `t3_thread_organize`). They never list
spaces, and point at `bot.json` for the main one. Botto writes them when they are
missing, when they still hold the short prompt an earlier build generated, or
when a manifest edit changes their text. Creating, renaming, pinning or archiving
a space, or changing the bot's look or model, leaves them byte-identical, so the
provider's prompt cache survives and the prompt cannot go stale.

## Costs

Botto spends a tool call to learn about another space instead of reading a list
in its prompt. Unnamed spaces show "New space" until T3 titles them. Botto can
adopt an unsaved replacement on retry. A main space archived on the host is
missing until the next connection or bare open.

### Recover a missing main space

If Botto creates a replacement but cannot save it in `bot.json`, keep that new
space so Botto can adopt it on retry. If someone deletes the unsaved replacement,
T3 reserves its ID and Botto displays a recovery error on bare open.

1. In the Botto project in T3 Code, choose an active space you want to use as the
   main space. If the project has no active spaces, create one in T3 Code.
2. Run `t3 thread list --project <workspace path> --json` on the T3 host and copy
   the chosen space's `threadId`.
3. Open `bot.json` in that workspace (usually `~/.botto/bots/main`). Set
   `mainThreadID` to the copied ID and save the file.
4. Reopen Botto. The chosen space becomes Main Space and the other spaces keep
   their conversations and IDs.
