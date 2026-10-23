# *[demo] — Features & Screens spec (for the native SwiftUI rewrite)

Source of truth: `www/index.html` at build `APP_COMMIT='9adeae1'`, `APP_SEQ=413` (line 15085).
Line numbers below refer to that file. Language engines (rhyme engine, AI prompts, Clean up, lyric sync
alignment, live-patch merge) are specified in `engines.md`; the data/backend layer (Supabase tables, RPCs,
storage buckets, library sync merge) is covered by `data-and-backend.md` — here it is only referenced where it
changes what the user sees.

Product name is written `*[demo]` throughout the UI copy (literally, including the asterisk and brackets);
keep it as a single localisable constant.

---

## 0. File map (where things are in index.html)

| Lines | What |
|---|---|
| 1–20 | `<head>`: early script (dev-build class, `splashing` class on iOS, focus guard during splash / auth gate) |
| 21–1208 | CSS (theme tokens at 22–25, see §10) |
| 1211 | `#splash` (three base64 PNGs: light, dark, `spl-v`) — ~572 KB |
| 1212–1306 | App markup: `#vDash`, `#vList`, `#vIdeas`, `#vEdit`, `#side`, all sheets, hidden file inputs |
| 1307–1614 | `lamejs` MP3 encoder as inert `text/plain` (only run inside a Web Worker) |
| 1615–1640 | `#lplay`, `#perf`, `#betagate`, `#authgate`, `#toast`, `#invbanner`, `#probanner` |
| 1641 | supabase-js 2.45.4 from CDN |
| 1643–15083 | `var DATA=\`...\`` — the rhyme dictionary (see engines.md §1) |
| 15084–20640 | All app code |

Rough code map (start lines): guide song 15090 · Ideas 15167 · voice memos 15191 · save/autosave 15343 · toast/haptics 15402 · navigation 15424 · keyboard handling 15447 · rhyme engine 15591 · writing voice 15623 · song list 15865 · editor 15890 · lyric editor/rich text 15937 · formatting 16008 · sidebar & gestures 16058–16304 · dev build 16309 · Datamuse 16375 · AI routing 16398 · AI consent 16474 · rhyme bar `ctx()`/`rhyme()` 16526–16639 · Lines mode 16641 · muse memory 16713 · song brief 16859 · word modes 16929 · Dictionary 16962 · rhyme map/syllables 17047 · Muse sheet 17085 · melody (dormant) 17133 · default covers 17220 · collaboration/live 17245–17580 · Rate 17581 · import/export 17693 · native glass bridge 17737 · swipe rows/pins/folders 17924–18058 · Clean up 18058 · beta 18093 · admin/dev dashboard 18205–18720 · remote config 18413 · support 18466 · notifications 18721 · auth 18768/18945/19216 · library sync 19069 · splash 19291 · plans/IAP/paywall 19312–19450 · Account 19450–19761 · versions 19762 · song files/audio 19767 · lyric sync 20040 · in-song player 20146 · Play with Lyrics 20244 · .lrc 20276 · Share 20283–20580 · Credits/Release 20582 · Perform 20622 · boot 20638.

---

## 1. App structure & navigation

### 1.1 Launch sequence (what the user sees)

1. **Splash (iOS only)** — `html.splashing` set in `<head>` when Capacitor native iOS. `#splash` shows the record-label
   image from the app icon in the same place as the LaunchScreen (light `spl-l` / dark `spl-d` variant), so the hand-over
   is invisible. On `load` (+120 ms, max 3 s) (line 19296): label spins `rotate 0→300° scale .96` (70%) → `360° scale 1`
   over 850 ms `cubic-bezier(.5,0,.25,1)`, light haptic, then label scales to 1.18 and fades (260 ms ease-in) while the
   splash fades (320 ms, 60 ms delay). Reduce Motion: fade only. While splashing, any focus request is deferred
   (`window.__splFocus`) and re-applied after (unless auth gate/sidebar is showing).
   *Native:* reproduce as a SwiftUI overlay matching LaunchScreen; keyboard must not appear until it's gone.
2. **Auth gate** `#authgate` — shown unless a stored Supabase session exists (checked synchronously, line 19290, so
   there is no flash). There is no signed-out mode any more ("Dev Mode has been removed", 18087).
3. **Beta gate** `#betagate` — after sign-in, `rpc beta_status` (§1.6).
4. **Main UI**: boot (line 20638): `vset(); applyPlan(); load(); renderList(); renderSide(); paintAcctIcons();` then
   **the most recently updated song is opened in the editor** (`openSong(songs[0].id)`), or a **new empty song is
   created and opened** if the library is empty. So the app lands in the editor, not the list. (Dev build lands on the
   dashboard instead, §8.)

### 1.2 Views (full screens)

Only one `.view` is `.on` at a time; `show(id)` switches (15434). Depth map `NAV_DEPTH={vList:0,vIdeas:1,vEdit:1}`:
going deeper slides in from the right (push), shallower slides back (pop), equal depth just fades; 460 ms. No slide on
Mac, with Reduce Motion, or with the docked sidebar at ≥980 px. Leaving Ideas while recording a voice memo
**stops and saves** the memo.

| View | Purpose | Native equivalent |
|---|---|---|
| `#vList` | Song list (home) | Root of NavigationStack |
| `#vIdeas` | Ideas list + jot box + voice memo recording | Pushed screen |
| `#vEdit` | Song editor | Pushed screen |
| `#vDash` | Dev/admin dashboard, only in the dev build | Separate TabView root in dev build |

**Back navigation**
- Editor top-left `#back` ("Songs") → `goBack()` (15905): if the song is completely empty (no title, lyrics, chords,
  notes, art, audio, files, credits, key, bpm, not shared, no folder) **it is deleted silently**; a folder placeholder
  song (`ph`) loses its `ph` flag once it has content. Then `toList()` stops the in-song player, closes sheets, shows list.
- Ideas `#ideaBack` → `show('vList')`.
- **Edge swipe back** (iOS, 16074): touch starting within 24 px of the left edge on `vEdit` or `vIdeas` drags the view
  right; the song list peeks underneath, starting at `translateX(-28%)` and `brightness(.94)` → 0 / 1 as the drag
  progresses. Commit if velocity > 0.3 px/ms, or (velocity > −0.2 and dx > 35% of width). Animation duration
  `clamp(rest / max(1.4,|v|), 140, 260)` ms, `cubic-bezier(.2,.8,.2,1)`, light haptic on commit. Vertical drags (>14 px
  and more vertical) cancel. *Native: this is the standard interactive pop gesture.*

### 1.3 Sidebar `#side` (iPad/Mac/wide layouts; drawer on iPhone)

- Header: `#logo` "*[demo]" (tap = `goBack()`, i.e. back to list), account button `#sacct` (avatar or glyph + red
  invite dot `#invdot2`), `#snew` New song (closes drawer on narrow), `#sfolder` New folder (`createFolder(true)`),
  `#shide` hide sidebar.
- `#svault` Ideas row: bulb tile, "Ideas", subtitle = latest idea text (or "A quick jot for lines and ideas"),
  count badge `#svaultct`. Tap → `openIdeas()`.
- `#sadm` Admin / `#sbeta` Beta Requests rows: dev build only (§8).
- `#sq` search: matches title + artist + lyrics (case-insensitive substring).
- `#slist` (`renderSide`, 16340): grouped like the list (Pinned first, then folders and "Unfiled", groups ordered by
  their most recently updated song). Group headers are buttons with a chevron and count; **tap toggles collapse**
  (`collapsed[folder]`, not persisted; search ignores collapse). Folder headers have a rename pencil (and double-click
  rename). Rows: cover thumb, title (or first lyric line, or "New Song"), subtitle "Shared · artist" (hidden if empty).
  Current song row highlighted. Rows support drag to folders (§3.6). Empty: "No results" / "No songs yet".
- Visibility (`syncSideVisibility`, 16067): never shown over `vList`, `vIdeas`, `vDash`. On wide screens (≥980 px) it is
  docked automatically whenever the editor is showing. Breadcrumb folder button `#cr-fold` opens it (all groups
  expanded). Editor `#sbt` shows it.
- Drawer gestures (iPhone, not on list): edge pan from <24 px or drag on the open drawer; rubber-band past either end
  (`rubber(over)=over*34*.55/(34+.55*|over|)`), scrim `#scrim2` opacity follows. Release: fling |v|>0.35 decides by
  direction, else open if position > −38% of width. Light haptic. Tapping scrim closes.
- *Native:* `NavigationSplitView` on iPad/Mac; on iPhone the sidebar is redundant with the list and could be dropped
  (it is only reachable from the editor via `#sbt` and the breadcrumb).

### 1.4 Editor chrome (top bar of `#vEdit`)

Left group `.lgrp`: `#back` (chevron "Songs"), `#sbt` (sidebar). Centre breadcrumb `#crumb`: `#cr-app` "*[d]" (= back),
`/`, `#cr-fold` (folder or "Unfiled"; opens sidebar), `/`, `#cr-song` (title or "Untitled").
Right group: `#vmap` Rhyme map toggle, `#vsyl` Syllable counts toggle, `#shareb` Share, `#rateb` Rate
(**hidden by default** via `display:none`; Rate is reached from Muse), then a separate `#det` Details (•••).
On iOS 26 these are native Liquid Glass buttons (§1.10) with SF Symbols: back `chevron.left`, sidebar `sidebar.left`,
map `highlighter`, syllables `number`, share `square.and.arrow.up`, rate `star`, details `ellipsis`.

**Details ••• menu (iOS 26 native, `ngSongMenu` 17793)** — three sections:
1. Details `info.circle` · Audio `waveform` · Chords `music.note.list` · Credits `person.2` (each opens the Details sheet
   on that tab)
2. Perform `music.mic` · Copy Lyrics `doc.on.doc`
3. (destructive) Remove Cover Art `photo` (only if art) · Delete Song `trash`

Elsewhere `#det` opens the Details sheet on Info (`dtab('inf'); renderVers(); renderCollab(); sheet(true)`).

### 1.5 Sheets

All sheets share one scrim `#scrim` and `sheet(on, id)` (15917): opening one blurs the editor/title/search, closes the
narrow-screen sidebar; closing closes **all** sheets and commits the Idea sheet (`ideaCommit`). Escape closes, in order:
Dictionary → any sheet → floating sidebar (Perform / Play with Lyrics close themselves).
Header: bold title + round glass **checkmark** "Done" button (iOS 26 restyle, 15913). Full-screen players (`#lp-x`,
`#pf-x`) use a round ✕.

**Drag to dismiss (16241)** — any sheet can be dragged down from its header, or from anywhere once its scroll content is
at the top. Not while a text field is focused (that swipe dismisses the keyboard instead); ignored on canvas, range
sliders, waveforms, `select`. 1:1 tracking, scrim opacity `1 − dy/(h·0.9)`. Commit if `dy > min(220, 0.33·h)` or
(`v > 0.6 px/ms` and `dy > 30`) → clicks the sheet's own Done (so closing by drag == tapping Done), light haptic.
Otherwise spring back 340 ms `cubic-bezier(.32,.72,0,1)`. *Native: `.sheet` with `presentationDetents([.large])` gives this.*

| Sheet | id | Title | Opened by |
|---|---|---|---|
| Details | `#sheet` | "Details" | `#det`, ••• menu |
| Writing voice | `#sheet2` | "Writing voice" | `#gear` (Pro) |
| Muse | `#sheet3` | "Muse" | `#stuckb`, "Muse" chip |
| Rate | `#sheet4` | "Rate" | Muse "Rate my song", `#rateb` (Pro) |
| Clean up | `#sheet5` | "Clean up" | Aa row "Clean up" |
| Account | `#sheet6` | "Account" / "*[demo] Pro" / "Credits" | account buttons, Pro banner |
| Idea | `#sheet7` | "Idea" / "New Idea" | tapping an idea, Ideas `+` |
| Share | `#sheet8` | "Share" | `#shareb` |
| Beta Requests | `#sheet10` | "Beta Requests" | dev/admin only |
| Admin | `#sheet11` | "Admin" | dev/admin only |
| Dictionary | `#dictSheet` | "Dictionary" | rhyme-bar handle `#rhyExpand` |

Each is specified in §2.

### 1.6 Auth gate & beta gate

