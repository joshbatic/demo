// *[demo] artist page renderer: artist.hellodemo.app/<username>.
// Pure function from the snapshot the app publishes (artist_pages.data) to a complete HTML page.
//
// d = { name, username, avatar, bio, links:[{k,u}], bg:{top,bot,glow,k}, featured, songs:[
//       { id, title, art, date:'YYYY-MM-DD', co, links:{spotify,apple,youtube,presave,preadd}, audio:{src,dur}|null } ] }
// env = { SB_URL, SB_KEY, PUB }: Supabase address, public key and the public bucket prefix (for checking file URLs)

const esc = (s) => String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const txt = (v, n) => (typeof v === 'string' ? v : '').replace(/\s+/g, ' ').trim().slice(0, n);
const col = (v) => (typeof v === 'string' && /^(#[0-9a-f]{3,8}|hsla?\(\s*[\d.]+\s*,\s*[\d.]+%\s*,\s*[\d.]+%\s*(,\s*[\d.]+\s*)?\))$/i.test(v.trim()) ? v.trim() : '');
const hsl3 = (v) => (typeof v === 'string' && /^\s*\d{1,3}\s*,\s*\d{1,3}%\s*,\s*\d{1,3}%\s*$/.test(v) ? v.trim() : '');
const https = (v) => { if (typeof v !== 'string') return ''; let u = v.trim(); if (/^http:\/\//i.test(u)) u = 'https://' + u.slice(7); if (!/^https:\/\/[^\s"'<>]+$/i.test(u) || u.length > 600) return ''; return u; };
const day = (v) => (typeof v === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(v) ? v : '');

const LINKS = { spotify: 'Spotify', apple: 'Apple Music', instagram: 'Instagram', tiktok: 'TikTok', youtube: 'YouTube', soundcloud: 'SoundCloud', bandcamp: 'Bandcamp', website: 'Website' };
const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
const DAYS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
function longDate(d) { const t = new Date(d + 'T12:00:00Z'); return DAYS[t.getUTCDay()] + ' ' + t.getUTCDate() + ' ' + MONTHS[t.getUTCMonth()]; }
function shortDate(d) { const t = new Date(d + 'T12:00:00Z'); return t.getUTCDate() + ' ' + MONTHS[t.getUTCMonth()].slice(0, 3) + ' ' + t.getUTCFullYear(); }

// releases go out at midnight local time, earliest in UTC+14; the page re-checks in the visitor's own time zone
function isOut(date) { if (!date) return true; const now = new Date(Date.now() + 14 * 3600e3).toISOString().slice(0, 10); return date <= now; }

function clean(d, env) {
  const okFile = (u) => { u = https(u); return u && (!env.PUB || u.indexOf(env.PUB) === 0) ? u : ''; };
  const songs = (Array.isArray(d.songs) ? d.songs : []).slice(0, 60).map((s) => {
    s = s || {}; const L = s.links || {};
    const a = s.audio && okFile(s.audio.src) ? { src: okFile(s.audio.src), dur: +s.audio.dur || 0 } : null;
    return {
      id: txt(s.id, 80), title: txt(s.title, 120) || 'Untitled', art: okFile(s.art), date: day(s.date), co: !!s.co, audio: a,
      links: { spotify: https(L.spotify), apple: https(L.apple), youtube: https(L.youtube), presave: https(L.presave), preadd: https(L.preadd) },
    };
  }).filter((s) => s.id);
  const bg = d.bg || {};
  return {
    name: txt(d.name, 80) || txt(d.username, 40), username: txt(d.username, 40), bio: txt(d.bio, 280),
    avatar: https(d.avatar),
    links: (Array.isArray(d.links) ? d.links : []).map((l) => ({ k: LINKS[l && l.k] ? l.k : 'website', u: https(l && l.u), label: txt(l && l.label, 30) })).filter((l) => l.u).slice(0, 12),
    bg: { top: col(bg.top) || 'hsl(24,70%,90%)', bot: col(bg.bot) || 'hsl(268,60%,88%)', glow: col(bg.glow) || 'hsl(210,70%,90%)', k: hsl3(bg.k) || '262,32%,24%' },
    featured: txt(d.featured, 80), songs,
  };
}

function pickFeatured(D) {
  const byId = D.songs.filter((s) => s.id === D.featured)[0];
  if (byId) return byId;
  const up = D.songs.filter((s) => s.date && !isOut(s.date)).sort((a, b) => (a.date < b.date ? -1 : 1))[0];
  return up || D.songs.filter((s) => s.date).sort((a, b) => (a.date < b.date ? 1 : -1))[0] || D.songs[0] || null;
}


/* ---- look: native iOS. Grouped background, inset grouped lists, SF type scale, capsule buttons, a tint
   colour from the artwork, a contact-card header, a nav bar that appears on scroll and a mini player. ---- */
const G = {
  play: '<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M7.5 4.9v14.2a1 1 0 0 0 1.53.85l11.2-7.1a1 1 0 0 0 0-1.7L9.03 4.05a1 1 0 0 0-1.53.85z"/></svg>',
  pause: '<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><rect x="6" y="4.5" width="4.2" height="15" rx="1.3"/><rect x="13.8" y="4.5" width="4.2" height="15" rx="1.3"/></svg>',
  note: '<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M19 3.5v11.7a3.3 3.3 0 1 1-1.8-2.9V7.4l-8 1.9v8.3a3.3 3.3 0 1 1-1.8-2.9V6.3a1 1 0 0 1 .77-.97l9.6-2.3A1 1 0 0 1 19 3.5z"/></svg>',
  camera: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true"><rect x="3.5" y="3.5" width="17" height="17" rx="5"/><circle cx="12" cy="12" r="4"/><circle cx="17.2" cy="6.8" r="1" fill="currentColor" stroke="none"/></svg>',
  video: '<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M4.5 5.5h15a2.5 2.5 0 0 1 2.5 2.5v8a2.5 2.5 0 0 1-2.5 2.5h-15A2.5 2.5 0 0 1 2 16V8a2.5 2.5 0 0 1 2.5-2.5zm5.5 3.3v6.4l5.4-3.2z"/></svg>',
  cloud: '<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M17.5 19H7a5 5 0 0 1-.8-9.94A6.5 6.5 0 0 1 18.6 8.6 5.2 5.2 0 0 1 17.5 19z"/></svg>',
  tag: '<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M7.6 6h13.4l-4.6 12H3z"/></svg>',
  globe: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" aria-hidden="true"><circle cx="12" cy="12" r="8.5"/><path d="M3.5 12h17M12 3.5c2.4 2.4 3.6 5.2 3.6 8.5s-1.2 6.1-3.6 8.5c-2.4-2.4-3.6-5.2-3.6-8.5S9.6 5.9 12 3.5z"/></svg>',
  bell: '<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M12 2.8a6 6 0 0 0-6 6v3.6l-1.7 2.9a1 1 0 0 0 .86 1.5h13.68a1 1 0 0 0 .86-1.5L18 12.4V8.8a6 6 0 0 0-6-6zM9.2 18.6a2.9 2.9 0 0 0 5.6 0z"/></svg>',
  chev: '<svg viewBox="0 0 8 14" width="8" height="14" aria-hidden="true"><path d="M1.5 1.5 6.5 7l-5 5.5" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>',
};
// generic glyphs on each service's colour, like Settings rows (not the services' logos)
const TILE = {
  spotify: ['#1DB954', G.note], apple: ['#FA2D48', G.note], instagram: ['linear-gradient(45deg,#F9A13A,#E1306C 55%,#8A3AB9)', G.camera],
  tiktok: ['#111', G.note], youtube: ['#FF0000', G.video], soundcloud: ['#FF5500', G.cloud], bandcamp: ['#1DA0C3', G.tag], website: ['#0A84FF', G.globe],
};
const tile = (k) => { const t = TILE[k] || TILE.website; return '<span class="tile" style="background:' + t[0] + '">' + t[1] + '</span>'; };

function hslOf(s) { const m = /hsla?\(\s*([\d.]+)\s*,\s*([\d.]+)%\s*,\s*([\d.]+)%/.exec(s || ''); return m ? [+m[1], +m[2], +m[3]] : [262, 40, 60]; }
function colours(bg) {
  const a = hslOf(bg.top), b = hslOf(bg.bot), k = (bg.k || '').split(',').map((x) => parseFloat(x)), h = isFinite(k[0]) ? k[0] : a[0];
  const sat = Math.max(48, Math.min(78, (isFinite(k[1]) ? k[1] : 40) * 1.6)), dim = h >= 40 && h <= 200; // yellows and greens need to be darker to carry white text
  return {
    tint: 'hsl(' + h + ',' + sat + '%,' + (dim ? 32 : 44) + '%)', tintD: 'hsl(' + h + ',' + sat + '%,68%)',
    h1: bg.top, h2: bg.bot,
    h1D: 'hsl(' + a[0] + ',' + Math.round(a[1] * 0.5) + '%,19%)', h2D: 'hsl(' + b[0] + ',' + Math.round(b[1] * 0.5) + '%,12%)',
  };
}

function render(raw, env) {
  const D = clean(raw || {}, env), q = esc, F = pickFeatured(D), C = colours(D.bg);
  const rest = D.songs.filter((s) => s !== F).sort((a, b) => {
    const ua = a.date && !isOut(a.date), ub = b.date && !isOut(b.date);
    if (ua !== ub) return ua ? -1 : 1;
    if (ua) return a.date < b.date ? -1 : 1;
    if (!!a.date !== !!b.date) return a.date ? -1 : 1;
    return a.date < b.date ? 1 : a.date > b.date ? -1 : 0;
  });
  const desc = D.bio || ('Music by ' + D.name + '. Listen, pre-save and hear about new songs first.');
  const img = D.avatar || (F && F.art) || 'https://hellodemo.app/icon-512.png';
  const url = 'https://artist.hellodemo.app/' + encodeURIComponent(D.username);
  const ini = (D.name.match(/\b\w/g) || ['?']).slice(0, 2).join('').toUpperCase();
  const state = (d) => (isOut(d) ? 'is-out' : 'is-up');
  const playable = [F].concat(rest).filter((s) => s && s.audio)[0];
  const ext = ' target="_blank" rel="noopener"';
  const playAttrs = (s) => ' data-src="' + q(s.audio.src) + '" data-title="' + q(s.title) + '" data-art="' + q(s.art) + '"';

  // quick actions under the name, like a contact card: play, then the first links
  const qa = [];
  if (playable) qa.push('<button class="qa play"' + playAttrs(playable) + '><span class="qi">' + G.play + '</span>Play</button>');
  D.links.slice(0, 4 - qa.length).forEach((l) => qa.push('<a class="qa" href="' + q(l.u) + '"' + ext + '><span class="qi">' + (TILE[l.k] || TILE.website)[1] + '</span>' + q(l.label || LINKS[l.k]) + '</a>'));

  let feat = '';
  if (F) {
    const L = F.links, up = F.date && !isOut(F.date);
    const listen = [['spotify', 'Spotify'], ['apple', 'Apple Music'], ['youtube', 'YouTube']].filter((x) => L[x[0]]);
    feat = '<section class="sec">' +
      '<h2 class="sh ' + state(F.date) + '" data-date="' + q(F.date) + '"><span class="up">Coming Soon</span><span class="out">Latest Release</span></h2>' +
      '<div class="card feat ' + state(F.date) + '" data-date="' + q(F.date) + '">' +
        '<div class="fhead"><span class="fart">' + (F.art ? '<img src="' + q(F.art) + '" alt="">' : '') + '</span><span class="ftx">' +
          (F.date ? '<span class="eyebrow"><span class="up">Out ' + q(longDate(F.date)) + '</span><span class="out">' + q(shortDate(F.date)) + '</span></span>' : '') +
          '<b>' + q(F.title) + '</b><span class="fby">' + q(D.name) + '</span></span></div>' +
        (F.date ? '<div class="cd up" role="timer" aria-label="Time until release"><span><b data-u="d">0</b>days</span><span><b data-u="h">0</b>hours</span><span><b data-u="m">0</b>min</span><span><b data-u="s">0</b>sec</span></div>' : '') +
        '<div class="acts">' +
          (L.presave ? '<a class="btn pri up" href="' + q(L.presave) + '"' + ext + '>Pre-save on Spotify</a>' : '') +
          (L.preadd ? '<a class="btn up" href="' + q(L.preadd) + '"' + ext + '>Pre-add on Apple Music</a>' : '') +
          (F.date ? '<button class="btn txt up remind" data-song="' + q(F.id) + '" data-title="' + q(F.title) + '"><span class="bi">' + G.bell + '</span>Remind Me</button>' : '') +
          (F.audio ? '<button class="btn pri out play"' + playAttrs(F) + '><span class="bi">' + G.play + '</span>Play</button>' : '') +
        '</div>' +
        (listen.length ? '<div class="rows out">' + listen.map((x) => '<a class="row" href="' + q(L[x[0]]) + '"' + ext + '>' + tile(x[0]) + '<span class="rl">Listen on ' + x[1] + '</span><span class="chev">' + G.chev + '</span></a>').join('') + '</div>' : '') +
      '</div></section>';
  }

  const songs = rest.length ? '<section class="sec"><h2 class="sh">Songs</h2><div class="card rows">' + rest.map((s) => {
    const L = s.links, lis = L.spotify || L.apple || L.youtube;
    let act = '';
    if (s.audio) act = '<button class="get play out"' + playAttrs(s) + ' aria-label="Play ' + q(s.title) + '">Play</button>';
    else if (lis) act = '<a class="get out" href="' + q(lis) + '"' + ext + '>Listen</a>';
    if (L.presave) act += '<a class="get up" href="' + q(L.presave) + '"' + ext + '>Pre-save</a>';
    return '<div class="row song ' + state(s.date) + '" data-date="' + q(s.date) + '"><span class="th">' + (s.art ? '<img src="' + q(s.art) + '" alt="" loading="lazy">' : '') + '</span>' +
      '<span class="rt"><b>' + q(s.title) + '</b><span>' + (s.date ? '<span class="up">Out ' + q(shortDate(s.date)) + '</span><span class="out">' + q(s.date.slice(0, 4)) + (s.co ? ' · Co-written' : '') + '</span>' : (s.co ? 'Co-written' : D.name)) + '</span></span>' + act + '</div>';
  }).join('') + '</div></section>' : '';

  const links = D.links.length ? '<section class="sec"><h2 class="sh">Links</h2><div class="card rows">' + D.links.map((l) =>
    '<a class="row" href="' + q(l.u) + '" target="_blank" rel="noopener me">' + tile(l.k) + '<span class="rl">' + q(l.label || LINKS[l.k]) + '</span><span class="chev">' + G.chev + '</span></a>').join('') + '</div></section>' : '';

  const css =
  ':root{--bg:#F2F2F7;--card:#fff;--label:#000;--label2:rgba(60,60,67,.6);--label3:rgba(60,60,67,.3);--sep:rgba(60,60,67,.2);--fill:rgba(120,120,128,.12);--bar:rgba(249,249,249,.8);--qa:rgba(255,255,255,.62);' +
    '--tint:' + C.tint + ';--h1:' + C.h1 + ';--h2:' + C.h2 + ';color-scheme:light dark}' +
  '@media (prefers-color-scheme:dark){:root{--bg:#000;--card:#1C1C1E;--label:#fff;--label2:rgba(235,235,245,.6);--label3:rgba(235,235,245,.3);--sep:rgba(84,84,88,.65);--fill:rgba(120,120,128,.24);--bar:rgba(22,22,24,.78);--qa:rgba(255,255,255,.1);' +
    '--tint:' + C.tintD + ';--h1:' + C.h1D + ';--h2:' + C.h2D + '}}' +
  '*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}[hidden]{display:none!important}' +
  // iOS 26 Safari colours the strip behind the Dynamic Island from the page's solid background-color: the header's top colour
  'html,body{background-color:var(--h1)}body{margin:0;color:var(--label);font:17px/1.29 -apple-system,"SF Pro Text",system-ui,"Helvetica Neue",Arial,sans-serif;letter-spacing:-.41px;-webkit-font-smoothing:antialiased;-webkit-text-size-adjust:100%}' +
  'a{color:inherit;text-decoration:none}button{font:inherit;letter-spacing:inherit;color:inherit;background:none;border:0;padding:0;cursor:pointer}' +
  '.wrap{max-width:640px;margin:0 auto}' +
  // header: the featured artwork, blurred, behind the photo, name and quick actions (like a contact poster)
  '.hero{position:relative;overflow:hidden;background:linear-gradient(180deg,var(--h1),var(--h2));padding:calc(env(safe-area-inset-top,0px) + 40px) 20px 26px}' +
  '.hero .bd{position:absolute;inset:-40px;background-size:cover;background-position:center;filter:blur(50px) saturate(1.4);opacity:.5;transform:scale(1.2)}' +
  '.hero::after{content:"";position:absolute;left:0;right:0;bottom:0;height:90px;background:linear-gradient(to bottom,transparent,var(--bg))}' +
  '.hero .in{position:relative;z-index:1;display:flex;flex-direction:column;align-items:center;text-align:center;max-width:600px;margin:0 auto}' +
  '.av{width:116px;height:116px;border-radius:50%;object-fit:cover;display:grid;place-items:center;font:600 42px/1 -apple-system,"SF Pro Rounded",system-ui;color:#fff;background:linear-gradient(180deg,#A5A9B4,#858993);box-shadow:0 10px 30px rgba(0,0,0,.18)}' +
  'h1{margin:16px 0 0;font:700 34px/41px -apple-system,"SF Pro Display",system-ui,sans-serif;letter-spacing:.37px}' +
  '.handle{margin-top:2px;font-size:15px;line-height:20px;letter-spacing:-.24px;color:var(--label2)}' +
  '.bio{margin:10px 0 0;font-size:15px;line-height:20px;letter-spacing:-.24px;color:var(--label);max-width:34em;white-space:pre-line;display:-webkit-box;-webkit-line-clamp:3;-webkit-box-orient:vertical;overflow:hidden}.bio.all{display:block}' +
  '.more{margin-top:2px;font-size:15px;font-weight:600;color:var(--tint)}' +
  '.qas{display:flex;gap:8px;width:100%;max-width:420px;margin-top:20px}' +
  '.qa{flex:1 1 0;min-width:0;height:64px;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:5px;border-radius:14px;background:var(--qa);-webkit-backdrop-filter:blur(20px) saturate(180%);backdrop-filter:blur(20px) saturate(180%);font-size:12px;font-weight:600;letter-spacing:0;color:var(--tint);transition:transform .15s,opacity .15s}' +
  '.qa .qi{display:flex}.qa svg{width:22px;height:22px}.qa:active{transform:scale(.95);opacity:.75}' +
  '.qa{white-space:nowrap;overflow:hidden;text-overflow:ellipsis;padding:0 4px}' +
  // body: grouped background with inset grouped lists
  'main{background:var(--bg);padding:6px 0 calc(env(safe-area-inset-bottom,0px) + 110px);min-height:60vh}' +
  '.sec{margin:22px 0 0}.sh{margin:0 0 8px;padding:0 20px;font:700 22px/28px -apple-system,"SF Pro Display",system-ui,sans-serif;letter-spacing:.35px}' +
  '.card{background:var(--card);border-radius:22px;margin:0 16px;overflow:hidden}' +
  '.row{position:relative;display:flex;align-items:center;gap:14px;min-height:52px;padding:8px 16px}' +
  '.row+.row::before{content:"";position:absolute;top:0;right:0;left:60px;border-top:.5px solid var(--sep)}' +
  '.row.song+.row.song::before{left:78px}' +
  'a.row:active,a.row.on{background:var(--fill)}@media (hover:hover){a.row:hover{background:var(--fill)}}' +
  '.tile{width:30px;height:30px;border-radius:8px;flex:none;display:grid;place-items:center;color:#fff}.tile svg{width:18px;height:18px}' +
  '.rl{flex:1;min-width:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.chev{flex:none;display:flex;color:var(--label3)}' +
  '.th{width:48px;height:48px;border-radius:8px;flex:none;overflow:hidden;background:var(--fill);box-shadow:0 0 0 .5px var(--sep)}.th img{width:100%;height:100%;object-fit:cover;display:block}' +
  '.rt{flex:1;min-width:0;display:flex;flex-direction:column;gap:1px}.rt b{font-weight:400;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.rt>span{font-size:13px;line-height:18px;letter-spacing:-.08px;color:var(--label2)}' +
  // App Store style capsule: grey fill, tint label
  '.get{flex:none;min-width:72px;height:30px;padding:0 14px;border-radius:99px;background:var(--fill);color:var(--tint);font-size:15px;font-weight:700;letter-spacing:-.24px;display:grid;place-items:center;transition:opacity .15s}.get:active{opacity:.6}' +
  // the featured release
  '.feat{padding:16px}.fhead{display:flex;gap:14px;align-items:center}' +
  '.fart{width:104px;height:104px;border-radius:10px;flex:none;overflow:hidden;background:var(--fill);box-shadow:0 6px 18px rgba(0,0,0,.14),0 0 0 .5px var(--sep)}.fart img{width:100%;height:100%;object-fit:cover;display:block}' +
  '.ftx{min-width:0;display:flex;flex-direction:column;gap:2px}.eyebrow{font-size:13px;line-height:18px;font-weight:600;letter-spacing:-.08px;color:var(--tint)}' +
  '.ftx b{font:600 22px/27px -apple-system,"SF Pro Display",system-ui,sans-serif;letter-spacing:.35px}.fby{font-size:15px;line-height:20px;letter-spacing:-.24px;color:var(--label2)}' +
  '.cd{display:grid;grid-template-columns:repeat(4,1fr);margin:16px 0 0;border-radius:14px;background:var(--fill)}' +
  '.cd span{display:flex;flex-direction:column;align-items:center;padding:10px 0 9px;font-size:12px;line-height:16px;letter-spacing:0;color:var(--label2);position:relative}' +
  '.cd span+span::before{content:"";position:absolute;left:0;top:12px;bottom:12px;border-left:.5px solid var(--sep)}' +
  '.cd b{font:600 22px/28px -apple-system,"SF Pro Display",system-ui,sans-serif;color:var(--label);font-variant-numeric:tabular-nums}' +
  '.acts{display:flex;flex-direction:column;gap:8px;margin-top:16px}.acts:empty{display:none}' +
  '.btn{display:flex;align-items:center;justify-content:center;gap:7px;height:50px;border-radius:99px;background:var(--fill);color:var(--tint);font-size:17px;font-weight:600;transition:opacity .15s,transform .15s}' +
  '.btn.pri{background:var(--tint);color:#fff}@media (prefers-color-scheme:dark){.btn.pri{color:#000}}.btn.txt{background:none;height:44px}.btn:active{opacity:.7;transform:scale(.98)}' +
  '.bi{display:flex}.bi svg{width:19px;height:19px}' +
  '.feat .rows{margin:12px -16px -16px;border-top:.5px solid var(--sep)}' +
  // upcoming vs out, by the visitor's own date (the server guesses first)
  '.is-out .up,.is-up .out{display:none!important}' +
  // sign-up: a form row like Settings
  '.field{display:flex;align-items:center;gap:10px;min-height:52px;padding:0 8px 0 16px}' +
  '.field input{flex:1;min-width:0;height:52px;border:0;background:none;outline:0;font:inherit;font-size:17px;letter-spacing:-.41px;color:var(--label)}.field input::placeholder{color:var(--label3)}' +
  '.field button{flex:none;height:36px;padding:0 10px;border-radius:10px;color:var(--tint);font-weight:600}.field button:disabled{opacity:.4}' +
  '.foot{margin:7px 20px 0;font-size:13px;line-height:18px;letter-spacing:-.08px;color:var(--label2)}.foot.ok{color:var(--label);font-weight:600}' +
  '.hp{position:absolute;left:-9999px;width:1px;height:1px;opacity:0}' +
  'footer{margin:34px 0 0;text-align:center;font-size:13px;color:var(--label2)}footer a{font-weight:600}' +
  // the nav bar that appears once the name scrolls away
  '.nav{position:fixed;top:0;left:0;right:0;z-index:5;height:calc(env(safe-area-inset-top,0px) + 44px);padding-top:env(safe-area-inset-top,0px);display:flex;align-items:center;justify-content:center;background:var(--bar);-webkit-backdrop-filter:blur(30px) saturate(180%);backdrop-filter:blur(30px) saturate(180%);border-bottom:.5px solid var(--sep);font-weight:600;opacity:0;pointer-events:none;transition:opacity .2s}.nav.on{opacity:1}' +
  // mini player
  '.mini{position:fixed;left:12px;right:12px;bottom:calc(env(safe-area-inset-bottom,0px) + 12px);z-index:6;max-width:616px;margin:0 auto;height:64px;display:flex;align-items:center;gap:12px;padding:0 10px 0 10px;border-radius:20px;background:var(--bar);-webkit-backdrop-filter:blur(30px) saturate(180%);backdrop-filter:blur(30px) saturate(180%);box-shadow:0 0 0 .5px var(--sep),0 10px 30px rgba(0,0,0,.18);overflow:hidden;transform:translateY(140%);transition:transform .35s cubic-bezier(.32,.72,0,1)}.mini.on{transform:none}' +
  '.mini img{width:44px;height:44px;border-radius:8px;object-fit:cover;flex:none;background:var(--fill)}.mini .mt{flex:1;min-width:0;display:flex;flex-direction:column}.mini .mt b{font-size:15px;font-weight:600;letter-spacing:-.24px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.mini .mt span{font-size:13px;color:var(--label2)}' +
  '.mini button{width:44px;height:44px;display:grid;place-items:center;flex:none;color:var(--label)}.mini button svg{width:26px;height:26px}.mini i{position:absolute;left:0;bottom:0;height:2px;width:0;background:var(--tint)}' +
  ':focus-visible{outline:2px solid var(--tint);outline-offset:2px}' +
  '@media (prefers-reduced-motion:reduce){*{transition:none!important}}';

  return '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">' +
  '<title>' + q(D.name) + ' · *[demo]</title><meta name="description" content="' + q(desc) + '"><link rel="canonical" href="' + q(url) + '">' +
  '<meta property="og:type" content="profile"><meta property="og:url" content="' + q(url) + '"><meta property="og:title" content="' + q(D.name) + '"><meta property="og:description" content="' + q(desc) + '">' +
  '<meta property="og:image" content="' + q(img) + '"><meta property="og:site_name" content="*[demo]"><meta name="twitter:card" content="summary"><meta name="twitter:title" content="' + q(D.name) + '"><meta name="twitter:image" content="' + q(img) + '">' +
  '<meta name="theme-color" content="' + q(C.h1) + '" media="(prefers-color-scheme: light)"><meta name="theme-color" content="' + q(C.h1D) + '" media="(prefers-color-scheme: dark)"><link rel="icon" href="https://hellodemo.app/icon-192.png">' +
  '<style>' + css + '</style></head><body>' +
  '<div class="nav" id="nav" aria-hidden="true">' + q(D.name) + '</div>' +
  '<header class="hero">' + (F && F.art ? '<div class="bd" style="background-image:url(&quot;' + q(F.art) + '&quot;)"></div>' : '') + '<div class="in">' +
    (D.avatar ? '<img class="av" src="' + q(D.avatar) + '" alt="">' : '<span class="av" aria-hidden="true">' + q(ini) + '</span>') +
    '<h1 id="nm">' + q(D.name) + '</h1>' + (D.username ? '<span class="handle">@' + q(D.username) + '</span>' : '') +
    (D.bio ? '<p class="bio" id="bio">' + q(D.bio) + '</p><button class="more" id="more" hidden>more</button>' : '') +
    (qa.length ? '<div class="qas">' + qa.join('') + '</div>' : '') + '</div></header>' +
  '<main><div class="wrap">' + feat + songs + links +
    '<section class="sec fans" id="fans"><h2 class="sh" id="fanh">New Music</h2><div class="card"><form class="field" id="fan" novalidate>' +
      '<input type="email" name="email" placeholder="Email" autocomplete="email" inputmode="email" required aria-label="Your email">' +
      '<input class="hp" name="website" tabindex="-1" autocomplete="off" aria-hidden="true"><button type="submit">Sign Up</button></form></div>' +
      '<p class="foot" id="fanmsg" role="status">Hear when ' + q(D.name) + ' releases something new. Only ' + q(D.name) + ' sees your email.</p></section>' +
    '<footer><a href="https://hellodemo.app/"' + ext + '>Made with *[demo]</a></footer></div></main>' +
  '<div class="mini" id="mini" aria-label="Now playing"><img alt="" id="mart"><span class="mt"><b id="mtt"></b><span>' + q(D.name) + '</span></span><button id="mpp" aria-label="Pause">' + G.pause + '</button><i id="mpr"></i></div>' +
  '<audio id="au" preload="none"></audio>' +
  '<script>(' + pageJS.toString() + ')(' + JSON.stringify({ u: D.username, n: D.name, sb: env.SB_URL, k: env.SB_KEY, play: G.play, pause: G.pause }).replace(/</g, '\\u003c') + ')</script>' +
  '</body></html>';
}

// in the visitor's browser: release state and countdown by their own date, the nav bar, the player, sign-ups
function pageJS(C) {
  var $ = function (s, r) { return (r || document).querySelector(s); }, $$ = function (s, r) { return [].slice.call((r || document).querySelectorAll(s)); };
  function relAt(d) { var p = d.split('-'); return new Date(+p[0], +p[1] - 1, +p[2]).getTime(); }
  function sync() {
    $$('[data-date]').forEach(function (el) { var d = el.getAttribute('data-date'), out = !d || Date.now() >= relAt(d); el.classList.toggle('is-out', out); el.classList.toggle('is-up', !out); });
    var f = $('.feat[data-date]'), d = f && f.getAttribute('data-date');
    if (d) { var r = Math.max(0, relAt(d) - Date.now()), u = { d: 864e5, h: 36e5, m: 6e4, s: 1e3 };
      ['d', 'h', 'm', 's'].forEach(function (k) { var b = $('[data-u="' + k + '"]', f); if (b) { b.textContent = Math.floor(r / u[k]); r %= u[k]; } }); }
  }
  sync(); setInterval(sync, 1000);
  // the compact title bar, once the big name has scrolled under the status bar
  var nav = $('#nav'), nm = $('#nm');
  if (nav && nm && 'IntersectionObserver' in window) new IntersectionObserver(function (e) { nav.classList.toggle('on', !e[0].isIntersecting); }, { rootMargin: '-60px 0px 0px 0px' }).observe(nm);
  // a long bio shows three lines and "more"
  var bio = $('#bio'), more = $('#more'); if (bio && more && bio.scrollHeight > bio.clientHeight + 2) { more.hidden = false; more.onclick = function () { bio.classList.add('all'); more.hidden = true; }; }
  // one player for every song, with a mini player like Music, and the song's artwork on the lock screen
  var A = $('#au'), src = null, mini = $('#mini');
  function paint() {
    var on = !A.paused;
    $$('.play').forEach(function (b) { var me = b.getAttribute('data-src') === src && on;
      if (b.classList.contains('get')) b.textContent = me ? 'Pause' : 'Play';
      else { var ic = $('.qi,.bi', b); if (ic) ic.innerHTML = me ? C.pause : C.play; b.lastChild.textContent = me ? 'Pause' : 'Play'; } });
    $('#mpp').innerHTML = on ? C.pause : C.play; $('#mpp').setAttribute('aria-label', on ? 'Pause' : 'Play');
  }
  $$('.play').forEach(function (b) { b.onclick = function () {
    var s = b.getAttribute('data-src');
    if (s === src) { if (A.paused) A.play(); else A.pause(); return; }
    src = s; A.src = s; A.play().catch(function () {});
    var art = b.getAttribute('data-art'), t = b.getAttribute('data-title');
    $('#mtt').textContent = t; var mi = $('#mart'); if (art) { mi.src = art; mi.hidden = false; } else mi.hidden = true; mini.classList.add('on');
    try { if ('mediaSession' in navigator && window.MediaMetadata) navigator.mediaSession.metadata = new MediaMetadata({ title: t, artist: C.n, album: '*[demo]', artwork: art ? [{ src: art, sizes: '512x512', type: /\.png(\?|$)/i.test(art) ? 'image/png' : 'image/jpeg' }] : [] }); } catch (e) {}
  }; });
  $('#mpp').onclick = function () { if (A.paused) A.play(); else A.pause(); };
  A.onplay = A.onpause = A.onended = paint;
  A.ontimeupdate = function () { if (A.duration) $('#mpr').style.width = (A.currentTime / A.duration * 100) + '%'; };
  // sign-ups; "Remind Me" brings you to the form for that song
  var form = $('#fan'), msg = $('#fanmsg'), song = null, base = msg.textContent;
  $$('.remind').forEach(function (b) { b.onclick = function () { song = { id: b.getAttribute('data-song'), t: b.getAttribute('data-title') };
    $('#fanh').textContent = 'Remind Me'; base = 'Get an email when “' + song.t + '” is out. Only ' + C.n + ' sees your email.'; msg.textContent = base; msg.className = 'foot';
    $('#fans').scrollIntoView({ behavior: 'smooth', block: 'center' }); setTimeout(function () { form.email.focus(); }, 380); }; });
  form.onsubmit = function (e) { e.preventDefault(); if (form.website.value) return;
    var em = form.email.value.trim(), btn = $('button', form);
    if (!/^[^@\s]+@[^@\s]+\.[a-z]{2,}$/i.test(em)) { msg.className = 'foot'; msg.textContent = 'That email doesn’t look right.'; return; }
    btn.disabled = true; msg.className = 'foot'; msg.textContent = 'Signing you up…';
    fetch(C.sb + '/rest/v1/rpc/fan_signup', { method: 'POST', headers: { apikey: C.k, Authorization: 'Bearer ' + C.k, 'Content-Type': 'application/json' },
      body: JSON.stringify({ name: C.u, email: em, song: song && song.id, title: song && song.t }) })
      .then(function (r) { return r.json(); })
      .then(function (r) { btn.disabled = false;
        if (r === 'ok') { form.email.value = ''; form.email.blur(); msg.className = 'foot ok'; msg.textContent = 'You’re on the list.' + (song ? ' You’ll hear when “' + song.t + '” is out.' : ''); }
        else { msg.className = 'foot'; msg.textContent = r === 'email' ? 'That email doesn’t look right.' : r === 'busy' ? 'Lots of sign-ups right now. Try again in a minute.' : 'Couldn’t sign you up. Try again.'; } })
      .catch(function () { btn.disabled = false; msg.className = 'foot'; msg.textContent = 'Couldn’t sign you up. Check your connection and try again.'; });
  };
}

function notFound(name) {
  return '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"><title>No page here · *[demo]</title><meta name="robots" content="noindex">' +
    '<style>html{background:#FFD3BE}body{margin:0;min-height:100vh;display:grid;place-items:center;font:17px/1.45 -apple-system,system-ui,sans-serif;color:#3B2E5A;background:linear-gradient(155deg,#FFD3BE,#E3CCFF 52%,#BFDDFF);background-color:#FFD3BE;text-align:center;padding:24px}' +
    'b{display:block;font-size:22px;margin-bottom:6px}p{margin:0;color:rgba(59,46,90,.7)}a{display:inline-block;margin-top:22px;color:#3B2E5A;font-weight:600;text-decoration:none;padding:10px 18px;border-radius:99px;background:rgba(255,255,255,.55)}</style></head>' +
    '<body><div><b>No page here</b><p>' + (name ? '@' + esc(name) + ' doesn’t have a public page yet.' : 'This page doesn’t exist.') + '</p><a href="https://hellodemo.app/">What’s *[demo]?</a></div></body></html>';
}

module.exports = { render, notFound, clean };
