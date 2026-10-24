#!/usr/bin/env bash
# Writes the current git commit into APP_COMMIT in every copy of the app, then commits that
# one-line change on its own. Run it after committing app changes and before syncing builds:
#
#   scripts/stamp-version.sh
#
# The version shown in Account is the commit *before* the stamp commit (a file can't contain the
# hash of the commit it lives in), which holds exactly the same code apart from the stamp itself.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "Commit or stash your changes first — the stamp has to describe committed code." >&2
  exit 1
fi

hash=$(git rev-parse --short HEAD)
# APP_SEQ counts commits, so newer builds always have bigger numbers (Admin › Settings › Minimum Build uses it)
seq=$(git rev-list --count HEAD)
files=(www/index.html web-artifact/songpad.html mac-app/app/index.html)

for f in "${files[@]}"; do
  [ -f "$f" ] || continue
  n=$(grep -c "^var APP_COMMIT='[^']*';$" "$f" || true)
  if [ "$n" != "1" ]; then echo "$f: expected exactly one APP_COMMIT line, found $n" >&2; exit 1; fi
  sed -i.bak "s/^var APP_COMMIT='[^']*';\$/var APP_COMMIT='$hash';/" "$f" && rm -f "$f.bak"
  if grep -q "^var APP_SEQ=[0-9]*;$" "$f"; then sed -i.bak "s/^var APP_SEQ=[0-9]*;\$/var APP_SEQ=$seq;/" "$f" && rm -f "$f.bak"; fi
done

# the native iPhone app (SwiftUI) shares the same build number, so one Minimum Build covers every app
native=native/Demo/App/Config.swift
if [ -f "$native" ] && grep -q "^    static let appSeq = [0-9]*$" "$native"; then
  sed -i.bak "s/^    static let appSeq = [0-9]*\$/    static let appSeq = $seq/" "$native" && rm -f "$native.bak"
  files+=("$native")
fi

# the share-link viewer carries a copy of the page renderer; rebuild it so it never drifts from the app
if command -v python3 >/dev/null; then python3 scripts/build-share-viewer.py >/dev/null && files+=(docs/s/index.html share/api/_viewer.js); fi

git add "${files[@]}"
git commit -q -m "Stamp version $hash"
echo "Stamped $hash (build $seq)"
