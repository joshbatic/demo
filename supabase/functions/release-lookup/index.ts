// *[demo] release-lookup: finds a released song in Apple Music's catalogue, so Details › Release can fill in
// its ISRC, UPC, release date, label and genre (and the ISWC from MusicBrainz, when it has one).
//
//   { action: "search", q: "kitchen light jordan lee", storefront?: "au" }
//       → { results: [{ id, title, artist, album, art, date, isrc }] }   (up to 8 songs)
//   { action: "detail", id: "<Apple Music song id>", storefront?: "au" }
//       → { isrc, upc, date, label, genre, copyright, album, url, iswc }
//
// Problems come back as { error } with HTTP 200, so the apps can show the message. Signed-in people only. Nothing is stored; the app writes what it gets into the song's release details.
//
// Deploy:  supabase functions deploy release-lookup     (JWT verification on)
// Secrets: MUSICKIT_PRIVATE_KEY   the whole .p8 file from Apple Developer › Keys (the Media Services key),
//                                 pasted in Supabase › Edge Functions › Secrets. Never commit it.
//          MUSICKIT_KEY_ID        optional; defaults to 428P4T77FN, that key's ID
//          MUSICKIT_TEAM_ID       optional; defaults to KZL3T52VV3, the developer team

import { createClient } from "jsr:@supabase/supabase-js@2";
import { SignJWT, importPKCS8 } from "npm:jose@5.9.6";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
const env = (k: string) => (Deno.env.get(k) || "").trim();

// ---- the Apple Music developer token: signed with the MusicKit key, kept for 12 hours ----
let token = "", tokenUntil = 0;
async function devToken(): Promise<string> {
  if (token && Date.now() < tokenUntil) return token;
  let pem = env("MUSICKIT_PRIVATE_KEY").replace(/\\n/g, "\n");
  if (!pem) throw new Error("not_set_up");
  if (!pem.includes("BEGIN")) pem = "-----BEGIN PRIVATE KEY-----\n" + pem.replace(/\s+/g, "") + "\n-----END PRIVATE KEY-----";
  const key = await importPKCS8(pem, "ES256");
  const now = Math.floor(Date.now() / 1000);
  token = await new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: env("MUSICKIT_KEY_ID") || "428P4T77FN" })
    .setIssuer(env("MUSICKIT_TEAM_ID") || "KZL3T52VV3").setIssuedAt(now).setExpirationTime(now + 12 * 3600)
    .sign(key);
  tokenUntil = Date.now() + 11 * 3600 * 1000;
  return token;
}

async function apple(path: string) {
  const r = await fetch("https://api.music.apple.com/v1/catalog/" + path, { headers: { Authorization: "Bearer " + await devToken() } });
  if (r.status === 401 || r.status === 403) { token = ""; throw new Error("apple_refused"); }
  if (!r.ok) throw new Error("apple_" + r.status);
  return await r.json();
}

const art = (a: any, px = 300) => a?.url ? String(a.url).replace("{w}", String(px)).replace("{h}", String(px)) : "";
const genreOf = (g: string[] = []) => g.find((x) => x !== "Music") || g[0] || "";
const store = (s: unknown) => /^[a-z]{2}$/.test(String(s || "")) ? String(s) : "au";

// ---- the ISWC (the song's code as a composition), from MusicBrainz, when it's been entered there ----
async function iswc(isrc: string): Promise<string> {
  if (!isrc) return "";
  const ua = { "User-Agent": "demo/1.1 ( help@hellodemo.app )", Accept: "application/json" };
  const c = new AbortController(), t = setTimeout(() => c.abort(), 5000);
  try {
    const r = await fetch(`https://musicbrainz.org/ws/2/isrc/${encodeURIComponent(isrc)}?inc=work-rels&fmt=json`, { headers: ua, signal: c.signal });
    if (!r.ok) return "";
    const d = await r.json();
    for (const rec of d.recordings || []) for (const rel of rec.relations || []) {
      const w = rel.work;
      if (w?.iswcs?.length) return w.iswcs[0];
      if (w?.id) {
        const wr = await fetch(`https://musicbrainz.org/ws/2/work/${w.id}?fmt=json`, { headers: ua, signal: c.signal });
        if (wr.ok) { const wd = await wr.json(); if (wd.iswcs?.length) return wd.iswcs[0]; }
      }
    }
    return "";
  } catch { return ""; } finally { clearTimeout(t); }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  // signed-in people only
  const auth = req.headers.get("Authorization") || "";
  const sb = createClient(env("SUPABASE_URL"), env("SUPABASE_ANON_KEY"), { global: { headers: { Authorization: auth } } });
  const { data: u } = await sb.auth.getUser();
  if (!u?.user) return json({ error: "Sign in to look up releases." });

  let body: any = {};
  try { body = await req.json(); } catch { /* empty */ }
  const sf = store(body.storefront);
  try {
    if (body.action === "search") {
      const q = String(body.q || "").trim().slice(0, 120);
      if (q.length < 2) return json({ results: [] });
      const d = await apple(`${sf}/search?types=songs&limit=8&term=${encodeURIComponent(q)}`);
      const songs = d?.results?.songs?.data || [];
      return json({ results: songs.map((s: any) => ({
        id: s.id, title: s.attributes?.name || "", artist: s.attributes?.artistName || "", album: s.attributes?.albumName || "",
        art: art(s.attributes?.artwork, 120), date: s.attributes?.releaseDate || "", isrc: s.attributes?.isrc || "",
      })) });
    }
    if (body.action === "detail") {
      const id = String(body.id || "");
      if (!/^\d{1,20}$/.test(id)) return json({ error: "Which song?" });
      const d = await apple(`${sf}/songs/${id}?include=albums`);
      const s = d?.data?.[0], a = s?.attributes || {};
      const al = s?.relationships?.albums?.data?.[0]?.attributes || {};
      const isrc = a.isrc || "";
      return json({
        isrc, upc: al.upc || "", date: a.releaseDate || al.releaseDate || "", label: al.recordLabel || "",
        genre: genreOf(a.genreNames), copyright: al.copyright || "", album: a.albumName || al.name || "",
        url: a.url || "", art: art(a.artwork, 600), iswc: await iswc(isrc),
      });
    }
    return json({ error: "Unknown action" });
  } catch (e) {
    const m = String((e as Error)?.message || e);
    if (m === "not_set_up") return json({ error: "Release lookup isn’t set up yet (MUSICKIT_PRIVATE_KEY)." });
    if (m === "apple_refused") return json({ error: "Apple Music didn’t accept the key. Check the MusicKit key and its Media ID." });
    return json({ error: "Couldn’t reach Apple Music. Try again in a moment." });
  }
});
