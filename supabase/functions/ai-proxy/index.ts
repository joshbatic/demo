// *[demo] ai-proxy: every AI request from the iPhone app and the web, so no OpenAI key ever lives on a device.
//
// The app sends { prompt, modelTier } and gets back { text }, or { error } with a message it can show.
//   modelTier "complex" (Rate, the voice profile) uses gpt-5 with medium reasoning (3 units).
//   modelTier "write" (Lines, rewrites) thinks a little before writing (1 unit).
//   modelTier "judge" (ranking and filtering lines) uses the small model with light reasoning (1 unit).
//   anything else uses gpt-5-mini with minimal reasoning (1 unit).
// Models can be overridden with the AI_WRITE_MODEL / AI_JUDGE_MODEL secrets; if a model is refused,
// the next one in the list is tried, so a bad override never breaks AI.
// Each request is counted against the account's plan limits first (supabase/plans.sql, ai_take()): Free gets a
// few quick requests a day, Pro and Beta the full set, with a monthly cap on the heavy ones for Pro.
// If the allowance can't be checked (ai_take errors), the request is refused.
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
  const tier = typeof body.modelTier === "string" ? body.modelTier : "";
  const complex = tier === "complex";

  // the account's daily allowance
  const { data: take, error: takeErr } = await sb.rpc("ai_take", { kind: "ai", units: complex ? 3 : 1 });
  if (!takeErr && take && take.ok === false) {
    if (take.reason === "off") return json({ error: "AI features are paused for maintenance. They'll be back shortly.", off: true });
    if (take.reason === "minute") return json({ error: "That's a lot of requests at once. Give it a minute and try again." });
    if (take.reason === "pro") return json({ error: "Rate and writing voice are part of *[demo] Pro.", pro: true });
    if (take.reason === "month") return json({ error: "You've used this month's 100 Rates and voice updates. They reset on the 1st." });
    if (take.reason === "day") return json(take.tier === "free"
      ? { error: `You've used today's ${take.limit} free AI requests. Go Pro for more, or try again in about ${hoursToReset()} hours.`, pro: true }
      : { error: `You've reached today's AI limit. It resets in about ${hoursToReset()} hours.` });
    if (take.reason === "beta") return json({ error: "Your beta access hasn't been approved yet." }, 403);
    return json({ error: "Sign in to use AI features." }, 401);
  }
  // if the allowance can't be checked, nothing is sent: an unchecked request could bypass every limit
  if (takeErr || !take) { console.error('ai_take', takeErr); return json({ error: "AI couldn't start just now. Try again in a moment." }); }

  const envW = Deno.env.get("AI_WRITE_MODEL"), envJ = Deno.env.get("AI_JUDGE_MODEL");
  type Try = { model: string; effort: string; max: number };
  const plan: Try[] =
    complex ? [{ model: "gpt-5", effort: "medium", max: 5000 }]
    : tier === "write" ? [
        ...(envW ? [{ model: envW, effort: "low", max: 4000 }] : []),
        { model: "gpt-5", effort: "low", max: 4000 },
        { model: "gpt-5-mini", effort: "low", max: 4000 },
      ]
    : tier === "judge" ? [
        ...(envJ ? [{ model: envJ, effort: "low", max: 2500 }] : []),
        { model: "gpt-5-mini", effort: "low", max: 2500 },
      ]
    : [{ model: "gpt-5-mini", effort: "minimal", max: 2000 }];
  const ac = new AbortController();
  const timer = setTimeout(() => ac.abort(), complex ? 110000 : tier === "write" ? 70000 : 45000);
  try {
    let last = "AI service error.";
    for (const t of plan) {
      const r = await fetch("https://api.openai.com/v1/chat/completions", {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${key}` },
        body: JSON.stringify({ model: t.model, messages: [{ role: "user", content: prompt }],
          max_completion_tokens: t.max, reasoning_effort: t.effort }),
        signal: ac.signal,
      });
      const j = await r.json().catch(() => null);
      if (!r.ok || !j) {
        last = j?.error?.message ?? `AI service error (${r.status}).`;
        // a missing or unsupported model falls through to the next one; anything else is final
        if ((r.status === 400 || r.status === 404 || r.status === 403) && t !== plan[plan.length - 1]) { console.warn("model refused", t.model, last); continue; }
        return json({ error: last });
      }
      const choice = j.choices?.[0];
      const text: string = choice?.message?.content ?? "";
      if (!text.trim()) return json({ error: choice?.finish_reason === "length" ? "The AI ran out of room before answering. Try again." : "The AI returned an empty response." });
      return json({ text });
    }
    return json({ error: last });
  } catch (e) {
    return json({ error: (e as Error)?.name === "AbortError" ? "The AI took too long to answer. Try again." : "Couldn't reach the AI service." });
  } finally {
    clearTimeout(timer);
  }
});
