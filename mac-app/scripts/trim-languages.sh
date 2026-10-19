#!/bin/bash
# Keeps English only in a built Mac app. Chrome (inside Electron) ships 55 languages that *[demo] never uses: about 40 MB.
#   bash scripts/trim-languages.sh "dist/[demo]-darwin-arm64/[demo].app"
# Run it before signing; it changes files inside the app.
set -euo pipefail
APP="$1"; [ -d "$APP" ] || { echo "No app at $APP"; exit 1; }
before=$(du -sm "$APP" | cut -f1)
find "$APP" -type d -name "*.lproj" ! -name "en.lproj" ! -name "en_GB.lproj" ! -name "Base.lproj" -prune -exec rm -rf {} +
echo "Languages trimmed: ${before} MB -> $(du -sm "$APP" | cut -f1) MB"
