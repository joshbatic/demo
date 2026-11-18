// The "How *[demo] works" guide: the words, and the little pictures that go with them.
// Edit here, then run `node scripts/guide/build.js`. It writes the web app's copy (between the GUIDE-CONTENT
// markers in www/index.html), the iPhone app's (native/Demo/Services/GuideContent.swift) and the iPhone app's
// pictures (native/Demo/Assets.xcassets/guide-*.imageset, drawn from the same HTML as the web's).
// Blocks: ['h', section] · ['p', paragraph] · ['f', picture, caption] · ['q', question, answer]

const blocks = [
  ['h', 'Start here'],
  ['p', 'Welcome to *[demo]. This song is a guide to everything in the app. Scroll through, and delete it from your songs whenever you like.'],
  ['p', 'Everything saves as you type, and syncs to every device you’re signed in on.'],

  ['h', 'Writing'],
  ['p', 'Tap + to start a song. Give it a title, then write: every line is a lyric line.'],
  ['p', 'Put a section name on its own line in square brackets, like [Verse] or [Bridge]. Write your chorus once under [Chorus]. Next time, type [Chorus] and press Return, and it fills itself in.'],
  ['f', 'write', 'Select words to make them bold, colour them, or highlight them. Highlights mark a Hook, a line to Rework, or an Idea.'],

  ['h', 'Rhymes & words'],
  ['p', 'The rhyme bar above the keyboard rhymes with the word you just wrote. Tap one to put it in.'],
  ['f', 'rhymes', 'Switch it to Perfect, Near, Phrases, Synonyms, Opposites, Define and more. Pull it up for the full Dictionary.'],
  ['p', 'Rhyme map colours the words that rhyme with each other. Syllable counts shows how long each line runs, so your verses sit evenly. Both are at the top of the song.'],
  ['f', 'map', 'Rhyme map and Syllable counts, both switched on.'],

  ['h', 'When you’re stuck'],
  ['p', 'Muse deals out quick prompts and exercises when the page is blank.'],
  ['p', 'Lines writes rhyming next lines in your voice. Writing voice sets that voice: genre, mood and style. Listen to the whole song makes every suggestion fit what you’ve written so far.'],
  ['p', 'Rate gives an honest co-writer’s read: a score, what’s working, and notes you can act on.'],
  ['f', 'rate', 'Rate’s notes point at the lines they’re about.'],

  ['h', 'Ideas & voice memos'],
  ['p', 'Ideas sits at the top of your songs. It’s a quick jot for stray lines, titles and concepts: tap + to jot one.'],
  ['p', 'Record a voice memo the moment a melody turns up. When an idea grows, start a song from it.'],
  ['f', 'ideas', 'Lines, ideas, concepts and memos, all in one place.'],

  ['h', 'Details & release'],
  ['p', 'Open ••• › Details for chords, key, tempo, capo, tuning and a status: Idea, Draft, Demo or Finished.'],
  ['p', '••• › Credits keeps the writers and their splits, plus the release details: ISRC, UPC, release date and label. Once a song is out, Find Release looks it up on Apple Music and fills them in for you.'],
  ['f', 'details', 'Details for the music. Credits for who wrote it and where it came out.'],

  ['h', 'Audio & lyric sync'],
  ['p', 'In ••• › Audio, add each version of the song: voice memo, demo, mix, master. Tick the one that’s current. Stems, artwork and session files can live with the song too.'],
  ['p', 'Sync Lyrics listens to the current version and times every line for you. Export .lrc saves the timed lyrics for streaming services and distributors.'],
  ['f', 'sync', 'Play with Lyrics lights up each line in time. Tap a line to jump there.'],

  ['h', 'Albums'],
  ['p', 'Gather songs into an album, EP or single with New Album, at the bottom of your songs. Its artwork goes on every song in it, and the album page shows how close each song is to finished.'],
  ['f', 'album', 'Read Lyrics shows the whole album’s words, one song after another.'],

  ['h', 'Sharing & co-writing'],
  ['p', 'Share sends a song as a link anyone can open, with its audio, or as an image of the lyrics. Share an album and it gets a page of its own, with every song on it.'],
  ['f', 'share', 'A share page: the song, its audio and its words, on any phone or computer.'],
  ['p', 'Pick a username in Account so co-writers can find you, then invite them from ••• › Co-write. You can write in the same song at the same time, and see each other’s changes as they happen.'],

  ['h', 'Perform'],
  ['p', '••• › Perform turns the song into a scrolling teleprompter for the stage or the studio. Set the speed and the text size, and it rolls on by itself.'],
  ['f', 'perform', 'Big, clear lyrics that scroll at your pace.'],

  ['h', 'Organising'],
  ['p', 'Make folders, and drag songs between them. Swipe a song left to pin it to the top, or to delete it.'],
  ['f', 'swipe', 'Swipe left on any song in the list.'],
  ['p', 'On iPhone, add the *[demo] widgets to your Home Screen: record a memo in one tap, or jump back into the song you were writing.'],

  ['h', 'Keeping it safe'],
  ['p', 'Save a Version in ••• › Details › Versions before big changes, and restore it any time. *[demo] also keeps one by itself when you come back to a song after a while.'],
  ['p', 'Clean up tidies case, spacing and section tags, ready for streaming services. The original is saved in Versions first.'],
  ['p', 'Copy Lyrics from •••, or export every song from Account. On Mac, songs are also saved as files in Documents › [demo] Songs.'],

  ['h', 'Common questions'],
  ['q', 'Where are my songs kept?', 'In your account, synced to iPhone, Mac and the web app at hellodemo.app/app. Each device keeps a copy too, so you can keep writing without a connection.'],
  ['q', 'Who can see my songs?', 'Only you, until you invite a co-writer or send a share link. You can stop a share link any time.'],
  ['q', 'How do I get my songs out?', 'Copy Lyrics from •••, export a song’s timed lyrics as .lrc, or export every song from Account.'],
  ['q', 'I changed something and want it back.', 'Open ••• › Details › Versions and restore an earlier version. Save one yourself before big changes.'],
  ['q', 'Do the AI features read my songs?', 'Only when you use them. Lines, Muse and Rate send what you’re working on to OpenAI. Turn AI Features off in Account and nothing is sent.'],
  ['q', 'What does Pro add?', 'Demos, mixes and stems with 5 GB of space, voice memos synced everywhere, lyric sync, co-writing, share links, Lines and Rate in your voice, and Perform mode.'],
  ['q', 'Where do I get help?', 'Account › Contact Support, or email help@hellodemo.app.'],
];

