// *[demo] share-link audio: GET /functions/v1/share-audio?s=<share id>
//
// A share link's audio is the song's own file in the private song-files bucket (no second copy). This sends the
// listener to a short-lived signed address for it, but only while the link exists and hasn't expired, and only for
// a file the link's owner may open themselves (public.share_audio checks both; supabase/share-links-v2.sql).
// Deploy with "Verify JWT" off: anyone with the link can listen, as before.

import { createClient } from "jsr:@supabase/supabase-js@2";

const env = (k: string) => (Deno.env.get(k) || "").trim();
const H = { "Access-Control-Allow-Origin": "*", "X-Content-Type-Options": "nosniff" };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: { ...H, "Access-Control-Allow-Methods": "GET, OPTIONS" } });
  const sid = new URL(req.url).searchParams.get("s") || "";
  if (!/^[A-Za-z0-9]{10}$/.test(sid)) return new Response("Not found", { status: 404, headers: H });
  const db = createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"), { auth: { persistSession: false } });
  const { data: path, error } = await db.rpc("share_audio", { sid });
  if (error) return new Response("Try again", { status: 503, headers: { ...H, "Cache-Control": "no-store" } });
  if (!path) return new Response("Not found", { status: 404, headers: { ...H, "Cache-Control": "public, max-age=60" } });
  const s = await db.storage.from("song-files").createSignedUrl(String(path), 6 * 3600);
  if (s.error || !s.data?.signedUrl) return new Response("Not found", { status: 404, headers: { ...H, "Cache-Control": "no-store" } });
  // the signed address lasts 6 hours; browsers may reuse this answer for 1, so a stopped link stops soon after
  return new Response(null, { status: 302, headers: { ...H, Location: s.data.signedUrl, "Cache-Control": "private, max-age=3600" } });
});
