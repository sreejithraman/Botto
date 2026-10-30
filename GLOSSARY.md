# Botto

Botto is a mobile companion for Hermes bots and their chats. This glossary names
the shared identities, avatar concepts, and notification relationships.

## Language

**Chat**:
An ongoing exchange with one bot, including its messages and related work.
_Avoid_: Conversation or session as interface labels

**Bot**:
A Hermes assistant shown in Botto, with its own identity, configuration, and chats.
_Avoid_: Account, chat

**Hermes profile**:
The host-managed identity and configuration behind a bot.
_Avoid_: Display name

**Profile ID**:
The host's identifier for a Hermes profile, independent of its visible label.
_Avoid_: Display name, title

**Notification pairing**:
An authorization for one device to receive notifications from one Hermes
profile on a saved host, removable without affecting other devices.

**Notification target**:
A provider registration used to deliver alerts for a notification pairing.
The provider can retire the target while the pairing remains authorized.

**Display name**:
The human-readable label shown for a bot, which can differ from its profile ID.
_Avoid_: Profile ID

**Shared avatar**:
A bot's saved appearance used across Hermes clients, expressed as a drawn face
or a saved image.
_Avoid_: Local theme

**Drawn face**:
An avatar described by a shape or generated recipe and a color, rather than a
saved image.
_Avoid_: Uploaded picture

**Shape family**:
The recognizable silhouette category of a drawn face, independent of its exact
contour, eyes, motion, or color shade.
_Avoid_: Exact drawing

**Activity cue**:
A symbol or prop shown with a bot's avatar to convey its current activity,
need for attention, or availability. Examples include the question mark,
lightbulb, wrench, sleeping z marks, no-signal symbol, and error mark.
_Avoid_: Accessory, activity badge, decoration

**Work phase**:
A kind of activity within a bot's ongoing work, such as thinking, using a tool,
or replying.
_Avoid_: Work mode

**Completion reaction**:
A brief celebration of a bot successfully finishing a turn.
_Avoid_: Finished state

**Turn reaction**:
A brief avatar response to a verified outcome of one bot turn, such as a
completion celebration or a surprised error response.
_Avoid_: Permanent outcome state
