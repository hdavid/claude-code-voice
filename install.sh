#!/bin/sh
# Install Claude Code Voice: the voice-alerts Claude Code plugin and the Claude Voice menu bar app.
#
#   curl -fsSL https://raw.githubusercontent.com/hdavid/claude-code-voice/main/install.sh | sh
#   curl -fsSL .../install.sh | sh -s -- --config-dir ~/.claude --config-dir ~/.claude-work
#
# Options:
#   --config-dir DIR   Claude Code config directory to install the plugin into (repeatable).
#                      Default: $CLAUDE_CONFIG_DIR, or ~/.claude.
#   --rule-only        Copy the voice rule into DIR/rules/ instead of installing the plugin
#                      (no voice-say, no permission alerts; the rule falls back to a lockf one-liner).
#   --no-plugin        Skip the plugin (and the rule).
#   --no-app           Skip the menu bar app.
#
# Running it again updates both.

set -eu

REPO="hdavid/claude-code-voice"
MARKETPLACE="claude-code-voice"
PLUGIN="voice-alerts@$MARKETPLACE"
APP_NAME="Claude Voice.app"
APP_DIR="$HOME/Applications"

config_dirs=""
want_plugin=1
want_app=1
rule_only=0

say_step() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
	case "$1" in
	--config-dir) [ "$#" -ge 2 ] || die "--config-dir needs a directory"; config_dirs="$config_dirs
$2"; shift ;;
	--rule-only) rule_only=1 ;;
	--no-plugin) want_plugin=0 ;;
	--no-app) want_app=0 ;;
	-h | --help) sed -n '2,18p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) die "unknown option: $1 (see --help)" ;;
	esac
	shift
done

[ "$(uname -s)" = Darwin ] || die "Claude Code Voice needs macOS (it speaks with macOS say)."
[ -n "$config_dirs" ] || config_dirs="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

install_plugin() {
	dir="$1"
	say_step "Plugin into $dir"
	export CLAUDE_CONFIG_DIR="$dir"
	if claude plugin marketplace list 2>/dev/null | grep -q "($REPO)"; then
		claude plugin marketplace update "$MARKETPLACE" || die "could not update the marketplace $MARKETPLACE in $dir"
	else
		claude plugin marketplace add "$REPO" || die "could not add the marketplace $REPO in $dir"
	fi
	if claude plugin list --json 2>/dev/null | grep -q "\"$PLUGIN\""; then
		claude plugin update "$PLUGIN" || die "could not update $PLUGIN in $dir"
	else
		claude plugin install "$PLUGIN" || die "could not install $PLUGIN in $dir"
	fi
	unset CLAUDE_CONFIG_DIR
}

install_rule() {
	dir="$1"
	say_step "Rule into $dir/rules"
	mkdir -p "$dir/rules"
	curl -fsSL "https://raw.githubusercontent.com/$REPO/main/rules/voice-alerts.md" -o "$dir/rules/voice-alerts.md"
	echo "installed $dir/rules/voice-alerts.md"
}

install_app() {
	say_step "Menu bar app into $APP_DIR"
	tag="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"
	[ -n "$tag" ] || die "could not find the latest release of $REPO"
	zip="Claude-Voice-$tag.zip"
	tmp="$(mktemp -d)"
	trap 'rm -rf "$tmp"' EXIT
	base="https://github.com/$REPO/releases/download/$tag"
	curl -fsSL "$base/$zip" -o "$tmp/$zip"
	curl -fsSL "$base/$zip.sha256" -o "$tmp/$zip.sha256"
	(cd "$tmp" && shasum -a 256 -c "$zip.sha256" >/dev/null) || die "checksum mismatch for $zip"
	ditto -x -k "$tmp/$zip" "$tmp/app"
	[ -d "$tmp/app/$APP_NAME" ] || die "$zip does not contain $APP_NAME"
	osascript -e 'quit app "Claude Voice"' >/dev/null 2>&1 || true
	mkdir -p "$APP_DIR"
	rm -rf "${APP_DIR:?}/$APP_NAME"
	ditto "$tmp/app/$APP_NAME" "$APP_DIR/$APP_NAME"
	open "$APP_DIR/$APP_NAME"
	echo "installed $APP_DIR/$APP_NAME ($tag); its icon is in the menu bar"
}

if [ "$want_plugin" = 1 ]; then
	if [ "$rule_only" = 0 ] && ! command -v claude >/dev/null 2>&1; then
		echo "claude CLI not found: installing the rule only (install Claude Code, then run this again for the plugin)"
		rule_only=1
	fi
	echo "$config_dirs" | while IFS= read -r dir; do
		[ -n "$dir" ] || continue
		case "$dir" in "~"/*) dir="$HOME/${dir#\~/}" ;; esac
		if [ "$rule_only" = 1 ]; then install_rule "$dir"; else install_plugin "$dir"; fi
	done
fi

[ "$want_app" = 1 ] && install_app

say_step "Done"
echo "New Claude Code sessions speak when they need you, one at a time. Mute from the menu bar icon,"
echo "Control Center, /voice-alerts:mute, or: touch ~/.claude/voice-muted"