**Auth gate `#authgate`** (1625): card with h1 "*[demo]", "Sign in to use *[demo]. Your songs sync to your account and
stay backed up.", buttons **Sign in with Google** `#ag-google` and **Sign in with Apple** `#ag-apple` (dark mode: Apple
button white, Google button `#2C2C2E`), error line `#ag-note`, legal line "By continuing, you agree to the Terms and
Privacy Policy." (links open `https://hellodemo.app/terms.html` / `privacy.html` in an in-app Safari sheet).
If no client after 4 s: "Couldn’t reach the sign-in service. Check your connection and try again."
While the gate is visible nothing behind it may take keyboard focus.
- Google: Supabase OAuth (PKCE), `prompt=select_account` when forced; native iOS opens the URL in the Browser plugin
  (popover) with redirect `demo://auth-callback` (dev build `demo-dev://`), caught via `appUrlOpen`. A callback link is
  only honoured if `songpad:oauthpend` was set within the last 15 minutes (anti-session-fixation).
- Apple (native, 19270): ASAuthorization with `clientId app.hellodemo.demo`, scopes email+name, SHA-256 hashed nonce;
  `signInWithIdToken({provider:'apple',token,nonce:raw})`; first-time given+family name saved to user metadata
  (`full_name`, `name`). User-cancel (code 1001) is silent; else toast "Sign in with Apple didn’t work. Please try again."
- Errors: "Sign-in failed. Please try again." or "Sign-in failed: <err>"; messages matching "spots are full" or
  "sign-ups are paused" are shown verbatim.
- **Staying signed in** (18945): an expired token is not a sign-out. The app keeps the stored user (`AUTH_STALE`), shows
  local songs, holds off sync/server checks, and retries refresh with backoff `min(30 s, 800 ms·2ⁿ)` (and immediately on
  `online`). Only an explicit `SIGNED_OUT` or a 4xx refusal shows the gate. After the user signs out,
  `songpad:signedout=1` prevents any late session from silently signing them back in.

**Beta gate `#betagate`** (`betaGate(st)`, 18159): shown when `beta_status` ∉ {open, admin, approved}.
Approved status is cached per user (`songpad:beta:<uid>` = "ok") so it doesn't flash next launch; if the check can't run
the app opens normally. Card: music-note art, title + body by status:
- `checking`: "*[demo]" / "Checking your access…"
- `none`: "*[demo] is in private beta" / "We’re letting songwriters in a few at a time. Ask for a spot and we’ll email
  you when there’s room." + **Request Access** (opens `https://hellodemo.app/beta.html?email=<email>`; email omitted
  for Apple private-relay addresses)
- `pending`: "You’re on the waitlist" / "Thanks for asking to join. We’ll email you when there’s a spot."
- `declined`: "Not this round" / "We couldn’t fit everyone into this round of the beta. We’ll let you know when *[demo]
  opens up more widely."
- Below (not while checking): "Approved? Enter the invite code from your email." + field "Invite code" (max 12, caps,
  one-time-code autofill) + **Enter** → `rpc redeem_beta_code {code}`; `'approved'` → toast "You’re in. Welcome to
  *[demo]", success haptic; else "That code didn’t work. Check it against the email we sent you." / network: "Couldn’t
  check the code. Check your connection and try again."
- Footer: "Signed in as <email | your Apple ID> · **Sign Out**". Re-checks when the app returns to foreground.

### 1.7 Banners, toasts, modal prompts

- **Toast** `#toast` (15402): single line glass pill, 1.6 s, light haptic. Positioned 14 px **above the rhyme bar**
  when the rhyme bar is on screen (measured rects, so it stays above the keyboard toolbar), otherwise default bottom.
  Every toast is logged (debug log); any toast starting "Couldn’t " is also reported to `app_errors`.
- **Pro banner** `#probanner` (19339): glass card "*[demo] Pro" + message (`upsellMsg(k)`), icon, chevron; same
  above-rhyme-bar anchoring; auto-hides after 6 s; tapping the row → `openAccount(k)` (→ paywall for free users);
  ✕ dismisses. Blurs the editor first (keyboard would cover it).
- **Invite banner** `#invbanner` (18819): avatar (photo or initial), "<Name> invited you", "to write “<song>” together",
  **Not Now** / **Accept** / ✕. Success haptic, auto-hides after 20 s, queued if several. Lifted above the keyboard
  toolbar when the keyboard is up. Accept joins and then opens the song. The invite stays in Account either way.
- **Remote banner** `#cfgban` (18427): admin-set message for everyone (`CFG.banner`, `banner_kind:'warn'` = amber).
  Slides away after 9 s (warn 20 s), returns next launch; tapping it or ✕ dismisses that `banner_id` forever
  (`songpad:banner-x`).
- **Forced update** `#cfgupd` (18438): full-screen alert when `CFG.min_seq > APP_SEQ` (never in dev builds):
  "Time to update", `CFG.update_note` or "This version of *[demo] is out of date. Update to keep writing. Your songs are
  safe and will be right here.", button **Get the Update** (iOS `itms-beta://` — TestFlight; Mac
  `https://hellodemo.app/mac.html`) / **Reload** (web), footer "Version <commit> · build <seq>".
  Remote config is read on launch (+700 ms), every 3 min, and on foreground if >30 s old; cached in `songpad:cfg`.
  Other flags: `ai_off`, `sync_off`, `uploads_off` with messages "AI features are paused for maintenance. They’ll be
  back shortly." / "Lyric sync is paused for maintenance. It’ll be back shortly." / "Adding music and files is paused
  for maintenance. Try again shortly."
- **AI consent prompt** (`aiConsent`, 16495): see engines.md §2.1. Title "Use AI features?", body (verbatim):
  "Lines, Muse, Rate, Writing voice and lyric sync send what you’re working on (your lyrics, the song brief and, for
  lyric sync, a low-quality copy of the audio) to OpenAI to write suggestions. It’s used only to answer each request,
  not to train models." + "\n\nNothing is sent unless you allow it. The Privacy Policy is in Account." Buttons
  **Allow** / **Not Now**. iOS uses the system alert (`@capacitor/dialog`); elsewhere an in-app card with a Privacy
  Policy link. Decline → toast "AI features are off. Turn them on any time in Account › AI Features."
- **Native confirmations**: `natConfirm` = UIAlertController alert; `natDestroy` = action sheet with a red destructive
  button + Cancel, preceded by a warning haptic. Web/Mac fall back to "tap again within 3 s" buttons
  ("Tap Again to Delete", etc.). Native rewrite: always use `confirmationDialog` with `.destructive`.

### 1.8 Onboarding / guide

There is no tutorial flow. Every library gets a built-in song **"How *[demo] works"** (`guideSong`, 15097):
fixed id `5f1d0c2e-6a8b-4c3d-9e7f-0a1b2c3d4e5f`, `guide:true`, `updated = guideAt = Date.UTC(2026,9,17,2)` (old on
purpose so any real edit or a delete from another device wins), status "Idea". `GUIDE_V=4`; seeded once per library
(`songpad:guide:<storageKey>` stores the version seen). If the user never edited it (`updated===guideAt`) and a newer
`GUIDE_V` ships, it is replaced; if deleted it stays deleted. Section-tag lines are rich-text bold `#8E8E96`; text in
`{braces}` becomes a yellow "Hook" highlight. Full text is at lines 15099–15149 — copy it verbatim (it documents every
feature and doubles as the onboarding). The guide song is excluded from voice learning, hooks, muse catalog and Rate's
"other songs".

### 1.9 Help / support

Account › About › **Contact Support** (§6.10). Signed-out fallback: mailto `help@hellodemo.app`. Privacy Policy / Terms
open `https://hellodemo.app/{privacy,terms}.html` in SFSafariViewController.

### 1.10 Platform notes that affect the native design

- **Liquid Glass bridge (iOS 26, 17737–17923)**: the web app currently asks a native plugin (`GlassBar`) to draw real
  glass bars over invisible web buttons every frame and to mirror the rhyme bar, Perform controls, sprint timer,
  toasts and banners. In SwiftUI this all becomes native: use `.glassEffect` toolbars. The bridge is useful only as the
  list of which controls are glass: account button (with plan tag, avatar, invite dot), list search field + New song
  (`square.and.pencil`), Ideas search + New idea (`plus`), Ideas back, editor left/right groups, details button, dev
  tab bar, every sheet's Done (checkmark), Account back (`chevron.left`), player close buttons (`xmark`),
  segmented controls (`UISegmentedControl` for every `.seg`), switches (`UISwitch` for `.swtch`).
- **Haptics** (`haptic(kind)`, 15408): kinds `light` (impact light), `medium` (impact medium), `select`
  (selection changed), `success` / `warning` (notification). Soft kinds (light/select) are de-duplicated within 160 ms.
  On iOS 26 every tap on a button-like element gets a light tap on touch-up (not after a drag) — so native buttons should
  use `.sensoryFeedback(.impact(weight:.light))` broadly.
- **Keyboard handling** (15447–15514, 16145–16240): see §4.13.
- **Press highlight**: rows (`.cell`, `.row`, `.drow`, plan row, credits rows) show a pressed state on touch-down,
  min 90 ms, cancelled by >8 px movement.

---
## 2. Sheets and full-screen modes in detail

### 2.1 Details sheet `#sheet` — tabs Info / Audio / Chords / Credits

Segmented control `#dseg` (`dtab(t)`, 15927): `inf` Info (default), `aud` Audio, `chd` Chords, `rel` Credits.
A fifth pane `mel` (Melody) exists but **has no tab button** in this build — dormant (§4.14).
`rel` (Credits) is Pro: free users get `upsell('release')` and stay on Info.

**Info pane `#p-inf`**
- Grouped form rows (each `input` writes straight into the song, sets `updated`, saves, refreshes header — map at 15893):
  - Artists `#f-artist` (placeholder "Add artists") → `song.artist`
  - Key `#f-key` select: "None" + `C C# D Eb E F F# G Ab A Bb B` + minors `Cm C#m … Bbm Bm` → `song.key`
  - Tempo `#f-bpm` (number, "BPM") → `song.bpm` (string)
  - Tuning `#f-tuning` ("Standard") → `song.tuning`
  - Status `#f-status`: Idea / Draft / Demo / Finished → `song.status` ("Finished" songs appear in Account › Credits)
  - Folder `#f-folder` ("None") with suggestions = existing folder names → `song.folder`
- Notes `#f-notes` textarea "Notes: melody ideas, references, co-writers" → `song.notes` (also fed to AI prompts, first
  400 chars).
- **Collaborators** section (`renderCollab`, §4.12).
- **Versions** section (`renderVers`, §4.11).
- Action rows: **Perform** (Pro, §2.10), **Copy Lyrics** (copies `title + "\n\n" + lyrics`, toast "Copied" / "Copy
  blocked by browser"), **Remove Cover Art** (red, only when art), **Delete Song** (red; confirm "Delete “<title>”?" /
  "This can’t be undone." / "Delete Song"; see `removeSong` §3.5).

**Chords pane `#p-chd`**
- Monospace textarea `#chd` → `song.chords`, placeholder "Am   F   C   G\nChords, tabs, strumming…" (no autocorrect/caps).
- Chord chips `#cq` (`chordChips`, 15930) for the song key (default C): major key → I ii iii IV V vi vii° + V7
  (`['','m','m','','','m','dim']` qualities, plus `N[(r+7)%12]+'7'`); minor key → i ii° III iv v VI VII + V
  (`['m','dim','','m','m','','']`), then `/` and `|`. Tapping inserts the chord + space at the caret (`/` and `|` get
  spaces both sides). Chips don't steal focus.

**Audio pane `#p-aud`** (`renderAud`, 19998) — **Pro** to add (`sfAdd` → `upsell('audio')`):
- **Versions** section, header action "Add" (picker accepts audio incl. m4a mp3 wav aac aif aiff flac caf ogg webm,
  multiple). Empty row: "Add a voice memo, demo, mix or master".
  Rows newest-first: round "current version" tick (tap another row's tick → becomes current, toast "“X” is now the
  current version"), name, meta "Kind · m:ss · size · MP3 from WAV", play/pause preview button (lock icon if it's a
  co-writer's file and you're Free). Tapping the name expands an inline editor (animated height 330 ms): kind chips
  **Voice memo / Demo / Mix / Master / Other**, name field, **Convert to MP3** (for already-uploaded WAV/AIFF/FLAC),
  **Delete** (tap twice: "Tap Again to Delete"; toast "Deleted “X”", medium haptic; leaves a tombstone so co-writers'
  copies drop it too).
  Uploads in progress show a placeholder row with spinner and status ("Converting “X” to MP3… 42%", "Uploading…").
  New audio becomes the current version. Kind is guessed from the filename: `voice|memo|recording` → Voice memo,
  `master` → Master, `mix` → Mix, else Demo. WAV/AIFF/FLAC are converted to MP3 on device first (256 kbps stereo,
  160 mono; >48 kHz resampled; toast "Added “X” as MP3, saving 41 MB").
