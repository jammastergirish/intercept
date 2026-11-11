#!/usr/bin/env bash
#
# Package build/Intercept.app into a distributable .dmg and print its SHA-256.
# Run ./build_app.sh first (or ./release.sh, which calls this).
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/Intercept.app"

if [ ! -d "$APP" ]; then
    echo "error: $APP not found — run ./build_app.sh release first." >&2
    exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="$ROOT/build/Intercept-$VERSION.dmg"
STAGING="$(mktemp -d)"

cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"   # drag-to-install target

rm -f "$DMG"
hdiutil create -volname "Intercept" \
    -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

# Version-less copy so a permanent …/releases/latest/download/Intercept.dmg
# link always resolves. Upload BOTH assets to each GitHub Release.
cp "$DMG" "$ROOT/build/Intercept.dmg"

echo "Created $DMG"
echo "        $ROOT/build/Intercept.dmg (version-less copy for the 'latest' link)"
echo -n "SHA-256: "
shasum -a 256 "$DMG" | awk '{print $1}'
