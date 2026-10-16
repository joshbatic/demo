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

## Version shown in Account

The bottom of the Account sheet shows `Version <commit>`, read from the `APP_COMMIT` constant in
the page. After committing app changes, run `scripts/stamp-version.sh` before syncing builds out:
it writes the current short commit hash into every copy and commits that one-line change as
`Stamp version <hash>`. The hash it shows is the commit just before the stamp — identical code
apart from the stamp line itself. Unstamped builds show `Version dev`.

## Audio, lyric sync & song files (Pro) — one-time Supabase setup

Audio versions, stems and attachments are stored in a private Supabase Storage bucket, and
automatic lyric sync runs through an Edge Function. Both need setting up once on the Supabase
project (`cygfgurzvmbtcegkpnss`):

1. **Storage bucket + access rules.** Dashboard → SQL Editor → New query → paste
   [`supabase/song-files.sql`](supabase/song-files.sql) → Run. This creates the private
   `song-files` bucket where each account can only reach its own folder.
2. **Upload size.** Dashboard → Storage → Settings → *Upload file size limit*. The free plan caps
   uploads at 50 MB per file. WAV, AIFF and FLAC uploads are converted to 256 kbps MP3 on the device
   first (about 80% smaller, so a typical song is a few MB), unless "Convert WAV to MP3" is turned off
   in a song's Audio tab to keep lossless masters, which can then need a higher limit (Pro plan).
   The MP3 encoder is lamejs 1.2.1 (LGPL-3.0), embedded unmodified in the page.
3. **Lyric sync function.** With the Supabase CLI, from this repo:
   `supabase functions deploy lyric-sync --project-ref cygfgurzvmbtcegkpnss`.
   It uses an `OPENAI_API_KEY` secret; if ai-proxy already has one it's shared, otherwise
   `supabase secrets set OPENAI_API_KEY=sk-... --project-ref cygfgurzvmbtcegkpnss`.

Until step 1 is done, uploads fail with a clear message; until step 3, "Sync Lyrics" does.
In Dev Mode (no account) audio is kept on the device instead, and lyric sync is unavailable.
Files are visible to their uploader only; collaborators on a shared song see the list but can't
play another person's files yet.


## Share links (listen.hellodemo.app/…)

Share → **Create Link** saves a copy of the song (lyrics, sync timings, colours, waveform, artwork and audio)
that anyone can open in a browser with no account. **Update** refreshes it at the same address; **Stop Sharing**
deletes it and its files.

One-time setup: Supabase → SQL Editor → paste the contents of `supabase/shares.sql` → Run. That adds the
`shares` table, the `get_share` function (the only public way in: one share by its exact id, so nobody can
list them) and the public `shares` storage bucket (owner-only writes, no public listing).

The viewer is `docs/s/index.html`, served by GitHub Pages with the rest of `docs/`. It's generated by
`scripts/build-share-viewer.py` from the renderer block marked `SHARE-RENDER` in `www/index.html` plus
`scripts/share-viewer.template.html`, so links look exactly like shared page files. `scripts/stamp-version.sh`
rebuilds it; run the script yourself if you change the renderer without stamping. It only ever loads the
public anon key, and it treats every share's data as untrusted: text is escaped, colours must be plain
`hsl()` values and artwork/audio must come from the project's `shares` bucket.

### Link previews (listen.hellodemo.app on Vercel)

New links are `listen.hellodemo.app/<id>`. That subdomain is the Vercel project in `share/`: a small function
that fills in each song's preview tags (title, opening lines and a 1200×630 picture the app uploads when you
create or update the link) so Messages, WhatsApp and Messenger show a proper preview, then returns the same
viewer with the song inside. Links made before this still open at `hellodemo.app/s/?<id>`, just without the preview.

One-time setup:
1. vercel.com → Add New → Project → import `joshbatic/demo` → set **Root Directory** to `share` → Deploy.
2. In the project: Settings → Domains → add `listen.hellodemo.app`. Vercel shows a CNAME value.
3. Namecheap → Domain List → hellodemo.app → Manage → Advanced DNS → Add New Record:
   type **CNAME**, host **listen**, value = the one Vercel showed, TTL Automatic.
Pushing to `main` redeploys it.
