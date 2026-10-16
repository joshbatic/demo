// listen.hellodemo.app/<id>: a *[demo] share link.
//
// Messages, WhatsApp and Messenger build their link previews from the page's <meta> tags without running
// any of its code, so this fills those in on the server (title, artist and the preview picture the
// app uploaded) and hands back the normal viewer with the song already inside, so it opens straight away.
// The viewer (_viewer.js) is generated from the app by scripts/build-share-viewer.py.
const VIEWER = require('./_viewer.js');

const SB_URL = /var SB_URL='([^']+)'/.exec(VIEWER)[1];
const SB_KEY = /SB_KEY='([^']+)'/.exec(VIEWER)[1];
const PUB = SB_URL + '/storage/v1/object/public/shares/';
const SITE = 'https://listen.hellodemo.app/';

const esc = (s) => String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const txt = (v, n) => (typeof v === 'string' ? v : typeof v === 'number' ? String(v) : '').replace(/\s+/g, ' ').trim().slice(0, n || 200);
const pub = (v) => (typeof v === 'string' && v.indexOf(PUB) === 0 && !/["'<>\s]/.test(v) ? v : '');
const json = (v) => JSON.stringify(v).replace(/</g, '\\u003c').replace(/\u2028/g, '\\u2028').replace(/\u2029/g, '\\u2029');

module.exports = async (req, res) => {
  const id = String((req.query && req.query.id) || '');
  if (!/^[A-Za-z0-9]{10}$/.test(id)) {
    res.statusCode = 302;
    res.setHeader('Location', 'https://hellodemo.app/');
    return res.end();
  }

  let data = null;
  try {
    const r = await fetch(SB_URL + '/rest/v1/rpc/get_share', {
      method: 'POST',
      headers: { apikey: SB_KEY, Authorization: 'Bearer ' + SB_KEY, 'Content-Type': 'application/json' },
      body: JSON.stringify({ sid: id }),
    });
    if (r.ok) data = await r.json();
  } catch (e) { /* the viewer shows a friendly error and retries in the browser */ }

  let html = VIEWER;
  if (data && typeof data === 'object') {
    const title = txt(data.title, 120) || 'Untitled';
    const artist = txt(data.artist, 120);
    // no lyrics in the preview: they're for whoever opens the link
    const hasAudio = !!(data.audio && pub(data.audio.src));
    const desc = (hasAudio ? 'Listen and read along' : 'Read the lyrics') + ' on *[demo]';
    const heading = title + (artist ? ' – ' + artist : '');
    const og = pub(data.og), img = og || pub(data.art) || 'https://hellodemo.app/icon-512.png';
    const meta = [
      '<title>' + esc(heading) + '</title>',
      '<meta name="description" content="' + esc(desc) + '">',
      '<meta property="og:type" content="website">', // (Facebook rejects music.song without extra music:* details)
      '<meta property="og:url" content="' + SITE + id + '">',
      '<meta property="og:title" content="' + esc(heading) + '">',
      '<meta property="og:description" content="' + esc(desc) + '">',
      '<meta property="og:image" content="' + esc(img) + '">',
      '<meta property="og:image:secure_url" content="' + esc(img) + '">',
      og ? '<meta property="og:image:type" content="image/' + (/\.png$/.test(og) ? 'png' : 'jpeg') + '"><meta property="og:image:width" content="1200"><meta property="og:image:height" content="630">' : '',
      '<meta property="og:site_name" content="*[demo]">',
      '<meta property="og:image:alt" content="' + esc(heading) + '">',
      '<meta name="twitter:card" content="' + (og ? 'summary_large_image' : 'summary') + '">',
      '<meta name="twitter:title" content="' + esc(heading) + '">',
      '<meta name="twitter:description" content="' + esc(desc) + '">',
      '<meta name="twitter:image" content="' + esc(img) + '">',
      '<link rel="canonical" href="' + SITE + id + '">',
    ].join('\n');
    html = html.replace(/<meta name="robots" content="noindex">\n?/, '').replace(/<meta property="og:site_name" content="\*\[demo\]">\n?/, '')
               .replace(/<!--META-->[\s\S]*?<!--\/META-->/, () => meta)
               .replace('var PRE=null;/*PRELOAD*/', () => 'var PRE=' + json({ id: id, data: data }) + ';');
  } else if (data === null) {
    res.statusCode = 404;
    html = html.replace(/<!--META-->[\s\S]*?<!--\/META-->/, () => '<title>Not shared any more · *[demo]</title>');
  }

  res.setHeader('Content-Type', 'text/html; charset=utf-8');
  // short edge cache: an updated link shows its new preview within a minute
  res.setHeader('Cache-Control', 'public, max-age=0, s-maxage=60, stale-while-revalidate=600');
  res.end(html);
};
