# Botto avatars

A bot's drawn face is saved in the T3 workspace's `bot.json`. iOS and macOS use
the shared Open Bot Avatar definitions. Viewing a saved avatar preserves its
recipe and color. See [the avatar identity decision](adr/0001-local-avatar-palette.md).

## Choose a face

Choose a shape and color during first-run setup or use **Change look** in the
BottoMac inspector. On iOS, open the bot details to edit its look. Saving changes
the selected appearance. Cancel leaves the last saved appearance in place.

`AvatarPresetDefinitions.json` and `AvatarPresetFrames.json` are the bundled
catalog and reference frames. The picker uses shared shape families and color
presets. Older recorded metadata can still carry a generated shape, a custom
color, or an image fingerprint. These values keep their existing interpretation
when displayed. The renderer supports explicit hex, RGB/RGBA, and HSL/HSLA
colors and falls back for values it cannot draw.

## Refresh and motion

Botto renders resting, working, action-needed, and completion poses from
conversation activity. A long operation can move among thinking, tool use, and
replying. Work cues follow the current Space. Reduce Motion keeps a still
presentation with the appropriate cue.

A cached image takes precedence over a drawn face when it is a deliberate
photo. The asset fingerprint recognizes a static preview of the same drawn
face, so the native renderer can continue drawing it. iOS demo supports
sample avatar and activity scenarios without a real host.

## Developer playground

Debug and Internal builds expose an avatar playground. Use it to inspect
presets, colors, activity cues, and reduced motion. See
[developer tools](developer-tools.md) and [the avatar engine build](../scripts/avatar-engine/README.md)
for the pinned renderer and regeneration checks.
