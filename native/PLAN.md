# Native SwiftUI rebuild

Goal: a 1:1 native replica of the *[demo] iPhone app (web build 9adeae1), written in SwiftUI with Liquid Glass.
Project: `~/Documents/Demo` (target `demo`, bundle `app.hellodemo.demo.native`); source in the repo under `native/Demo`.
Specs (from the web app): `native/spec/features-and-screens.md`, `data-and-backend.md`, `engines.md`.

## Done
- Sign in (Apple, Google), beta gate, waitlist
- Library sync (same merge rules as the web), local cache
- Song list: header, bottom search dock, pins, folders as scrolling labels, swipe actions, previews
- Editor: rich text, rhyme map, syllable gutter, chorus auto-fill, web-style top bar, sidebar drawer, header scrolls with the lyrics
- Rhyme bar: status, Aa formatting row, word modes on a track, chips, Dictionary sheet
- Your own icons throughout
- Phase A: Details sheet (Info, Audio list, Chords + chord chips, Credits + Release), versions, cover art, ••• menu, Writing voice

## To do
- Phase B: audio (playing, uploads, MP3 conversion, in-song player, Play with Lyrics, lyric sync, stems/files, idea memos)
- Phase C: AI (Muse, Lines mode, Rate, Clean up, Listen to the whole song, learned voice)
- Phase D: sharing and live co-writing
- Phase E: song list and Ideas extras (folders, import/export, idea tags, guide song, onboarding)
- Phase F: full Account, paywall and RevenueCat, push, remote config, Perform, sprint timer
