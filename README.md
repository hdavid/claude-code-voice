# Claude Code Voice

Make Claude Code speak when it needs you, and mute it from the menu bar or Control Center.

Two parts, one file:

- **The `voice-alerts` Claude Code plugin**: when Claude needs you (a question, an action only you can take, a
  result you are waiting for) it says so out loud, and chimes for an event it was watching for. It speaks through
  `voice-say`, which lets **only one session talk at a time**: when several sessions need you at once, they queue
  and speak one after the other instead of over each other. Permission prompts are announced too. Everything stays
  silent while `~/.claude/voice-muted` exists. `~/.claude/voice-volume` (5 to 100) sets how loud Claude speaks,
  without touching the Mac's volume.
- **Claude Voice.app**: a menu bar switch with Claude's volume slider, and a Control Center toggle. The icon
  follows the mute file either way, so "mute" typed to Claude and the menu are the same switch.

Requires macOS 26 (Tahoe) or later. Not affiliated with Anthropic; Claude is a trademark of Anthropic, PBC.

## Install

One line installs the plugin (into `~/.claude`) and the menu bar app (into `~/Applications`). Run it again later
to update both:

```
curl -fsSL https://raw.githubusercontent.com/hdavid/claude-code-voice/main/install.sh | sh
```

Options go after `sh -s --`:
- `--config-dir DIR`: install the plugin into another Claude Code config directory. Repeat it for several, e.g.
  `--config-dir ~/.claude --config-dir ~/.claude-work`.
- `--rule-only`: copy only the rule file into `DIR/rules/`, no plugin.
- `--no-app`, `--no-plugin`: skip one half.

The app download is checked against the release's sha256. To install by hand instead:

1. **The plugin.** In Claude Code:
   ```
   /plugin marketplace add hdavid/claude-code-voice
   /plugin install voice-alerts@claude-code-voice
   ```
   New sessions pick it up. It brings:
   - the rule `rules/voice-alerts.md`, loaded into every session by a SessionStart hook, which says when and how
     Claude should speak;
   - `voice-say` on Claude's PATH (`bin/voice-say`): mute check, chime, and the one-at-a-time lock;
   - a Notification hook that says "<folder> session: Claude needs your permission to use <tool>." when a
     permission dialog blocks a session (silent for AskUserQuestion and ExitPlanMode, which Claude speaks itself);
   - `/voice-alerts:mute` and `/voice-alerts:unmute`.

   Without the plugin, the rule alone still works: copy `rules/voice-alerts.md` to `~/.claude/rules/`. It then
   falls back to a `lockf` one-liner that uses the same lock.
