#!/bin/sh
# Tests voice-say's silencing without making a sound: `say` and `afplay` are replaced by stubs that log their call.
#   - muted by hand: nothing spoken, the sentence is recorded for the app's red flash
#   - a call app has the mic (voice-in-call) while the app runs: same
#   - voice-in-call left by an app that is not running: ignored, the sentence is spoken
#   - nothing set: spoken, nothing recorded
set -eu

here="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/voice-say-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT INT TERM

mkdir -p "$work/bin" "$work/claude"
for tool in say afplay; do
	printf '#!/bin/sh\necho "%s $*" >>"%s/spoken.log"\nsleep "${STUB_SECONDS:-0}"\n' "$tool" "$work" >"$work/bin/$tool"
	chmod +x "$work/bin/$tool"
done
# `sleep` under its own name (a symlink: a copied system binary is killed for its signature) stands in for the running app (pgrep may only see the user's processes).
running_app=cvtestapp$$
running_app="$(printf '%.15s' "$running_app")"   # pgrep -x sees at most 15-16 characters of a name
ln -s /bin/sleep "$work/bin/$running_app"
"$work/bin/$running_app" 120 &
app_pid=$!
trap 'kill "$app_pid" 2>/dev/null; rm -rf "$work"' EXIT INT TERM
for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x "$running_app" >/dev/null && break; sleep 0.1; done
pgrep -x "$running_app" >/dev/null || { echo "cannot see the stand-in app with pgrep"; exit 1; }

fails=0
check() {   # <name> <expected spoken: yes|no> <expected missed: yes|no> <app name> <sentence>
	name="$1" want_spoken="$2" want_missed="$3" app="$4" sentence="$5"
	rm -f "$work/spoken.log"
	rm -rf "$work/claude/voice-missed"
	PATH="$work/bin:$PATH" CLAUDE_VOICE_DIR="$work/claude" CLAUDE_VOICE_APP="$app" CLAUDE_VOICE_GAP=0 \
		"$here/bin/voice-say" --sync "$sentence"
	spoken=no; [ -s "$work/spoken.log" ] && spoken=yes
	missed=no; ls "$work/claude/voice-missed/"*.txt >/dev/null 2>&1 && missed=yes
	if [ "$spoken" = "$want_spoken" ] && [ "$missed" = "$want_missed" ]; then
		echo "ok   $name"
	else
		echo "FAIL $name: spoken=$spoken (want $want_spoken), missed=$missed (want $want_missed)"
		fails=$((fails + 1))
	fi
	if [ "$missed" = yes ]; then
		got="$(cat "$work/claude/voice-missed/"*.txt)"
		[ "$got" = "$sentence" ] || { echo "FAIL $name: recorded '$got'"; fails=$((fails + 1)); }
	fi
}

check "speaks when nothing is set" yes no "$running_app" "Test session: hello."

touch "$work/claude/voice-muted"
check "muted by hand: silent, recorded" no yes "$running_app" "Test session: muted."
rm -f "$work/claude/voice-muted"

echo Teams >"$work/claude/voice-in-call"
check "in a call: silent, recorded" no yes "$running_app" "Bose session: in a call."
check "stale call file, app not running: speaks" yes no "no-such-app-$$" "Test session: stale."
rm -f "$work/claude/voice-in-call"

# A call starts while a long sentence plays: it stops within about a second and is recorded as missed.
interrupted() {   # <name> <file that silences> <its content>
	name="$1" file="$2"
	rm -rf "$work/claude/voice-missed" "$work/spoken.log"
	start=$(date +%s)
	PATH="$work/bin:$PATH" CLAUDE_VOICE_DIR="$work/claude" CLAUDE_VOICE_APP="$running_app" CLAUDE_VOICE_GAP=0 \
		STUB_SECONDS=20 "$here/bin/voice-say" --sync "Test session: a long sentence." &
	speaker=$!
	sleep 1
	echo "$3" >"$work/claude/$file"
	wait "$speaker" || true
	took=$(($(date +%s) - start))
	rm -f "$work/claude/$file"
	if [ "$took" -le 4 ] && ls "$work/claude/voice-missed/"*.txt >/dev/null 2>&1; then
		echo "ok   $name (${took}s)"
	else
		echo "FAIL $name: took ${took}s, missed=$(ls "$work/claude/voice-missed" 2>/dev/null | wc -l)"
		fails=$((fails + 1))
	fi
}
interrupted "a call starts mid-sentence: cut off" voice-in-call Teams
interrupted "muted mid-sentence: cut off" voice-muted ""

[ "$fails" -eq 0 ] || { echo "$fails failure(s)"; exit 1; }
echo "all passed"
