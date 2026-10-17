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

const PLAY = '<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M8 5.5v13a1 1 0 0 0 1.5.86l10.4-6.5a1 1 0 0 0 0-1.72L9.5 4.64A1 1 0 0 0 8 5.5z"/></svg>';

function linkBtns(s, big) {
  const L = s.links, b = [];
  // both sets are drawn; the page shows whichever matches the visitor's own date
  if (L.presave) b.push('<a class="btn pri up" href="' + esc(L.presave) + '" target="_blank" rel="noopener">Pre-save on Spotify</a>');
  if (L.preadd) b.push('<a class="btn up" href="' + esc(L.preadd) + '" target="_blank" rel="noopener">Pre-add on Apple Music</a>');
  if (L.spotify) b.push('<a class="btn ' + (big ? 'pri ' : '') + 'out" href="' + esc(L.spotify) + '" target="_blank" rel="noopener">Spotify</a>');
  if (L.apple) b.push('<a class="btn out" href="' + esc(L.apple) + '" target="_blank" rel="noopener">Apple Music</a>');
  if (L.youtube) b.push('<a class="btn out" href="' + esc(L.youtube) + '" target="_blank" rel="noopener">YouTube</a>');
  return b.length ? '<div class="btns">' + b.join('') + '</div>' : '';
}