2. **The app.** Download `Claude-Voice-<version>.zip` from the
   [latest release](https://github.com/hdavid/claude-code-voice/releases/latest) (signed and notarized), unzip,
   move `Claude Voice.app` to `~/Applications` or `/Applications`, open it. The Claude mark with sound waves appears in the menu bar.

## Use

- **Menu bar**: click the icon for Claude's volume slider, Mute, "Open at login" and Quit. The slider changes only
  Claude's voice and chime, not the Mac's volume; letting go plays a short sample at the new level. Option- or Control-click
  the icon to mute or unmute at once. While muted the mark is struck through and the icon is dimmed. Unmuting
  plays a short pop, so you hear that the voice is back.
- **Control Center**: open Control Center, "Edit Controls…" at the bottom, add "Claude voice". The toggle is ON
  when Claude speaks. It can also be placed in the menu bar from there. The app must have been launched once, and
  the gallery lists the control only from its second opening: macOS asks the extension for its controls when the
  gallery opens, so the first gallery is built before the answer arrives. If it is still missing, right-click the
  Desktop, "Edit Widgets…", close it, and open "Edit Controls…" again.
- **Shortcuts and Spotlight**: the action "Toggle Claude voice" is available, so a global keyboard shortcut can be
  assigned in the Shortcuts app.
- **From a terminal or a Claude session**: `touch ~/.claude/voice-muted` mutes, `rm ~/.claude/voice-muted` unmutes.
  `echo 40 > ~/.claude/voice-volume` sets Claude's volume to 40 %.
  Muting also drops sentences that are still waiting for their turn.

## Answer out loud

Switch on **Voice replies** in the menu. When Claude asks a question, the app speaks it and asks "Reply?". Say
"yes", then your answer after the tink; stop talking for two seconds to finish. The app reads it back and asks
"Send, redo, or cancel?" ("Read back before sending" in the menu turns that step off). "Send" hands the text to the
session that asked, as if you had typed it. Anything else, or silence, and the question waits on screen as usual.

The first time, macOS asks for Microphone and Speech Recognition access. Recognition runs on the Mac (on-device);
the microphone is only open while the app is waiting for an answer. Sessions ask through `voice-ask "question"`,
which prints the confirmed answer.

## One voice at a time

`voice-say` holds an flock on `~/.claude/voice.lock` (via macOS `lockf`) while it chimes and speaks, then
releases it after a short gap. Other sessions wait for the lock in the background, so `voice-say` returns at once
and Claude's turn is never held up. The kernel releases the lock when the holder exits, even if it is killed, so a
crashed session cannot leave the voice stuck. Waiting sentences are not strictly first-come, first-served, and one
that waits more than 300 seconds is dropped. Settings, as environment variables: `CLAUDE_VOICE_WAIT` (seconds,
default 300), `CLAUDE_VOICE_GAP` (silence between sessions, default 0.4), `CLAUDE_VOICE_CHIME` (sound file).
`voice-say --sync` waits until its sentence has been spoken.

The icon is the Claude mark with the speaker's sound waves, rendered by `scripts/make-icons.py` into
`Shared/Assets.xcassets` and used by both the menu bar and the Control Center toggle.

## Build from source

```
brew install xcodegen
./build.sh            # project.yml → Xcode project → Release build → ~/Applications/Claude Voice.app → launch
```

Signing is ad-hoc by default, which is enough for the menu bar switch. The Control Center control needs a real
identity: macOS refuses the extension unless it is sandboxed, and the widget daemon drops an ad-hoc signed control
right after registering it. Put your identity in a git-ignored `Local.xcconfig` (see `Signing.xcconfig`); no
provisioning profile is needed. The extension is sandboxed with one exception, `~/.claude`, where the file lives.

`scripts/package.sh` builds a universal Release zip into `dist/`, signed with `DEVELOPER_ID_APP` when that is set
and notarized when `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID` and `NOTARY_PASSWORD` are set.

## Releases

`.github/workflows/build.yml` builds every push and pull request (ad-hoc, as a check). `.github/workflows/release.yml`
runs on a `v*` tag: it imports the Developer ID certificate from the repository secrets into a throwaway keychain,
builds, signs, notarizes, staples, and attaches the zip and its sha256 to the GitHub Release. The secret names are
listed at the top of that workflow.

## Layout

- `Shared/`: the state files both targets read and write (mute, volume, voice-reply switches).
- `App/`: the menu bar app (AppKit, `LSUIElement`), the Shortcuts intent, and voice replies (`VoiceReplies`,
  `Listener`, `Speaker`).
- `Control/`: the WidgetKit extension with the `ControlWidgetToggle`.
- `rules/voice-alerts.md`: the instruction that makes Claude Code speak.
- `.claude-plugin/`, `hooks/`, `commands/`, `bin/voice-say`, `bin/voice-ask`, `scripts/permission-alert.sh`: the Claude Code plugin
  and the marketplace that lists it.
- `install.sh`: the one-line installer for the plugin and the app.
- `project.yml`, `Signing.xcconfig`: the XcodeGen spec and signing defaults. `build.sh`, `scripts/package.sh`.

## Licence

MIT, see `LICENSE`.
