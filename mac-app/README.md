# [demo] for macOS

A lyric notepad for songwriters, wrapped as a Mac app with Electron.

## What's in here
- `app/index.html`: the whole app (the same file that runs on claude.ai)
- `main.js`: the Mac window, menus, microphone permission, and mirroring songs to files
- `preload.js`: the small bridge between the page and the Mac
- `build/`: app icon and Info.plist additions

## Your songs
Songs are saved inside the app, and mirrored automatically to **Documents › [demo] Songs**:
one plain-text file per song (inside a folder per song folder), plus `[demo] backup.json`
with everything, including chords, notes, melodies, versions and ratings.

## Run from source (needs Node.js 20+)
    npm install
    npm start

## Rebuild the app
    npm run package
    codesign --force --deep --sign - "dist/[demo]-darwin-arm64/[demo].app"

## Build a download for your website
    bash scripts/build-download.sh
Makes `dist/demo-<version>-mac.dmg` (one app for Apple Silicon and Intel Macs). Without an Apple Developer ID
people approve it once in System Settings › Privacy & Security › Open Anyway; with one, the script signs and
notarises it so it opens cleanly. The steps are at the top of the script.

## Not in this version
Claude features (Lines, Rate, ranking, Unstick me's Read/Four doors/Flip it) and
collaboration need claude.ai or your own server, so they're hidden here.
Rhyme dictionary, Datamuse word lists, melody, syllables, rhyme map, versions and Perform all work.
