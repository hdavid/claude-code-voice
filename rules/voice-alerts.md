# Voice alerts: Claude speaks when it needs you (macOS)

Install: the `voice-alerts` plugin loads this file into every session. Without the plugin, copy it to
`~/.claude/rules/voice-alerts.md` (Claude Code reads every `.md` under `~/.claude/rules/` as a standing instruction),
or paste its contents into `~/.claude/CLAUDE.md`.

## Core rule

**When Claude needs the user, it says so out loud: an action only the user can take, a question, a result the user
is waiting for. For an event Claude was watching for (a build finished, a device appeared), it plays a chime
first.** Unless voice is muted. Several sessions run at once and a question on screen is easy to miss; a sentence
spoken aloud is not.

## How to speak

Use `voice-say`, never a bare `say` or `afplay`:

```bash
voice-say "Firmware session: the build is ready, please flash it."
voice-say --chime "Backup session: the copy finished."
```

`voice-say` (on the PATH when the plugin is enabled) does three things a bare `say` does not:

- **One session at a time.** All sessions share one lock (`~/.claude/voice.lock`), so two sessions that need the
  user at the same moment speak one after the other, never over each other. The command returns at once and the
  sentence waits for its turn in the background.
- **Mute.** Nothing plays while `~/.claude/voice-muted` exists, checked at the moment the sentence's turn comes,
  so muting also silences sentences that are still waiting. The Claude Voice menu bar switch and its Control Center
  toggle flip that file from outside the session.
- **Calls.** Nothing plays either while a call app (Teams, Slack, Zoom, FaceTime, a browser...) has the microphone:
  the app writes `~/.claude/voice-in-call` then (menu: "Mute during calls"; list in `~/.claude/voice-call-apps`).
  A sentence already playing is cut off as soon as a call starts or the user mutes.
  A sentence not spoken while muted or in a call makes the menu bar icon flash red with its subject, so start
  every sentence with the session's name.
- **Chime.** `--chime` plays the Hero sound before the sentence.

If `voice-say` is not on the PATH (this file installed without the plugin), use the same lock directly:

```bash
nohup lockf -k -s -t 300 ~/.claude/voice.lock sh -c '[ -e ~/.claude/voice-muted ] || say "$1"' _ "Firmware session: ..." >/dev/null 2>&1 &
```

The user says "mute" → Claude runs `touch ~/.claude/voice-muted`. "unmute" → `rm -f ~/.claude/voice-muted`.
With the plugin, `/voice-alerts:mute` and `/voice-alerts:unmute` do the same.

## How to apply

- **Timing.** The sound plays when the question is actually on screen, never before. Write the answer text first,
  then send `voice-say` and the question together in the same final message. Never speak at the start of a turn
  and then carry on with more work or prose.
- **Order.** In that message the `voice-say` call comes FIRST and the question AFTER it. Tool calls run in the order
  they are sent and a question waits for the answer, so a `voice-say` placed after the question only speaks once
  the user has already answered.
- **Wording.** One short sentence: the session's subject first ("Firmware session: ..."), then what the user
  should do.
- **Waiting on something.** For a log, a build or a device, run a background loop that waits for the condition and
  then runs `voice-say --chime "..."`. The user does not have to answer; the sound tells them it is done.
- **Permission prompts.** Nothing announces them; the plugin does not speak for permission dialogs.
  Questions (AskUserQuestion) and plans (ExitPlanMode) are spoken by Claude itself.
- **Claude hears only through `voice-ask`** (below). Without it there is no microphone and the user types.
- **In addition, never instead.** Speech accompanies the written question; the question itself stays on screen.

## Voice replies: `voice-ask`

When the user has switched on "Voice replies" in the Claude Voice menu, they can answer a question out loud. For
every question:

1. Write the question and its options on screen first, as usual.
2. Run `voice-ask "<subject>: <question>, options in a few words"` as a foreground Bash call with
   `timeout: 600000`. It waits its turn on the voice lock; the app speaks the question, asks "Reply?", takes the
   dictation, reads it back and asks "Send, redo, or cancel?".
3. **Exit 0:** stdout is the user's answer in their own words. Act on it as the answer; when it names an option,
   take that option; when it is unclear, ask on screen with AskUserQuestion.
4. **Exit 1** (declined, nothing heard, cancelled): ask on screen with AskUserQuestion, without `voice-say`; the
   question was already spoken.
5. **Exit 2** (voice replies off, muted, in a call, or the app not running; returns at once): the usual `voice-say` first,
   then AskUserQuestion.

`voice-ask` takes the place of `voice-say` for questions; announcements that need no answer still use `voice-say`.
A dictated answer comes from speech recognition: read names, numbers and commands in it with care, and confirm
anything destructive or irreversible on screen before doing it.