- **Lyric sync** section (only when there is a current version): status line —
  "**Listening…** <progress>" / "**Synced** to “X”: 23 of 25 lines heard." (+ " Lyrics changed since. Sync again to
  update." when the lyric lines no longer match) / "Synced to another version." / "Time every line to “X”."
  Buttons **Sync Lyrics** | **Sync Again**, **Play with Lyrics**, **Export .lrc** (when synced). Pro + AI consent
  required; engine in engines.md §4.
- **Stems & files** section, "Add" (any file type, multiple). Empty row "Attach stems, artwork or session files".
  Rows: kind tile icon, name, "Kind · size", open button (opens a signed URL / share sheet). Kinds
  **Stem / Artwork / Session / Other**, guessed: `stem|vox|vocal|drum|bass|guitar|keys|synth|perc` → Stem,
  `image/*` → Artwork, `.logicx .als .flp .ptx .rpp .band .cpr .song .zip` → Session, else Other.
- Error copy for files (`sfErr`, 19809): "adding music and files is paused for maintenance. Try again shortly." ·
  "you’ve used all <limit> of your storage. Delete some audio or files to make room." · "audio storage isn’t set up yet."
  · "that file isn’t in storage any more. It may have been replaced or deleted on another device, or it was shared by
  someone whose files you can’t open yet." · "it’s bigger than the upload limit." · "you don’t have access to that
  file." · "check your connection and try again." Prefixed by e.g. "Couldn’t upload “X”: " / "Couldn’t play it: ".
- Co-writer's recording while Free: tapping play → Pro banner "<Name> added a recording. Go Pro to listen and add your
  own." (file: "…added a file. Go Pro to open it…").

**Credits pane `#p-rel`** (`renderRel`, 20582) — Pro:
- **Credits** section, actions **Split Evenly** (ghost; only with >1 split-bearing credit; 2-decimals, remainder to the
  first) and **Add** (first credit is prefilled with your name, role Writer, split 100; focus goes to the new name).
  Empty row "Add writers, producers and performers".
  Row: name field, role select (Writer, Composer, Lyricist, Producer, Performer, Featured artist, Mix engineer,
  Mastering engineer, Other), split % field (only for Writer/Composer/Lyricist; digits and "." only), remove ✕.
  Note under: "Splits should add up to 100%." / "Writer splits total 100%." / amber "Writer splits add up to 85%. They
  should total 100%."
- **Release** section: ISRC (placeholder "CC-XXX-YY-NNNNN", forced uppercase), UPC / EAN ("12 or 13 digits", digits
  only), Release date (date picker), Label ("Independent"), Genre ("e.g. Indie pop"), **Explicit** switch.
  Validation note: "An ISRC looks like CC-XXX-YY-NNNNN (12 characters)." (regex `^[A-Z]{2}-?[A-Z0-9]{3}-?\d{2}-?\d{5}$`),
  "A UPC is 12 digits (13 for an EAN)." (`^\d{12,13}$`).
- Stored as `song.credits=[{name,role,split}]`, `song.release={isrc,upc,date,label,genre,explicit}`.

### 2.2 Writing voice `#sheet2` (`buildSettings`, 15830) — Pro (`upsell('voice')`)

Per-song settings (`song.pf`), also saved as the global default for new songs (`songpad:prefs`). Every change saves
immediately (text fields debounce 300 ms), clears AI caches and re-runs the rhyme bar. The gear `#gear` shows a dot when
anything differs from defaults (`pfTouched`: genre, mood, dial, era, pov, tense, img, dev, refs, custom).

- Summary row: "Genre · Mood · Language · <who’s singing>" + **Reset** (back to defaults).
- **Genre** (horizontal chip row): Any, Pop, Bedroom pop, Indie folk, Alt-rock, Alternative, Pop-punk, Emo, Synth-pop,
  Dance-pop, Hyperpop, R&B, Neo-soul, Hip-hop, Trap, Drill, Country, Americana, Gospel, Blues, Afrobeats. (An unknown
  saved value is inserted after "Any".) Selected chip scrolls to centre.
- **Mood**: Any, Heartbreak, Longing, Bittersweet, Hopeful, Euphoric, Romantic, Infatuated, Jealous, Angry, Defiant,
  Grief, Regretful, Lonely, Nostalgic, Wistful, Playful, Confident, Empowered, Anxious, Numb, Dark, Tender.
- **Language** (segmented): Poetic / Conversational (default) / Slang / Explicit. Also filters the rhyme dictionary's
  flagged words (engines.md §1.6).
- **Who’s singing** (text, `dial`): placeholder "e.g. 1970s Glasgow shipyard worker, Melbourne skater kid".
- **Fine-tune** disclosure (subtitle "N set" or "Point of view, tense, imagery and more"):
  - Point of view (seg): Any / I / You / We / They (value `Story`)
  - Tense: Any / Present / Past
  - Imagery (multi-select chips; the stored value is the description): City streets, Small town, Suburbs, Nature, Coast,
    Desert, Open road, Night, Home, Weather, Faith, Money, Nightlife, Technology, Nostalgia objects, Domestic, Work
    (descriptions at 15791–15807)
  - Techniques (multi): Concrete detail, Metaphor, Simile, Internal rhyme, Wordplay, Repetition, Dialogue, Second
    person, Specific names, List structure, Understatement, Callback (15810–15821)
  - Rhymes (seg): Perfect and near (`strict:false`, default) / Perfect only (`strict:true`)
  - Clichés: Allow (default) / Avoid
  - Influences (text, `refs`): "Artists or records for tone, e.g. Phoebe Bridgers"
  - Anything else (text, `custom`): "e.g. short lines, no rhymes on “-ing”"
- **How the muse sees your writing**: the learned voice profile (engines.md §2.6) in an editable auto-growing textarea
  (max 420 pt tall; edits debounce 600 ms and mark it `edited`, status "Your edits are kept. Relearn replaces them.").
  No profile: "Write a few songs and the muse will describe your style here, then use it for every suggestion." (fewer
  than 16 catalogue lines) or "Not learned yet. Tap Learn My Voice, or it will happen on its own as you write."
  Status line: "Learning from your songs…" / "Learned from your songs and what you keep, rewrite and skip. Edit it if
  it’s off." Button **Learn My Voice** / **Relearn** (disabled while building or with <8 catalogue lines; Pro; needs
  connection → toast "Needs a connection"; failure "Couldn’t learn it this time. Try again in a moment."; success haptic).
- Footer: "Saved with this song. Shapes the lines and words suggested for it."
- Unused legacy fields in PDEF: `voice` (dialect presets in `VOICES`, not shown), `era` (not shown but honoured in
  prompts if set).

### 2.3 Muse `#sheet3` (`buildStuck`, 17100)

Opened by the gradient Muse button `#stuckb` (title "Call the muse"; "Muse (rate mode is on)" while rating) or the
"Muse" chip on an empty line. Not Pro-gated as a whole. Body: output area `#stk-out` above a grid of cards `#stg`:

1. **Song brief card** (when a song is open): "Tell the muse about this song" / "Who’s singing, to whom, where, one real
   detail." — or, once set, "About this song" / summary "who · to <x> · where". Opens the brief form:
   "Tell the muse about this song" / "Fill in what you like." Fields: **Who’s singing** ("e.g. me at 19, my dad, a
   bartender closing up"), **Singing to** ("e.g. my ex, my brother, nobody"), **Where and when** ("e.g. Glenelg, the
   night before I moved"), **One real detail from it** ("e.g. her blue Corolla with the cracked windscreen"),
   **Anything else that’s true** (textarea, "what actually happened, what you can’t say out loud"); max 160 chars each,
   600 for the last. **Save** (success haptic, toast "The muse knows this song now" or "Song brief cleared" if all
   empty) and **Clear** (disabled when empty and nothing saved). Stored `song.brief={who,to,where,thing,more}`.
2. **Read my song** (AI; hidden when AI unavailable) — "What this is really about, where it stalls, and a few doors
   out". Shows "… Reading your song", then "… Picking the best ways forward", then: the read paragraph, "Answer one of
   these in your head" + 3 bulleted questions, "Ways forward (tap to add the line)" + 4 move rows (direction, line,
   "N syl · tap to add", each with a "Not this one" ✕), **Read again**. Prompt: engines.md §2.4.
3. **Rate my song** / **Rate mode is on** (AI, Pro tag + lock when Free → `upsell('rate')`): "Scores and notes on what’s
   landing and what isn’t" / "Notes are marked in your lyrics. Tap to hide them." (tapping when on turns rate mode off,
   toast "Rate mode off").
4. **Stare at a thing** — "90 seconds on one object. Every sense. No rhyming." → "Zoom in on" + big noun (50% chance a
   frequent word from this song (`topics()`), else one of 30 `NOUNS`, 17087) + "90 seconds on just this: how it looks,
   sounds, smells and feels. No rhyming. It goes in a scratch section." Buttons **Start 90 seconds** (appends
   `[Scratch: <noun>]` to the end of the song, bolded, and starts a 90 s sprint) and **Another object**.
5. **Wild card** — "One odd instruction. Just do it." → "Strategy card" + one of 30 `CARDS` (17086, copy verbatim) +
   **Another card**.
6. **Pen never stops** — "Five minutes. No deleting. No rhyme bar. Go." → sprint (§2.12).

Inserting a line from the Muse (`insLine`): closes the sheet, inserts after the current line (or replaces it if the
caret line is empty), adds a newline, flashes the inserted text, toast "Added to your song", medium haptic, and records
it for the muse memory (`mzUsed`). Stale responses for an older panel are discarded (`STK_SEQ`).
Errors: "This one needs a connection, which isn’t set up in this copy. Try the cards that work offline." /
"Couldn’t get a response. Try again in a moment."

### 2.4 Rate `#sheet4` (`openRate`, 17600) — Pro

Opening Rate turns on **rate mode** (strengths/issues highlighted in the lyrics: green-ish `rkgood`, red-ish `rkbad`).
- Head: "What to rate" segmented — Whole song / This <Section> (section containing the caret, trailing number removed) /
  Selection (if text was selected); "Feedback" segmented — Encouraging (default) / Balanced / Blunt (persisted
  `songpad:rtone`, select haptic); big button **Rate** / **Rate Again** / "… Reading"; note "Judged on what this song is
  going for and how you write, with your <Genre, Mood> voice in mind."
