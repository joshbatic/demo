# *[demo] native iPhone client: data & backend spec

Source of truth for this document: `www/index.html` at build `APP_COMMIT='9adeae1'`, `APP_SEQ=413`, plus
`supabase/*.sql`, `supabase/functions/*`, `share/api/s.js`, and the live column list of the base tables
(read from project `cygfgurzvmbtcegkpnss` on 23 Oct 2026). JS line references are into the main `<script>`
block (the app code starts after the embedded rhyme `DATA` blob, roughly `index.html` line 15084 onward).
Quoted snippets are only included where the exact logic matters.

Conventions used below:

- **ms** means a JavaScript millisecond epoch (`Date.now()`), stored as a JSON number. Almost every timestamp
  *inside* JSON blobs is ms. Postgres columns are `timestamptz` (ISO strings over PostgREST).
- **"local-only"** means the web app keeps it in `localStorage` or IndexedDB on the device and never sends it.
- Any song or idea key starting with `_` is device-local bookkeeping. It is stripped before anything is
  written to the cloud (`libClean`, `ser`) and must never be uploaded.
- **Preserve unknown fields.** The web and Mac clients will keep writing to the same rows. A native client
  must round-trip every key it doesn't understand on songs, ideas, audio and file items. If it doesn't,
  the next sync deletes those fields for everyone.

---

## 0. Quick reference

| Thing | Value |
|---|---|
| Supabase URL | `https://cygfgurzvmbtcegkpnss.supabase.co` (`SB_URL`, app.js line ~1316) |
| Anon / publishable key | `SB_KEY` on the same line (public JWT, role `anon`; also copied into `supabase/service-status.sql` and `notify.sql` cron jobs) |
| supabase-js used by web | `@supabase/supabase-js@2.45.4` UMD, `createClient(SB_URL, SB_KEY, {auth:{persistSession:true, autoRefreshToken:true, flowType:'pkce'}})` |
| Song-files bucket | `SF_BUCKET = 'song-files'` (private) |
| Share bucket | `SHARE_BUCKET = 'shares'` (public read by URL, not listable) |
| Share page base | `SHARE_BASE = 'https://listen.hellodemo.app/'` + 10-char id |
| OAuth redirect | `demo://auth-callback` (App Store / TestFlight build), `demo-dev://auth-callback` (dev build) |
| Bundle ids / APNs topics | `app.hellodemo.demo`, `app.hellodemo.demo.dev` (dev features turn on when the app id ends in `.dev`) |
| RevenueCat | `RC_KEY = ''` (empty: purchases are not live yet), entitlement `RC_ENT = 'pro'`, packages `offerings.current.monthly` / `.annual` |
| Prices shown | `PRICE = {month:'A$8.99', year:'A$69.99', trial:7}` (fallback when the store price isn't loaded) |
| Build stamps | `APP_COMMIT` (git short hash, shown in Account › Version), `APP_SEQ` (integer build sequence, compared with `app_config.min_seq`) |
| Device id | `LIB_DEV`, a UUID kept in `localStorage['songpad:device']`, created on first launch |

---

## 1. Data model

### 1.1 Song object

Songs are plain JSON objects held in the array `songs`. The same object shape goes into localStorage,
`cloud_library.data.songs[]`, `shared_songs.data`, backups and imports.

#### Core text fields (all strings unless noted)

| Field | Type | Notes |
|---|---|---|
| `id` | string | **UUID v4** (`crypto.randomUUID()`). Legacy or imported songs may have `'s' + Date.now() + rand(0..9999)` ids (`fromText`). Sharing a song with a non-UUID id gives it a new UUID first (moves its IDB melody blob and pin). `shared_songs.id` is text but RLS helpers compare `::text`, and the app requires a UUID before sharing. |
| `title` | string | `''` = untitled. The list shows `title` or else the first lyric line, or else "New Song". |
| `lyrics` | string | Plain text, `\n` line breaks. **The canonical text.** Section headers are lines that match `^\s*\[[^\]]+\]\s*$` (e.g. `[Chorus]`). Lines starting with `[` are excluded from "lyric lines" for previews, the muse and sync. |
| `rich` | string (HTML) | The formatted copy of `lyrics`. See §1.2. May be `''` or missing. |
| `chords` | string | Free text (chord chart). |
| `notes` | string | Free text. |
| `artist` | string | Credit line. New songs get `myName()`. |
| `folder` | string | `''` = no folder ("Songs" group). Folders are *implicit*: see §1.6. |
| `status` | string | One of `Idea` (default), `Draft`, `Demo`, `Finished` (the `<select id="f-status">` options). Import can bring any string. "Finished" songs are listed under Credits in Account. |
| `key` | string | `''` or one of `C C# D Eb E F F# G Ab A Bb B`, optionally with `m` suffix for minor (`KY` array). |
| `bpm` | string **or number** | The input writes a **string** (`'120'`). Live co-writing patches convert numeric strings to a **Number** (`liveApply`). Decode both, and write a string. |
| `tuning` | string | Free text, placeholder "Standard". |
| `capo`, `time` | string | Always `''` in new songs. There's no UI any more. Import parses `Capo:`. Keep them round-tripped. |
| `updated` | number (ms) | **The conflict clock.** Every edit sets `updated = Date.now()`. See §2. |
| `created` | number (ms) | Only set on the built-in guide song. Normally absent. |

#### Structured fields

| Field | Shape | Notes |
|---|---|---|
| `pf` | Writing voice object (`mkPF`), see §1.3 | Per song. New songs get `mkPF({})`. |
| `art` | string | Cover art as a **data URL**: `data:image/jpeg;base64,...`. The app centre-crops the picked image to **480×480**, JPEG quality 0.8 (`canvas.toDataURL('image/jpeg',.8)`). Only values matching `^data:image\/(jpeg\|png\|webp\|gif);base64,[A-Za-z0-9+/=]+$` are ever displayed (`artOk`). Anything else (such as a URL a co-writer injected) must be ignored. `''` or missing means the generated default cover (§1.8). It's stored **inline in the song JSON**, so each cover costs roughly 30–60 KB in every sync payload. |
| `audio[]` | array of audio items (§1.4) | Audio versions. Exactly one should have `cur:true` (the "current" version). |
| `files[]` | array of file items (§1.4) | Stems, artwork, sessions, other. |
| `rmFiles` | `{ [fileId]: ms }` | File tombstones (§3.6). Merged across copies, and they always win. |
| `sync` | object | Synced lyric timings (§1.4.3). |
| `credits[]` | `[{name:string, role:string, split:string}]` | `role` ∈ `Writer, Composer, Lyricist, Producer, Performer, Featured artist, Mix engineer, Mastering engineer, Other`. `split` is a **string** percentage (`'50'`, `'33.33'`, or `''`) and is only meaningful for `Writer/Composer/Lyricist`. When the role changes to a non-split role, `split` is set to `''`. The first credit added defaults to `{name: myName(), role:'Writer', split:'100'}`. "Split Evenly" puts the rounding remainder on the first writer. |
| `release` | `{isrc?, upc?, date?, label?, genre?, explicit?:bool}` | Strings except `explicit`. ISRC is uppercased and validated against `^[A-Z]{2}-?[A-Z0-9]{3}-?\d{2}-?\d{5}$`. UPC is digits only, 12–13 long (a warning only). `date` is `YYYY-MM-DD` from `<input type=date>`. |
| `versions[]` | `[{t:ms, lyrics:string, rich:string, label:string}]` | Snapshots. `label` ∈ `'Auto'`, `'Saved'`, `'Before restore'`, `'Before clean-up'`, or `''`. Max **30** (oldest shifted off). No duplicate is added if lyrics and rich equal the last one. An auto-snapshot happens on opening a song if the last one is over 2 h old. A snapshot does **not** bump `updated`. When local storage is full, `saveLocal` trims to the last 10 and blanks `rich` on all but the last 3. Shared copies keep only the last **8** (`ser`). |
| `melody` | `{name, dur:number, sens:number, apply:string, phrases:[{start, end, notes:[{t, d, m, s:0\|1, l:0\|1}]}]}` | Hummed melody analysis (Pro). `apply` = `'all'` or a section key. **The source audio is only in the device's IndexedDB** (`audio` store, key = song id), so it isn't synced. |
| `rating` | object | Last "Rate" result (§1.4.4). |
| `intents[]` | `[{quote:string, why:string, t:ms}]` | Lines the writer marked "meant that way" in Rate. |
| `brief` | `{who?, to?, where?, thing?, more?}` | Song brief strings (each ≤160 chars, `more` ≤600). Deleted when empty. |
| `scheme` | string | Rhyme scheme hint: `auto` (default when missing), `ABAB`, `AABB`, `ABBA`, `ABCB`. |
| `shares` | `{ [userId]: {id, at:ms, audio:bool, by:userId, aid:audioId\|null, aname:string\|null} }` | This user's share link per writer (§4.4). |
| `share` | `{id, at, audio, by?, ...}` | **Legacy** single-slot share link. Read it if it's yours (`by===uid`, or no `by` and you own the song or it isn't shared). Delete it when you write `shares`. |
| `ph` | `1` | Placeholder "empty folder" song (§1.6). |
| `guide`, `guideAt` | `true`, ms | Built-in guide song (§1.7). |

#### Collaboration fields (on the song itself)

| Field | Type | Notes |
|---|---|---|
| `shared` | bool | True if the song is co-written through `shared_songs`. It's in `cloud_library` but **excluded** from `shared_songs.data` (`ser` drops it). |
| `owner` | uuid string | Owner's auth user id. |
| `ownerEmail` | string | Owner's email. |
| `members` | `[uuid]` | Advisory only. `[owner]` at share time, and an acceptor appends themselves. Don't rely on it for permissions (the server is authoritative; see the `syncShared` comment). |
| `lastEditBy` | string | **Email** of the last person to push the shared copy (set in `pushShared`). Live patches overwrite it with the sender's display **name** (`x.who`), so it can hold either. The "Sam added 3 new lines" hint takes `lastEditBy.split('@')[0]`, capitalised. |
| `lastEditAt` | ms | Set in `pushShared`. |

#### Device-local keys (never uploaded)

`_autoArtist` (the auto-assigned artist name, used to tell when the artist was hand-edited), `_pushed` (ms of
the last `updated` pushed to `shared_songs`), `_warned`, `_conv`. **`_autoArtist` is local-only**, so
re-crediting logic on another device sees it as missing.

#### Example

```json
{
  "id": "3b0c6c2e-1d0e-4f7a-9b6e-2f2c3e1a9d10",
  "title": "Glenelg",
  "lyrics": "[Verse]\nBlue Corolla, cracked windscreen\n...",
  "rich": "<span style=\"font-weight: bold; color: rgb(142, 142, 150);\">[Verse]</span><br>Blue Corolla, ...",
  "chords": "", "notes": "", "artist": "Josh", "folder": "Summer", "status": "Draft",
  "key": "G", "bpm": "92", "tuning": "", "capo": "", "time": "",
  "pf": {"genre":"Any","mood":"Any","voice":"Neutral","dial":"","era":"Any","pov":"Any","tense":"Any","img":[],"dev":[],"reg":"Conversational","strict":true,"cliche":false,"refs":"","custom":""},
  "audio": [{"id":"...","name":"Demo 1","path":"<uid>/<songId>/<fileId>.mp3","size":4123456,"mime":"audio/mpeg","added":1761200000000,"kind":"Demo","dur":182.4,"cur":true,"peaks":[12,40,...]}],
  "files": [], "rmFiles": {},
  "sync": {"audioId":"...","at":1761200000000,"sig":"Blue Corolla...\n...","lines":[{"text":"Blue Corolla, cracked windscreen","t":12.4}],"timed":18,"total":20},
  "versions": [{"t":1761100000000,"lyrics":"...","rich":"...","label":"Auto"}],
  "updated": 1761234567890
}
```

