# Claude Code Voice

Make Claude Code speak when it needs you, and mute it from the menu bar or Control Center.

Two parts, one file:

- **`rules/voice-alerts.md`**: a standing instruction for Claude Code. When Claude needs you (a question, an action
  only you can take, a result you are waiting for) it says so out loud with macOS `say`, and chimes for an event
  it was watching for. It stays silent while `~/.claude/voice-muted` exists.
- **Claude Voice.app**: a menu bar switch and a Control Center toggle that create and remove that file. The icon
  follows the file either way, so "mute" typed to Claude and a click on the icon are the same switch.

Requires macOS 26 (Tahoe) or later. Not affiliated with Anthropic; Claude is a trademark of Anthropic, PBC.

## Install

1. **The rule.** Claude Code reads every `.md` under `~/.claude/rules/` as a standing instruction:
   ```
   mkdir -p ~/.claude/rules
   curl -fsSL https://raw.githubusercontent.com/hdavid/claude-code-voice/main/rules/voice-alerts.md -o ~/.claude/rules/voice-alerts.md
   ```
   Or paste the file into `~/.claude/CLAUDE.md`. New sessions pick it up; the file says how Claude should time
   and word what it speaks.
2. **The app.** Download `Claude-Voice-<version>.zip` from the
   [latest release](https://github.com/hdavid/claude-code-voice/releases/latest) (signed and notarized), unzip,
   move `Claude Voice.app` to `~/Applications` or `/Applications`, open it. A speaker appears in the menu bar.

## Use

- **Menu bar**: click the icon to mute or unmute. While muted the speaker is crossed and the icon is dimmed.
  Right-click (or control-click) for the state, "Open at login" and Quit. Unmuting plays a short pop, so you hear
  that the voice is back.
- **Control Center**: open Control Center, "Edit Controls…" at the bottom, add "Claude voice". The toggle is ON
  when Claude speaks. It can also be placed in the menu bar from there. The app must have been launched once, and
  the gallery lists the control only from its second opening: macOS asks the extension for its controls when the
  gallery opens, so the first gallery is built before the answer arrives. If it is still missing, right-click the
  Desktop, "Edit Widgets…", close it, and open "Edit Controls…" again.
- **Shortcuts and Spotlight**: the action "Toggle Claude voice" is available, so a global keyboard shortcut can be
  assigned in the Shortcuts app.
- **From a terminal or a Claude session**: `touch ~/.claude/voice-muted` mutes, `rm ~/.claude/voice-muted` unmutes.

The icon is Claude.app's own menu bar mark with a speaker beside it when Claude.app is installed (the mark is read
from that app at run time, never shipped here); otherwise an asterisk.

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

- `Shared/MuteState.swift`: the one file, read and written by both targets.
- `App/`: the menu bar app (AppKit, `LSUIElement`) and the Shortcuts intent.
- `Control/`: the WidgetKit extension with the `ControlWidgetToggle`.
- `rules/voice-alerts.md`: the instruction that makes Claude Code speak.
- `project.yml`, `Signing.xcconfig`: the XcodeGen spec and signing defaults. `build.sh`, `scripts/package.sh`.

## Licence

MIT, see `LICENSE`.
