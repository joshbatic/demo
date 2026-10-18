#!/bin/bash
# Builds *[demo] for Mac as a download: dist/demo-<version>-mac.dmg
# Works on Apple Silicon and Intel Macs (one "universal" app).
#
#   bash scripts/build-download.sh
#
# Without an Apple Developer ID it's signed "ad hoc": it runs, but people have to approve it once in
# System Settings › Privacy & Security › Open Anyway (fine for beta testers).
# Once your Apple Developer account is active, sign and notarise it so it opens with no warning:
#   1. Xcode › Settings › Accounts › Manage Certificates › + › "Developer ID Application"
#   2. xcrun notarytool store-credentials demo-notary --apple-id YOU@EXAMPLE.COM --team-id TEAMID
#      (it asks for an app-specific password from account.apple.com)
#   3. DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=demo-notary bash scripts/build-download.sh
set -euo pipefail
cd "$(dirname "$0")/.."
VER=$(node -p "require('./package.json').version")
echo "Building *[demo] $VER for Mac…"
npm install --no-audit --no-fund
npx electron-packager . "[demo]" --platform=darwin --arch=universal \
  --icon=build/icon.icns --app-bundle-id=com.demo.songwriting --app-category-type=public.app-category.music \
  --extend-info=build/extend.plist --app-version="$VER" --build-version="$VER" \
  --out=dist --overwrite --ignore='^/dist' --ignore='^/build' --ignore='^/scripts' --ignore='^/README'
APP="dist/[demo]-darwin-universal/[demo].app"
rm -f "$APP/Contents/Resources/app/dev-build"   # never ship the developer version

if [ -n "${DEVELOPER_ID:-}" ]; then
  echo "Signing with $DEVELOPER_ID…"
  codesign --deep --force --options runtime --timestamp --entitlements build/entitlements.mac.plist --sign "$DEVELOPER_ID" "$APP"
else
  echo "No DEVELOPER_ID: signing ad hoc (people will need Open Anyway the first time)."
  codesign --deep --force --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"

DMG="dist/demo-$VER-mac.dmg"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "[demo]" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

if [ -n "${DEVELOPER_ID:-}" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
  codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"
  echo "Sending to Apple for notarisation (usually a few minutes)…"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  echo "Notarised: it will open with no warnings."
fi
echo
echo "Done: mac-app/$DMG ($(du -h "$DMG" | cut -f1))"
open -R "$DMG" 2>/dev/null || true