- Busy: "… Reading the whole song|the Chorus section|the selected lines like a listener would".
- Result (`renderRating`, 17647):
  - Hero: score "7.4 / 10", delta "+0.4 since last time" / "−0.3 since last time" / "Same as last time" (only vs a
    previous rating with the same scope and tone), verdict sentence, "Could reach 8.5" + the one change (spark tile).
  - "How it was read": Reads as (intent), Its world, Your style (personality).
  - "Scores": Cleverness, Legibility, Cohesion, Voice fit — bar (0–10) + value + one-line why.
  - "What’s working": quote, "Role · note"; tap → closes sheet, selects that text in the editor.
  - Issues group titled by tone ("Could be even stronger" / "Could be stronger" / "Where it falls apart"): quote,
    "Role · problem", "Try: <fix>", buttons **Rework This** (selects the line, switches the rhyme bar to Lines mode,
    toast "Selected. Tap Rewrite selection for options.") and **I Meant That** (inline field "What were you going for?
    (optional)", max 200, **Keep It** / **Cancel**; saves to `song.intents`, toast "Got it. Re-rating with that in
    mind." and re-runs Rate automatically).
  - "Kept as intended": each intent with reason ("No reason given") and **Undo** (toast "Removed. Rate again to include
    it.").
  - Footer "Whole song · Encouraging · <date>", **Exit Rate Mode** row.
- Missing quote: toast "That line has changed since the rating".
- Errors: "Rating needs a connection, which isn’t set up in this copy." / toast "Write something to rate first" /
  "That didn’t come back cleanly. Try again." / "Couldn’t get a rating. Try again in a moment."
- Prompt and post-processing: engines.md §2.5. The rating is saved on the song (`song.rating`).

### 2.5 Clean up `#sheet5` (`renderCleanup`, 18081)

From the Aa row's "Clean up". Rules: engines.md §3.
- Empty song: "Write some lyrics first, then clean them up."
- "Capitals (mostly ALL CAPS|mostly lowercase|mostly sentence case now)" — segmented Sentence case / ALL CAPS /
  lowercase (preselected to the detected case).
- "Style": Tidy / Streaming-ready. Description: Tidy "Consistent capitals and section tags, “I” fixed, single spaces."
  / Streaming "Capitals at line starts, no end punctuation, repeats written out, tidy spacing."
- "Section tags": Keep / Remove.
- "N lines will change" / "Already clean", then a monospace preview of the result.
- **Apply to Song** (disabled when nothing changes): saves a version "Before clean-up", replaces lyrics, drops all rich
  formatting, re-bolds section tags, toast "Cleaned up. The original is saved in Versions."
- **Copy Cleaned Text** (toast "Copied cleaned lyrics"). Note: "Removes colours, bold and highlights."

### 2.6 Idea `#sheet7` (`editIdea`, 15333)

Title "Idea" (existing) / "New Idea" (from `+`). Body: if the idea has a voice memo, a large memo player row with
**Remove** (if the idea has no text, removing deletes the idea: toast "Voice memo deleted"; else "Recording removed").
Auto-growing textarea `#itext` (min 96 pt), placeholder "A line, a title, an idea…" or "Add words to go with it…" for a
memo. For existing ideas: **Start a Song** row (orange spark tile; takes the current text first) and **Delete Idea**
(confirm "Delete this idea?" / "This can’t be undone." / "Delete Idea"; toast "Idea deleted").
New ideas focus the text field after 350 ms. **Saving happens on close** (Done, scrim, drag, Escape) via `ideaCommit`:
empty new ideas are discarded; changed text updates `updated`; a memo idea with text becomes kind `line`, without text
kind `memo`.

### 2.7 Share `#sheet8` (`openShare`, 20467)

Builds a colour palette first (from cover art, else the song's generated-cover colours), then shows:
- A preview card on a pastel gradient (palette colour → next colour diagonally, glow of a third top-right): a
  "player card" (art 58 pt, title, "artist · Key of X · N BPM", and when audio is included a play circle, waveform,
  "0:00" / "-m:ss", skip icons) and up to 40 lyric blocks (section headings, lines, gaps).
- Colour swatches (radio, select haptic) when the palette has >1 colour.
- **Link** row: subtitle "Sign in to make a link" / "listen.hellodemo.app/<id>" + "Updated 5 min ago" / "Anyone can open
  it, no account needed"; button **Create Link** / **Update** (busy "Making the link…" / "Updating the link…" with
  spinner). The URL is **copied to the clipboard during the tap** (before upload finishes) — toast "Link ready and
  copied" / "Link updated and copied" (or ". Tap Share Link to send it." if copy failed); failure "Couldn’t make the
  link: <reason>" (+ " (the copied link won’t work)"). 180 s timeout "It took too long. Check your connection and try
  again." Success haptic.
- **Include audio** switch (only if the song has a current version; audio only uploaded for Pro): subtitle "<version
  name>" + "Plays with the lyrics lit in time" / "Plays from the link"; off: "Lyrics only".
- Buttons: **Share Image** ("Preparing…" while rendering; PNG via share sheet, else download), **Copy Lyrics**
  ("Title – Artist\n\n" + lyrics). When a link exists: **Share Link** (system share sheet with URL; Mac copies,
  "Link copied") and red **Stop Sharing** (confirm "Stop the share link?" / "Anyone with the link can no longer open
  it."; toast "The link no longer works"). Note "The link shows the song as of your last update."
- Image spec, link mechanics and page renderer: engines.md §6 (client renderers). Share links are not Pro-gated except
  for the audio.

### 2.8 Dictionary `#dictSheet` (`openDict`, 16981)

Opened by the grab handle on top of the rhyme bar. Nearly full-screen; closes sidebar; blurs the editor; on iOS the
search field is **not** auto-focused (elsewhere focused+selected after 260 ms).
- Search field "Search any word" (no autocorrect/caps). Prefilled with the selected word (last word of a selection) or
  the word the caret is touching; otherwise keeps the last search.
- Word-mode tabs `#dictwm` (same list as the rhyme bar, §4.8).
- Results `#dictout`: chips with syllable-count badge (perfect up to 60 then near up to 40; Near mode 80); Define mode
  shows rows "pos" + definition text. Hints: "Search any word to see rhymes, synonyms, definitions and more." /
  "Finding synonyms for “x”" / "No near rhymes found for “x”." / "No definition found for “x”." / "Looking up “x”".
- Typing debounces 280 ms; Return runs and dismisses the keyboard.
- Tapping a chip inserts it **at the caret position remembered when the dictionary opened** (leading space if needed),
  advances that remembered position, toast "Inserted “x”". The sheet stays open.
- Drag-down on its header closes (free 24 px then rubber band; commit v>0.5 or dy>90). Done `#dictdone`.

### 2.9 Paywall `#pw` (`openPaywall(why)`, 19420)

Full-screen modal with scrim; ✕, scrim tap and Escape close; light haptic on open; closes itself if the user becomes
Pro. Hero: Pro logo, "*[demo] Pro", "Everything you need to take a song from the first line to the finished demo.",
plus the reason line (`upsellMsg(why)`) when opened from a gate.
Feature list (icon tile colour, title, subtitle), staggered fade-in 120 + 45·i ms:
| Colour | Title | Subtitle |
|---|---|---|
| #FF2D55 | Demos, mixes and stems | Keep every take with its song. 5 GB of space. |
| #FF9500 | Voice memos everywhere | Synced to all your devices, with no limit. |
| #AF52DE | Lyric sync | Play your demo with the words lighting up in time. |
| #007AFF | Co-writing | Invite co-writers and finish the song together. |
| #30B0C7 | Share links | Send a song, with its audio, to anyone. |
| #5856D6 | Lines, Rate and your voice | Suggestions that sound like you, and honest notes on a draft. |
| #34C759 | Perform mode | Big, clear lyrics for the stage, plus whole-song listening and release details. |

Bottom bar on iOS: plan radio cards **Yearly** ("A$69.99 a year", badge "Save 35%", default) and **Monthly**
("A$8.99 a month") — prices from StoreKit/RevenueCat when available; CTA **Start 7-Day Free Trial** ("One moment…" while
busy); fine print "7 days free for new subscribers, then <price> a year|a month, charged to your Apple ID. Renews
automatically unless you cancel at least 24 hours before the period ends, in Settings › Apple ID › Subscriptions.";
links **Restore Purchases** ("Restoring…"), **Terms of Use**, **Privacy Policy**.
Off iOS: "Pro is sold in the *[demo] iPhone app: A$8.99 a month or A$69.99 a year, with a 7-day free trial. Subscribe
there and Pro works here too, on the same account." + **Got It**.
Purchase flow (RevenueCat; `RC_KEY` is empty in this build so it currently toasts "Subscriptions open soon. You’ll start
your 7-day free trial right here."): entitlement `pro`, app user id = Supabase user id; after purchase/restore the server
is asked to re-check (edge fn `revenuecat {action:'sync'}`, retried once after 2.5 s) and the plan is refreshed.
Toasts: "Sign in first, so Pro is saved to your account." · "The App Store isn’t answering. Check your connection and
try again." · "Welcome to *[demo] Pro" · "Purchase received. Pro switches on in a moment." · "The purchase didn’t go
through. <msg>" (user cancel silent) · "Pro restored" · "No *[demo] Pro subscription found for this Apple ID" ·
"Couldn’t restore: <msg>". *Native: use StoreKit 2 (or RevenueCat SDK) directly; keep server-side plan as authority.*

### 2.10 Perform `#perf` (`perfOpen`, 20624) — Pro (`upsell('perform')`)

Full-screen teleprompter. Header: title, "artist · Key of X · N BPM", close ✕. Body: lyrics with their rich formatting
(colours, bold, highlights) at 34 pt. Glass control bar: **A−** / **A+** (±4, range 20–72), **−** / **+** speed through
`[0.5, 0.75, 1, 1.25, 1.5, 2, 3]` shown as "1×", **Play/Pause**. Auto-scroll = 28 pt/s × speed, stops at the end; tapping
the text toggles play. Screen wake lock while open. Escape closes, Space toggles. *Native: `isIdleTimerDisabled`.*

### 2.11 Play with Lyrics `#lplay` (`openPlay`, 20252) — Pro (`upsell('play')`)

Requires a current audio version ("Add audio in Details › Audio first"). Full-screen: header title +
"artist · <version> (<kind>)", ✕ (closing keeps audio playing in the in-song player, like Apple Music's lyrics view).
Line list: synced lines (`song.sync.lines`) or, unsynced, the plain lyric lines with note "Not synced yet. Tap Sync
Lyrics in Details › Audio."; if lyrics changed since sync: "Lyrics changed since syncing. Showing the synced version."
Current line = last line with `t ≤ now + 0.25 s` → style `on`; earlier lines `past`. The current line auto-scrolls to
32% from the top (smooth) unless the user scrolled in the last 3 s. Tapping a timed line seeks there and plays.
Bottom: scrubber (range), elapsed / length, **back 10 s**, play/pause, **forward 10 s**. Continues from wherever the
in-song player is. Esc closes, Space toggles.

### 2.12 Sprint timer `#sprint` (`sprintGo`, 17128)

"Pen never stops" (300 s) or "Stare at a thing" (90 s). Closes sheets, adds `body.sprinting` (hides the rhyme bar),
moves caret to end, shows a glass pill "m:ss" + **Stop**. Updates every 250 ms. End → toast "Time. N new words." /
Stop → "Stopped. N new words." (word count delta).

---
## 3. Song list `#vList`

### 3.1 Layout
- Large title header "*[demo]" (+ "DEV" pill in dev build) with the **account button** `#acctb` top-right: profile photo
  (or person glyph), a plan tag `#acctplan` ("Pro" / "Beta"; hidden on Free), and a red dot `#invdot1` when there are
  pending co-writing invites. Tap → Account sheet.
- Scrolling list `#list` under a floating header (top padding measured from the header, `fitHeads`).
- Footer links under the list: **New Folder** · **Import Songs** · **Export All Songs** (`#newfolderb`, `#impb`, `#expb`).
- Bottom dock: glass search field `#q` ("Search") and round **New song** button `#new` (pencil; SF Symbol
  `square.and.pencil`) → `newSong()` creates and opens an empty song.

### 3.2 Rows and grouping (`renderList`, 15867)
- **Ideas row first** (only when not searching) — built like a song row: bulb tile, "Ideas", latest idea's first line
  (or "Voice memo · 0:42", or "A quick jot for lines, ideas and concepts"), meta "12 ideas · <date>" or "Tap + to jot
  one", and a small **+** ("Jot an idea") that opens Ideas with the jot box focused.
- Then groups:
  1. **Pinned** (any pinned song, regardless of folder; shows its folder name in the meta line)
  2. Each **folder** and **"Songs"** (= no folder). Folders and "Songs" are ordered **by their most recently updated
     song** (descending) — "Songs" is not forced first/last.
- Within groups songs are sorted by `updated` descending.
- Folder header: folder name + rename pencil (`.fren`) (also double-click); "Songs" and "Pinned" have none.
- Song row (`rowEl` 17950): cover thumbnail (art, or generated cover §4.2), **title** = title || first lyric line ||
  "New Song"; **subtitle** = (title ? first lyric line : second lyric line) || "No lyrics yet" (placeholder folder songs:
  "Empty folder. Tap to write its first song, or drag songs here."); **meta** = [folder (pinned group only), "Shared",
  artist, status, key, "N BPM", `fd(updated)`] joined " · ". "Lyric lines" = non-empty lines not starting with `[`
  (`llines`).
- `fd(t)`: today → local time "3:41 PM"; otherwise "Oct 21" (`month:'short', day:'numeric'`).
- Empty states: no songs → "**No songs yet**" / "Tap the pencil to write your first line."; search with no matches →
  "No Results".
- A drop zone "Drop here for a new folder" (`.newzone`) is appended while dragging (§3.6).

### 3.3 Search
`#q` filters on `(title + ' ' + lyrics).toLowerCase().indexOf(query)` — plain substring, title and lyrics only (the
sidebar search also includes artist). Grouping is kept for results; the Ideas row is hidden while searching.
Mac menu "Find" goes back to the list and focuses search.

### 3.4 Row gestures (iPhone)
- **Swipe left** (starts when |dx|>14 and |dx|>1.5·|dy|): row content follows the finger, revealing a **Pin** button
  (`.rpin`, "Pin to top"/"Unpin") and a **Delete** button (trash; for someone else's shared song the label is
  **Leave**). Past −56 px the pull gets rubber-band resistance (×0.22). Past −24 px the row becomes "held" (actions
  stay revealed after release). Past −120 px on release the delete button is **armed** (turns solid red with the word
  "Delete"/"Leave") — a hard swipe never deletes by itself. Tapping the trash once arms it, a second tap deletes;
  armed state reverts after 3 s. Only one row can be held; touching elsewhere or scrolling clears it.
- **Long-press**: on iOS 26 with the native context-menu plugin, a system context menu with a preview (title, meta,
  first ~9 lyric lines) and actions: **Open** (`arrow.up.forward.app`) · **Pin/Unpin** (`pin`/`pin.slash`) ·
  **Copy Lyrics** (`doc.on.doc`, toast "Lyrics copied") · **Delete Song** (`trash`) / **Leave Song**
  (`rectangle.portrait.and.arrow.right`), destructive, confirm "Delete “T”?" "This can’t be undone." / "Leave “T”?"
  "It stays with its owner.". Without the plugin, a 500 ms press "holds" the row (reveals actions) and then dragging
  moves it between folders.
- Mac: hover reveals the actions; HTML5 drag and drop.
- *Native: `.swipeActions(edge:.trailing)` with Pin + destructive Delete (keep the two-step confirm via
  `confirmationDialog`), `.contextMenu(preview:)`, `.draggable`/`.dropDestination` on folder headers.*

### 3.5 Pin, delete, leave
- Pins are **local to the device** (`songpad:pins` = `{songId: pinnedAt}`), not synced. `setPin` toasts
  "Pinned “T”" / "Unpinned".
- `removeSong(s)` (18005): warning haptic; deletes the song's audio and files from storage (unless leaving someone
  else's song), stops its public share link, for a shared song: owner → removes it for everyone (members are pinged),
  member → leaves (removes own membership). Unpins, removes the melody blob, removes from the library, returns to the
  list if it was open. Toast "Deleted “T”" / "Left “T”".

### 3.6 Folders
- A folder exists only as the `folder` string on songs. **New Folder** (`createFolder`, 18042) creates a placeholder
  song (`ph:1`, empty, `folder:"New Folder"` / "New Folder 2"…) so the empty folder shows, then immediately opens the
  inline rename field for that header.
- **Rename** (`renameFolder`, 18016): the header text becomes a text field (selected); Enter or blur commits, Escape
  cancels. Empty, unchanged, "Unfiled" or "Songs" are ignored. All songs with the old folder get the new name and
  `updated=now`; collapse state follows; toast "Renamed to “X”" (+ " (N songs)").
- **Move**: drag a song row onto a folder header or onto any row in that folder (the header highlights `dropon`), onto
  the "Songs"/"Unfiled" group (= no folder), or onto "Drop here for a new folder" (creates "New Folder N" and opens
  rename). Touch: after the long-press hold, moving starts the drag with a medium haptic; light haptic on drop.
  `moveSongToFolder` sets folder, clears `ph`, removes any now-redundant empty placeholder in the target, toast
  "Moved to “F”" / "Moved out of folders". The Folder field in Details is the non-drag way.

### 3.7 Import / export
- **Import Songs** (`#impin`, multiple files, `.json,.txt`): each file is read as text; JSON if the name ends `.json`
  or content starts with `[`/`{` — accepted shapes: an array of songs, `{songs:[…]}` (the backup format) or a single
  song object; anything else goes through `fromText` (engines.md §3.6).
  `importSongs(list)` (17700): skip entries that aren't objects with a string `id`; strip sharing fields
  (`shared`, `owner`, `members`) and every key starting with `_`; coerce text fields to strings; drop non-array
  `credits/audio/files/versions`; set `updated=now` (so a restore beats an older tombstone). New id → added; existing
  unshared song and the imported one was newer (by its original `updated`) → replaced; otherwise skipped.
  Toast: "3 songs added" / "No new songs" + ", 1 updated" + ", 2 already here" + ", 1 file unreadable".
- **Export All Songs**: `backupJSON()` = `{"app":"*[demo]","saved":<ISO>,"songs":[…]}` (indent 1), excludes shared
  songs and `_` keys; filename "*[demo] backup YYYY-MM-DD.json"; delivered via share sheet (iOS), download (web), or on
  Mac the app opens its Documents folder (songs are mirrored there as files) with toast "Your songs and *[demo]
  backup.json are in this folder". Nothing to export: "No songs to export yet".
- *Native: `.fileImporter` / `ShareLink` with a `FileDocument`; keep both formats byte-compatible.*

### 3.8 Song model (fields the UI uses)
`{id (UUID), title, lyrics (plain text, "\n" lines), rich (sanitised HTML of the editor, optional), chords, key, bpm,
capo, time, tuning, status, folder, notes, artist, _autoArtist, art (data:image/jpeg base64, 480²), pf (writing voice),
scheme ('auto'|'ABAB'|…), brief, rating, intents, versions[], audio[], files[], sync, credits[], release, melody,
shared, owner, ownerEmail, members[], lastEditBy, lastEditAt, shares{uid:rec}, rmFiles{}, ph, guide, guideAt, updated}`.
`newSong()` defaults: empty strings, `status:'Idea'`, `artist = _autoArtist = myName()`, `pf = defaults`.

---

## 4. Editor `#vEdit`

### 4.1 Header area (scrolls with the lyrics, inside `#sc`)
- **Cover art** `#cov` (square, left of title). Tap → photo picker; image is centre-cropped to a square, scaled to
  **480×480 JPEG quality 0.8**, stored as a data URL in `song.art` (only `data:image/(jpeg|png|webp|gif);base64` is ever
  rendered — `artOk`, so co-writers can't inject remote URLs). Unreadable → toast "Could not read that image". Remove
  via Details › Remove Cover Art.
- **Title** `#title` single-line field, placeholder "Untitled", autocorrect on.
- `#artist` line (hidden when empty), `#sub` = "status · key · N BPM".
- `#savestate` "Saving…" / "Saved" with a dot: shown at most once every 2 minutes (decided once per debounce cycle);
  "Saved" fades after 1.8 s.
- `#here` collaborator line: "Sam is writing…" while live edits arrive (2.5 s), or "Sam added 3 new lines · tap to
  dismiss" (§4.12).
- In-song player `#np` (§4.10) when the song has audio.

### 4.2 Generated cover (no art) — `cover(s)` (17225)
A 40×40 SVG: soft gradient seeded by the song id + white rounded bars, one per lyric line (width = 24·clamp(syllables/12,
0.18, 1), height 1.8, x=8, starting y=9, spacing 3.6 (2.9 if >6 bars)), a half-gap between sections, max 9 bars.
Empty song: three bars `.72, .5, .62` at 60% opacity (else 82%). Gradient (`covPick`, 17234): FNV-1a hash of the id
(`h=2166136261; h^=c; h=imul(h,16777619)`), then xorshift32 (`h^=h<<13; h^=h>>>17; h^=h<<5`, /2³²) draws: pastel pair
from `COV_PAL` (12 pairs, 17232), angle 0–360°, glow centre 15–85% x/y, glow colour from a second pair. Linear gradient
across the angle + radial glow (r 60%, opacity .85→0) + a dim overlay (`cvdim`, stronger in dark mode). It regenerates
as lyrics change (`refreshViews`). This determinism matters: the same song looks the same on every device and in share
images (`covHex(id)` = `[p[1], glow, p[0]]` is the share-card fallback palette).

### 4.3 Lyrics editing — rich text
- `#lyr` is a contenteditable; placeholder "Start with a line…"; spellcheck off, autocorrect on, sentence caps.
- **Plain text is the source for every engine**: `getText()` walks the DOM, text nodes as-is, `<br>` = "\n" (one
  trailing "\n" dropped). `song.lyrics = getText()` and `song.rich = innerHTML` are both saved on every input.
- Enter always inserts a line break (never a paragraph). Paste is plain text only (`\r` removed). Drop disabled.
- **Formatting that exists** (Aa row, `buildFmt` 16027): **Bold**, *Italic*, Underline, Strikethrough (buttons reflect the
  selection state); text colour: Default (theme ink) + Rose `#E5566F`, Amber `#D4881C`, Moss `#4E9A5B`, Tide `#2C8DBF`,
  Indigo `#5D6BE0`, Plum `#A35FCB`, Slate `#8E8E96`; highlight: **Hook** `rgba(255,204,0,.38)`, **Rework**
  `rgba(255,69,58,.24)`, **Idea** `rgba(10,132,255,.22)`; **Clean up** (opens §2.5); **Clear formatting** (✕).
  Applied with `styleWithCSS`, so formatting is inline `style` spans. "Hook" highlights feed the voice learning
  (engines.md §2.6).
- Sanitiser for stored/received rich HTML (`clean`, 15952): allowed tags B I U S STRIKE STRONG EM SPAN BR FONT MARK DIV
  P; attributes stripped except `style` (only `color`, `background-color`, `background`, `font-weight`, `font-style`,
  `text-decoration[-line|-color]` declarations; anything with `url(`, `expression`, `@`, `\`, or positioning dropped)
  and `FONT color`.
- **Native recommendation**: store an attributed representation that round-trips to this HTML subset (bold, italic,
  underline, strike, foreground colour from the 7-colour palette, background from the 3 highlights). Plain text must
  stay derivable exactly (line breaks only). Sync/share keeps sending `lyrics` + `rich`.
- **Section tags**: a line that is exactly `[Something]` is a section label. After Enter, the line just finished is
  styled bold + Slate if it is a tag (`tagBold`, 15998; `--slate`). Section labels split stanzas for rhyme schemes,
  the rhyme map, syllable gutter, melody mapping, Rate sections, sync (tags are not sung) and the cover bars.
- **Chorus auto-fill**: pressing Enter on a line that is exactly `[Chorus]` (caret collapsed), when an earlier `[Chorus]`
  exists, inserts that chorus's lines (`chorusText()` = lines after the first `[Chorus]` until a blank line or tag).
- **Empty-line chips** in the rhyme bar (§4.7) insert `[Verse]`, `[Pre-Chorus]`, `[Chorus]` (+ " + lyrics" variant),
  `[Bridge]`, `[Outro]`.
- Caret visibility (`reveal`, 15967): while typing, the caret line is kept between the top bar (+12) and the rhyme bar
  (−14); on tap/selection change it is centred. Mouse selection drags don't scroll.
- Word under a tap is highlighted (`tw`, `rgba(142,142,150,.22)`) — only after a tap, never while typing. Mac hover
  highlights the word under the pointer (`hv`, `rgba(120,120,128,.14)`). Inserted text flashes (`fl`,
  `rgba(142,142,150,.45)`, 520 ms). Rate marks: strengths = solid underline Moss `#4E9A5B` 2 pt, issues = wavy underline
  Amber `#D4881C` 1.5 pt, offset 4 pt.
- Scrolling the lyrics more than 70 px while the keyboard is up dismisses the keyboard (like Notes).
- Autosave: every edit → `save()` (debounced 250 ms) → local write, then mirror/sync/push. Writes immediately when the
  app is backgrounded. If local storage is full, old versions are trimmed (keep last 10, rich only on last 3) and a toast
  says "This device is out of space for songs. Your edits are still saving to your account."
- Undo: there is no custom undo stack — it relies on the platform text undo (and Versions). *Native: provide the
  standard UndoManager for text edits.*

### 4.4 Rhyme map `#vmap` and syllable counts `#vsyl`
Toggles persisted in `songpad:view` (`{map:false, syl:false, ctx:true}`); toast "Rhyme map on/off", "Syllable counts
on/off". Both re-render 140 ms after edits/resizes (`refreshViews`).
- **Rhyme map**: words that rhyme within the same stanza share one of 8 colours (CSS highlights `rm0..rm7`). Algorithm
  in engines.md §1.10.
- **Syllable counts**: a left gutter `#gut` with the syllable count of each lyric line (not tags/blank), aligned to the
  line's first word; with a melody (§4.14) shows "7/8" coloured ok / off-by-1 / off-by-more with tooltip "Melody has 8
  syllables here" / "Fits the melody".

### 4.5 The rhyme bar `#rhy` (bottom toolbar)
Glass panel docked at the bottom (above the keyboard when it's up). From top:
1. **Grab handle** `#rhyExpand` → Dictionary (§2.8).
2. Row 1: `#rs` status text (left) + button group `.r1g`: **Muse** `#stuckb` (gradient icon), **Aa** `#aa` (toggles the
   formatting row `#fmt`), **Listen to the whole song** `#ctxb` (toggle, Pro), **Writing voice** `#gear` (Pro, dot when
   customised), **Lines** `#lm` (toggle, Pro; shows a "Pro" tag when Free).
3. `#fmt` formatting row (when Aa on).
4. `#wm` word-mode tabs (hidden in Lines mode or when there is no target word).
5. `#rc` results row (horizontally scrolling chips, or Lines' vertical list).

Behaviour on mobile: swipe down on the bar while the keyboard is up dismisses the keyboard (bar follows 1:1 for 64 px
then rubber-bands, commit v>0.5 or dy>60, always springs back with `cubic-bezier(.34,1.56,.64,1)`). During a sprint
the bar is hidden. Horizontal chip rows fade their edges only where content is hidden (8 px), and a tapped selected chip
scrolls to centre.

The bar re-renders (`rhyme()`, 16548) on every input and selection change. What it targets comes from `ctx()`
(engines.md §1.8): selected text, else the word under the caret, else — when the caret is at the end of a line that
should rhyme with an earlier line — that earlier line's last word ("via line N").

### 4.6 Status line `#rs`
- Word: "**word** · 2 syl · line 1 · 3 to match" — "line N" when the target came from the scheme partner; "N to match" =
  partner (or melody) syllables minus current line syllables when positive.
- Multi-word selection: "**first few words…** · 6 syl · ends “night”" (`shortSel`: tags stripped, ≤22 chars cut at a word).
- Lines mode: "Line 3 · rhymes with line 1 · 8 syl" / "new rhyme" / "(melody)"; with a selection "Selection · 7 syl ·
  ends “x”" or "3 lines · …".
- Nothing: "Tap any word for rhymes".
- Appended: " · ranked for this song" or " · … ranking for this song" (context ranking, §4.8).

### 4.7 Results in word mode (`rhyme()`)
- Empty line, no selection: chips **Muse**, **[Verse]**, **[Pre-Chorus]**, **[Chorus]** (label "[Chorus] + lyrics" when
  a chorus exists → inserts the tag and the chorus text), **[Bridge]**, **[Outro]**. Inserting a tag adds a trailing
  newline unless a lyric line directly follows.
- Chips show the word plus a small syllable-count badge; chips whose syllables exactly fill the gap ("N to match") are
  highlighted (`f`) and sorted first. Rare words (frequency tier ≥8) and letter-by-letter abbreviations go last
  (`order`, 16604).
- Tapping a chip: replaces the selection, or the tapped word, or inserts at the caret with a leading space if needed;
  matches capitalisation of what it replaces (ALL CAPS → upper, Capitalised → capitalised); flashes; records perfect vs
  near for learning (`songpad:linepref`).
- Selections of more than 8 words or spanning lines: "Select a word or short phrase to see rhymes." 2–8 words: **phrase
  rhymes** via AI (Pro; Free hint "Phrase rhymes for a multi-word selection are part of *[demo] Pro. Select just the
  last word for single-word rhymes."; offline "Matching a multi-word selection needs a connection. Select just the last
  word for offline rhymes."); busy "… Finding phrases that rhyme with “…”"; none "No phrase rhymes found for “…”."
  Phrase chips are inserted **at the end of the previous line** rather than replacing the selection (`addP`, 16585) —
  probably a bug; decide whether to copy it or replace the selection like single-word chips.

### 4.8 Word modes `WMODES` (16930)
Tabs: **Rhymes** (`rhy`, default: up to 40 perfect + 30 near, near omitted when "Perfect only") · **Perfect** (40) ·
**Near** (60) · **Phrases** (`phr`) · **Synonyms** (`syn`) · **Related** (`rel`) · **Describe** (`adj`) · **Opposites**
(`ant`) · **Sounds like** (`snd`) · **Define** (`def`). Mode is global (not per song), resets per launch.
- Rhyme modes: instant offline results from the built-in dictionary, upgraded in the background with Datamuse
  (re-render if the user is still on that word). Separator label "near" between perfect and near chips. Empty "No
  (perfect |near )rhymes found for “x”."
- **Context ranking** (Pro, AI, when "Listen to the whole song" is on): the candidate list is re-ordered by AI for fit
  with this song (engines.md §2.7).
- Meaning modes: Datamuse (`ml`, `rel_trg`, `rel_jjb`, `rel_ant`, `sl`; with `topics=` top-5 song words when listening to
  the whole song), fallback AI list of 24 (Pro only). Busy "… Finding synonyms for “x”"; empty "Nothing found for “x”."
  or "Meaning-based lists need a word database or a connection, and neither is reachable here."
- Define: Datamuse definitions (up to 6) else AI (3 senses); shown as one block, "pos. text" per line.

### 4.9 Lines mode (`lineView`, 16641) — Pro, AI
Toggle `#lm`. Without AI: "Lines needs a connection to write full lines — not available here yet. Turn it off to keep
using word rhymes."
- **No selection**: scheme chips **Auto · ABAB** (shows detected scheme) / **ABAB** / **AABB** / **ABBA** / **ABCB**
  (saved per song in `song.scheme`). Hint before generating: "Line 3 will rhyme with “night” (line 1) and match its 8
  syllables. Select words to work from just those." (or "…and fit your melody (8 syllables).") / "This line starts a new
  rhyme. I’ll match the syllables of the line above." / "Start a stanza. Write line 1, then press return for line 2."
  Button **Write line N**. While busy: "… Writing line N", then "… Picking the best ones for you". Results: up to 6 line
  buttons (text + meta "8 syl (+1) · near rhyme"), each with a "Not this one" ✕ → "Why not?" chips **Cliché**, **Not my
  voice**, **Too on the nose**, **Doesn’t sing**, **Makes no sense**, **Just Hide It** (removes the row and teaches the
  muse). "No exact match this time. Closest fits first." when nothing hit the syllable target and judging failed.
  **New ideas** regenerates (previous batch is passed to the model as "already suggested"). Error + **Try again**.
  Tapping a line replaces the current line (or inserts after a tag line), adds a newline, flashes.
- **With a selection**: chips **Lines that rhyme** / **Rewrite selection** / **Tighten**. Idle hint "Uses only what you
  selected: 7 syllables, ending on “x”." Busy hints "Writing lines that rhyme with your selection" / "Rewriting your
  selection" / "Tightening your selection". Rewrite/Tighten replace the selection (re-located if the text moved; toast
  "The selected text has changed" if gone); "Lines that rhyme" inserts a new line after the selection's line.
- Results are cached per (target, stanza position, scheme, voice, context) so toggling back is instant.
- When results arrive the keyboard is dismissed so they are visible.
- Prompts and ranking: engines.md §2.2–2.3.

### 4.10 In-song player `#np` (`paintPlayer`, 20209)
Appears under the title when the song has audio (current version = the one ticked, else the newest).
- Compact: play/pause (lock icon when the version is a co-writer's and you're Free → Pro banner), version name, subtitle
  "Demo · Lyrics synced" (locked: "Added by Sam · Demo · Pro"), time ("3:12" idle, "-2:01" playing), full-screen button
  → Play with Lyrics. A thin progress bar.
- Tap the player (touch devices) to expand: waveform scrubber, elapsed, **−15 s** / **+15 s**, "-remaining".
- Waveform: 180 normalised peaks per version (computed once from the audio, `pow(v/max, .7)·100`, saved on the version
  so other devices don't download audio to draw it). Rounded bars 2.4 pt wide, 2.1 pt gap; played part in ink, rest
  muted at 42%. **Dock-style magnification** under the finger (Gaussian σ = 20 pt: width ×(1+1.1g), height ×(1+.62g)
  + 6g, neighbours re-flow). Scrub haptics: light on grab, selection tick every 5 s of song, medium at either end, light
  on release (seek happens on release). Keyboard: ←/→ ±5 s, Space toggles.
- One shared audio player for the song (also used by Play with Lyrics); leaving the song (back to list) pauses it;
  opening a different song pauses it if it belongs to another song.
- iOS requires audio to start from a tap: signed URLs are fetched ahead of time; audio is cached on device (500 MB LRU,
  files ≤60 MB) after first play.

### 4.11 Versions (Details › Info)
`snap(label)` (19763) saves `{t, lyrics, rich, label}` unless identical to the last version; max 30. Automatic version
"Auto" when opening a song whose last version is >2 h old (`autoSnap`). **Save Version** row (toast "Version saved" /
"No changes since the last version"). Rows newest first: "Oct 21, 3:40 PM · Auto" + "182 words"; tapping **restores**
immediately (first saving the current text as "Before restore"), closes the sheet, toast "Restored. Your previous text
was saved as a version." Other labels: "Saved", "Before clean-up". Synced/shared copies keep only the last 8.

### 4.12 Collaborators (Details › Info) and live co-writing
- Not shared / signed out (`renderCollab`, 17536): avatar stack (you + "+"), "**Write this one together**", "Invite
  co-writers by username and write it together, live." (signed out: "Sign in to write with other people."), button
  **Share Song** (Pro tag; `upsell('share')`). Sharing toast: "Shared. Invite a collaborator by username below."
- Shared, owner: invite field "@" + "Invite by username" + **Invite** (disabled when empty; Return submits). Typeahead
  after 2 characters (250 ms): up to 5 profiles whose username starts with the text, each with avatar, display name,
  "@username" and badge **Invite** / **On song** / **Invited**. Errors: "Enter a username", "No one found with that
  username", "That’s your own account", "Couldn’t send the invite: only the song’s owner can invite people."; success
  "Invited @sam".
- People list: owner ("Name (you)", @handle, badge **Owner**), members (badge **Co-writer**; owner sees **Remove** →
  tap again "Remove?" → toast "Removed Sam"), pending invites ("Hasn’t accepted yet", badge **Invited**). Owner with
  nobody: "No one else yet. Invite a co-writer above."
- Footer: owner **Stop Sharing** (confirm "Stop sharing “T”?" / "Your co-writers lose access. The song stays with you."
  → toast "Sharing stopped. The song is back on this device only.") / member **Leave Song** ("Leave “T”?" / "It’s removed
  from your devices. The owner can invite you again." → "You left the song"). Note: "Co-writers need *[demo] and a
  username." / "Leaving removes the song from your library."
- Avatars: photo, else a gradient from the person's id (`covHex`) with their initial.
- **Auto artist credit** (`applyCredits`): when members change, `song.artist` becomes "A & B" / "A, B & C" unless the
  artist was edited by hand (`_autoArtist` tracks the auto value). Renaming yourself updates songs still showing your
  old auto name.
- **Live editing**: while a shared song is open, changes stream to co-writers within ~150 ms as small text patches; their
  edits appear in place, keeping your caret; "Sam is writing…" under the title. IME composition defers incoming
  patches. Algorithm in engines.md §5. If the owner deletes/unshares: toast "“T” was removed by its owner" (or "N shared
  songs were removed by their owners") and the song disappears.
- "Added since you looked": `#here` shows "Sam added 3 new lines · tap to dismiss" for lines added by another editor
  since you last dismissed (`songpad:seen`).
- Accepting invites: Account › Invitations, invite banner, push notification (§6.7).
- `sendPres()`/`#pres` (live presence carets) is a stub — not implemented.

### 4.13 Keyboard handling (iPhone)
- The editor and the rhyme bar are sized to the visual viewport (`--vvh/--vvt`); in the native WKWebView the keyboard
  height is *estimated* as `clamp(innerHeight·0.4, 280, 340)` because visualViewport is unreliable. *Native: use the
  real keyboard safe-area and put the rhyme bar in a keyboard-attached toolbar / `safeAreaInset(edge:.bottom)`.*
- The system input accessory bar is turned off natively; ways to dismiss: swipe down on lyrics/title when scrolled to
  top (>70 px), scroll lyrics >70 px, swipe down on the rhyme bar, in other fields swipe down >64 px or tap an empty
  area. Fields in sheets scroll themselves to the middle of the visible area (`revealInSheet`).
- On opening a song: blank songs and non-touch devices focus the lyrics at the end; on phones existing songs open
  without the keyboard.

### 4.14 Melody (dormant, Pro `melody`)
A hidden Details pane: import or record a hummed melody; on-device onset/pitch detection splits it into phrases of
syllables with strong beats and held notes (`analyze`, 17155); each lyric line (within the chosen section, or the whole
song) then gets a target syllable count and rhythm pattern ("DUM da da~") used by the rhyme bar, Lines prompts and the
syllable gutter. UI: "Import Recording"/"Replace Recording", "Record"/"Stop Recording" ("Recording. One phrase per
line."), "This melody is for" (Whole song + sections), "Syllable detection" Fewer/Normal/More, phrase rows (play, pitch
dots, −/count/+), "Remove Melody". Tip: "Hum or sing “da da da”, one phrase per lyric line, with a short breath between
lines. Clear separate syllables work best. A voice memo from your phone works." There is no tab to reach it in this
build; port only if product wants it back (Medium–Large).

### 4.15 "Listen to the whole song" `#ctxb` (Pro)
Pressed by default for Pro (forced off on Free). Title "Listening to the whole song: suggestions fit your song" / "Only
listening to nearby lines"; toast "Listening to the whole song" / "Only listening to nearby lines". When on, AI prompts
include the whole song with a marker (`songCtx`), Datamuse meaning lookups get `topics`, and rhyme lists are re-ranked
for the song. When off, prompts include only the current stanza.

---

## 5. Ideas `#vIdeas`

- Header: back `#ideaBack`, large title "Ideas". Bottom dock: search `#iq` "Search ideas" + **+** `#inew` (opens a
  blank Idea sheet).
- **Jot box** (top): auto-growing textarea `#ijot` (max 180 pt) "A line, a title, an idea…", Return (without Shift, not
  composing) saves (`ijotSave`): new idea `{kind:'line', text}` at the top, light haptic, box cleared; on iPhone the
  keyboard then closes, on Mac it stays focused for the next one. Send button `#ijotgo`, mic button `#ijmic`.
- **Voice memo recording** (`irecStart`, 15206):
  - Free: max **10 memo ideas** (`FREE_MEMOS`) — the 11th → `upsell('memos')` ("Free keeps 10 voice memos on this
    device, up to a minute each. Pro syncs them everywhere, with no limit."); max **60 s** each (auto-stops: "Saved at a
    minute, the longest on Free. Pro memos can run 10 minutes."). Pro: max **600 s** ("Saved at 10 minutes, the longest
    a voice memo can be.").
  - Format: MediaRecorder with the first supported of `audio/mp4`, `audio/webm;codecs=opus`, `audio/webm`,
    `audio/ogg;codecs=opus`…; 128 kbps; echo cancellation, noise suppression and AGC **off** (singing). Chunks every
    1 s. Files saved with extension from mime (m4a/ogg/wav/mp3/webm). *Native: AVAudioRecorder AAC .m4a, 44.1/48 kHz,
    128 kbps, `.measurement` mode / voice processing off.*
  - UI while recording: the jot box turns into a strip: **Cancel**, red dot, timer "0:12", live waveform, round stop
    button (**Stop and save**). Waveform: a new bar every 70 ms scrolling left, newest bar at the right edge following
    the voice live; level on a dB scale `(20·log10(peak)+50)/44` clamped 0–1, attack 0.6 / release 0.25 smoothing; bars
    3 pt wide, 2.5 pt gap, opacity fading toward the left (`.35+.65·x/w`). Medium haptic on start.
  - If the peak level stays below 0.04 after 3.5 s: "No sound is coming in. Check your microphone." (Mac: "…Check the
    input in System Settings › Sound, and that *[demo] is allowed under Privacy & Security › Microphone.").
    Mic blocked: "Allow microphone access for *[demo] in Settings to record." (Mac: "Turn on *[demo] in System Settings ›
    Privacy & Security › Microphone, then try again." and opens that pane). Not available: "Recording isn’t available
    here."
  - Stop: success haptic; shorter than 0.6 s → "That was too short to keep."; Cancel → "Recording discarded".
    Leaving Ideas or backgrounding the app **stops and saves**.
  - Save (`ideaMemoSave`): the blob is stored on device first (IndexedDB `f:<memoId>`), idea
    `{kind: text?'line':'memo', text: <whatever was typed in the jot box>, memo:{id, path:'local:<id>', mime, size,
    dur (0.1 s), peaks[60], pend:true}}`, toast "Voice memo saved"; 60 waveform peaks computed after decode. Then
    uploaded (Pro + signed in only) to `song-files/<uid>/ideas/<memoId>.<ext>`; Free memos stay on the device.
- **List** (`renderIdeas`, 15317): sorted by `updated` desc; search over text + tags (substring). Each card: text, memo
  player row (play/pause, scrubbable waveform with the same magnification + haptics as the song player — tick per
  second, medium at ends — time "0:42" or "0:12 / 0:42"), date line `fd(updated)` + " · In a song" if used. Tap → Idea
  sheet. Swipe left → delete (same arm-then-tap as songs; toast "Idea deleted", medium haptic).
  Empty: "Nothing here yet. Type a line and press Return, or tap the mic and hum it." / "No ideas match."
- **Start a Song** (`ideaToSong`, 15312): kind `line` → new song with lyrics = text + "\n"; kind `idea` → title = first
  line (if ≤60 chars), notes = text; kind `concept` → notes = text and `brief.more` = text (first 600). Status "Idea",
  artist = you. The idea gets `used = songId`. A memo becomes the song's first audio version (kind "Voice memo",
  current) — **Pro only**; Free: "Your voice memo stays in Ideas. Pro adds recordings to songs." Toast "New song from
  your idea" / "…voice memo".
- Tags and kinds: the data model has `tags[]` and kinds `line | idea | concept | memo` (`IKINDS`: Line "A lyric line or
  hook", Idea "A title, image, phrase, anything", Concept "What a song could be about"), but this build has **no UI to
  set tags or kinds** (the tag row `#itagrow` is always hidden). Keep the fields for sync compatibility.
- Ideas sync with the library like songs (`data-and-backend.md`).

---
## 6. Account `#sheet6` (`renderAccount`, 19505)

Settings-style grouped list with solid Apple-colour icon tiles (`ACC_SOLID`, 19471: Name & Username `#007AFF`,
Notifications `#FF3B30`, Import `#007AFF`, Export `#34C759`, Storage `#8E8E93`, AI Features `#AF52DE`, Reset What Rate
Learned `#5856D6`, Blocked `#FF2D55`, Privacy `#007AFF`, Terms `#8E8E93`, Contact Support `#34C759`, Switch Account
`#5856D6`, Start a Song `#FF9500`). Three pages with a back chevron in the header: **main** ("Account"), **plan**
("*[demo] Pro"), **credits** ("Credits"). Background updates don't re-render while you're typing in the sheet
(`refreshAccount` waits for focus to leave). `openAccount(k)` with a feature key opens the **paywall** for Free users
instead (admins excepted), or the plan page for others.

### 6.1 Profile hero
Round avatar button ("Change photo", camera badge) → photo picker, centre-crop **256×256 JPEG 0.85**, saved to the
profile (toast "Photo updated"). No photo: initials (first + last word) or a person glyph. Name = display name ||
username || Apple/Google name || "Your account"; "Pro" badge when on paid Pro. Line under: "@handle" and email (dimmed).

### 6.2 Name & Username
Row value "@handle" or "Not set" (blue). Tap → inline section "Name & username" with **Cancel** / **Save**: **Name**
("Shown on song credits") and **Username** ("@" prefix shown; "@" and spaces stripped as you type). Enter saves, Escape
cancels; drafts survive re-renders. Rules: lowercased, `^[a-z0-9_]{3,20}$` else "Usernames are 3–20 characters:
letters, numbers, underscores."; taken → "That username’s taken."; reserved → "That username’s reserved. If it’s your
name, get in touch through hellodemo.app and we’ll set it up for you." Success "Saved"; then (if a username was set)
asks for notification permission with "You’ll get a notification when someone invites you to a song." Renaming
re-credits songs still showing your old auto artist name.

### 6.3 Notifications (iPhone only)
Row value **On** / **Off** / **Turn On** (blue). Not determined → system prompt (toast "Notifications are on");
denied → "Notifications are off for *[demo]. Turn them on in Settings › *[demo] › Notifications."; granted → expands
switches (server prefs `my_notify_prefs` / `set_notify_prefs`, default on):
- **Co-writing** — "When someone accepts your invite or edits a song you share"
- **Writing reminders** — "A gentle nudge after a few days away, at most once a week" (time zone sent so it lands
  around 6 pm local)
- **Account & Pro** — "Beta access, Pro and your free trial"
- **Share link plays** — "When someone opens a song you shared, once a day"
- Note: "Invites and replies from *[demo] Support always come through. To turn everything off, use Settings › *[demo] ›
  Notifications."
Push handling (18746): registration token stored (`songpad:pushtok`) and registered with topic = bundle id
(`app.hellodemo.demo` / `.dev`). Foreground pushes: invite → refresh invites (banner); support → toast "*[demo] Support
replied. See Account › Contact Support."; co-write on the open song → pull it; account → refresh plan + toast title;
other → toast "title: body". Tapping a notification: invite/support/account → opens Account (the code sets
the support section to expand, but `openAccount('')` then resets it — a bug; expand it natively); `song` → opens that
song; `open:'songs'` → list. Sign-out unregisters the token. Permission is never asked
at launch — only at moments that explain it (after setting a username, after contacting support).

### 6.4 Links
Section "Links" with **Edit** (→ **Cancel** / **Save**): Spotify ("Paste your artist link"), Instagram ("@username"),
TikTok ("@username"). Display value: "@handle" for Instagram/TikTok, "Artist page"/"Connected" for Spotify, "Add" when
empty; tapping a set link opens it. Normalisation: bare handles → `https://instagram.com/<h>`,
`https://tiktok.com/@<h>`, `https://open.spotify.com/artist/<id>`; anything else gets `https://`.

### 6.5 Invitations
`#acc-invites` (hidden when none): "Invitations" + rows: owner avatar, song title, "from <name> · **Block**",
**Accept** / **Decline** (toast "Joined “T”" / "Invite declined"). Block: confirm "Block <name>?\n\nThey won’t be able to
invite you to songs. They aren’t told." → declines their pending invites, toast "Blocked <name>. To report them, email
help@hellodemo.app". Invites are polled every 45 s and on push/realtime ping.

### 6.6 Plan row and plan page
Main page plan row (`.accplan`): Pro → "*[demo] Pro" + **Active** badge, "Renews 12 Nov 2026" or "Everything’s
unlocked"; Beta → "*[demo] Beta", "Everything’s unlocked during the beta"; Free → "*[demo] Pro", "Demos, co-writing,
lyric sync and more" + capsule **Go Pro** (→ paywall). Otherwise tap → plan page:
- Reason message (from the gate that opened it) when not Pro.
- Beta: card "*[demo] Beta" / "Everything’s unlocked while *[demo] is in beta."
- Pro: logo, "*[demo] Pro **Active**", "Renews 12 November 2026" / "Thanks for supporting *[demo].", meter "Rates this
  month" "N of 100" (`PLAN.heavy_month`), "Included" list (the 7 paywall features).
- Free: card "Free" / "Unlimited songs, rhymes and ideas. Free for good."
- Admins: "Testing" → "Preview the Free plan" switch ("On: your account is on Free until you turn this off." / "See
  *[demo] exactly as a free user does."; toasts "You’re on the Free plan" / "Back to your full plan").
- Not Pro: **See What’s in Pro** (paywall). Pro via App Store: **Manage Subscription** (system manage sheet, fallback
  `https://apps.apple.com/account/subscriptions`) · **Restore Purchases**.

### 6.7 Credits page
Lists songs with a title and status **Finished** that you own, co-write, or that are unshared. Empty: "**No credits
yet**" / "Mark a song Finished and it shows up here." Stats strip: N **Songs** / N **Written** / N **Co-written**
(co-written = shared and not owner, or any credit name that isn't you). Rows: cover, title, "Written" or "Co-written
with Sam & Ana" (+N when >2), your split "50%", release "Mar 2026"; tap opens the song. Reached from main page row
**Credits** (value = number of Finished songs).

### 6.8 Your songs
**Credits** (→ page), **Import Songs**, **Export All Songs** (same as list footer, §3.7), **Storage** "1.2 GB of 5 GB"
(red when full; refreshed every time Account opens, at most every 15 s; `rpc my_storage`). Default limit fallback in
error copy is 150 MB; the paywall promises 5 GB for Pro; admin copy mentions "The free plan has 1 GB in total".

### 6.9 Muse & privacy
- **AI Features** On/Off (blue "Off"): turning off → `songpad:aiconsent='no'`, toast "AI features are off"; turning on →
  shows the consent prompt again, toast "AI features are on". Note under the section: "AI features send what you’re
  working on to OpenAI." (or "Anthropic (Claude)" in the Claude-artifact runtime).
- **Reset What Rate Learned** → clears `rating.personality` on every song, toast "Rate will learn your style fresh".
- **Blocked** (only if any): count, expands to rows with **Unblock** (toast "Unblocked @x").

### 6.10 About & support
**Privacy Policy**, **Terms of Service** (in-app browser). **Contact Support** (value "1 reply"/"2 replies" when answered)
expands the support form (`supForm`, 18482):
- Topic picker: Something’s not working / Account or sign-in / Subscription or billing / Idea or request / Something else.
- Message (max 4000): placeholder "What’s happening? What were you doing when it went wrong? The more detail, the faster
  we can help."
- Checkbox **Include diagnostics** (on): "Your app version, device, plan, sync status and recent error messages. Never
  your lyrics or songs." (payload in `diagReport`, 18457: build, seq, platform, device/screen, language, time zone,
  online, signed in, provider, plan, IAP state, sync state, counts, storage, local storage sizes, paused flags, last
  25 log lines with quoted names and tokens scrubbed; ≤11.5 KB).
- **Send** ("Sending…"); under 3 chars → "Write a little more so we can help."; success "Sent. We’ll reply by email." then
  the push permission ask "You’ll also get a notification when we reply."; failure "Couldn’t send your message: …".
- "We reply by email to <email>, usually within a day."
- "Your messages": each ticket with topic (or "From *[demo]" for admin-initiated), status "Waiting for a reply" /
  "Answered" / "Closed", relative time ("just now", "5 min ago", "3 h ago", "2 d ago", date), message, replies
  ("*[demo] · 2 h ago").

### 6.11 Account actions
- **Switch Account** — signs out and the next Google sign-in forces the account chooser.
- **Sign Out** (red) — confirm "Sign out of *[demo]?" / "Your songs stay safe in your account." Clears plan cache, the
  on-device audio cache, push registration, live/sync channels; shows the auth gate.
- **Delete Account** (red) — confirm "Delete your account?" with body: "Your songs, ideas, recordings, share links and
  profile are deleted from your account, and songs you share stop being shared. Copies on your other devices go when you
  sign out there. If you pay for Pro through Apple, cancel it in Settings › your name › Subscriptions: deleting your
  account doesn’t stop billing. This can’t be undone." Flow (19750): delete every stored file under the user's folders
  in `song-files` and `shares` (100 per batch), then `rpc delete_my_account`, clear every local key containing the uid
  and local memo blobs, sign out, toast "Your account and everything in it has been deleted." Errors "Couldn’t delete
  your account: …".
- **Version** footer: "Version 9adeae1" (selectable text) = `APP_COMMIT`.
- Dev build adds a "Developer" group: Mac daily AI request limit (Default 400 / 1,000 / 5,000 / Unlimited) and "Test
  invite notification (3s delay)".
- Signed out (not normally reachable): Sign in with Google / Apple buttons.

---

## 7. Plans, Pro gates and upsell keys

Plans come from the server (`rpc my_plan` → `{tier, expires_at, beta_unlocks, storage_limit, heavy_month, sync_month}`),
cached in `songpad:plan` (bound to the user id), refreshed on sign-in and on foreground if >60 s old. Tiers: `free`,
`pro` (paid or admin-granted), `beta` (everything unlocked during beta). **`isPro()` is `tier !== 'free'`**, so Beta
counts as Pro everywhere. Prices `PRICE={month:'A$8.99', year:'A$69.99', trial:7}`; `FREE_MEMOS=10`,
`FREE_MEMO_SECS=60`.

`applyPlan()` (19331) on change: toggles `body.pro`; account tag shows "Pro"/"Beta"; when Free it forces "Listen to the
whole song" off, Lines off, rate mode off, adds lock styling to Rate/Voice/Listen buttons and a "Pro" tag to **Lines**
and **Perform**; when Pro it turns "Listen to the whole song" back on.

`upsell(k, msg?)` shows the Pro banner with `upsellMsg(k)`: "<FEAT[k]> is part of *[demo] Pro." except `memos` ("Free
keeps 10 voice memos on this device, up to a minute each. Pro syncs them everywhere, with no limit.") and `ai` ("You’ve
used today’s free AI. Pro has plenty more."). `FEAT` (19320): lines "Lines", rate "Rate", perform "Perform mode", voice
"Writing voice", listen "Listening to the whole song", melody "Melody", share "Inviting co-writers", muse "Muse", audio
"Adding music and files", sync "Lyric sync", play "Play with Lyrics", release "Release details", memos "More voice
memos", ai "More AI".

| # | Gate (line) | What's blocked on Free | Behaviour |
|---|---|---|---|
| 1 | `irecStart` 15206 | 11th voice memo | `upsell('memos')` |
| 2 | memo timer 15228 | memo longer than 60 s | auto-stop + toast (Pro 600 s) |
| 3 | `ideaMemoUpload` 15252 / `ideaMemosPending` 15257 | uploading memos to the cloud | silently stays on device |
| 4 | `ideaMemoToSong` 15305 | memo → song audio | `upsell('audio', 'Your voice memo stays in Ideas. Pro adds recordings to songs.')` |
| 5 | Learn My Voice 15860 | building the voice profile manually | `upsell('voice')` |
| 6 | `dtab('mel')` 15927 | Melody pane | `upsell('melody')` |
| 7 | `dtab('rel')` 15927 | Credits & release tab | `upsell('release')` |
| 8 | phrase rhymes 16591 | 2–8-word selection rhymes | inline hint (no banner) |
| 9 | `mzProfAuto` 16840 | automatic voice-profile learning | silent |
| 10 | `mlist` AI fallback 16959 | AI word lists when Datamuse has nothing | empty list |
| 11 | `rankGet` 17038 | ranking rhymes for the song | silent |
| 12 | `#ctxb` 17084 | Listen to the whole song | `upsell('listen')` |
| 13 | Muse "Rate my song" 17104/17107 | Rate | locked card + `upsell('rate')` |
| 14 | Share Song (collab) 17542 | inviting co-writers | Pro tag + `upsell('share')` |
| 15 | `rateClick` 17687 | Rate button | `upsell('rate')` |
| 16 | `sfCanPlay` 19793 (`sfLocked` 19798) | playing/opening a co-writer's uploaded audio/files | lock icon + `upsell('audio', '<Name> added a recording. Go Pro to listen and add your own.')` |
| 17 | `sfAdd` 19944 | adding audio versions / files | `upsell('audio')` |
| 18 | `runSync` 20128 | lyric sync | `upsell('sync')` |
| 19 | `openPlay` 20252 | Play with Lyrics | `upsell('play')` |
| 20 | `shLinkMake` 20535 | audio inside share links | link is made without audio |
| 21 | Perform 20628 | Perform mode | `upsell('perform')` |
| 22 | `#gear` 20632 | Writing voice sheet | `upsell('voice')` |
| 23 | `#lm` 20634 | Lines mode | `upsell('lines')` |
| 24 | `applyPlan` | ctx/Lines/rate mode forced off | — |

**Not gated** (Free gets them): writing, rhyme bar word modes (Datamuse + built-in), Define (incl. AI fallback),
Dictionary, rhyme map, syllable counts, Clean up, Muse sheet incl. **Read my song** (AI), song brief, wild cards,
sprints, versions, import/export, share image, share links (lyrics only), Ideas (10 memos ≤60 s, device only).
The `muse` and `ai` keys have messages but no client-side trigger in this build (server quota errors surface as the
feature's own error text). Server-side the AI proxy also enforces quotas; the client-side baked-key guard (20/min,
400/day) only applies to the OpenAI-key fallback.

---

## 8. Dev / admin dashboard (dev build only)

`DEV_BUILD` is true in the Mac "[developer]" app (`window.desktop.devBuild`) or an iOS build whose bundle id ends in
`.dev` (then the auth scheme is `demo-dev`). It adds a DEV pill, title "[developer]", and opens on `#vDash` with a glass
tab bar `#dtabs`: **Dashboard** · **Songs** (the normal app) · **Users** · **Help** (badge = open tickets) · **More**.
Everything requires the admin account (dev@hellodemo.app); otherwise "Sign in as the admin" / "This account isn’t the
admin" / "The dashboard is for dev@hellodemo.app. Your songs are under Songs." Data refreshes every 2 min and on
foreground. (Non-dev builds show the same tools in sheets `#sheet11` Admin and `#sheet10` Beta Requests for the admin.)
Brief contents (`admRender`, 18318; tabs Overview / Help / Users / Errors / Status / Debug / Settings):
- **Dashboard/Overview** — stat tiles with coloured icons: Accounts, New today, Signed in today, Waiting for beta,
  Storage used, AI units today, Errors today, Help desk, Services, Songs; "New Accounts per Day" chart (24 h / 7 d /
  30 d); shortcuts.
- **Users** — search "Search email, username or name"; user detail page ("‹ All Users"): plan chips (Free/Pro/Beta via
  `admin_set_plan`), access on/off (`admin_set_access`, shows invite code), devices & builds, recent errors, notes,
  "View Account", "Copy Email", "Copy Details".
- **Help** — help-desk inbox (`admin_tickets`): open/answered/closed, reply box ("Reply to …", **Send Reply**, toast
  "Reply emailed to …"), private note ("Private note, only you see it"), Close/Reopen, diagnostics summary line.
- **More** → Beta Requests (waitlist lock switch, Waiting/Approved/Declined lists, Approve/Decline/"Approve Instead",
  copyable invite codes; approving emails the TestFlight link + code), Errors ("Grouped by message. Reports never
  include lyrics, and song and file names are removed."), Service Status (groups "Your app", "Your providers",
  "Platform status"; **Check Now**), Settings (remote banner, pause AI / sync / uploads, minimum build, "Beta Unlocks
  Everything" switch, "Storage per Account (MB)"; "Changes apply straight away for everyone."), Debug (local log,
  sign-in trace, **Copy Diagnostics**), and external links (Supabase Dashboard, Supabase Users, Edge Function Logs,
  Resend Emails, OpenAI Usage).
- *Native: Small–Medium; can stay web-only (or a separate internal target) — recommend not porting to the consumer app.*

---

## 9. Settings persisted locally (localStorage) that affect UI

| Key | Content | Effect |
|---|---|---|
| `songpad:v1:<uid>` (`K+':'+uid`) | songs array | library (bare `songpad:v1` = legacy signed-out) |
| `songpad:devmode:v1` | songs | legacy Dev Mode library (removed feature) |
| `songpad:ideas:v1:<uid>` | ideas array | Ideas |
| `songpad:guide:<storageKey>` | number | guide song version seeded |
| `songpad:prefs` | Writing voice object | default voice for songs without `pf` |
| `songpad:view` | `{map, syl, ctx}` | Rhyme map / Syllables / Listen toggles |
| `songpad:pins` | `{songId: ts}` | Pinned group (device-local) |
| `songpad:seen` | `{songId: lyrics}` | "X added N lines" hint |
| `songpad:rtone` | `enc`/`bal`/`blunt` | Rate feedback tone |
| `songpad:linepref` | `{perfect, near, loose}` counts | nudges AI toward slant rhymes |
| `songpad:aiconsent` | `yes`/`no`/absent | AI consent |
| `songpad:muse:ev\|pend\|prof[:<uid>\|:dev]` | muse memory events, pending checks, voice profile | AI personalisation |
| `songpad:plan` | plan object | Pro gating offline |
| `songpad:beta:<uid>` | `ok` | skip beta gate flash |
| `songpad:cfg` | remote config | banner, pauses, forced update |
| `songpad:banner-x` | banner id | dismissed remote banner |
| `songpad:profile:<uid>` | profile cache | name/avatar before network |
| `songpad:pushtok` | APNs token | push registration |
| `songpad:device` | UUID | device id for sync/live echo suppression |
| `songpad:acache` | `{path:[size,lastUsed]}` | on-device audio cache index (blobs in IndexedDB `songpad/audio` as `c:<path>`) |
| `songpad:sync:base\|tomb:<uid>` | sync bookkeeping | library sync (`data-and-backend.md`) |
| `songpad:signedout` | `1` | stay signed out |
| `songpad:oauthpend` | timestamp | OAuth callback guard |
| `songpad:bakedusage` (+`:build`) | `{date,count}` | client AI quota for baked-key fallback |
| `songpad:devbuild` | `1` | dev styling before JS loads |
| `songpad:devprofile`, `songpad:devmode`, `songpad:mp3`, `songpad:writer` | — | obsolete, removed on launch |
| Supabase `sb-cygfgurzvmbtcegkpnss-auth-token` | session | auth |

IndexedDB `songpad` v1, object store `audio`: `f:<id>` local-only files and memos, `<songId>` melody recordings,
`c:<storagePath>` cached cloud audio. *Native: SwiftData/SQLite for library + files in Application Support; UserDefaults
for the small prefs above; Keychain for the session.*

---

## 10. Visual system (for parity)

- Theme tokens (CSS lines 22–25): light — bg `#fff`, ink `#000`, mute `rgba(60,60,67,.6)`, separator
  `rgba(60,60,67,.16)`, tint `#1C1C1E` (the app's accent is near-black / near-white, not blue), fill
  `rgba(118,118,128,.12)`, red `#FF3B30`, sheet `rgba(242,242,247,.8)`, glass `rgba(250,250,252,.72)`, slate `#8E8E96`;
  dark — bg `#000`, ink `#fff`, mute `rgba(235,235,245,.6)`, tint `#F2F2F7`, red `#FF453A`, sheet `rgba(28,28,30,.86)`,
  glass `rgba(58,58,62,.58)`. Follows system appearance (an unused `data-theme` override exists).
- Typography: system font (SF Pro); editor lyrics are large body text; Perform 34 pt default.
- Muse button: diagonal gradient (dark: `#6B4A5E → #4E3F7A → #2F4E72`).
- Spring easing token `--spring` (CSS 1166) used for sheet/row animations; reduce-motion respected throughout.
- Rhyme map colours: `rgba(255,149,0,.30)`, `rgba(52,199,89,.28)`, `rgba(0,122,255,.24)`, `rgba(175,82,222,.26)`,
  `rgba(255,45,85,.24)`, `rgba(90,200,250,.34)`, `rgba(255,204,0,.38)`, `rgba(162,132,94,.32)`.
