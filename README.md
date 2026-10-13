# *[demo]

Songwriter/lyric app, kept as three in-sync pieces:

- **`mac-app/`** — source for the macOS Electron app (`main.js`, `preload.js`,
  `app/index.html` is the actual app UI/logic, `build/icon.png` is the app
  icon source).
- **`web-artifact/`** — the same app (`songpad.html`) published as a Claude
  web artifact, plus its PWA manifest and home-screen icons.
- **`ios/`, `www/`, `capacitor.config.json`, `package.json`** at the repo
  root — the Capacitor wrapper used to build and run a real native iOS app
  on a connected iPhone via Xcode (no App Store / TestFlight needed for
  personal testing).

`mac-app/app/index.html` and `web-artifact/songpad.html` are meant to stay
byte-for-byte identical except for the small PWA `<head>` block in the web
artifact version. `www/index.html` (used by the iOS build) is a copy of the
same file bundled for Capacitor.

## Updating

Whenever a new build is produced, the same `index.html` gets copied into
all three of `mac-app/app/`, `web-artifact/`, and `www/`, then:
- the web artifact is republished,
- the Mac `.app` bundle's `Contents/Resources/app/app/index.html` is
  overwritten,
- and `npx cap sync ios` is run so the iOS build picks up the change.

## iOS's AI key is NOT in this repo

iOS has no AI bridge of its own (the Mac app uses the user's own OpenAI key
via `window.desktop`; the web artifact uses the `claude.ai` host's `window.
claude.use('sample')`; neither exists in a Capacitor/native WebView). So the
app's `BAKED_OPENAI_KEY` constant — otherwise always `''` — gets a real
OpenAI key patched in, but **only** in the actual local Xcode project the
user builds from, `~/Documents/songpad-ios` on their Mac (not this cloned
repo, which is not that project — it has no `.git` of its own and isn't
pushed anywhere). The key is applied directly to that project's `www/
index.html` and `ios/App/App/public/index.html` after every sync, as a
find/replace on top of the otherwise-identical master content:

```
BAKED_OPENAI_KEY=''  →  BAKED_OPENAI_KEY='sk-...'
```

This repo's own `www/index.html` (and every other copy here) must keep
`BAKED_OPENAI_KEY=''` — this repo is pushed to GitHub, and the web artifact
copy especially is loaded by anyone with its public link, so a real key must
never land in any file here. If asked to sync a new build to iOS, patch the
key into `~/Documents/songpad-ios` only, never into this repo.
