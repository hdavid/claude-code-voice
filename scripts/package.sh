#!/bin/bash
# Builds the Release app (universal), signs it, notarizes it when the credentials are present, and leaves a zip
# and its sha256 in dist/. Used by the release workflow and usable by hand.
#
#   DEVELOPER_ID_APP   "Developer ID Application: Name (TEAMID)"; without it the identity comes from
#                      Signing.xcconfig / Local.xcconfig (ad-hoc by default)
#   NOTARY_APPLE_ID, NOTARY_TEAM_ID, NOTARY_PASSWORD
#                      Apple ID, team and app-specific password for notarytool; all three or no notarization
#   VERSION            goes into the file name (default: git describe)
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-$(git describe --tags --always 2>/dev/null || echo dev)}"
command -v xcodegen >/dev/null || { echo "xcodegen missing: brew install xcodegen" >&2; exit 1; }
xcodegen generate --quiet

SIGN_ARGS=()
if [ -n "${DEVELOPER_ID_APP:-}" ]; then
  TEAM=$(sed -n 's/.*(\([A-Z0-9]*\))$/\1/p' <<<"$DEVELOPER_ID_APP")
  [ -n "$TEAM" ] || { echo "DEVELOPER_ID_APP must end in (TEAMID): $DEVELOPER_ID_APP" >&2; exit 1; }
  SIGN_ARGS=("CODE_SIGN_IDENTITY=$DEVELOPER_ID_APP" "DEVELOPMENT_TEAM=$TEAM")
fi

rm -rf build/Build/Products/Release dist
mkdir -p dist
xcodebuild -project ClaudeVoice.xcodeproj -scheme ClaudeVoice -configuration Release -derivedDataPath build \
  -quiet ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} build
APP="build/Build/Products/Release/Claude Voice.app"
[ -d "$APP" ] || { echo "no app at $APP" >&2; exit 1; }
codesign --verify --deep --strict "$APP"
lipo -archs "$APP/Contents/MacOS/Claude Voice"

if [ -n "${NOTARY_APPLE_ID:-}" ] && [ -n "${NOTARY_TEAM_ID:-}" ] && [ -n "${NOTARY_PASSWORD:-}" ]; then
  ditto -c -k --keepParent "$APP" dist/notarize.zip
  xcrun notarytool submit dist/notarize.zip --apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" \
    --password "$NOTARY_PASSWORD" --wait
  rm -f dist/notarize.zip
  xcrun stapler staple "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
else
  echo "NOTARY_APPLE_ID / NOTARY_TEAM_ID / NOTARY_PASSWORD not all set: not notarized" >&2
fi

ZIP="dist/Claude-Voice-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
(cd dist && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
echo "packaged: $ZIP"
