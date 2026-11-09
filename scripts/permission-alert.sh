#!/bin/sh
# Notification hook (permission_prompt): Claude is blocked on a permission dialog and cannot speak for itself,
# so the plugin says it, named after the session's folder. Goes through voice-say: muted means silent, and it
# waits its turn behind any other session that is speaking.
#
# Claude Code sends permission_prompt for every pending tool dialog, with the message
# "Claude needs your permission to use <tool>". That includes AskUserQuestion and ExitPlanMode: those are a
# question or a plan, not a permission request, and Claude already speaks them itself (rules/voice-alerts.md).
# Saying "Claude needs your permission" for them is wrong, so they stay silent here. For a real permission
# dialog the sentence names the tool.

set -u

input="$(cat)"
field() { printf '%s' "$input" | jq -r "$1 // empty" 2>/dev/null || true; }

cwd="$(field .cwd)"
message="$(field .message)"
subject="$(basename "${cwd:-Claude}")"
tool="${message#Claude needs your permission to use }"
[ "$tool" = "$message" ] && tool=""

case "$tool" in
  AskUserQuestion*|ExitPlanMode*) exit 0 ;;
esac

if [ -n "$tool" ]; then
  sentence="$subject session: Claude needs your permission to use $tool."
else
  sentence="$subject session: Claude needs your permission."
fi

exec "$(dirname "$0")/../bin/voice-say" "$sentence"
