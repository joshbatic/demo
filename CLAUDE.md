# Notes for Claude

- After every app change, finish by telling Josh the build number: the `APP_COMMIT` value that `scripts/stamp-version.sh` writes (shown in the app at Account › Version), and whether it's on dev (beta and [developer] apps only) or released.

## Branches and releases (since launch, 2 Nov 2026)
People use the app now, so new work never goes straight to them.
- `dev`: where all app work goes (www/, native/, mac-app/, supabase/). Every push to dev updates the private beta at hellodemo.app/beta/ (`.github/workflows/beta.yml`, noindex). Deploy dev builds to the **[developer]** Mac and iPhone apps and Josh's Xcode project for testing, never to the public *[demo].app.
- `main`: what everyone has. Pushing it redeploys hellodemo.app (website, and the web app at hellodemo.app/app from `docs/app/index.html`) and listen.hellodemo.app (Vercel); the Mac download rebuilds from it. App changes reach main only through a release.
- **Releasing:** write `RELEASE-NOTES-vX.Y.Z.md`, then `scripts/release.sh X.Y.Z` on dev. It sets the version everywhere, merges dev into main, copies the app to docs/app, mac-app and web-artifact, stamps and pushes; GitHub then tags it `vX.Y.Z` (`tag-release.yml`) and rebuilds the Mac download (the version change in mac-app/package.json starts it). Then dev is brought level with main. Then copy the release to Josh's public *[demo].app, and he archives the iPhone app in Xcode for the App Store.
- **Versions:** one number for every platform, the same as the App Store's (`APP_VERSION` in www/index.html, `version` in the package.json files, `MARKETING_VERSION` in the Xcode project). Features bump the middle number (1.1.0 → 1.2.0), fixes the last (1.1.0 → 1.1.1). The build number (APP_SEQ, stamped by `scripts/stamp-version.sh`) keeps counting across everything.
- **Urgent fixes:** commit the fix on dev, release it as the next fix version (X.Y.Z+1). Only for something that can't wait: fix on main, release by hand, then merge main into dev.
- **Website-only changes** (docs/ except docs/app and docs/beta) go straight to main.
- 1.0.0 is the App Store launch build (in review). 1.1.0 (albums, album links, widgets) went to web and Mac on 2 Nov 2026; the iPhone gets 1.1.0 as its first update after approval.
- `next` (from 4.0.0, pre-launch numbering) is retired; `stable-1` … `stable-5` are frozen snapshots of past milestones; never commit to them.
- Release notes live in `RELEASE-NOTES-vX.Y.Z.md`.

## Mac dev build
- `~/Applications/[developer].app` is a copy of the Mac app with a `dev-build` file in `Contents/Resources/app/` (opens on the admin dashboard with a tab bar: Dashboard, Songs, Users, Help, More; same look as the public app plus a DEV tag; its own data and `demo-dev://` sign-in). Dev builds go into [developer].app only; a release goes into both apps. `mac-app/scripts/make-dev-app.sh` recreates it.
- Josh's Xcode work lives in `~/Documents/Documents - Josh’s MacBook Pro - 1/` (keep it there): `demo/` is the native iPhone app's Xcode project, `demo App Store/` the listing assets.
- `~/Documents/Documents - Josh’s MacBook Pro - 1/songpad-ios-dev` is the [developer] iPhone app (app ID `app.hellodemo.demo.dev`, `demo-dev://` sign-in, black inverted icon). The app turns on its dev features when its ID ends in `.dev`. Copy `www/index.html` into its `www/` and `ios/App/App/public/` too.