function render(raw, env) {
  const D = clean(raw || {}, env), q = esc, F = pickFeatured(D);
  const rest = D.songs.filter((s) => s !== F).sort((a, b) => {
    const ua = a.date && !isOut(a.date), ub = b.date && !isOut(b.date);
    if (ua !== ub) return ua ? -1 : 1;
    if (ua) return a.date < b.date ? -1 : 1;
    if (!!a.date !== !!b.date) return a.date ? -1 : 1;
    return a.date < b.date ? 1 : a.date > b.date ? -1 : 0;
  });
  const title = D.name + ' · *[demo]';
  const desc = D.bio || ('Music by ' + D.name + '. Listen, pre-save and get new songs first.');
  const img = D.avatar || (F && F.art) || 'https://hellodemo.app/icon-512.png';
  const url = 'https://artist.hellodemo.app/' + encodeURIComponent(D.username);
  const ini = (D.name.match(/\b\w/g) || ['?']).slice(0, 2).join('').toUpperCase();

  const feat = !F ? '' :
    '<section class="feat card ' + (isOut(F.date) ? 'is-out' : 'is-up') + '" data-date="' + q(F.date) + '" data-id="' + q(F.id) + '" data-title="' + q(F.title) + '">' +
      '<div class="fart">' + (F.art ? '<img src="' + q(F.art) + '" alt="">' : '') +
        (F.audio ? '<button class="play big" data-src="' + q(F.audio.src) + '" data-title="' + q(F.title) + '" data-art="' + q(F.art) + '" aria-label="Play ' + q(F.title) + '">' + PLAY + '</button>' : '') + '</div>' +
      '<div class="fbody"><span class="when">' + (F.date ? '<span class="up">Out ' + q(longDate(F.date)) + '</span><span class="out">Out now</span>' : '<span class="out">New</span>') + '</span>' +
        '<h2>' + q(F.title) + '</h2>' +
        (F.date ? '<div class="cd up" aria-live="off"><span><b data-u="d">0</b>days</span><span><b data-u="h">0</b>hours</span><span><b data-u="m">0</b>minutes</span><span><b data-u="s">0</b>seconds</span></div>' : '') +
        (F.audio ? '<div class="prog" aria-hidden="true"><i></i></div>' : '') +
        linkBtns(F, true) +
        (F.date ? '<button class="btn remind up" data-song="' + q(F.id) + '" data-title="' + q(F.title) + '">Remind me when it’s out</button>' : '') +
      '</div></section>';

  const list = rest.length ? '<section class="music"><h3>Music</h3><div class="card list">' + rest.map((s) =>
    '<div class="row ' + (isOut(s.date) ? 'is-out' : 'is-up') + '" data-date="' + q(s.date) + '">' +
      '<span class="th">' + (s.art ? '<img src="' + q(s.art) + '" alt="" loading="lazy">' : '') + '</span>' +
      '<span class="rt"><b>' + q(s.title) + '</b><span>' + (s.date ? '<span class="up">Out ' + q(shortDate(s.date)) + '</span><span class="out">' + q(s.date.slice(0, 4)) + (s.co ? ' · Co-written' : '') + '</span>' : (s.co ? 'Co-written' : 'Song')) + '</span></span>' +
      (s.audio ? '<button class="play" data-src="' + q(s.audio.src) + '" data-title="' + q(s.title) + '" data-art="' + q(s.art) + '" aria-label="Play ' + q(s.title) + '">' + PLAY + '</button>' : '') +
      (() => { const L = s.links, a = [];
        if (L.presave) a.push('<a class="mini up" href="' + q(L.presave) + '" target="_blank" rel="noopener">Pre-save</a>');
        if (L.spotify || L.apple || L.youtube) a.push('<a class="mini out" href="' + q(L.spotify || L.apple || L.youtube) + '" target="_blank" rel="noopener">Listen</a>');
        return a.length ? '<span class="minis">' + a.join('') + '</span>' : ''; })() +
    '</div>').join('') + '</div></section>' : '';

  const links = D.links.length ? '<nav class="links" aria-label="Links">' + D.links.map((l) => '<a href="' + q(l.u) + '" target="_blank" rel="noopener me">' + q(l.label || LINKS[l.k]) + '</a>').join('') + '</nav>' : '';

  return '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">' +
  '<title>' + q(title) + '</title><meta name="description" content="' + q(desc) + '"><link rel="canonical" href="' + q(url) + '">' +
  '<meta property="og:type" content="profile"><meta property="og:url" content="' + q(url) + '"><meta property="og:title" content="' + q(D.name) + '"><meta property="og:description" content="' + q(desc) + '">' +
  '<meta property="og:image" content="' + q(img) + '"><meta property="og:site_name" content="*[demo]"><meta name="twitter:card" content="summary"><meta name="twitter:title" content="' + q(D.name) + '"><meta name="twitter:image" content="' + q(img) + '">' +
  '<meta name="theme-color" content="' + q(D.bg.top) + '"><link rel="icon" href="https://hellodemo.app/icon-192.png">' +
  '<style>' +
  '*{box-sizing:border-box}[hidden]{display:none!important}html{background:' + D.bg.top + '}:root{--k:' + D.bg.k + ';--glass:rgba(255,255,255,.66);--hair:hsla(var(--k),.1)}' +
  // iOS 26 Safari tints the bar behind the Dynamic Island from the solid background-color, so the gradient sits on it
  'body{margin:0;min-height:100vh;color:hsl(var(--k));font:16px/1.45 -apple-system,"SF Pro Text",system-ui,"Helvetica Neue",Arial,sans-serif;-webkit-font-smoothing:antialiased;' +
    'background:radial-gradient(90% 55% at 85% 0%,' + D.bg.glow + ',transparent 70%),linear-gradient(160deg,' + D.bg.top + ',' + D.bg.bot + ');background-color:' + D.bg.top + ';background-attachment:fixed}' +
  'main{max-width:520px;margin:0 auto;padding:calc(env(safe-area-inset-top,0px) + 44px) 18px calc(env(safe-area-inset-bottom,0px) + 40px)}' +
  'a{color:inherit}button{font:inherit;color:inherit;background:none;border:0;padding:0;cursor:pointer;-webkit-tap-highlight-color:transparent}' +
  '.card{background:var(--glass);-webkit-backdrop-filter:blur(26px) saturate(170%);backdrop-filter:blur(26px) saturate(170%);border-radius:26px;box-shadow:0 0 0 .5px var(--hair),0 1px 1px hsla(var(--k),.05),0 14px 34px hsla(var(--k),.12),inset 0 1px 0 rgba(255,255,255,.6)}' +
  'header{display:flex;flex-direction:column;align-items:center;text-align:center;gap:6px;margin-bottom:22px}' +
  '.av{width:108px;height:108px;border-radius:50%;object-fit:cover;display:grid;place-items:center;font-size:38px;font-weight:700;background:var(--glass);box-shadow:0 0 0 3px rgba(255,255,255,.7),0 10px 28px hsla(var(--k),.22);margin-bottom:10px}' +
  'h1{margin:0;font:700 31px/1.1 -apple-system,"SF Pro Display",system-ui,sans-serif;letter-spacing:-.022em}' +
  '.handle{font-size:15px;color:hsla(var(--k),.6)}.bio{margin:6px 0 0;max-width:30em;font-size:16.5px;color:hsla(var(--k),.85);white-space:pre-line}' +
  '.links{display:flex;flex-wrap:wrap;justify-content:center;gap:8px;margin:0 0 26px}' +
  '.links a{padding:9px 16px;border-radius:99px;background:var(--glass);-webkit-backdrop-filter:blur(20px);backdrop-filter:blur(20px);box-shadow:0 0 0 .5px var(--hair);font-size:15px;font-weight:600;text-decoration:none;transition:transform .12s,background-color .15s}' +
  '.links a:active{transform:scale(.96)}@media (hover:hover){.links a:hover{background:rgba(255,255,255,.85)}}' +
  '.feat{overflow:hidden;margin-bottom:26px}.fart{position:relative;aspect-ratio:1;background:hsla(var(--k),.08)}.fart img{width:100%;height:100%;object-fit:cover;display:block}' +
  '.play{width:40px;height:40px;border-radius:50%;flex:none;display:grid;place-items:center;background:hsl(var(--k));color:#fff;transition:transform .12s}.play:active{transform:scale(.92)}.play svg{width:16px;height:16px}' +
  '.play.big{position:absolute;right:16px;bottom:16px;width:58px;height:58px;box-shadow:0 8px 24px rgba(0,0,0,.25)}.play.big svg{width:22px;height:22px}' +
  '.fbody{padding:18px 20px 20px;display:flex;flex-direction:column;gap:12px}' +
  '.when{font-size:14px;font-weight:600;color:hsla(var(--k),.62)}h2{margin:-6px 0 0;font:700 26px/1.15 -apple-system,"SF Pro Display",system-ui,sans-serif;letter-spacing:-.018em}' +
  '.cd{display:grid;grid-template-columns:repeat(4,1fr);gap:8px}.cd span{display:flex;flex-direction:column;align-items:center;padding:10px 0 8px;border-radius:16px;background:hsla(var(--k),.07);font-size:12.5px;color:hsla(var(--k),.6)}' +
  '.cd b{font:700 26px/1.1 -apple-system,"SF Pro Display",system-ui,sans-serif;color:hsl(var(--k));font-variant-numeric:tabular-nums}' +
  '.prog{height:4px;border-radius:2px;background:hsla(var(--k),.12);overflow:hidden}.prog i{display:block;height:100%;width:0;background:hsl(var(--k))}' +
  '.btns{display:flex;flex-wrap:wrap;gap:8px}.btn{display:inline-flex;align-items:center;justify-content:center;flex:1 1 auto;min-height:46px;padding:0 18px;border-radius:99px;background:hsla(var(--k),.09);font-size:15.5px;font-weight:600;text-decoration:none;text-align:center;transition:transform .12s,opacity .15s}' +
  '.btn.pri{background:hsl(var(--k));color:#fff}.btn:active{transform:scale(.97)}' +
  // upcoming vs out: the page decides with the visitor's own date (script below); before it runs, the server's guess holds
  '.is-out .up,.is-up .out{display:none!important}' +
  '.music h3,.fans h3{margin:0 0 8px 6px;font-size:14px;font-weight:600;color:hsla(var(--k),.58)}' +
  '.list{overflow:hidden}.row{display:flex;align-items:center;gap:13px;padding:10px 14px;position:relative}.row+.row::before{content:"";position:absolute;top:0;left:79px;right:0;border-top:.5px solid var(--hair)}' +
  '.th{width:52px;height:52px;border-radius:10px;flex:none;overflow:hidden;background:hsla(var(--k),.1);box-shadow:0 0 0 .5px var(--hair)}.th img{width:100%;height:100%;object-fit:cover;display:block}' +
  '.rt{flex:1;min-width:0;display:flex;flex-direction:column;gap:1px}.rt b{font-weight:600;font-size:16px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.rt>span{font-size:13.5px;color:hsla(var(--k),.6)}' +
  '.minis{display:flex;gap:6px}.mini{padding:7px 12px;border-radius:99px;background:hsla(var(--k),.09);font-size:13.5px;font-weight:600;text-decoration:none}' +
  '.fans{margin-top:26px}.fans .card{padding:18px 18px 16px}.fans p{margin:0 0 12px;font-size:15.5px}' +
  'form{display:flex;gap:8px}form input[type=email]{flex:1;min-width:0;height:46px;border:0;border-radius:99px;padding:0 18px;font:inherit;font-size:16px;color:hsl(var(--k));background:rgba(255,255,255,.75);box-shadow:inset 0 0 0 .5px var(--hair);outline:0}' +
  'form input[type=email]:focus{box-shadow:inset 0 0 0 1.5px hsla(var(--k),.5)}form .btn{flex:none}.hp{position:absolute;left:-9999px;width:1px;height:1px;opacity:0}' +
  '.fine{margin:10px 2px 0;font-size:13px;color:hsla(var(--k),.55)}.msg{margin:10px 2px 0;font-size:14.5px;font-weight:600}' +
  'footer{margin-top:34px;text-align:center;font-size:14px;font-weight:600;color:hsla(var(--k),.45)}footer a{text-decoration:none}@media (hover:hover){footer a:hover{color:hsla(var(--k),.75)}}' +
  ':focus-visible{outline:2px solid hsla(var(--k),.55);outline-offset:3px}' +
  '@media (prefers-reduced-motion:reduce){*{transition:none!important}}' +
  '</style></head><body><main>' +
  '<header>' + (D.avatar ? '<img class="av" src="' + q(D.avatar) + '" alt="">' : '<span class="av" aria-hidden="true">' + q(ini) + '</span>') +
    '<h1>' + q(D.name) + '</h1>' + (D.username ? '<span class="handle">@' + q(D.username) + '</span>' : '') + (D.bio ? '<p class="bio">' + q(D.bio) + '</p>' : '') + '</header>' +
  links + feat + list +
  '<section class="fans"><h3>New music</h3><div class="card"><p>Get an email when ' + q(D.name) + ' releases something new.</p>' +
    '<form id="fan" novalidate><input type="email" name="email" placeholder="Your email" autocomplete="email" inputmode="email" required aria-label="Your email"><input class="hp" name="website" tabindex="-1" autocomplete="off" aria-hidden="true"><button class="btn pri" type="submit">Sign up</button></form>' +
    '<div class="msg" id="fanmsg" role="status" hidden></div><p class="fine">Only ' + q(D.name) + ' sees your email.</p></div></section>' +
  '<footer><a href="https://hellodemo.app/" target="_blank" rel="noopener">Made with *[demo]</a></footer></main>' +
  '<audio id="au" preload="none"></audio>' +
  '<script>(' + pageJS.toString() + ')(' + JSON.stringify({ u: D.username, n: D.name, sb: env.SB_URL, k: env.SB_KEY }).replace(/</g, '\\u003c') + ')</script>' +
  '</body></html>';
}

