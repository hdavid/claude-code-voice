#!/bin/sh
# Notification hook (permission_prompt): Claude is blocked on a permission dialog and cannot speak for itself,
# so the plugin says it, named after the session's folder. Goes through voice-say: muted means silent, and it
# waits its turn behind any other session that is speaking.

set -u

input="$(cat)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"
subject="$(basename "${cwd:-Claude}")"

exec "$(dirname "$0")/../bin/voice-say" "$subject session: Claude needs your permission."
