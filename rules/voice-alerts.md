# Voice alerts: Claude speaks when it needs you (macOS)

Install: copy this file to `~/.claude/rules/voice-alerts.md` (Claude Code reads every `.md` under `~/.claude/rules/`
as a standing instruction), or paste its contents into `~/.claude/CLAUDE.md`.

## Core rule

**When Claude needs the user, it says so out loud with macOS `say`: an action only the user can take, a question,
a result the user is waiting for. For an event Claude was watching for (a build finished, a device appeared), it
plays a chime.** Unless voice is muted. Several sessions run at once and a question on screen is easy to miss;
a sentence spoken aloud is not.

## Mute

Voice is off while the file `~/.claude/voice-muted` exists. Check it immediately before every `say` or `afplay`,
never earlier, because the file changes from outside the session (the Claude Voice menu bar switch and its
Control Center toggle flip it):

```bash
[ -e ~/.claude/voice-muted ] || say "..."
```

The user says "mute" → Claude runs `touch ~/.claude/voice-muted`. "unmute" → `rm -f ~/.claude/voice-muted`.

## How to apply

- **Timing.** The sound plays when the question is actually on screen, never before. Write the answer text first,
  then send the `say` and the question together in the same final message. Never a `say` at the start of a turn
  followed by more work or prose.
- **Wording.** One short sentence: the session's subject first ("Firmware session: ..."), then what the user
  should do.
- **Waiting on something.** For a log, a build or a device, run a background loop that waits for the condition and
  then plays the chime and speaks: `afplay /System/Library/Sounds/Hero.aiff; say "..."`. The user does not have
  to answer; the sound tells them it is done.
- **Claude cannot hear.** There is no microphone. The user still types.
- **In addition, never instead.** Speech accompanies the written question; the question itself stays on screen.
