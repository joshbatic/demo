# Notes for Claude

- After every app change, finish by telling Josh the build number: the `APP_COMMIT` value that `scripts/stamp-version.sh` writes (shown in the app at Account › Version).

## Branches and releases
- `main`: the released 4.x line. Pushing it redeploys hellodemo.app (GitHub Pages) and listen.hellodemo.app (Vercel), so it gets fixes for the current release.
- `next`: work toward the next major release (started from 4.0.0). On hold: Josh isn't using it for a while, so don't merge `main` into it or report its build number until he says otherwise. Work goes on `main`.
- `stable-1` … `stable-5`: frozen snapshots of past milestones; never commit to them. `stable-5` is a snapshot of build e996c85 (19 Oct 2026).
- Releases are tagged `vX.Y.Z` on `main`, with notes in `RELEASE-NOTES-vX.Y.Z.md`.

## Mac dev build
- `~/Applications/[developer].app` is a copy of the Mac app with a `dev-build` file in `Contents/Resources/app/` (opens on the admin dashboard with a tab bar: Dashboard, Songs, Users, Help, More; same look as the public app plus a DEV tag; its own data and `demo-dev://` sign-in). When updating the Mac app's `index.html`, `main.js` or `preload.js`, copy them into both apps. `mac-app/scripts/make-dev-app.sh` recreates it.
- Josh's Xcode work lives in `~/Documents/Documents - Josh’s MacBook Pro - 1/` (keep it there): `demo/` is the native iPhone app's Xcode project, `demo App Store/` the listing assets.
- `~/Documents/Documents - Josh’s MacBook Pro - 1/songpad-ios-dev` is the [developer] iPhone app (app ID `app.hellodemo.demo.dev`, `demo-dev://` sign-in, black inverted icon). The app turns on its dev features when its ID ends in `.dev`. Copy `www/index.html` into its `www/` and `ios/App/App/public/` too.
