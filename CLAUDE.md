# Notes for Claude

- After every app change, finish by telling Josh the build number: the `APP_COMMIT` value that `scripts/stamp-version.sh` writes (shown in the app at Account › Version).

## Branches and releases
- `main`: the released 4.x line. Pushing it redeploys hellodemo.app (GitHub Pages) and listen.hellodemo.app (Vercel), so it gets fixes for the current release.
- `next`: work toward the next major release (started from 4.0.0). New features go here unless Josh says they're for the current release; bring fixes across from `main` with a merge.
- `stable-1` … `stable-4`: frozen snapshots of past milestones; never commit to them.
- Releases are tagged `vX.Y.Z` on `main`, with notes in `RELEASE-NOTES-vX.Y.Z.md`.