// ---- the pictures: plain HTML, white cards on a clear background (the app draws the soft colour behind) ----
const wave = (n, lit) => '<span class="gw">' + Array.from({ length: n }, (_, i) => {
  const h = Math.round(6 + Math.abs(Math.sin(i * 0.7) * 20 + Math.sin(i * 2.3) * 6));
  return '<i style="height:' + h + 'px' + (i >= lit ? ';opacity:.3' : '') + '"></i>';
}).join('') + '</span>';
const tag = (t) => '<b class="gt">[' + t + ']</b>';
const st = (s) => '<span class="gs gs-' + s.toLowerCase() + '">' + s + '</span>';

const figs = {
  write: '<div class="gc">' + tag('Chorus') + '<br><span class="hk">Leave the kitchen light on</span><br>I’ll find my way <span class="rw">home somehow</span><br><span class="gi">Through the rain</span> and the radio<br>' + tag('Verse 2') + '<br><span class="gm">…</span></div>',
  rhymes: '<div class="gseg"><span class="on">Perfect</span><span>Near</span><span>Phrases</span><span>Synonyms</span></div><div class="gchips"><span>night</span><span>light</span><span>tonight</span><span>bright</span><span>alright</span><span>sight</span><span>hold on tight</span></div>',
  map: '<div class="gc gmap"><div><span>Leave the kitchen <u class="ra">light</u> on</span><em>7</em></div><div><span>I’ll find my way <u class="rb">home</u></span><em>6</em></div><div><span>On a <u class="ra">night</u> like this</span><em>5</em></div><div><span>Til I’m <u class="rb">alone</u></span><em>4</em></div></div>',
  rate: '<div class="gc"><div class="grate"><span class="gring"><i></i>78</span><span><b>Strong hook, soft second verse</b><br><span class="gm">The chorus lands. Verse 2 repeats its images.</span></span></div><div class="gnote"><i style="background:#34C759"></i><span><b>Working:</b> “Leave the kitchen light on”</span></div><div class="gnote"><i style="background:#FF9500"></i><span><b>Try:</b> a new image in line 6</span></div></div>',
  ideas: '<div class="gc glist"><div><span class="gk">Line</span>Leave the kitchen light on</div><div><span class="gk">Idea</span>A song called “Radio Weather”</div><div><span class="gk">Concept</span>Two people who only talk in cars</div><div class="gmemo"><span class="gplay"></span>' + wave(26, 26) + '<span class="gm">0:24</span></div></div>',
  details: '<div class="gc grows"><div><span>Key</span><b>A minor</b></div><div><span>Tempo</span><b>92 BPM</b></div><div><span>Status</span>' + st('Finished') + '</div></div><div class="gc grows" style="margin-top:8px"><div><span class="gfr"><i></i>Find Release</span><b class="gm">Apple Music ›</b></div><div><span>ISRC</span><b>AU-XYZ-26-00012</b></div></div>',
  sync: '<div class="gc">' + wave(44, 26) + '<div class="glyr"><div class="gm2">Leave the kitchen light on</div><div class="glit">I’ll find my way home somehow</div><div class="gm2">Through the rain and the radio</div></div></div>',
  album: '<div class="galb"><span class="gart"></span><div><b>Late Night Sessions</b><br><span class="gm">Album · 2026 · 2 of 4 finished</span></div></div><div class="gc gtr"><div><em>1</em><span>Kitchen Light</span>' + st('Finished') + '</div><div><em>2</em><span>Better in the Dark</span>' + st('Demo') + '</div><div><em>3</em><span>Ninety Days</span>' + st('Draft') + '</div></div>',
  share: '<div class="gsh"><span class="gart sm"></span><b>Kitchen Light</b><span class="gm">Jordan Lee</span><span class="gbtn">▶︎ Listen</span><div class="gshl">Leave the kitchen light on<br>I’ll find my way home somehow</div></div>',
  perform: '<div class="gperf"><div class="gm3">Leave the kitchen light on</div><div class="gbig">I’ll find my way<br>home somehow</div><div class="gm3">Through the rain and the radio</div><div class="gpc"><span>Slower</span><b>Speed 1.2×</b><span>Faster</span></div></div>',
  swipe: '<div class="gsw"><div class="gsr"><span class="gart xs"></span><span><b>Kitchen Light</b><br><span class="gm">Leave the kitchen light on</span></span></div><span class="gpin">Pin</span><span class="gdel">Delete</span></div>',
};

