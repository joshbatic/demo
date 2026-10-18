#!/bin/bash
# Makes "[demo] Dev.app" next to "[demo].app": the same app, running as the dev build
# (its own data and sign-in, Beta Requests on the home screen, developer tools, inverted icon).
# Run on the Mac after building or updating the regular app:   bash mac-app/scripts/make-dev-app.sh
set -euo pipefail
APPS="${APPS:-$HOME/Applications}"
SRC="$APPS/[demo].app"; DEV="$APPS/[demo] Dev.app"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
[ -d "$SRC" ] || { echo "Can't find $SRC"; exit 1; }
rm -rf "$DEV"
cp -a "$SRC" "$DEV"
PB=/usr/libexec/PlistBuddy; PL="$DEV/Contents/Info.plist"
$PB -c "Set :CFBundleIdentifier com.demo.songwriting.dev" "$PL"
$PB -c "Set :CFBundleName [demo] Dev" "$PL"
$PB -c "Set :CFBundleDisplayName [demo] Dev" "$PL" 2>/dev/null || $PB -c "Add :CFBundleDisplayName string [demo] Dev" "$PL"
$PB -c "Delete :CFBundleURLTypes" "$PL" 2>/dev/null || true
$PB -c "Add :CFBundleURLTypes array" -c "Add :CFBundleURLTypes:0 dict" \
    -c "Add :CFBundleURLTypes:0:CFBundleURLName string com.demo.songwriting.dev.auth" \
    -c "Add :CFBundleURLTypes:0:CFBundleTypeRole string Editor" \
    -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes array" -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string demo-dev" "$PL"
cp "$HERE/build/icon-dev.icns" "$DEV/Contents/Resources/electron.icns"
echo "This copy runs as [demo] Dev (see main.js)." > "$DEV/Contents/Resources/app/dev-build"
# fresh seals for both, so macOS keeps their microphone permission
codesign --force --deep --sign - "$SRC"
codesign --force --deep --sign - "$DEV"
touch "$DEV"   # refresh the Dock/Finder icon
echo "Done: $DEV"
