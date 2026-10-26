#!/bin/bash
# Regenerates the Xcode project, builds Claude Voice (Release) and installs it to ~/Applications.
# Usage: ./build.sh            build + install + (re)launch
#        ./build.sh --no-launch build + install only
set -euo pipefail
cd "$(dirname "$0")"
command -v xcodegen >/dev/null || { echo "xcodegen missing: brew install xcodegen" >&2; exit 1; }
xcodegen generate --quiet
xcodebuild -project ClaudeVoice.xcodeproj -scheme ClaudeVoice -configuration Release -derivedDataPath build -quiet build
APP_SRC="build/Build/Products/Release/Claude Voice.app"
APP_DST="$HOME/Applications/Claude Voice.app"
[ -d "$APP_SRC" ] || { echo "build produced no app at $APP_SRC" >&2; exit 1; }
mkdir -p "$HOME/Applications"
pkill -x "Claude Voice" 2>/dev/null || true
for _ in $(seq 1 50); do pgrep -x "Claude Voice" >/dev/null || break; sleep 0.1; done   # an `open` during the old quit fails (-600)
rm -rf "$APP_DST"
ditto "$APP_SRC" "$APP_DST"
echo "installed: $APP_DST"
if [ "${1:-}" != "--no-launch" ]; then
  open "$APP_DST"
  echo "launched. Control Center: Edit Controls... then add \"Claude Voice\"."
fi
