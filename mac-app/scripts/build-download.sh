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
bash scripts/trim-languages.sh "$APP"           # English only: about 40 MB smaller

if [ -n "${DEVELOPER_ID:-}" ]; then
  echo "Signing with ${DEVELOPER_ID}…"
  # Apple's notary wants every piece of code signed on its own, inside out, with the hardened runtime and a
  # timestamp (codesign --deep skips some of Electron's helpers and libraries).
  sign() { codesign --force --options runtime --timestamp --entitlements build/entitlements.mac.plist --sign "$DEVELOPER_ID" "$1"; }
  # 1. loose executables and libraries anywhere inside (crashpad handler, ShipIt, dylibs, native modules).
  #    A bundle's own main executable (Electron Framework's binary, a helper app's MacOS/…) is left for step 2:
  #    signing it signs the whole bundle, which only works once everything inside is signed.
  while IFS= read -r -d '' f; do
    case "$f" in
      *.app/Contents/MacOS/*) continue ;;
    esac
    dir=$(dirname "$f"); base=$(basename "$f")
    case "$dir" in
      *"/$base.framework/Versions/"*) [ "$(basename "$dir")" != "Helpers" ] && [ "$(basename "$dir")" != "Resources" ] && [ "$(basename "$dir")" != "Libraries" ] && continue ;;
    esac
    if file -b "$f" | grep -q "Mach-O"; then sign "$f"; fi
  done < <(find "$APP/Contents/Frameworks" "$APP/Contents/Resources" -depth -type f \( -perm -u+x -o -name "*.dylib" -o -name "*.node" -o -name "*.so" \) -print0)
  # 2. bundles, deepest first: frameworks and the helper apps
  while IFS= read -r -d '' b; do sign "$b"; done < <(find "$APP/Contents/Frameworks" -depth \( -name "*.framework" -o -name "*.app" \) -print0)
  # 3. the app itself
  sign "$APP"
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
  OUT=$(xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)
  echo "$OUT"
  SUB=$(echo "$OUT" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{const j=JSON.parse(d);console.log(j.id+" "+j.status)})')
  if [ "${SUB#* }" != "Accepted" ]; then
    echo "Apple didn't accept it. Its report:"
    xcrun notarytool log "${SUB%% *}" --keychain-profile "$NOTARY_PROFILE" || true
    exit 1
  fi
  xcrun stapler staple "$DMG"
  echo "Notarised: it will open with no warnings."
fi
echo
echo "Done: mac-app/$DMG ($(du -h "$DMG" | cut -f1))"
open -R "$DMG" 2>/dev/null || true
