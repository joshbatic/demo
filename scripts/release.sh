#!/usr/bin/env bash
# Releases what's on `dev` to everyone: hellodemo.app/app (web), the Mac download, and the version the iPhone
# app is archived from. Run it on `dev` with a clean tree:
#
#   scripts/release.sh 1.2.0
#
# It sets the version everywhere (web, Mac, iPhone), merges dev into main, copies the app to the website and
# the Mac app, stamps the build and pushes; GitHub then tags it vX.Y.Z (.github/workflows/tag-release.yml) and
# rebuilds the Mac download. Finally dev is brought level with main. Write what's new in RELEASE-NOTES-vX.Y.Z.md first (a draft is made from the commits if it's missing).
#
# Versions are one number for every platform, the same as the App Store's: 1.1.0 for features, 1.1.1 for fixes.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

V="${1:-}"
[[ "$V" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Usage: scripts/release.sh X.Y.Z" >&2; exit 1; }
[ "$(git branch --show-current)" = dev ] || { echo "Run this on the dev branch." >&2; exit 1; }
git diff --quiet && git diff --cached --quiet || { echo "Commit or stash your changes first." >&2; exit 1; }
git fetch -q --tags origin 2>/dev/null || true
git rev-parse -q --verify "refs/tags/v$V" >/dev/null && { echo "v$V is already released." >&2; exit 1; }
git fetch -q origin
git merge -q --ff-only origin/dev 2>/dev/null || true

# 1. the version, everywhere
sed -i.bak "s/^var APP_VERSION='[^']*';\$/var APP_VERSION='$V';/" www/index.html && rm -f www/index.html.bak
for p in mac-app/package.json package.json; do
  sed -i.bak "0,/\"version\": \"[^\"]*\"/s//\"version\": \"$V\"/" "$p" && rm -f "$p.bak"
done
sed -i.bak "s/MARKETING_VERSION = [0-9.]*;/MARKETING_VERSION = $V;/" native/xcode/project.pbxproj && rm -f native/xcode/project.pbxproj.bak

# 2. release notes (a draft from the commits since the last release, if you haven't written them)
NOTES="RELEASE-NOTES-v$V.md"
if [ ! -f "$NOTES" ]; then
  LAST=$(git describe --tags --abbrev=0 --match 'v1.*' 2>/dev/null || true)
  { echo "# *[demo] $V"; echo; echo "## What's new"; echo
    git log --no-merges --format='- %s' ${LAST:+$LAST..}HEAD | grep -v '^- Stamp version' | head -40; } > "$NOTES"
  echo "Drafted $NOTES from the commits. Edit it, then run this again."; git checkout -q -- . ; exit 1
fi
git add -A && git commit -q -m "Version $V"

# 3. onto main, and out to the website and the Mac app
git checkout -q main && git merge -q origin/main --ff-only 2>/dev/null || true
# -X theirs: the copies on main (docs/app, mac-app/app, web-artifact) get build-number edits from beta.yml; dev's win, and are overwritten just below anyway
git merge -q --no-ff -X theirs dev -m "Release $V"
cp www/index.html docs/app/index.html
cp www/index.html mac-app/app/index.html
cp www/index.html web-artifact/songpad.html
# the Mac download's name carries the version (demo-mac-X.Y.Z.dmg, .github/workflows/mac-download.yml)
sed -i.bak -E "s/demo-mac-[0-9]+\.[0-9]+\.[0-9]+\.dmg/demo-mac-$V.dmg/g" docs/mac.html && rm -f docs/mac.html.bak
git add -A && git commit -q -m "Release $V: web app and Mac app" || true
scripts/stamp-version.sh
git push -q origin main
# the "Tag release" workflow tags it vX.Y.Z, and the new version in mac-app/package.json starts the Mac download build

# 5. dev carries on from the release
git checkout -q dev && git merge -q --ff-only main && git push -q origin dev
echo "Released $V ($(git rev-parse --short main)). Archive the iPhone app from this version in Xcode for the App Store."
