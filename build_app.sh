#!/usr/bin/env bash
#
# Build Intercept and wrap it into a proper .app bundle so macOS will grant it
# Microphone + Screen & System Audio Recording permissions.
#
# Usage:
#   ./build_app.sh [debug|release]     # build the bundle
#   ./build_app.sh release run         # build then launch
#   ./build_app.sh release install     # build, copy to /Applications, launch
#
set -euo pipefail

APP_NAME="Intercept"
BUNDLE_ID="com.intercept.recorder"
ROOT="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${1:-release}"
DO_RUN="${2:-}"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
APP="$ROOT/build/$APP_NAME.app"
CONTENTS="$APP/Contents"

# App icon: render the iconset once, then turn it into AppIcon.icns.
if [ ! -f "$ROOT/Resources/AppIcon.icns" ]; then
    echo "==> rendering app icon"
    ICONSET="$ROOT/build/AppIcon.iconset"
    rm -rf "$ICONSET"
    swift "$ROOT/gen_icon.swift" "$ICONSET"
    iconutil -c icns "$ICONSET" -o "$ROOT/Resources/AppIcon.icns"
fi

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN_DIR/$APP_NAME" "$CONTENTS/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"

# Reuse One Tap Transcribe's stable self-signed identity if it exists, so
# rebuilds keep their code identity and macOS keeps the Screen Recording grant.
# Fall back to ad-hoc signing otherwise.
SIGN_ID="One Tap Local Signing"
SIGN_KC="$HOME/Library/Keychains/onetap-signing.keychain-db"
if [ -f "$SIGN_KC" ] && security find-identity -p codesigning "$SIGN_KC" 2>/dev/null | grep -q "$SIGN_ID"; then
    echo "==> code signing (stable identity: $SIGN_ID)"
    security unlock-keychain -p onetap-local "$SIGN_KC" 2>/dev/null || true
    codesign --force --deep --sign "$SIGN_ID" --keychain "$SIGN_KC" \
        --identifier "$BUNDLE_ID" \
        --entitlements "$ROOT/Resources/$APP_NAME.entitlements" \
        "$APP"
else
    echo "==> code signing (ad-hoc — permissions may need re-granting after rebuilds)"
    codesign --force --deep --sign - \
        --identifier "$BUNDLE_ID" \
        --entitlements "$ROOT/Resources/$APP_NAME.entitlements" \
        "$APP"
fi

echo "==> done: $APP"

if [[ "$DO_RUN" == "install" ]]; then
    echo "==> installing to /Applications"
    pkill -x "$APP_NAME" 2>/dev/null || true
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" "/Applications/$APP_NAME.app"
    open "/Applications/$APP_NAME.app"
elif [[ "$DO_RUN" == "run" ]]; then
    echo "==> launching"
    open "$APP"
fi
