# Claude Code Voice

> ## [→ w0ts.github.io/claude-code-voice](https://w0ts.github.io/claude-code-voice/)
> **What Claude Voice is, how to install and use it: on the site.**
> This README is for developers.

Two parts: a Claude Code plugin (the voice rule and the `voice-say` / `voice-ask` commands) and a macOS menu bar app,
Claude Voice, with its Control Center toggle. They talk through files in `~/.claude`: `voice-muted`, `voice-volume`,
`voice.lock`, `voice-call-apps`.

## Layout

| Path | What |
|---|---|
| `.claude-plugin/` | Plugin and marketplace manifests |
| `rules/voice-alerts.md` | The rule loaded into every session: when and how Claude speaks |
| `bin/voice-say`, `bin/voice-ask` | Speak through the shared lock and the mute file; ask and hear the spoken answer |
| `commands/` | `/voice-alerts:mute`, `/voice-alerts:unmute` |
| `hooks/hooks.json` | Loads `rules/voice-alerts.md` into every session at start |
| `App/` | The menu bar app (SwiftUI): menu, volume, voice replies, call detection, missed alerts, self-update |
| `Control/` | The Control Center toggle (WidgetKit control) |
| `Shared/` | State shared by the app and the control: mute, volume, reply settings, icons |
| `install.sh` | The one-line installer: plugin into `~/.claude`, the latest release's app into `~/Applications` |
| `site/` | The user site, deployed by `.github/workflows/pages.yml` |
| `scripts/` | Packaging, icons, tests |

The bundle IDs stay `io.github.hdavid.claude-code-voice(.control)` from before the move to w0ts: changing them resets
macOS's microphone and speech permissions and breaks the Control Center toggle and self-update for installed apps.

## Build

```
brew install xcodegen && ./build.sh
```

Builds Release, installs to `~/Applications` and relaunches (`--no-launch` to skip). Put your signing identity in a
git-ignored `Local.xcconfig` (see `Signing.xcconfig`).

Tests: `scripts/test-voice-say.sh`; `scripts/check-no-permission-alert.sh` (also in CI) fails if the plugin ever speaks
for permission dialogs again.

## Release

Push a `v*` tag: `.github/workflows/release.yml` builds, signs, notarizes and attaches `Claude-Voice-<tag>.zip` to the
GitHub release. Installed apps update themselves from the latest release.

MIT licence. Not affiliated with Anthropic.
