#!/bin/bash
# Builds ScreenRecorder.app into ./build.
#   ./build.sh          build the app
#   ./build.sh --run    build, then (re)launch it
# Signing: a stable identity keeps macOS permissions (Screen Recording, Mic) across rebuilds.
# Uses $CODESIGN_IDENTITY if set, else a keychain certificate named "ScreenRecorder Dev"
# if one exists, else ad-hoc ("-"), which loses permissions on every rebuild.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="ScreenRecorder"
APP="build/$APP_NAME.app"
DEV_CERT="ScreenRecorder Dev"

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    IDENTITY="$CODESIGN_IDENTITY"
elif security find-identity -p codesigning | grep -q "\"$DEV_CERT\""; then
    IDENTITY="$DEV_CERT"
else
    IDENTITY="-"
    echo "warning: ad-hoc signing; macOS will ask for permissions again after this build." >&2
    echo "         Create a \"$DEV_CERT\" code-signing certificate to fix that (see README)." >&2
fi

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign "$IDENTITY" --identifier com.aelhomsany.ScreenRecorder "$APP"
echo "Built $APP (signed with: $IDENTITY)"

if [[ "${1:-}" == "--run" ]]; then
    pkill -x "$APP_NAME" 2>/dev/null || true
    open "$APP"
fi
