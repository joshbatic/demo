// artist.hellodemo.app/<username>: a writer's public page (link in bio), drawn on the server from the snapshot
// the app publishes, so link previews and the first paint have everything. See supabase/artist-pages.sql.
const VIEWER = require('./_viewer.js');
const { render, notFound } = require('./_artist.js');

const SB_URL = /var SB_URL='([^']+)'/.exec(VIEWER)[1];
const SB_KEY = /SB_KEY='([^']+)'/.exec(VIEWER)[1];
const PUB = SB_URL + '/storage/v1/object/public/shares/';

module.exports = async (req, res) => {
  const name = String((req.query && req.query.name) || '').replace(/^@/, '');
  res.setHeader('Content-Type', 'text/html; charset=utf-8');
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('X-Frame-Options', 'DENY');
  res.setHeader('Referrer-Policy', 'strict-origin-when-cross-origin');
  if (!/^[A-Za-z0-9_]{3,20}$/.test(name)) { res.statusCode = 404; res.setHeader('Cache-Control', 'public, s-maxage=300'); return res.end(notFound('')); }

  let data = null;
  try {
    const r = await fetch(SB_URL + '/rest/v1/rpc/get_artist', {
      method: 'POST',
      headers: { apikey: SB_KEY, Authorization: 'Bearer ' + SB_KEY, 'Content-Type': 'application/json' },
      body: JSON.stringify({ name }),
    });
    if (!r.ok) throw new Error('status ' + r.status);
    data = await r.json();
  } catch (e) {
    // a Supabase hiccup isn't "no page": don't cache it
    res.statusCode = 503; res.setHeader('Cache-Control', 'no-store');
    return res.end(notFound(name).replace('No page here', 'Couldn’t load this page').replace(/<p>.*?<\/p>/, '<p>Try again in a moment.</p>'));
  }
  if (!data || typeof data !== 'object') { res.statusCode = 404; res.setHeader('Cache-Control', 'public, s-maxage=60'); return res.end(notFound(name)); }
  res.setHeader('Cache-Control', 'public, max-age=0, s-maxage=60, stale-while-revalidate=60');
  res.end(render(data, { SB_URL, SB_KEY, PUB }));
};
