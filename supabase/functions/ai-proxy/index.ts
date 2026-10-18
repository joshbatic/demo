// *[demo] ai-proxy: every AI request from the iPhone app and the web, so no OpenAI key ever lives on a device.
//
// The app sends { prompt, modelTier } and gets back { text }, or { error } with a message it can show.
//   modelTier "complex" (Rate, the voice profile) uses gpt-5; everything else uses gpt-5-mini.
// Each request is counted against the account's daily limit first (supabase/ai-limits.sql, ai_take()).
// If that SQL hasn't been run yet, requests are allowed rather than broken.
//
// Deploy:  supabase functions deploy ai-proxy        (or paste this into Edge Functions > ai-proxy > Code)
// Needs:   the OPENAI_API_KEY secret (already set if AI works today).
// Callers must be signed in.

import { createClient } from "jsr:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

const MAX_PROMPT = 24000;

// limits reset at midnight UTC
const hoursToReset = () => { const n = new Date(); return Math.max(1, Math.ceil((Date.UTC(n.getUTCFullYear(), n.getUTCMonth(), n.getUTCDate() + 1) - n.getTime()) / 3600e3)); };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "Use POST." }, 405);

  const key = Deno.env.get("OPENAI_API_KEY");
  if (!key) return json({ error: "AI isn't set up yet (missing OPENAI_API_KEY)." });

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
  });
  const { data: who, error: whoErr } = await sb.auth.getUser();
  if (whoErr || !who?.user) return json({ error: "Sign in to use AI features." }, 401);

  let body: { prompt?: unknown; modelTier?: unknown };
  try { body = await req.json(); } catch { return json({ error: "Expected JSON." }, 400); }
  const prompt = typeof body.prompt === "string" ? body.prompt : "";
  if (!prompt.trim()) return json({ error: "Empty prompt." });
  if (prompt.length > MAX_PROMPT) return json({ error: `That request is too large (${prompt.length} characters, limit ${MAX_PROMPT}).` });
  const complex = body.modelTier === "complex";

  // the account's daily allowance
  const { data: take, error: takeErr } = await sb.rpc("ai_take", { kind: "ai", units: complex ? 3 : 1 });
  if (!takeErr && take && take.ok === false) {
    if (take.reason === "minute") return json({ error: "That's a lot of requests at once. Give it a minute and try again." });
    if (take.reason === "day") return json({ error: `You've reached today's AI limit. It resets in about ${hoursToReset()} hours.` });
    return json({ error: "Sign in to use AI features." }, 401);
  }
  // (if ai_take doesn't exist yet, or errors, the request goes ahead rather than breaking the app)

  const payload: Record<string, unknown> = {
    model: complex ? "gpt-5" : "gpt-5-mini",
    messages: [{ role: "user", content: prompt }],
    max_completion_tokens: complex ? 5000 : 2000,
    reasoning_effort: complex ? "medium" : "minimal",
  };
  const ac = new AbortController();
  const timer = setTimeout(() => ac.abort(), complex ? 110000 : 45000);
  try {
    const r = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${key}` },
      body: JSON.stringify(payload),
      signal: ac.signal,
    });
    const j = await r.json().catch(() => null);
    if (!r.ok || !j) return json({ error: j?.error?.message ?? `AI service error (${r.status}).` });
    const choice = j.choices?.[0];
    const text: string = choice?.message?.content ?? "";
    if (!text.trim()) return json({ error: choice?.finish_reason === "length" ? "The AI ran out of room before answering. Try again." : "The AI returned an empty response." });
    return json({ text });
  } catch (e) {
    return json({ error: (e as Error)?.name === "AbortError" ? "The AI took too long to answer. Try again." : "Couldn't reach the AI service." });
  } finally {
    clearTimeout(timer);
  }
});
