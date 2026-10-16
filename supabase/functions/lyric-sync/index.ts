// *[demo] lyric-sync: hears a song and returns when each sung word starts.
//
// The app sends a small speech-quality copy of the track (16 kHz mono WAV, made on the device) plus
// the song's lyrics as a hint. This forwards it to OpenAI's Whisper with word-level timestamps and
// returns the words; the app then lines them up against the lyric lines itself.
//
// Deploy:   supabase functions deploy lyric-sync
// Needs:    an OPENAI_API_KEY secret on the project (supabase secrets set OPENAI_API_KEY=sk-...),
//           the same one ai-proxy uses if it's already set.
// Callers must be signed in (the default JWT check), so it can't be used anonymously.

import { createClient } from "jsr:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

const MAX_BYTES = 24 * 1024 * 1024; // Whisper's limit is 25 MB

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "Use POST." }, 405);

  const key = Deno.env.get("OPENAI_API_KEY");
  if (!key) return json({ error: "Lyric sync isn't set up yet (missing OPENAI_API_KEY)." }, 500);

  // Only signed-in users.
  const auth = req.headers.get("Authorization") ?? "";
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: auth } },
  });
  const { data: who, error: whoErr } = await sb.auth.getUser();
  if (whoErr || !who?.user) return json({ error: "Sign in to sync lyrics." }, 401);

  let form: FormData;
  try { form = await req.formData(); } catch { return json({ error: "Expected audio as form data." }, 400); }
  const audio = form.get("audio");
  if (!(audio instanceof File)) return json({ error: "No audio was sent." }, 400);
  if (audio.size > MAX_BYTES) return json({ error: "That track is too long to sync (over about 12 minutes)." }, 413);
  // Whisper only reads the first ~224 tokens of a prompt; the start of the lyrics is plenty of a hint.
  const prompt = String(form.get("prompt") ?? "").slice(0, 800);

  const out = new FormData();
  out.append("file", audio, audio.name || "track.wav");
  out.append("model", "whisper-1");
  out.append("response_format", "verbose_json");
  out.append("timestamp_granularities[]", "word");
  if (prompt) out.append("prompt", prompt);

  const r = await fetch("https://api.openai.com/v1/audio/transcriptions", {
    method: "POST",
    headers: { Authorization: `Bearer ${key}` },
    body: out,
  });
  const body = await r.json().catch(() => null);
  if (!r.ok || !body) return json({ error: body?.error?.message ?? `Transcription failed (${r.status}).` }, 502);

  const words = (body.words ?? []).map((w: { word: string; start: number; end: number }) => ({
    w: w.word, s: Math.round(w.start * 100) / 100, e: Math.round(w.end * 100) / 100,
  }));
  return json({ words, duration: body.duration ?? null, text: body.text ?? "" });
});