// runs in the visitor's browser: upcoming/out by their own date, the countdown, one player for every song, and sign-ups
function pageJS(C) {
  var $ = function (s, r) { return (r || document).querySelector(s); }, $$ = function (s, r) { return [].slice.call((r || document).querySelectorAll(s)); };
  function relAt(d) { var p = d.split('-'); return new Date(+p[0], +p[1] - 1, +p[2]).getTime(); }
  function sync() {
    $$('[data-date]').forEach(function (el) { var d = el.getAttribute('data-date'), out = !d || Date.now() >= relAt(d); el.classList.toggle('is-out', out); el.classList.toggle('is-up', !out); });
    var f = $('.feat[data-date]'), d = f && f.getAttribute('data-date');
    if (d) { var left = Math.max(0, relAt(d) - Date.now()), u = { d: 864e5, h: 36e5, m: 6e4, s: 1e3 }, r = left;
      ['d', 'h', 'm', 's'].forEach(function (k) { var b = $('[data-u="' + k + '"]', f); if (b) { b.textContent = Math.floor(r / u[k]); r %= u[k]; } }); }
  }
  sync(); setInterval(sync, 1000);
  // one audio element; the lock screen shows the song's own artwork
  var A = $('#au'), curB = null, PL = '<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M8 5.5v13a1 1 0 0 0 1.5.86l10.4-6.5a1 1 0 0 0 0-1.72L9.5 4.64A1 1 0 0 0 8 5.5z"/></svg>',
    PA = '<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><rect x="6" y="5" width="4" height="14" rx="1.2"/><rect x="14" y="5" width="4" height="14" rx="1.2"/></svg>';
  function paint() { $$('.play').forEach(function (b) { var on = b === curB && !A.paused; b.innerHTML = on ? PA : PL; b.setAttribute('aria-label', (on ? 'Pause ' : 'Play ') + b.getAttribute('data-title')); }); }
  $$('.play').forEach(function (b) { b.onclick = function () {
    if (curB === b) { if (A.paused) A.play(); else A.pause(); return; }
    curB = b; A.src = b.getAttribute('data-src'); A.play().catch(function () {});
    try { if ('mediaSession' in navigator && window.MediaMetadata) { var art = b.getAttribute('data-art'); navigator.mediaSession.metadata = new MediaMetadata({ title: b.getAttribute('data-title'), artist: C.n, album: '*[demo]', artwork: art ? [{ src: art, sizes: '512x512', type: /\.png(\?|$)/i.test(art) ? 'image/png' : 'image/jpeg' }] : [] }); } } catch (e) {}
  }; });
  A.onplay = A.onpause = A.onended = paint;
  A.ontimeupdate = function () { var p = $('.feat .prog i'), fb = $('.feat .play'); if (p && curB === fb && A.duration) p.style.width = (A.currentTime / A.duration * 100) + '%'; };
  // sign-ups: the main form, and "Remind me" on an upcoming release (which brings you to the form, tagged with that song)
  var form = $('#fan'), msg = $('#fanmsg'), song = null;
  $$('.remind').forEach(function (b) { b.onclick = function () { song = { id: b.getAttribute('data-song'), t: b.getAttribute('data-title') };
    $('.fans p').textContent = 'Get an email when “' + song.t + '” is out.'; $('.fans').scrollIntoView({ behavior: 'smooth', block: 'center' }); setTimeout(function () { form.email.focus(); }, 350); }; });
  form.onsubmit = function (e) { e.preventDefault(); if (form.website.value) return;
    var em = form.email.value.trim(), btn = $('button', form);
    if (!/^[^@\s]+@[^@\s]+\.[a-z]{2,}$/i.test(em)) { msg.hidden = false; msg.textContent = 'That email doesn’t look right.'; return; }
    btn.disabled = true; msg.hidden = false; msg.textContent = 'Signing you up…';
    fetch(C.sb + '/rest/v1/rpc/fan_signup', { method: 'POST', headers: { apikey: C.k, Authorization: 'Bearer ' + C.k, 'Content-Type': 'application/json' },
      body: JSON.stringify({ name: C.u, email: em, song: song && song.id, title: song && song.t }) })
      .then(function (r) { return r.json(); })
      .then(function (r) { btn.disabled = false;
        if (r === 'ok') { form.hidden = true; msg.textContent = 'You’re on the list. ' + C.n + ' will be in touch.'; }
        else msg.textContent = r === 'email' ? 'That email doesn’t look right.' : r === 'busy' ? 'Lots of sign-ups right now. Try again in a minute.' : 'Couldn’t sign you up. Try again.'; })
      .catch(function () { btn.disabled = false; msg.textContent = 'Couldn’t sign you up. Check your connection and try again.'; });
  };
}

function notFound(name) {
  return '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"><title>No page here · *[demo]</title><meta name="robots" content="noindex">' +
    '<style>html{background:#FFD3BE}body{margin:0;min-height:100vh;display:grid;place-items:center;font:17px/1.45 -apple-system,system-ui,sans-serif;color:#3B2E5A;background:linear-gradient(155deg,#FFD3BE,#E3CCFF 52%,#BFDDFF);background-color:#FFD3BE;text-align:center;padding:24px}' +
    'b{display:block;font-size:22px;margin-bottom:6px}p{margin:0;color:rgba(59,46,90,.7)}a{display:inline-block;margin-top:22px;color:#3B2E5A;font-weight:600;text-decoration:none;padding:10px 18px;border-radius:99px;background:rgba(255,255,255,.55)}</style></head>' +
    '<body><div><b>No page here</b><p>' + (name ? '@' + esc(name) + ' doesn’t have a public page yet.' : 'This page doesn’t exist.') + '</p><a href="https://hellodemo.app/">What’s *[demo]?</a></div></body></html>';
}

module.exports = { render, notFound, clean };