### 1.2 `rich` vs `lyrics`

- `rich` is the `innerHTML` of the contenteditable lyric editor. Line breaks are `<br>` (Enter is forced to
  `insertLineBreak`, so there are no `<div>`/`<p>` blocks from the web, though they're tolerated). Formatting
  comes from `document.execCommand` with `styleWithCSS=true`, which produces `<span style="...">` with
  `font-weight: bold`, `font-style: italic`, `text-decoration: underline|line-through`, `color: <hex/rgb>`
  and `background-color: rgba(...)`. Older content can contain `<b> <i> <u> <s> <strike> <strong> <em> <font color>
  <mark>`.
- Palette: text colours `Rose #E5566F, Amber #D4881C, Moss #4E9A5B, Tide #2C8DBF, Indigo #5D6BE0,
  Plum #A35FCB, Slate #8E8E96`. Highlights (background): `Hook rgba(255,204,0,.38)`, `Rework rgba(255,69,58,.24)`,
  `Idea rgba(10,132,255,.22)`. Section tags are auto-styled **bold and slate** (`--slate`, default `#8E8E96`) by
  `tagBold()`. Hook highlights feed the learned voice ("favourite lines").
- **Sanitising (must be replicated when rendering anyone's `rich`)**, from `clean(h)`. Allowed elements:
  `B I U S STRIKE STRONG EM SPAN BR FONT MARK DIV P`. All others are removed *with their content*. All
  attributes are removed except `style` (and `color` on `FONT`). A `style` is dropped entirely if it contains
  `url(`, `expression`, `@` or `\`, or contains characters outside `[\w\s:;#.,%()\-]`. Otherwise only the
  declarations `color, background-color, background, font-weight, font-style, text-decoration,
  text-decoration-line, text-decoration-color` survive, and none mentioning `position/fixed/absolute`.
- **Relationship rules:**
  1. On every edit the web writes both: `lyrics = plainText(editor)` and `rich = editor.innerHTML` (the input
     handler at line 5552). Plain text is computed by walking text nodes, with `<br>` → `\n` (trailing `\n` dropped).
  2. **Display prefers `rich`**: `setLyr` shows `clean(rich)` if `rich` is non-empty, else the escaped
     `lyrics` with `\n`→`<br>`. So **if you change `lyrics` without producing a matching `rich`, set
     `rich = ''`**. Otherwise other clients will display the stale formatted text. The web does exactly this in
     `liveApply` and in Clean up.
  3. Never treat `rich` as the source of the text. Rhymes, sync, the muse, the share page and the cover
     drawing all use `lyrics`.
- Perform mode renders `clean(rich)` or the escaped lyrics.

### 1.3 Writing voice (`pf`, `mkPF`)

```js
var PDEF={genre:'Any',mood:'Any',voice:'Neutral',dial:'',era:'Any',pov:'Any',tense:'Any',img:[],dev:[],
          reg:'Conversational',strict:true,cliche:false,refs:'',custom:''};
function mkPF(o){var p=deepcopy(PDEF);o=o||{};Object.keys(o).forEach(function(k){if(k in PDEF)p[k]=o[k]});
  if(o.style&&!o.genre&&o.style!=='Any')p.genre=o.style;return p}
```

`mkPF` is "defaults + known keys only", plus a migration of the old `style` key into `genre`. `img` and `dev`
are string arrays (multi-select). `strict` is "Perfect only" rhymes, and `cliche:true` means avoid clichés.
Opening a song sets the active voice to `mkPF(song.pf || globalPrefs)`. Changing it writes **both**
`song.pf` (bumping `updated`) and `localStorage['songpad:prefs']` (the last-used voice, the default for
songs without `pf`).

### 1.4 File items, sync, rating

#### 1.4.1 Audio item (`song.audio[]`)

```json
{ "id": "<uuid>", "name": "Demo 1", "path": "<uploaderUid>/<songId>/<id>.<ext>" | "local:<id>",
  "size": 123, "mime": "audio/mpeg", "added": 1761200000000,
  "kind": "Voice memo" | "Demo" | "Mix" | "Master" | "Other",
  "dur": 182.4, "cur": true, "peaks": [0..100 x 180],
  "orig": {"name":"Demo 1.wav","size":40000000,"mime":"audio/wav"} }
```

- `kind` is guessed from the filename (voice/memo/recording → Voice memo, master, mix, else Demo).
- `peaks`: 180 integers 0–100 (`round((v/max)^0.7*100)`). They're computed on the device after upload, and
  the song is re-saved.
- `dur`: seconds, 1 decimal.
- `cur`: exactly one should be true. Adding an item makes it current. Deleting the current one makes the last
  item current.
- `orig` is present when the file was converted to MP3 on the device. WAV/AIFF/FLAC are always converted
  before upload at **256 kbps stereo or 160 kbps mono**, resampled to 44.1 or 48 kHz if above 48 kHz. Converting
  an existing item gives it a **new id and path**, and `sync.audioId` is updated to match.
- The uploader is the first path segment (`sfOwner`). "Mine" = uploaded by me or `local:`.
- `path: "local:<id>"` means the bytes are only on the device (IndexedDB key `f:<id>`). That happens when
  signed out / Dev Mode, or for an idea memo that hasn't uploaded yet.

#### 1.4.2 File item (`song.files[]`)

The same shape without `cur/dur` (`peaks/orig` are possible). `kind` ∈ `Stem, Artwork, Session, Other`, guessed
from the name or MIME (stem/vox/vocal/drum/bass/guitar/keys/synth/perc → Stem; `image/*` → Artwork;
`.logicx .als .flp .ptx .rpp .band .cpr .song .zip` → Session).

#### 1.4.3 `song.sync` (lyric timings)

```json
{ "audioId": "<audio item id>", "at": 1761200000000, "sig": "<lyric lines joined by \\n>",
  "lines": [{"text": "line as written", "t": 12.4}], "timed": 18, "total": 20 }
```

`lines` holds only non-blank, non-`[section]` lines in order. `t` is seconds to 2 decimals. `sig` is used to
notice that the lyrics changed after syncing. Deleting the referenced audio item deletes `sync`. The alignment
algorithm is described in §7.3.

#### 1.4.4 `song.rating`

The AI's JSON (`modelTier:'complex'`), filtered, plus bookkeeping:

```json
{ "world":"...", "personality":"...(<=300 chars)", "intent":"...", "overall": 0-100?, "verdict":"...",
  "potential":{"score":n,"how":"..."},
  "scores":{"cleverness":{"score":n,"why":""},"legibility":{...},"cohesion":{...},"voice":{...}},
  "strengths":[{"quote":"","role":"","note":""}],
  "issues":[{"quote":"","role":"","problem":"","check":"","confidence":0.0-1.0,"fix":""}],
  "t": ms, "scope": "song"|"sec"|"sel", "tone": "enc"|"bal"|"blunt", "prev": number|null, "marks": true }
```

Issues with `confidence < 0.72`, or whose quote overlaps a strength, are dropped before saving.
`rating.personality` across songs feeds the voice profile. Account › "Reset What Rate Learned" blanks it on every
song.

### 1.5 Ideas

Stored in the array `ideas` and synced inside `cloud_library.data.ideas` (§2).

```json
{ "id": "<uuid>", "text": "a line or caption", "kind": "line" | "idea" | "concept" | "memo",
  "tags": [], "created": ms, "updated": ms,
  "used": "<songId>",
  "memo": { "id": "<uuid>", "path": "<uid>/ideas/<memoId>.<ext>" | "local:<memoId>",
            "mime": "audio/mp4", "size": 12345, "dur": 12.3, "peaks": [60 ints 0..100], "pend": true } }
```

- `kind`: a typed jot is `line`. A memo with no caption is `memo`, and becomes `line` once text is added (and back
  to `memo` if the text is cleared). `idea`/`concept` exist in the data model (`IKINDS`), but the current UI only
  creates `line`/`memo`.
- `tags`: always `[]` in the current UI. Keep them.
- `used`: the id of a song started from it.
- Sort order: `updated` descending.
- Memo recording: MediaRecorder `audio/mp4` preferred (ext from mime: mp4/m4a/aac → `m4a`, ogg, wav, mp3,
  else webm), 128 kbps, with echo cancellation, noise suppression and AGC **off**. Minimum 0.6 s. Max **600 s
  (Pro) / 60 s (Free)**. `peaks` is 60 samples taken from the 180-bin peaks. The blob is saved to IndexedDB
  `f:<memoId>` first, with `path:'local:<id>'` and `pend:true`, then uploaded if Pro and signed in (§4.2). After a
  successful upload: `path` = storage path, `pend` deleted, `updated` bumped, and the IDB copy is moved into the
  audio cache.
- "Start a Song" from an idea makes a new song (`title` = first line if kind `idea` and ≤60 chars,
  `lyrics = text+'\n'` for `line`, `notes = text` for others, `brief.more` for `concept`). If the idea has a memo
  (Pro only) the recording is **copied** into the song as its first audio item (`kind:'Voice memo'`, `cur:true`):
  a storage `copy` from the idea path to `<uid>/<songId>/<newId>.<ext>`, or an upload from IDB if still local.
- Deleting an idea deletes its memo file from storage too.

### 1.6 Folders

There is **no folder list**. A folder exists because some song has `song.folder === name`. The list groups by
`folder || 'Songs'`. Groups are ordered by their most recently updated song, with "Pinned" first.

- **Empty folder**: "New Folder" creates a placeholder song
  `{pf, id, title:'', lyrics:'', ..., folder:'New Folder N', ph:1, updated}`. It's shown with "Empty folder…"
  text. `ph` is deleted when the song gets a title or lyrics. When a real song is moved into the folder, the
  folder's empty placeholders are removed.
- **Rename**: every song with `folder===old` gets the new name and `updated=now`. The names `Unfiled` and `Songs`
  are refused.
- **Leaving an empty song** (`goBack`): a song with no title, lyrics, chords, notes, art, audio, files,
  credits, key, bpm or folder, and not shared, is deleted on navigating back.

### 1.7 Built-in guide song

Fixed id `5f1d0c2e-6a8b-4c3d-9e7f-0a1b2c3d4e5f`, `GUIDE_V=4`, `GUIDE_AT=Date.UTC(2026,9,17,2)`.
`created = updated = guideAt = GUIDE_AT`, `guide:true`, `status:'Idea'`. It's seeded once per library
(localStorage flag `songpad:guide:<libraryKey>` = version). A fixed id plus an old timestamp means any real edit or
delete synced from elsewhere wins. If the song exists with `updated === guideAt < GUIDE_AT` it's replaced by
the new version. If the flag is 0 and the song is absent, it's added. If it was deleted, it stays deleted. It's
excluded from the muse's catalogue. The text is in `guideSong()` (lines 14–74), and its `rich` uses
the bold slate span for tags and the Hook highlight for `{...}`.

### 1.8 Default cover (no `art`)

Deterministic from `song.id` (FNV-1a hash → xorshift) picking from `COV_PAL` (12 pastel pairs), with a gradient
angle, a radial glow centre and a glow colour. White rounded bars are drawn, one per lyric line, with width =
`clamp(syllables/12, .18, 1)`, a gap between sections, at most 9 bars, and placeholder bars `[.72,.5,.62]` if empty.
`covHex(id)` gives the share card's fallback colours. Replicating it is optional but makes covers match across
devices.

### 1.9 Pins, settings and other per-device state

| Key (localStorage) | Contents | Synced? |
|---|---|---|
| `songpad:v1:<uid>` | songs array for that account (`K+':'+uid`) | via `cloud_library` |
| `songpad:v1` | songs while signed out (legacy, **not migrated** into an account) | no |
| `songpad:ideas:v1:<uid>` | ideas array | via `cloud_library` |
| `songpad:sync:tomb:<uid>` | `{songs:{id:ms}, ideas:{id:ms}}` local tombstones | merged into `cloud_library` |
| `songpad:sync:base:<uid>` | `{songs:[ids], ideas:[ids]}` ids present at the last successful sync | no (critical for delete detection) |
| `songpad:guide:<libraryKey>` | guide version seeded | no |
| `songpad:pins` | `{songId: ms}` pinned songs | **no: pins are per device** |
| `songpad:seen` | `{songId: lyricsWhenLastSeen}` for the "co-writer added N lines" hint | no |
| `songpad:prefs` | last-used writing voice (PF) | no (but `song.pf` is) |
| `songpad:view` | `{map:bool, syl:bool, ctx:bool}` rhyme map / syllables / "listen to whole song" | no |
| `songpad:linepref` | `{perfect:n, near:n, loose:n}` learned rhyme preference | no |
| `songpad:rtone` | Rate tone `enc`/`bal`/`blunt` | no |
| `songpad:aiconsent` | `'yes'` / `'no'` / absent (AI permission, §7.1) | no, per device |
| `songpad:muse:ev:<uid>`, `songpad:muse:pend:<uid>`, `songpad:muse:prof:<uid>` | muse memory (§7.4) | via `muse_events`/`muse_profile` |
| `songpad:profile:<uid>` | cached profile row | no |
| `songpad:plan` | cached `PLAN` (§6) | no |
| `songpad:cfg` | cached `app_config_public()` result + `at` | no |
| `songpad:banner-x` | dismissed `banner_id` | no |
| `songpad:beta:<uid>` | `'ok'` once access is confirmed | no |
| `songpad:pushtok` | APNs device token hex | registered via `push_register` |
| `songpad:device` | device UUID (`LIB_DEV`) | used in pings and broadcasts |
| `songpad:acache` | audio cache index `{path:[bytes, lastUsedMs]}` | no |
| `songpad:bakedusage`, `…:build` | local AI rate counter (§7.1) | no |
| `songpad:oauthpend` | ms when an OAuth sign-in was started | no |
| `songpad:signedout` | `'1'` after an explicit sign-out | no |
| `songpad:devbuild` | `'1'` on dev builds | no |
| `sb-cygfgurzvmbtcegkpnss-auth-token` | supabase-js session (`SB_STORE_KEY`) | Keychain equivalent natively |

IndexedDB database `songpad`, version 1, one object store `audio` (out-of-line keys):

- `<songId>`: the melody source recording for that song.
- `f:<fileId>`: bytes of a `local:` audio/file item or an un-uploaded idea memo.
- `c:<storagePath>`: the audio cache (up to **500 MB** total, LRU-trimmed to 85%, files >60 MB not cached).
  It's keyed by path, which changes whenever a file is replaced, so it's never stale. Cleared on sign-out. Copies
  not referenced by any song or idea are pruned 45 s after sign-in.

Mac only: `window.desktop.mirror(songs)` writes song files plus `*[demo] backup.json` to Documents › [demo] Songs.
This is irrelevant for iOS.

### 1.10 Backup / import format

Export: `{"app":"*[demo]","saved":ISO,"songs":[...non-shared songs, _keys stripped...]}`.
Import accepts that, a bare array, `{songs:[]}`, a single song object, or plain text (§`fromText`: line 1 =
title; an optional line 2 of `by X · Key: G · 92 BPM · Capo: 2 · Tuning: … · Status: …`; then the body, with
optional `\n--- Chords ---\n` and `\n--- Notes ---\n` sections). On import, string fields are coerced to strings,
`shared/owner/members` are dropped, `_` keys are dropped, and **`updated` is set to now** (so an older delete
tombstone can't remove it). An existing id is replaced only if not shared and the imported `updated` was newer.

---

## 2. Library sync (`cloud_library`)

### 2.1 Table

`public.cloud_library(user_id uuid PK, data jsonb not null default '[]', updated_at timestamptz not null default now())`.
One row per account (RLS: own row). `data`:

```json
{ "v": 2,
  "songs": [ <song>, ... ],          // sorted by id ascending (libCanon), _keys removed
  "ideas": [ <idea>, ... ],          // sorted by id ascending
  "deleted": { "songs": {"<id>": ms}, "ideas": {"<id>": ms} } }
```

Legacy: `data` may be a bare array of songs (v1). Read it as `{songs:data, ideas:[], deleted:{}}`. The next push
rewrites it as v2. Admin RPCs and `notify_scheduled` (writing nudges use `cloud_library.updated_at`) read this
row, so keep `songs`/`ideas` as arrays and keep `updated_at` meaningful.

Shared songs are **also** stored here (with `shared:true, owner, members…`). Every member's library has its own
copy, and `shared_songs` is the common copy (§3).

### 2.2 When sync runs

- `save()` (called on essentially every keystroke) sets `libTyping=now` and debounces a **250 ms** local write
  (`saveFlush`). `saveFlush` writes localStorage, then calls `syncShared()` and `cloudPush()`.
- `saveIdeas()` debounces 200 ms, writes localStorage, then calls `cloudPush()`.
- `cloudPush()` debounces **900 ms**, then calls `cloudSync()`.
- On sign-in (first time per uid in a session): `cloudPull()` → `cloudSync(first=true)` + `libListen()`.
- Realtime broadcast `changed` on channel `library:<uid>` from another device (payload `dev` ≠ mine) →
  `cloudSync()` after 250 ms.
- Poll: every **20 s** while visible, plus on focus/visible: `select updated_at from cloud_library where user_id=me`.
  If it differs from `libSeenAt`, run `cloudSync()`.
- `online` event → `cloudSync()`. App hidden or `pagehide` → flush the pending local save and run `cloudSync()` immediately.
- Only one sync runs at a time. A request during a sync sets `libAgain` and re-runs once it finishes.
- `libReady()` requires: signed in, **session not stale** (§5.4), not Dev Mode, the active library key is
  the account's, and a client exists. While the session is stale, nothing syncs.

### 2.3 Algorithm (`cloudSync`), exact

```
attempt():
  row = select data, updated_at from cloud_library where user_id = uid  (maybeSingle)
  if error: (first? toast "Couldn't reach cloud storage: …") stop
  remote = libNorm(row?.data); prevAt = row?.updated_at; now = Date.now()
  localTomb = libGet('tomb', {}); base = libGet('base', null)
  tomb.songs = maxPerKey(localTomb.songs, remote.deleted.songs)   // libMax: keep larger ms per id
  tomb.ideas = maxPerKey(localTomb.ideas, remote.deleted.ideas)
  pinS = (cur && now - libTyping < 4000) ? cur.id : null          // song being typed in right now
  pinI = (idea sheet open) ? curIdea.id : null
  mergedSongs = libMergeList(songs, remote.songs, tomb.songs, base?.songs, now, pinS)
  mergedIdeas = libMergeList(ideas, remote.ideas, tomb.ideas, base?.ideas, now, pinI)
  apply merged into local arrays (keep object identity and each object's _keys); save tomb locally
  if anything changed: persist localStorage, re-render; if the open song vanished → leave the editor,
     toast "That song was deleted on another device"
  payload = {v:2, songs: canon(mergedSongs), ideas: canon(mergedIdeas), deleted: tomb}
  was     = {v:2, songs: canon(remote.songs), ideas: canon(remote.ideas), deleted: remote.deleted}
  if row exists && row.data is not an array && canonicalJSON(payload) == canonicalJSON(was):
       libSeenAt = prevAt; base = current ids; done        // nothing to write
  stamp = new Date().toISOString()
  if prevAt: update cloud_library set data=payload, updated_at=stamp
             where user_id=uid AND updated_at=prevAt  returning updated_at      // compare-and-swap
  else:      insert {user_id, data:payload, updated_at:stamp} returning updated_at
  lost = (insert failed with 23505) || (update returned 0 rows)
  if lost: retry attempt() up to 4 tries total, then give up silently
  if other error: toast "Couldn't sync to your account: …"
  on success: libSeenAt = returned updated_at; base = current ids; broadcast 'changed' {dev: LIB_DEV}
```

`canonicalJSON` (`libStr`) is JSON with object keys sorted recursively and `undefined` values dropped. Arrays keep
their order (lists are id-sorted first). A native implementation must produce the same comparison, or it will
write on every sync (harmless but noisy, and it fires `changed` to other devices).

`base` and `ids` are the ids of the **local** lists after merge.

### 2.4 Merge rule (`libMergeList`), exact

```js
// local wins ties; `pin` is the item being edited right now, which always keeps the local copy
function libMergeList(local,remote,tomb,base,now,pin){
  var have={};local.forEach(x=>{if(x&&typeof x.id==='string')have[x.id]=1});
  if(base)base.forEach(function(id){if(!have[id]&&!tomb[id])tomb[id]=now});   // deletion detection
  var rb={};remote.forEach(x=>{if(x&&typeof x.id==='string')rb[x.id]=x});
  var out=[],used={};
  local.forEach(function(x){if(!x||typeof x.id!=='string'||used[x.id])return;used[x.id]=1;var r=rb[x.id],w=x;
    if(r&&x.id!==pin){var ru=r.updated||0,xu=x.updated||0;
      if(ru>xu||(ru===xu&&libStr(libClean(r))>libStr(libClean(x))))w=r}       // deterministic tie-break
    if(x.id!==pin&&tomb[x.id]&&tomb[x.id]>=(w.updated||0))return;out.push(w)});
  remote.forEach(function(r){if(!r||typeof r.id!=='string'||used[r.id])return;used[r.id]=1;
    if(tomb[r.id]&&tomb[r.id]>=(r.updated||0))return;out.push(r)});
  Object.keys(tomb).forEach(function(id){if(now-tomb[id]>LIB_TOMB_TTL)delete tomb[id]}); // 90 days
  return out;
}
```

Consequences a native client must respect:

1. **Whole-object last-writer-wins on `updated` (client clock).** There's no field-level merge in the library.
   Bump `updated` on every user-visible change, including file metadata (`sfTouch`), credits and release.
2. **Deletes are inferred**: an id that was in `base` (last synced ids) but is no longer local gets a tombstone
   at `now`. So: persist `base` after every successful sync, and *never* drop items from the local list for any
   reason other than a user delete (or a server-confirmed removal of a shared song) while `base` still lists
   them. A partial or failed local load would otherwise delete songs everywhere.
3. A tombstone beats an item only if `tomb >= item.updated`. So an edit made after a delete (on another device)
   resurrects the item, and a restore or import (which sets `updated=now`) survives an older delete.
4. Tombstones expire after **90 days** (`LIB_TOMB_TTL=90*864e5`).
5. Local `_` keys survive a remote replacement (`libApplyList` keeps them).
6. Ideas use the identical algorithm.

### 2.5 What's not in `cloud_library`

Pins, view toggles, the AI consent flag, Rate tone, the global writing-voice default, the muse memory (it has its
own tables), the profile, plan, notification prefs, melody source audio, and the audio cache.

### 2.6 Offline behaviour

- Everything works from localStorage. Writes queue implicitly: the next `cloudSync` (online event, foreground,
  next edit) merges and pushes.
- If localStorage is full, versions are trimmed (§1.4) and the cloud push still happens. A toast appears at most
  once a minute.
- Remote config is cached (`songpad:cfg`) and still applies offline.
- Shared songs: an edit made offline is pushed by `syncShared()` on the next save once `updated > _pushed`.
  There's no queue beyond that comparison.

### 2.7 `app_config` flags (clarification)

`app_config_public()` → `{banner, banner_kind:'info'|'warn', banner_id, ai_off, sync_off, uploads_off, min_seq,
update_note, updated_at}`.

- **`sync_off` pauses *lyric sync* (audio → timings), not library sync.** There's no remote kill switch for
  cloud_library sync. When `sync_off`, "Sync Lyrics" shows "Lyric sync is paused for maintenance…", and the
  server's `ai_take('sync')` also returns `reason:'off'`.
- `ai_off`: client refuses AI requests with "AI features are paused for maintenance…". The server enforces it too.
- `uploads_off`: `sfRoom()` rejects uploads ("Adding music and files is paused…"). A restrictive storage policy
  enforces it server-side (an RLS error).
- `min_seq`: if `APP_SEQ > 0 && min_seq > APP_SEQ` and this is not a dev build, show a blocking "Time to update"
  overlay (text `update_note` or a default; button → `itms-beta://` on iOS for now, the App Store later). **The
  native app must ship an `APP_SEQ` integer on the same scale (> 413)** so the existing switch keeps working.
- `banner`: shown at the top when `banner_id` ≠ `localStorage['songpad:banner-x']`. Tapping dismisses it for good
  (stores the id). It auto-hides after 9 s (20 s for `warn`) and returns on the next launch.
- Loaded at launch (+700 ms), every **180 s** while visible, and on foreground if >30 s old. Anyone can call it
  (anon too).

---

## 3. Shared songs and collaboration

### 3.1 Tables (live columns)

```
shared_songs(id text PK, owner_id uuid not null, owner_email text, data jsonb not null default '{}', updated_at timestamptz)
collab_members(song_id text, user_id uuid, email text, joined_at timestamptz default now())  -- unique (song_id,user_id)
collab_invites(id uuid PK default gen_random_uuid(), song_id text, song_title text, owner_id uuid, owner_email text,
               owner_name text, invitee_user_id uuid, invitee_username text, invitee_email text,
               status text default 'pending' ('pending'|'accepted'|'declined'), created_at, responded_at)
user_blocks(blocker uuid default auth.uid(), blocked uuid, created_at, PK(blocker,blocked), check blocker<>blocked)
```

RLS summary (from `collab-hardening.sql`, `invite-guard.sql`, `plans.sql`, `user-blocks.sql`):

- `shared_songs` insert/update: `owner_id = me OR is_song_member(id, me)`. A trigger refuses any change to `id`,
  or to `owner_id` by a non-owner. Deleting a row (owner) cascades: a trigger deletes its `collab_members` and
  `collab_invites`. A co-writer **must use UPDATE, not upsert** (an upsert is also checked as an insert; see
  `pushShared`).
- `collab_members` insert: `user_id = me AND (owns_song OR has_invite)`, where `has_invite` = a pending invite to
  me, or one accepted in the last 10 minutes. The owner can delete anyone. A member can delete themselves.
- `collab_invites` insert: `owner_id = me AND owns_song(song_id)` **and `paid()`** (Free can't invite).
  Invitee select/update: `invitee_user_id = me` only (email matching was removed). Select is hidden if the
  invitee blocked the owner. The guard trigger allows only `pending → accepted|declined`, once, and sets
  `responded_at` server-side. The invitee can't change who or what the invite is for.
- `user_blocks`: own rows only (select/insert/delete).
- `notify_song_edited` trigger: when `shared_songs.data` changes beyond `lastEditBy/lastEditAt/updated`, every
  other member gets a push (`cowrite`, deduped per 30 min per song per recipient).

### 3.2 `shared_songs.data` shape

The output of `ser(song)`: the song object minus all `_` keys and minus `shared`, with `versions` truncated to
the **last 8**, deep-copied. It therefore contains `owner`, `ownerEmail`, `members`, `lastEditBy`, `lastEditAt`,
`rmFiles`, `audio`, `files`, `sync`, `credits`, `shares`, `pf`, `rating`, etc. Row columns: `id = song.id`,
`owner_id`, `owner_email`, `updated_at = now ISO`.

### 3.3 Sharing a song (owner)

`shareSong()` (Pro only in the UI): ensure the id is a UUID. If `artist` is empty, set it to `myName()`. Set
`shared=true, owner=me, ownerEmail=my email, members=[me], updated=now`, then `pushShared` and `save`.

### 3.4 Pushing edits (`syncShared` → `pushShared`)

- On every `saveFlush`, for each local song with `shared && updated > _pushed`:
  - if it's the song open in a live channel: at most one push every **4 s** (`shT`, `shLast`);
  - otherwise push now.
- `pushShared(s)`: set `s.lastEditBy = myEmail; s.lastEditAt = now; body = ser(s)`.
  - Owner (or `!s.owner`): `upsert shared_songs {id, owner_id: s.owner||me, owner_email: s.ownerEmail||myEmail, data: body, updated_at: nowISO}`.
  - Co-writer: `update shared_songs set data=body, updated_at=nowISO where id=s.id returning id`. **Zero rows
    returned is treated as error `42501`** (not a member).
  - On `42501`: run `sharedGoneCheck`. If the song still exists server-side, toast once "Couldn't save your
    changes to “…”. Ask the owner to invite you again." On other errors: toast "Couldn't sync this song (kept on
    this device): …".
  - On success: `_pushed = max(_pushed, body.updated)`.
- Leaving the song or hiding the app calls `liveFlushNow()` (an immediate push if dirty).

### 3.5 Pulling (`pullShared`)

Called when a shared song is opened, when a `cowrite` push arrives for the open song, after sign-in for the open
song, and from `sfUrl` when a file 404s.

```
row = select data, owner_id, owner_email from shared_songs where id = s.id (maybeSingle)
d = row.data
if d.rmFiles: d.rmFiles = {...s.rmFiles, ...d.rmFiles}
if d.updated <= s.updated:  merge only file tombstones into local (fileMerge); if anything changed, updated=now + save
if d.updated  > s.updated:  copy EVERY key of d onto s (overwrite), then re-merge local rmFiles (if that changes
                            anything, updated=now) else apply tombstones (fileGC);
                            s.owner=row.owner_id; s.ownerEmail=row.owner_email; s._pushed=d.updated;
                            refresh the editor keeping the caret clamped
```

There's **no background polling of shared songs**. A co-writer's edits reach a song that isn't open only when
it's opened, via push notification, or via the live channel while open. (The member's *own* other devices get it
through `cloud_library` sync.) Consider adding a periodic pull in native.

Conflict handling is LWW on `updated` for the whole song, except file tombstones, which are a union (§3.6).
While the song is open, live patches (§3.7) are what actually keep text consistent.

### 3.6 File tombstones on shared songs

Deleting an audio or file item sets `song.rmFiles[id] = now`, removes the item, deletes the storage object
(only your own uploads can be deleted, per RLS), and broadcasts `files`.

```js
fileMerge(s, rm, audio, files):   // union rm into s.rmFiles; union audio/files lists by id (theirs first, then mine);
                                  // then fileGC: drop any item whose id is in rmFiles; ensure one cur audio
```

### 3.7 Live co-writing (Realtime broadcast)

Channel name `song:<songId>`, config `{broadcast:{self:false}, private: RT_PRIV}`. `RT_PRIV` starts true. If the
very first private join fails with an `unauthori|denied|permission|not allowed` CHANNEL_ERROR, the client falls
back to a public channel for the rest of the session. RLS (`realtime-private.sql`) allows only the owner and
members on `song:*`. Join on opening a shared song. Leave on closing it. Re-ensure every 10 s, on focus, on online,
and on visible. CHANNEL_ERROR/TIMED_OUT/CLOSED → retry in 2 s.

Every payload carries `id` (song id) and `dev` (sender `LIB_DEV`). Ignore your own `dev` and other song ids.

| event | payload | meaning / handling |
|---|---|---|
| `p` | `{id, dev, who: senderDisplayName, u: senderUpdatedMs, ch: {field: Patch}}` | Text patch for fields `LIVE_F = ['lyrics','title','artist','chords','notes','key','bpm','tuning','status']`. Sent at most every **150 ms** with all changes since the last one. |
| `fmt` | `{id, dev, u, txt: lyrics, h: richHTML}` | Formatting changed without the text changing. Apply only if my `lyrics === txt`. Set `rich = clean(h)`. |
| `need` | `{id, dev, u?}` | "Send me the whole song". Reply with `full` if I have the song open and (`!u` or my `updated >= u`). Also sent by a joiner right after SUBSCRIBED. Throttle `full` to one per 800 ms. |
| `full` | `{id, dev, who, u, f: {lyrics,title,artist,chords,notes,key,bpm,tuning,status,rich}}` | Whole-text resync. If I have unsent local changes (my values ≠ my snapshot), send mine and ask for `need` again after 400 ms. If I'm newer (`updated > u`) and identical, ignore it. Otherwise replace all of those fields. |
| `files` | `{id, dev, rm: rmFiles, audio: [...], files: [...]}` | `fileMerge`. Sent after any file change (`sfTouch`). |
| `gone` | `{id, dev}` | The owner deleted or stopped sharing. Run `sharedGoneCheck` after 1.5 s. |

Patch format (`liveDiff(old,new)`): the common prefix length `f`, plus the removed text `d`, the inserted text
`i`, up to 16 chars of context before `c` and after `a`:

```js
function liveDiff(a,b){if(a===b)return null;var n=Math.min(a.length,b.length),p=0;while(p<n&&a.charCodeAt(p)===b.charCodeAt(p))p++;
  var q=0;while(q<n-p&&a.charCodeAt(a.length-1-q)===b.charCodeAt(b.length-1-q))q++;
  return{f:p,d:a.slice(p,a.length-q),i:b.slice(p,b.length-q),c:a.slice(Math.max(0,p-16),p),a:a.slice(a.length-q,a.length-q+16)}}
```

Applying (`livePatch(text,P)`): if `text.substr(P.f, d.length)===d` and the context `c` before and `a` after
still match, splice there. Otherwise search for `c`'s tail+`d` (overlaps of decreasing length: n, then 8, then
n-2 … ≥3) or `d`+`a`'s head, and pick the candidate nearest `P.f`. If both contexts are empty, use
`min(P.f, len)`. If no candidate is found, the patch fails, so send `need`. Character offsets are **UTF-16 code
units** (JS `charCodeAt`/`slice`): a Swift client must diff and patch on `String.utf16`, not on Characters.

Each side keeps a snapshot (`LIVE.snap`) of the last sent or received value per field. Outgoing diffs are against
the snapshot. Incoming patches are applied to both the live value and the snapshot. During IME composition,
incoming patches are queued. After applying: `updated = max(updated, x.u)`. If nothing local was pending, also
set `_pushed = updated`. Set `lastEditBy = x.who`, save (without re-broadcasting: `LIVE.applying`), and show
"<first name> is writing…" for 2.5 s. When lyrics are patched without rich, `rich=''` (or the patch is applied
directly to the DOM and rich is re-read).

### 3.8 Invites

Create (owner, Pro, song already shared):

1. Find the user: `profiles.select('user_id,username').ilike('username', v).limit(1)`, where v is lowercased
   with the `@` stripped. Suggestions as you type (≥2 chars, 250 ms debounce):
   `profiles.select('user_id,username,display_name,avatar_url').ilike('username', v+'%').not('username','is',null).neq('user_id', me).limit(5)`.
2. Insert `collab_invites {song_id, song_title: title||'Untitled', owner_id: me, owner_email, owner_name: myName()||null, invitee_user_id, invitee_username}`.
   If the error mentions `row-level security` (the shared row hasn't landed yet), `pushShared` the song and retry
   once after 2.5 s.
3. Ping the invitee's devices: broadcast `invite` `{}` on `library:<inviteeUid>` (subscribe, send, remove; 8 s cap).
4. `functions.invoke('push', {action:'invite', song_id, invitee})` sends an APNs push if the invite was created in
   the last 10 min and the invitee hasn't blocked the sender.

Receive: `pullInvites()` = `collab_invites.select('*').eq('status','pending').or('invitee_user_id.eq.<me>,invitee_email.ilike.<myEmail>')`.
It runs at sign-in, every **45 s**, on a library `invite` broadcast, and on an `invite` push. New ids (not seen
before) show an in-app banner (owner's avatar and name from `profiles`, "X invited you to write “T” together",
Accept / Not now, 20 s). (RLS only returns `invitee_user_id = me` now. The email branch is dead.)

Accept (order matters):

1. `collab_members.upsert({song_id, user_id: me, email: myEmail}, {onConflict:'song_id,user_id'})`. On error,
   toast "Couldn't join: …" and stop.
2. `collab_invites.update({status:'accepted', responded_at: nowISO}).eq('id', inv.id)` (errors are only logged).
3. `shared_songs.select('data,owner_id,owner_email').eq('id', inv.song_id)`. If the song isn't already local:
   create `s = deepcopy(data)`, `s.id = song_id`, `s.shared = true`, `s.owner = row.owner_id||inv.owner_id`,
   `s.ownerEmail = …`, `s.members = unique(members + [me])`, `s.updated = now`, `s._pushed = s.updated`. Push it
   into songs and save (it then syncs into my library). The owner gets a push via the `notify_invite_accepted` trigger.
4. Optionally recompute the artist credit (`applyCredits`, §5.6).

Decline: `update({status:'declined', responded_at})`. Blocking someone also declines all their pending invites to me.

Members list (Details › Collaborators): `collab_members.select('user_id,email').eq('song_id',id)`. For the owner,
also `collab_invites.select('invitee_user_id,invitee_username,invitee_email,status').eq('song_id',id).eq('status','pending')`,
plus `profiles.select('user_id,display_name,username,avatar_url').in('user_id', ids)`.
Owner remove: `collab_members.delete().eq('song_id',id).eq('user_id',x)`.

### 3.9 Leaving, stopping and deleting

- **Co-writer leaves or deletes**: `collab_members.delete().eq('song_id',id).eq('user_id',me)`. The song is removed
  locally (a library tombstone follows). Their file uploads are *not* deleted.
- **Owner stops sharing** (`stopSharing`): `sharedEnd(s)`, then locally delete `owner/ownerEmail/members`, set
  `shared=false`, `updated=now`.
- **Owner deletes**: delete all audio and file objects, stop the share link, then `sharedEnd(s)`.
- `sharedEnd(s)`: broadcast `gone` on `song:<id>` if joined. Select `collab_members.user_id` for the song, send
  `gone` to each member's `library:<uid>`, then after 600 ms `shared_songs.delete().eq('id', id)` (the trigger
  removes members and invites).
- **`sharedGoneCheck`** runs at sign-in +5 s, on a `gone` event, and on a `42501` push failure. Only with a valid
  current session (`auth.getSession()` user = me), and never while the session is stale: signed-out RLS returns
  zero rows without an error, which would look like everything being gone. Select `shared_songs.id` in the list of
  shared songs I don't own. Drop the local ones that are missing. If *all* of 2+ are missing, re-check once after
  8 s before dropping. Drop = leave the editor if it's open, remove the pin and IDB melody, remove from songs, save,
  and toast "“T” was removed by its owner".

### 3.10 Blocks

- Load: `user_blocks.select('blocked')` → profiles for names.
- Block: `insert {blocker: me, blocked: id}` (a duplicate is OK), then decline that person's pending invites.
- Unblock: `delete().eq('blocker',me).eq('blocked',id)`.

Blocked users' invites are invisible (RLS) and don't push. They aren't told.

### 3.11 The "collaborator added lines" hint

Local-only. `SEEN[songId]` = the lyrics string last seen. If `lastEditBy` ≠ my email and lyrics differ, count lines
(multiset diff) added since then, and show "Name added N new lines · tap to dismiss".

---

## 4. Storage

### 4.1 Buckets and paths

| Bucket | Public | Path | Written by |
|---|---|---|---|
| `song-files` | no | `<uploaderUid>/<songId>/<fileId>.<ext>` | song audio and files |
| `song-files` | no | `<uid>/ideas/<memoId>.<ext>` | idea voice memos |
| `shares` | yes (read by URL, not listable) | `<uid>/<shareId>/art-<v>.(jpg\|png)`, `audio-<v>.<ext>`, `og-<v>.(jpg\|png)` where `v = Date.now().toString(36)` | share links |

`ext` = the filename extension (1–6 alnum chars) or the MIME subtype, lowercased, alnum only (`sfExt`).

Policies:

- Read your own folder.
- Read other uploaders' files in `song-files` only if **both** you and the uploader are on that song (owner or
  member, via `can_read_song_file(folder[1], folder[2])`) **and you're on a paid plan** (`paid()`).
- Write, update and delete only in your own folder.

Restrictive insert policies on both buckets:

- `storage_has_room()` (under the plan limit);
- `beta_ok()`;
- `not feature_off('uploads')`;
- `paid()`, except that `shares` accepts `png/jpg/jpeg/webp` for anyone (free share-link pictures).

### 4.2 Operations

| Op | Call |
|---|---|
| Upload a song file | `sfRoom()` (checks `uploads_off` + `my_storage`), then `storage.from('song-files').upload(path, file, {contentType: file.type\|\|'application/octet-stream', upsert:false})`. On success, add `size` to the cached used bytes and put audio into the local cache. |
| Upload an idea memo | `sfRoom()` then `upload(path, blob, {contentType: mime\|\|'audio/mp4', upsert:true})`. Pro only (Free memos stay on the device: `pend:true`, `local:`). Pending memos are retried whenever Ideas renders or the plan becomes Pro. |
| Play or open | `createSignedUrl(path, 3600)`, cached in memory until 60 s before expiry. Audio is served from the IDB cache first. The first stream also fills the cache (`acFill`). Non-Pro users trying to play others' files get an upsell instead (`sfCanPlay = isPro() \|\| sfMine(item)`). |
| A file 404s | Likely replaced on another device: `pullShared` / `cloudSync`, wait 1.8 s, find the item by id (or by `orig.name` match) and retry once with its new path. |
| Copy memo → song | `storage.from('song-files').copy(memoPath, '<uid>/<songId>/<newId>.<ext>')` |
| Copy audio → share | `storage.from('song-files').copy(a.path, '<uid>/<shareId>/audio-<v>.<ext>', {destinationBucket:'shares'})`. Falls back to download and re-upload when the item is `local:`, over 40 MB, or the copy fails. |
| Delete | `remove([path])` (errors are ignored). Also drops the cache entry. |
| Delete account | List both buckets recursively under `<uid>` (`list(prefix,{limit:1000})`: entries with `id` are files, without are folders) and remove in chunks of 100. Then call the RPC. |

### 4.3 Storage limits

- `my_storage()` → a table of one row `{used_bytes bigint, limit_bytes bigint|null}` (the client handles an array or
  an object). Cached 30 s. `null` limit = unlimited. Used bytes = the sum of object sizes in both buckets under `<uid>/`.
- `storage_limit_for(plan)`: **Pro 5 GB** (5120 MiB). **Beta** = `storage_limit.per_account_mb` (default **150 MB**,
  adjustable by admin). **Free 20 MB** (in effect only share-link pictures, because song uploads need `paid()`).
- The client blocks the upload when `used >= limit` ("you've used all X of your storage…"). The server enforces
  it too. A full or RLS error is mapped to friendly messages in `sfErr`. Account shows "Storage: X of Y" (refreshed
  every 15 s while open).

### 4.4 Share links (`shares` table + listen.hellodemo.app)

Table: `shares(id text PK check ~ '^[A-Za-z0-9]{10}$', owner uuid default auth.uid(), song_id text, data jsonb, created_at, updated_at)`.
The owner has CRUD. The public reads only via `get_share(sid)` (anon), which returns `data || {"updated": <epoch seconds>}`.

Id: 10 chars from `ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789` (crypto random). The same song reuses
my existing id (`song.shares[me].id`).

Make or update (`shLinkMake`), run in parallel:

- `art`: the cover data URL (or a rendered 480×480 JPEG q0.9 of the default cover) uploaded as `art-<v>.jpg|png`.
- `audio` (only if "Include audio" and Pro): the current audio version. Reuse the previous upload if it's the same
  `aid`, else copy it server-side (above).
- `og`: a 1200×630 preview picture, `og-<v>.jpg|png`.

Uploads use `{upsert:true, contentType, cacheControl:'31536000'}`, and URLs come from `getPublicUrl`.
Then `shares.upsert({id, owner: me, song_id, data, updated_at: nowISO})`. Then list `<uid>/<id>/` and remove files
not in this version (skipped if a newer attempt started). Then set
`song.shares[me] = {id, at: now, audio: bool, by: me, aid, aname}` (`sfTouch`). The whole operation has a 180 s
cap, and the link is copied to the clipboard at the start of the tap.

**Published `data` (exactly what the public page gets):**

```json
{ "v": 1, "title": "", "artist": "", "key": "", "bpm": "",
  "blocks": [ {"sec": "Chorus"} | {"gap": true} | {"line": "text", "t": 12.4 | null} ],
  "bg": {"top": "hsl(...)", "bot": "hsl(...)", "glow": "hsl(...)", "k": "H,S%,L%"},
  "art": "<public URL of art-v.jpg>",
  "audio": {"src": "<public URL>", "name": "Demo 1", "dur": 182.4, "peaks": [...]} | null,
  "og": "<public URL of og-v.jpg>" }
```

`blocks` comes from `lyrics`: blank lines collapse to one `gap` (trailing gaps removed), `[x]` lines become
`{sec:x}`, and lyric lines get `t` from `song.sync` only if the sync belongs to the shared audio and the text
matches line-for-line. `bg` is derived from the art palette (or the default cover colours), and the user can pick
among palette swatches (`shBg`). **No notes, chords, credits, collaborators or other metadata are published.**

Stop: `shares.delete().eq('id', id)`, list and remove `<uid>/<id>/*`, then delete `song.shares[me]`. Deleting a song
also stops its link. Only the writer who made a link can stop it.

Public page: Vercel `share/api/s.js` serves `listen.hellodemo.app/<id>`. It calls
`POST /rest/v1/rpc/get_share {sid}` with the anon key, injects OG meta tags (title/artist, `og` image, or `art`, or
the app icon) and inlines the data. Only URLs under `…/storage/v1/object/public/shares/` are trusted. The viewer
calls `rpc/share_seen {sid}` (anon), which queues a `plays` push to the owner (once a day per link). It returns 404
"Not shared any more" when the share is missing.

There are also local-only share outputs: a PNG lyric card and a standalone HTML page with base64 audio inside. They
make no backend calls.

---

## 5. Auth and profile

### 5.1 Client setup and persistence

- `createClient(SB_URL, SB_KEY, {auth:{persistSession:true, autoRefreshToken:true, flowType:'pkce'}})`. The session
  lives in `localStorage['sb-cygfgurzvmbtcegkpnss-auth-token']`. For native, use supabase-swift with Keychain
  storage, PKCE and autoRefresh.
- At launch, if a stored session exists, the app immediately treats its `user` as signed in in **stale** mode
  (shows that account's library; no sync, beta check or other server calls) while supabase validates or refreshes.
- `onAuthStateChange(ev, session)` → `authApply`:
  - A session arrives and `songpad:signedout === '1'` and the event isn't `SIGNED_IN` → refuse it (wipe it and
    sign out). This guarantees that a sign-out sticks even if the network call failed.
  - A session arrives → clear `signedout`, `AUTH_STALE = false`, `AUTH_USER = user`, run `onAuthUser()`.
  - No session, event ≠ `SIGNED_OUT`, and a stored session exists → stay signed in as stale and run
    `authRecover()`: `refreshSession()` with backoff `min(30 s, 800 ms·2^n)`, retried on `online`. A **4xx that
    isn't a network error** → treat as `SIGNED_OUT`.
  - Otherwise → signed out.

`onAuthUser()` on a new uid:

- reset per-user state, load the muse memory, hide the auth gate;
- if not stale: `beta_status` check (§6.5), RevenueCat `iapStart`, switch to the account's library key,
  `app_seen_ping`, `pushStart`;
- first time this session: `cloudPull`, `planRefresh` (`my_plan`), `pullInvites`, `loadProfile`, start the 45 s
  invite poll, `mzPull` (+1.5 s), `sharedGoneCheck` (+5 s), audio cache prune (+45 s);
- `pullShared` and `liveEnsure` for the open song.

Sign out (`signOutGoogle`):

- RevenueCat `logOut`, stop library realtime and poll, leave the live channel, clear the audio cache;
- set `songpad:signedout='1'`, set the plan to free and remove `songpad:plan`;
- `push_forget(token)` (2.5 s cap), then `auth.signOut()`, and wipe the stored session regardless;
- switch to the signed-out library key and show the auth gate.

### 5.2 Google (OAuth, PKCE)

On iOS: `signInWithOAuth({provider:'google', options:{redirectTo: AUTH_SCHEME+'://auth-callback', skipBrowserRedirect:true, queryParams:{prompt:'select_account'}}})`.
The returned `url` opens in `Browser.open({presentationStyle:'popover'})` (SFSafariViewController). Native:
`ASWebAuthenticationSession` with callback scheme `demo` / `demo-dev`. `AUTH_SCHEME` is `demo`, or `demo-dev`
when the app id ends with `.dev`. Before opening: `localStorage['songpad:oauthpend'] = now`. Only one flow can be
in flight at a time (a second PKCE flow would overwrite the verifier).

Callback (`appUrlOpen` with a URL starting `<scheme>://auth-callback`), via `handleAuthUrl`:

1. Ignore it unless `oauthpend` was set within **15 min** (a defence against injected links). Clear it.
2. `error_description` or `error` in the query or fragment → toast it. The signup-limit hook messages ("Today's
   tester spots are full…", "New sign-ups are paused…") are shown verbatim.
3. `code` → `exchangeCodeForSession(code)`.
4. Otherwise, `access_token` + `refresh_token` in the fragment → `setSession`.
5. Otherwise try `exchangeCodeForSession(fullUrl)`.

### 5.3 Sign in with Apple

Native plugin `@capacitor-community/apple-sign-in`:

- `raw` = 24 random bytes hex; `nonce = sha256hex(raw)`;
- `authorize({clientId:'app.hellodemo.demo', redirectURI:'https://cygfgurzvmbtcegkpnss.supabase.co/auth/v1/callback', scopes:'email name', state: raw.slice(0,12), nonce: hashed})`;
- then `auth.signInWithIdToken({provider:'apple', token: identityToken, nonce: raw})`;
- if Apple returned a given or family name and `user_metadata.full_name` is empty →
  `auth.updateUser({data:{full_name: nm, name: nm}})` (Apple only sends the name the first time);
- cancel (code 1001 / "cancel") is silent.

Native: `ASAuthorizationAppleIDProvider` with the hashed nonce. The token audience will be the bundle id, so
**`app.hellodemo.demo.dev` must be in the Supabase Apple provider's client IDs** for the dev build. (The web passes
`app.hellodemo.demo` even on the dev build.) Without the plugin, the app falls back to OAuth with provider `apple`.

"Hide My Email" users have `@privaterelay.appleid.com` emails. The beta gate then hides the address and relies on
invite codes.

### 5.4 Profiles

Live columns: `profiles(user_id uuid PK, username text, display_name text, avatar_url text, link_spotify, link_instagram,
link_tiktok, link_youtube, link_x, link_website text, pro boolean default false, pro_since timestamptz, updated_at)`.
The app uses only `username, display_name, avatar_url, link_spotify, link_instagram, link_tiktok`. `pro` and
`pro_since` are legacy (the plan comes from `my_plan`). Profiles are readable by other signed-in users (search,
names, avatars).

- **Load**: show the cached `songpad:profile:<uid>` first. Then
  `select username,display_name,avatar_url,link_* where user_id=me order by updated_at desc nulls last limit 1`.
  - If a row exists but `display_name` is empty → `update display_name = user_metadata.full_name||name`.
  - If there's no row and no cache → `upsert {user_id, avatar_url: meta.avatar_url, display_name: meta.full_name||meta.name, updated_at}`.
  - If there's no row but there is a cache → retry once after 1.5 s, and never overwrite with OAuth defaults.
- **Username**: trim, strip leading `@`, lowercase, must match `^[a-z0-9_]{3,20}$`. Save with
  `upsert {user_id, username, display_name: dn||myName()||v, updated_at}` (onConflict `user_id`).
  - Error `23505` → "That username's taken." (unique index on `lower(username)`).
  - A message containing `reserved_username` → "That username's reserved…" (trigger `profiles_reserved_guard`).
    Matching ignores case and non-alphanumerics. For `artist`-kind entries it also strips prefixes
    `thereal|real|official|its|iam` and suffixes `official|music|hq|vevo|tv|fans|fan|daily|news`. The table can't be
    read from the app.
- **Display name**: the "Name" field. Changing your name re-credits songs whose `artist` equals the old name or
  `_autoArtist` (`renameMyArtistCredit`), and pushes shared ones.
- **Avatar**: the picked image is centre-cropped to **256×256 JPEG q0.85** and saved as a **data URL in
  `profiles.avatar_url`** (no storage upload): `upsert {user_id, avatar_url, display_name, updated_at}`. When
  displaying others' avatars, accept only `data:image/(jpeg|png|webp|gif);base64,` or https on
  `*.googleusercontent.com`, `*.cygfgurzvmbtcegkpnss.supabase.co` or `*.apple.com` (`avOk`), with `referrerPolicy=no-referrer`.
- **Links**: `upsert {user_id, updated_at, link_spotify, link_instagram, link_tiktok}`, normalised to a full URL
  (`instagram.com/<x>`, `tiktok.com/@<x>`, `open.spotify.com/artist/<x>`, or `https://` prepended) or null.
- `myName()` = `profile.display_name || profile.username || user_metadata.full_name || user_metadata.name || ''`.

### 5.5 Delete account

1. Delete all objects under `<uid>/` in `song-files` and `shares` (§4.2).
2. `rpc('delete_my_account')` → `'deleted'`. It deletes owned shared songs (with their members and invites), own
   memberships and invites, shares, muse rows, ai_calls, app_errors, beta_requests (by user or email),
   cloud_library, profiles, plans, push_tokens, push_outbox, notify_prefs, support_tickets, app_seen, user_blocks,
   and `auth.users`.
3. Locally delete `local:` blobs and every localStorage key containing the uid, then sign out.

If the RPC is missing, show "Account deletion isn't set up on the server yet".

### 5.6 Artist credit automation (`applyCredits`)

On accept, and when the owner opens Collaborators: names for `[owner, ...members]` (display_name or username, or
`myName()` for me), joined as "A", "A & B" or "A, B & C". This is applied only if `song.artist` is empty or equals
`_autoArtist`. Then save and push.

---

## 6. Plans and purchases

### 6.1 `my_plan()` RPC (authenticated)

```json
{ "tier": "free" | "beta" | "pro",
  "expires_at": "ISO" | null,        // only for a 'pro' row
  "source": "admin" | "apple" | ... | null,
  "beta_unlocks": true,
  "storage_limit": 5368709120 | null, "storage_used": 123,
  "heavy_month": 3,                  // Rate / voice-profile requests this month (units>=3 rows / 3)
  "sync_month": 42 }                 // lyric-sync minutes this month
```

`plan_for(user)` order:

1. Any `plans` row with `tier='free'` → `free` (overrides everything, even admin).
2. Admin email → `pro`.
3. `plans.tier='pro'` and not expired → `pro`.
4. `plan_config.beta_unlocks` and (the beta gate is off, or the user has an approved beta request) → `beta`.
5. Otherwise `free`.

`plans(user_id PK, tier 'free'|'pro'|'auto', source, expires_at, trial bool, updated_at)` can't be read by clients.

Client `PLAN` (cached in `songpad:plan`):
`{tier, expires_at, beta_unlocks, storage_limit, heavy_month, sync_month, at: ms, uid}`.

- **`isPro()` = `tier !== 'free'`**: Beta counts as Pro everywhere in the client.
- Refreshed on sign-in, on foreground if >60 s old, after purchase or restore, and on an `account` push.
- If the uid changes, reset to free first.
- If the server says `free` but RevenueCat reported Pro on this device in the last 24 h, call the `revenuecat`
  `{action:'sync'}` function once (60 s guard) and refresh again instead of downgrading.

### 6.2 Limits by plan

Server (`ai_take`, `plans.sql`; days are **UTC**, months are calendar UTC):

| | Free | Beta | Pro |
|---|---|---|---|
| Quick AI (units=1) | 10/day | 300 units/day | 300 units/day |
| Heavy AI (`modelTier:'complex'`, units=3: Rate, voice profile) | refused (`reason:'pro'`) | within 300/day | within 300/day, max **100/month** |
| Lyric sync (1 unit = 1 minute piece) | refused | 60/day | 60/day, **300/month** |
| Per-minute rate | 30 AI calls/min, 12 sync calls/min | same | same |
| Storage | 20 MB (share pictures only) | `storage_limit.per_account_mb` (150 MB) | 5 GB |
| Song file uploads / share audio | refused by policy | yes | yes |
| Play co-writers' files | refused by policy | yes | yes |
| Send invites | refused by policy (can still join) | yes | yes |

Client constants and gates (all of these are **client-only** unless noted):

| Constant / gate | Value | Where enforced |
|---|---|---|
| `FREE_MEMOS` | 10 | `irecStart`: Free can't record more than 10 idea memos (counts ideas with `memo`) → upsell `memos` |
| `FREE_MEMO_SECS` / `IREC_MAX` | 60 s / 600 s | Recording auto-stops |
| Memo upload | Pro only | `ideaMemoUpload` (Free memos stay on the device) |
| Memo → song | Pro only | `ideaMemoToSong` |
| Add audio/files | Pro | `sfAdd` → upsell `audio` (server also enforces) |
| Play others' files | Pro | `sfCanPlay` → `sfLocked` upsell (server also enforces) |
| Lines | Pro | `#lm` → `lines` |
| Rate | Pro | `rateClick` → `rate` (server: heavy) |
| Writing voice sheet, Learn My Voice | Pro | `#gear`, `voice` |
| Listen to whole song (context) | Pro | `#ctxb` → `listen`, and forced off on Free |
| Melody tab | Pro | `dtab('mel')` → `melody` |
| Release/credits tab | Pro | `dtab('rel')` → `release` |
| Perform mode | Pro | `perform` |
| Play with Lyrics | Pro | `play` |
| Lyric sync | Pro | `runSync` → `sync` (server too); track ≤ **720 s** |
| Share Song (co-write) | Pro | `share` (server: invites need paid) |
| Share link with audio | Pro | audio is silently omitted on Free |
| Phrase rhymes for multi-word selection, AI ranking, AI define fallback, auto voice profile | Pro | silently skipped |
| Local AI guard | 20/min, 400/day | `bakedGuardCall` (localStorage `songpad:bakedusage`, reset per day and per new iOS build), before any `ai-proxy` call |
| `AC_MAX` | 500 MB | audio cache |
| Support tickets | 5 per 24 h | `support` function |

Upsell keys (`FEAT`): `lines, rate, perform, voice, listen, melody, share, muse, audio, sync, play, release, memos, ai`.
`openAccount(k)` on Free (non-admin) opens the paywall.

### 6.3 RevenueCat (iOS)

- Plugin `@revenuecat/purchases-capacitor`. `RC_KEY` is the public Apple SDK key (`appl_…`) and is currently
  **empty**, so the purchase UI says "Subscriptions open soon".
- On sign-in: `configure({apiKey: RC_KEY, appUserID: supabaseUserId})`, or `logIn` if the user changed. Then
  `getOfferings()` → `current.monthly` and `current.annual`. Then `getCustomerInfo()`. If it shows the entitlement
  `pro` active but the server plan is free, run `iapSync`.
- Buy: `purchasePackage({aPackage})`. Restore: `restorePurchases()`. Manage: `showManageSubscriptions()`, or open
  `https://apps.apple.com/account/subscriptions`.
- `iapSync(customerInfo)`: if `entitlements.active.pro`, set the local tier to `pro` optimistically. Then call
  `functions.invoke('revenuecat', {action:'sync'})`, retrying once after 2.5 s. Then `planRefresh`. If the server
  still says free but Apple says Pro, stay Pro locally.
- On sign-out: `logOut()`.
- Paywall copy: a 7-day trial, yearly is preselected and labelled "Save 35%". Prices come from
  `product.priceString`, falling back to `PRICE`.

**`revenuecat` edge function** (Verify JWT **off**):

- **Webhook**: `Authorization` equals the secret `REVENUECAT_WEBHOOK_AUTH` (raw or with a `Bearer ` prefix,
  constant-time compare). `event.type==='TEST'` → `{ok:true,test:true}`. Otherwise it collects UUIDs from
  `app_user_id, original_app_user_id, aliases, transferred_from, transferred_to` and runs `sync(id)` for each. If
  any fails it returns 500 (RevenueCat retries).
- **App**: body `{action:'sync'}` with the user JWT → `sync(me)` → `{ok, user, plan:'pro'|'cleared'|'unchanged', expires?, error?}` (502 on error).
- **Admin**: `{action:'admin_sync', user}`, where `is_admin()` is required.
- `sync(user)`: `GET https://api.revenuecat.com/v1/subscribers/<user>` with `REVENUECAT_SECRET_KEY`.
  - Entitlement `pro` active (no expiry or a future one) → upsert `plans {tier:'pro', source:'apple', expires_at, trial: period_type==='trial'}`.
  - Inactive, the user had Apple subscriptions, and the current row is apple+pro → set `tier:'auto', expires_at:null`.
  - Admin-given plans are untouched.

### 6.4 Beta gate

- `beta_status()` (called right after sign-in and on foreground while the gate is shown) returns
  `'open' | 'admin' | 'approved' | 'pending' | 'declined' | 'none'`. An active Pro plan returns `'approved'`.
  - `open`, `admin` or `approved` → allowed. Cache `songpad:beta:<uid>='ok'`.
  - Otherwise show the waitlist screen: `none` → "Request Access" opens `https://hellodemo.app/beta.html?email=<email>`
    (only if not a relay address), plus an invite-code entry and Sign Out.
  - If the RPC errors, the app opens normally (the server still refuses AI and uploads via `beta_ok()`).
- `redeem_beta_code(code)` normalises the code (uppercase, alnum only, length ≥ 6) and returns `'approved'` or
  `'invalid'` (with a 0.5 s delay on invalid). Codes are shown as `XXXX-XXXX`.
- `beta` edge function: `{action:'request', email, name, role, heard, link, note, website|hp_field, t}` comes from
  the website, not the app. `{action:'decide', id, approve}` is admin only (§8).
- `plan_config.beta_unlocks` (shown in `my_plan.beta_unlocks`): when true, approved beta users (or everyone, when
  the gate is off) get tier `beta`, which means everything is unlocked. Admins can switch it off with
  `admin_set_beta_unlocks`.

---

## 7. RPCs and edge functions used by the app

Edge functions are called through `functions.invoke(name, {body})`, which is
`POST https://cygfgurzvmbtcegkpnss.supabase.co/functions/v1/<name>` with headers
`Authorization: Bearer <user access token>`, `apikey: <anon key>`, and `Content-Type: application/json` (or
multipart). **Most functions return HTTP 200 with `{error: "..."}`** for user-facing failures. Always check
`data.error` as well as the status. For non-2xx, the body is still `{error}` (the web reads
`error.context.json().error`).

### 7.1 `ai-proxy`

Request: `{prompt: string (1..24000 chars), modelTier?: 'complex'}`. Response: `{text: string}` or `{error: string, off?: true, pro?: true}`.

- Server: checks the user, then `ai_take('ai', complex ? 3 : 1)`. The model is `gpt-5` (complex, max 5000
  completion tokens, reasoning medium, 110 s timeout) or `gpt-5-mini` (2000 tokens, reasoning minimal, 45 s).
- Errors (all HTTP 200 unless noted):

| Condition | `error` text | Extra |
|---|---|---|
| Paused | "AI features are paused for maintenance. They'll be back shortly." | `off:true` |
| Per-minute limit | "That's a lot of requests at once. Give it a minute and try again." | |
| Free tier asking for Rate or voice | "Rate and writing voice are part of *[demo] Pro." | `pro:true` |
| Monthly heavy cap | "You've used this month's 100 Rates and voice updates. They reset on the 1st." | |
| Daily cap on Free | "You've used today's 10 free AI requests. Go Pro for more, or try again in about N hours." | `pro:true` |
| Daily cap on other plans | "You've reached today's AI limit. It resets in about N hours." | |
| Beta not approved | "Your beta access hasn't been approved yet." | HTTP 403 |
| Not signed in | "Sign in to use AI features." | HTTP 401 |
| Other | "AI couldn't start just now…", "The AI took too long to answer. Try again.", "The AI ran out of room before answering. Try again.", "The AI returned an empty response.", "Couldn't reach the AI service.", OpenAI's own message, "That request is too large (N characters, limit 24000).", "Empty prompt." | |

- Client wrapper: the AI consent check runs first. `localStorage['songpad:aiconsent']` must be `'yes'`. The first
  user-initiated use shows a native Allow / Not Now dialog naming OpenAI. Background calls never prompt (they fail
  silently unless the user tapped within the last 2.5 s). Then the local guard (§6.2), then the client-side
  `CFG.ai_off` check.
- **Every caller expects JSON in `text`.** `parseAIJson` tries a raw parse, then a ```json fenced block, then the
  first `{`/`[` to the last `}`/`]`. All prompts are built client-side (lines ~1465–1846, 2529–2541, 1760–1774). For
  a native port they can be copied verbatim. `heavy` (complex) calls are Rate and the voice-profile build.

### 7.2 `lyric-sync`

Request: `multipart/form-data` with `audio` (File; **≤24 MB**) and `prompt` (lyrics hint, truncated server-side
to 800 chars). Response:

```json
{ "words": [{"w": " word", "s": 1.23, "e": 1.56}],
  "segments": [{"s": 0.0, "e": 4.2, "ns": 0.02, "lp": -0.31}],   // no_speech_prob, avg_logprob
  "duration": 61.9, "text": "..." }
```

Errors (`{error}`, with `off`/`pro` flags):

| Condition | Status |
|---|---|
| Not signed in | 401 |
| Paused | 503 |
| Beta not approved | 403 |
| Pro required | 403 |
| Monthly cap ("…5 hours…") | 429 |
| Per-minute or daily cap | 429 |
| No audio | 400 |
| Too large (over about 12 min) | 413 |
| Whisper failure | 502 |

Each call is 1 unit (`ai_take('sync',1)`).

Client procedure (`runSync`), which must be replicated for compatible results:

1. Pick the current audio item. Download it (cache first). Decode it. Downmix to mono 16 kHz PCM.
2. Split into **60 s pieces with 2 s overlap** on each side (`a = max(0, k·60−2)`, `b = min(dur, (k+1)·60+2)`).
   Encode each as **48 kbps MP3** (fallback: 16-bit WAV). Send at most **4 in parallel**, each with a **90 s**
   client timeout. Retry once unless the error mentions sign in, deployment, too long, not set up, limit, a minute
   or paused.
3. Drop words inside segments where `ns > .6 && lp < -.8`. Keep words with `s <= pieceLen+.5`, offset by `a`, and
   keep only those starting in `[k·60, (k+1)·60)` (the last piece keeps everything after).
4. `alignLyrics(lines, words)` (lines 4969–4996). Normalise words (lowercase, strip apostrophes, `&`→`and`,
   non-alnum → space). Run a global alignment:
   - match: exact = 4, or 2 for stop words; fuzzy (Levenshtein/len ≤ .34, both ≥3 chars) = 2; else −2;
   - gap: skip a lyric word = −2; skip a heard word = −1, and free after the last lyric word; leading heard words are free;
   - ties prefer skipping the heard word.

   A line's time is the time of its first matched word, if `real>0` (non-stop-word) and `hit ≥ max(1, ceil(cnt·.3))`
   and (`hit≥2` or `cnt≤2`). Then enforce monotonic order (null out decreasing times) and fill gaps linearly between
   neighbours (or ±3 s per line at the ends, or `3·index` if nothing was timed).
5. Save `song.sync = {audioId, at, sig, lines:[{text,t}], timed, total}`. If `timed < 40% of total`, tell the user
   some lines are estimates.

### 7.3 Other edge functions called by the app

| Function | Body | Response | When |
|---|---|---|---|
| `push` | `{action:'invite', song_id, invitee}` | `{ok:true, sent:n}` | After creating an invite |
| `support` | `{action:'submit', topic:'bug'\|'account'\|'billing'\|'idea'\|'other', message (3..4000), diag?: object}` | `{ok:true, id}` or `{error}` (400 "Write a little more…", 429 "You've sent a few messages today…", 500) | Account › Contact Support. `diag` = `diagReport()`: build, seq, platform, dev, native, ua, screen, lang, tz, online, signed_in, provider, plan, iap status, sync status, song and idea counts, storage, localStorage size summary, paused flags, last 25 log lines (scrubbed, never lyrics). It's trimmed to ≤11.5 KB, and the server caps it at 12 KB. After sending, the app asks for push permission ("You'll also get a notification when we reply"). |
| `revenuecat` | `{action:'sync'}` | see §6.3 | After purchase or restore, and when the server lags Apple |

`status` and `beta` are admin-only from the app (§8).

### 7.4 RPCs and table calls (non-admin)

| Name | Params | Returns | When |
|---|---|---|---|
| `app_config_public()` | none | §2.7 object | Launch, every 180 s, on foreground (anon OK) |
| `app_seen_ping(p_device, p_platform, p_build, p_seq, p_ua)` | `LIB_DEV`, `'ios'\|'mac'\|'web'` + `'-dev'` on dev builds, `APP_COMMIT`, `APP_SEQ`, user agent (≤300) | void | Once per uid per launch, after sign-in (not stale) |
| `beta_status()` | none | text | Sign-in |
| `redeem_beta_code(code)` | text | `'approved'\|'invalid'` | Waitlist screen |
| `my_plan()` | none | §6.1 | Sign-in, foreground >60 s, after purchase |
| `my_storage()` | none | `[{used_bytes, limit_bytes}]` | Before uploads (30 s cache), Account |
| `my_notify_prefs()` | none | `{cowrite, nudge, account, plays}` (bools, default all true) | Account › Notifications |
| `set_notify_prefs(p jsonb)` | any subset of `{cowrite, nudge, account, plays, tz}` (`tz` must be an IANA name) | the prefs object | Toggle; and `{tz}` on each push registration |
| `push_register(p_token, p_topic, p_build)` | APNs token hex (32–200), `'app.hellodemo.demo'\|'app.hellodemo.demo.dev'`, `APP_COMMIT` | void | After `registration` (each launch when permission is granted) |
| `push_forget(p_token)` | token | void | On sign-out (before `signOut`) |
| `my_tickets()` | none | `[{id, topic, message, status:'open'\|'replied'\|'closed', replies:[{at, by:'admin', text, emailed}], created_at, updated_at}]` (latest 20) | Contact Support (30 s cache). Tickets whose message starts with `(You wrote to them) ` are admin-initiated and shown as "From *[demo]". |
| `delete_my_account()` | none | `'deleted'` | §5.5 |
| `app_errors` insert | `{build: APP_COMMIT, platform, kind:'crash'\|'shown', screen (≤40), message (≤600, with “quoted” text replaced by “…”), detail (≤2000)}` | | Uncaught errors and every toast starting "Couldn't ". Dedupe by kind+message, max 25 per session, signed-in only. Stops for the session if the table is missing. |
| `muse_events` upsert (onConflict `id`, ignoreDuplicates) | batches of 50: `{id, song_id, src, outcome:'kept'\|'edited'\|'deleted'\|'reject'\|'passed', shown (≤600), final (≤600), reason, created_at}` | | 1.5 s after each event |
| `muse_events` select | `id,song_id,src,outcome,shown,final,reason,created_at order by created_at desc limit 500` | | Sign-in +1.5 s (merge by id, upload local-only ones) |
| `muse_profile` select / upsert | `{user_id, profile, edited, basis, updated_at}` | | Sign-in; after building or editing (newer `updated_at` wins) |

Muse local shapes:

- Event `{id: base36 time + random, song, src, o: outcome, shown, final?, why?, at: ms}` (local keeps 500).
- Pending check `{id, song, src, shown, at}` (40): each used suggestion is re-checked after ≥3 min against the
  song's lines. An exact normalised match is `kept`, similarity ≥ .45 is `edited` with the best line as `final`,
  else `deleted`. Shared songs with more than one member are skipped.
- Reject reasons: `cliche, voice, nose, sing, sense`.
- Profile `{text, edited, at: ms, n: outcomeCountAtBuild}`. It's rebuilt automatically every 25 new outcomes, or
  every 14 days when there are new outcomes (Pro, ≥16 catalogue lines, never over a user-edited profile).

### 7.5 Push notifications (iOS)

- `@capacitor/push-notifications`. Never ask at launch. Ask (`requestPermissions`) only after sending a support
  message, sharing a song or accepting an invite, setting a username, or from Account. If permission is granted at
  sign-in, `register()` silently.
- `registration` → store the token (`songpad:pushtok`) → `push_register(token, topic, APP_COMMIT)` and
  `set_notify_prefs({tz})`. The topic is the app's bundle id.
- The server sends via APNs. It tries production first, then sandbox for new tokens. Payload:
  `{aps:{alert:{title, body}, sound:'default', 'thread-id': kind}, ...data}`, where `data.kind` is one of:

| kind | data | tap action | in-foreground action |
|---|---|---|---|
| `invite` | `invite` (id), `song` | `pullInvites`, open Account | `pullInvites` |
| `support` | `ticket` | open Account › Contact Support | reload tickets, toast |
| `cowrite` | `song` | open the song, `pullShared` | `pullShared` if open |
| `account` | `open:'account'` | `planRefresh`, open Account | `planRefresh`, toast the title |
| `nudge` | `open:'songs'` | show the song list | toast |
| `plays` | `song` | open the song | toast |
| `test`, `message` | none | none | toast |

- Automatic notifications (`notify.sql`, via the `push_outbox` queue drained every minute):
  - `cowrite`: invite accepted, or a co-writer edited (once per 30 min per song);
  - `nudge`: 3+ days without a library change, around 18:00 in the stored tz, at most weekly;
  - `account`: beta approved, Pro given, trial ends in 2 days, Pro ended;
  - `plays`: share link opened, daily.

  Each respects `notify_prefs`. Invites and support replies are always sent.

---

## 8. Admin / dev-only backend calls (brief)

All of these require `is_admin()` (email in `app_admins`, currently `dev@hellodemo.app`) and raise
"Admins only" otherwise. They're shown only in dev builds (`DEV_BUILD`: app id ends in `.dev`, or the Mac
`[developer].app`).

- **Beta**:
  - `beta_admin_summary()` → `{pending, approved, declined, gate}`;
  - `beta_admin_list(p_status)` → `beta_requests` rows;
  - `beta_admin_set_gate(p_on)`;
  - `functions.invoke('beta', {action:'decide', id, approve})` → `{ok, status, code, email, emailed, emailReady}`
    (emails a TestFlight link and code). If that fails, the fallback is `beta_admin_decide(p_id, p_approve)`;
  - `beta_admin_mark_emailed`.
- **Overview, users and errors**:
  - `admin_overview()`;
  - `admin_users(p_q, p_limit)` (rows: id, email, provider, created_at, last_sign_in_at, username, display_name,
    songs, ideas, storage_bytes, ai_today, errors_7d, beta, plan);
  - `admin_errors(p_hours)` → `{groups, latest}`;
  - `admin_user_errors(p_user)`;
  - `admin_user_detail(p_user)` (everything about one account: devices, sessions, plan row, usage, tickets…);
  - `admin_push_devices(p_user)`.
- **Account actions**:
  - `admin_set_plan(p_user, p_tier 'free'|'pro'|'beta'(=auto), p_days)` (also used to preview Free on your own
    account);
  - `admin_set_beta_unlocks(p_on)`;
  - `admin_plan_summary()`;
  - `admin_set_access(p_user, p_approved)`;
  - `admin_reset_ai(p_user)`;
  - `admin_signout_user(p_user)`;
  - `admin_suspend(p_user, p_on)`;
  - `functions.invoke('revenuecat', {action:'admin_sync', user})`.
- **Settings and remote controls**:
  - `admin_set_setting(p_key 'signups_per_day'|'storage_mb', p_value int|null)`;
  - `admin_set_config(p jsonb)` (any of banner, banner_kind, ai_off, sync_off, uploads_off, min_seq, update_note;
    returns `app_config_public()`);
  - `admin_builds()` (builds seen in the last 30 days).
- **Help desk**:
  - `admin_tickets(p_status 'open'|'replied'|'closed'|'all')` → `{counts, list}`;
  - `admin_ticket_update(p_id, p_status, p_note)`;
  - `support` `{action:'reply', id, text}` → `{ok, emailed, emailReady}`;
  - `support` `{action:'email', user, subject, text}` (starts a conversation; inserted as a replied ticket).
- **Push**: `push` `{action:'admin_send', user, title?, body}` and `{action:'test'}`.
- **Status**: `admin_status()` → `{services:[{service, at, ok, ms, detail, up_24h, up_7d, avg_ms, last_down, bars[48]}], checked_at}`;
  `functions.invoke('status', {action:'check'})` → `{results, saved, action}`.
- **Server-side only** (not callable by the app): `_notify*`, `notify_claim/result/scheduled`, the cron-token
  helpers, `hook_signup_limit` (Before User Created auth hook: daily cap, messages surface as OAuth `error_description`),
  `grant_username`.

---

## 9. Risks and gotchas for the native rewrite

1. **Whole-object LWW on device clocks.** The library and shared songs both resolve conflicts by comparing
   `updated` (client `Date.now()`). A phone with a wrong clock can win or lose every merge. There is no field merge.
   Keep it identical for compatibility, but consider clamping a future `updated` to server time.
2. **Delete detection depends on `base`.** Losing or resetting `songpad:sync:base` is safe (no deletes inferred).
   But a local list that is *missing* items while `base` is intact will tombstone those items for every device.
   Load local data fully before the first sync, and migrate the web's localStorage library (or start empty
   *with an empty base*).
3. **Round-trip unknown fields** on songs, ideas and items, and keep the canonical JSON comparison. Otherwise the web
   app's fields (`melody`, `rating`, `pf`, `scheme`, `brief`, `shares`, `share`, `capo`, `time`, `guide`…) will be
   stripped from the cloud.
4. **`rich` is HTML from contenteditable**, and it takes priority over `lyrics` for display on the other clients. A
   native editor must either emit the same HTML subset (spans with inline style, `<br>`) or clear `rich` whenever it
   edits the text. Formatting would be lost for web users in the second case.
5. **Live co-writing offsets are UTF-16 code units.** Use `String.utf16` for `liveDiff`/`livePatch`, or emoji and
   accented text will corrupt co-writers' copies.
6. **The `cloud_library` payload is large and fully rewritten** on every sync: cover art is inline base64, there are
   up to 30 versions with `rich`, and ratings are included. On large libraries, expect hundreds of KB to MB per sync,
   with a 20 s poll.
7. **Mixed `bpm` type** (string vs number). Decode leniently.
8. Shared songs that aren't open don't get co-writers' edits until opened (no poll of `shared_songs`).
9. Many Pro gates are **client-only** (Lines, Perform, Melody, Release, Play with Lyrics, whole-song context, memo
   limits, voice memo upload). The server only enforces AI units, sync, storage, file reads and writes, and invites.
   Keep parity in native, or the free tier silently changes.
10. **The `beta` tier counts as Pro** in `isPro()`. The beta gate fails open on RPC errors.
11. **`ai-proxy` returns HTTP 200 with `{error}`**. Don't treat 200 as success.
12. **`RC_KEY` is empty**: purchases have never run in production. The `revenuecat` webhook depends on
    `appUserID = supabase user id`.
13. **Sign in with Apple audience**: the dev bundle id needs adding to the Supabase Apple provider. The web code
    hard-codes `clientId:'app.hellodemo.demo'`.
14. **`APP_SEQ` must continue the existing sequence** (> 413), or `min_seq` will lock out or never reach native builds.
15. **The pinned list is per device** (not synced). AI consent is also per device.
16. **Avatars are data URLs in `profiles.avatar_url`.** Other users' rows can contain anything, so validate them
    (`avOk`) and the cover `art` (`artOk`) before rendering. Sanitise every `rich` you render.
17. **Signed-out songs** (`songpad:v1`) are never merged into an account. The app requires sign-in, so in practice
    this only matters for very old installs.
18. **Realtime private channels**: the web silently falls back to public channels if a private join is refused.
    Confirm "Allow public access" is off in Realtime settings, or keep the same fallback.
19. Invite email matching in `pullInvites` is dead code, because RLS only matches `invitee_user_id`. Invites are by
    username only.
20. Free users' idea memos never leave the device. Another device will show them as "still uploading from the
    device it was recorded on".