const css = `.gf{font:14px/1.45 -apple-system,BlinkMacSystemFont,Inter,system-ui,sans-serif;color:#000;text-align:left;-webkit-user-select:none;user-select:none}
.gf b{font-weight:600}.gf .gm{color:#8E8E93}.gf .gm2{color:rgba(0,0,0,.28)}.gf .gm3{color:rgba(255,255,255,.35);font-size:15px}
.gf .gc{background:#fff;border-radius:12px;box-shadow:0 1px 3px rgba(0,0,0,.1),0 0 0 .5px rgba(0,0,0,.05);padding:10px 12px}
.gf .gt{color:#8E8E96;font-weight:700}.gf .hk{background:rgba(255,204,0,.38);border-radius:3px}.gf .rw{background:rgba(255,69,58,.24);border-radius:3px}.gf .gi{background:rgba(10,132,255,.22);border-radius:3px}
.gf .gseg{display:flex;background:rgba(118,118,128,.12);border-radius:9px;padding:2px;font-size:12px;margin-bottom:10px}.gf .gseg span{flex:1;text-align:center;padding:4px 0;border-radius:7px;color:#3C3C43}.gf .gseg .on{background:#fff;box-shadow:0 1px 2px rgba(0,0,0,.15);font-weight:600;color:#000}
.gf .gchips{display:flex;gap:6px;flex-wrap:wrap}.gf .gchips span{background:#fff;border-radius:999px;padding:5px 11px;font-size:13px;box-shadow:0 0 0 .5px rgba(0,0,0,.1),0 1px 2px rgba(0,0,0,.06)}
.gf .gmap div{display:flex;justify-content:space-between;gap:10px}.gf .gmap em{font-style:normal;color:#8E8E93;font-size:12px;font-variant-numeric:tabular-nums;padding-top:1px}.gf .gmap u{text-decoration:none;border-radius:3px;padding:0 2px;font-weight:600}.gf .ra{color:#2C8DBF;background:rgba(44,141,191,.14)}.gf .rb{color:#A35FCB;background:rgba(163,95,203,.14)}
.gf .grate{display:flex;gap:12px;align-items:center;margin-bottom:8px}.gf .gring{width:54px;height:54px;position:relative;display:grid;place-items:center;font-size:19px;font-weight:700;flex:none}.gf .gring i{position:absolute;inset:0;border-radius:50%;background:conic-gradient(#34C759 0 78%,rgba(118,118,128,.16) 78% 100%);-webkit-mask:radial-gradient(circle,transparent 21px,#000 22px);mask:radial-gradient(circle,transparent 21px,#000 22px)}
.gf .gnote{display:flex;gap:8px;align-items:baseline;font-size:13px;margin-top:4px}.gf .gnote i{width:8px;height:8px;border-radius:4px;flex:none}
.gf .glist>div{display:flex;gap:8px;align-items:center;padding:6px 0;border-top:.5px solid rgba(60,60,67,.14)}.gf .glist>div:first-child{border-top:0;padding-top:0}.gf .gk{font-size:11px;font-weight:600;color:#3C3C43;background:rgba(118,118,128,.14);border-radius:5px;padding:1px 6px;flex:none}
.gf .gw{display:flex;align-items:center;gap:2px;height:30px;flex:1}.gf .gw i{width:3px;border-radius:2px;background:#FF2D55;opacity:.9}
.gf .gmemo{gap:10px}.gf .gplay{width:24px;height:24px;border-radius:12px;background:#FF2D55;flex:none;position:relative}.gf .gplay::after{content:'';position:absolute;left:9px;top:7px;border-left:8px solid #fff;border-top:5px solid transparent;border-bottom:5px solid transparent}
.gf .grows>div{display:flex;justify-content:space-between;align-items:center;padding:6px 0;border-top:.5px solid rgba(60,60,67,.14)}.gf .grows>div:first-child{border-top:0;padding-top:0}.gf .grows>div:last-child{padding-bottom:0}.gf .grows span{color:#000}.gf .grows b{font-weight:400;color:#8E8E93}
.gf .gfr{display:flex;align-items:center;gap:8px}.gf .gfr i{width:22px;height:22px;border-radius:6px;background:#FA2D48;display:inline-block;position:relative}.gf .gfr i::after{content:'';position:absolute;left:5px;top:5px;width:8px;height:8px;border:2px solid #fff;border-radius:50%}
.gf .gs{font-size:12px;font-weight:600;border-radius:999px;padding:2px 9px}.gf .gs-finished{background:rgba(52,199,89,.16);color:#248A3D}.gf .gs-demo{background:rgba(175,82,222,.14);color:#8944AB}.gf .gs-draft{background:rgba(255,149,0,.16);color:#C93400}.gf .gs-idea{background:rgba(118,118,128,.14);color:#3C3C43}
.gf .glyr{margin-top:8px;font-size:15px}.gf .glit{font-weight:700;font-size:16px}
.gf .galb{display:flex;gap:12px;align-items:center;margin-bottom:10px}.gf .gart{width:64px;height:64px;border-radius:10px;flex:none;background:radial-gradient(circle at 70% 30%,#FFD3A5,transparent 60%),linear-gradient(135deg,#7F7FD5,#E86ED0 60%,#FFB199);box-shadow:0 4px 12px rgba(0,0,0,.15)}.gf .gart.sm{width:120px;height:120px;border-radius:12px;margin:2px auto 10px;display:block}.gf .gart.xs{width:34px;height:34px;border-radius:7px;box-shadow:none}
.gf .gtr>div{display:flex;gap:10px;align-items:center;padding:6px 0;border-top:.5px solid rgba(60,60,67,.14)}.gf .gtr>div:first-child{border-top:0;padding-top:0}.gf .gtr>div:last-child{padding-bottom:0}.gf .gtr em{font-style:normal;color:#8E8E93;width:12px}.gf .gtr span:not(.gs){flex:1}
.gf .gsh{background:linear-gradient(180deg,#E9DDFB,#FBE3EC);border-radius:16px;padding:14px;text-align:center;display:flex;flex-direction:column;align-items:center;box-shadow:0 0 0 .5px rgba(0,0,0,.06)}.gf .gsh>b{font-size:17px}.gf .gbtn{margin:8px 0 10px;background:#1C1C1E;color:#fff;border-radius:999px;padding:6px 16px;font-size:13px;font-weight:600}.gf .gshl{font-size:13px;color:#3C3C43}
.gf .gperf{background:#000;border-radius:14px;padding:16px 14px;color:#fff;text-align:center}.gf .gbig{font-size:24px;font-weight:700;line-height:1.2;margin:8px 0}.gf .gpc{display:flex;justify-content:space-between;align-items:center;margin-top:12px;font-size:12px;color:rgba(255,255,255,.55)}.gf .gpc b{color:#fff;background:rgba(255,255,255,.16);border-radius:999px;padding:4px 12px;font-weight:600}
.gf .gsw{display:flex;border-radius:12px;overflow:hidden;box-shadow:0 0 0 .5px rgba(0,0,0,.06);height:56px}.gf .gsr{flex:1;background:#fff;display:flex;gap:10px;align-items:center;padding:0 12px;margin-left:-40px;padding-left:52px;white-space:nowrap;overflow:hidden}.gf .gsr b{font-size:15px;font-weight:500}.gf .gsr .gm{font-size:12px}
.gf .gpin,.gf .gdel{width:64px;display:grid;place-items:center;color:#fff;font-size:12px;font-weight:600;flex:none}.gf .gpin{background:#FF9500}.gf .gdel{background:#FF3B30}`;

module.exports = { blocks, figs, css };
