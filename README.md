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
