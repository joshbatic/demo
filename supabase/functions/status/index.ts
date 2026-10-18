// *[demo] status: checks every service the app depends on and saves the results (supabase/service-status.sql).
//
//   { action: "cron" }   from the 5-minute schedule; needs the x-cron-token header to match STATUS_CRON_TOKEN.
//   { action: "check" }  from [developer] › Admin › Status › Check Now; admins only.
// Returns { results: [{ service, ok, ms, detail }] }. ok is "up", "slow", "down" or "unknown".
//
// Deploy:  supabase functions deploy status        (or paste into Edge Functions › New function › "status")
// Secrets: STATUS_CRON_TOKEN (any long random text, also pasted into the schedule). It also reads
// OPENAI_API_KEY and RESEND_API_KEY, which are already set, to check those keys still work.
// Nothing here uses AI or sends email: OpenAI is asked for its model list, Resend for its domains.

import { createClient } from "jsr:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-cron-token",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
const env = (k: string) => (Deno.env.get(k) || "").trim().replace(/^["'`]|["'`]$/g, "").replace(/^Bearer\s+/i, "").trim();

type Ok = "up" | "slow" | "down" | "unknown";
type Result = { service: string; ok: Ok; ms: number | null; detail: string };
const SLOW_MS = 3000;

// one HTTP request with a time limit; never throws
async function hit(url: string, init: RequestInit = {}, timeoutMs = 9000) {
  const c = new AbortController(), t = setTimeout(() => c.abort(), timeoutMs), t0 = performance.now();
  try {
    const r = await fetch(url, { ...init, signal: c.signal, redirect: "follow" });
    const text = await r.text().catch(() => "");
    return { status: r.status, text, ms: Math.round(performance.now() - t0), error: "" };
  } catch (e) {
    return { status: 0, text: "", ms: Math.round(performance.now() - t0), error: (e as Error)?.name === "AbortError" ? "timed out" : String((e as Error)?.message || e).slice(0, 120) };
  } finally { clearTimeout(t); }
}
const speed = (ok: boolean, ms: number): Ok => ok ? (ms > SLOW_MS ? "slow" : "up") : "down";
const why = (h: { status: number; error: string }) => h.error || `HTTP ${h.status}`;

// a page or endpoint that should answer with one of the expected codes
async function web(service: string, url: string, good: (s: number) => boolean, init: RequestInit = {}): Promise<Result> {
  const h = await hit(url, init);
  const ok = !h.error && good(h.status);
  return { service, ok: speed(ok, h.ms), ms: h.ms, detail: ok ? (h.ms > SLOW_MS ? `slow (${h.ms} ms)` : "") : why(h) };
}

// a public status page (Statuspage format): none = up, minor = slow (degraded), major/critical = down
async function statusPage(service: string, url: string): Promise<Result> {
  const h = await hit(url, { headers: { Accept: "application/json" } });
  if (h.error || h.status !== 200) return { service, ok: "unknown", ms: h.ms, detail: `status page unreachable (${why(h)})` };
  try {
    const j = JSON.parse(h.text), ind = String(j?.status?.indicator || ""), desc = String(j?.status?.description || "");
    const ok: Ok = ind === "none" ? "up" : ind === "minor" || ind === "maintenance" ? "slow" : ind ? "down" : "unknown";
    return { service, ok, ms: h.ms, detail: ok === "up" ? "" : desc.slice(0, 200) };
  } catch { return { service, ok: "unknown", ms: h.ms, detail: "status page format changed" }; }
}

// Apple's developer system status (TestFlight, App Store Connect, push…), published as a JSONP file
async function appleStatus(): Promise<Result> {
  const service = "apple";
  const h = await hit("https://www.apple.com/support/systemstatus/data/developer/system_status_en_US.js");
  if (h.error || h.status !== 200) return { service, ok: "unknown", ms: h.ms, detail: `status page unreachable (${why(h)})` };
  try {
    const body = h.text.slice(h.text.indexOf("{"), h.text.lastIndexOf("}") + 1);
    const j = JSON.parse(body), watch = /testflight|app store connect|apns|push notification|certificates|xcode cloud|sign in with apple|developer id/i;
    const open = (j.services || []).filter((s: { serviceName?: string; events?: { eventStatus?: string }[] }) =>
      watch.test(s.serviceName || "") && (s.events || []).some((e) => !/resolved|completed/i.test(e.eventStatus || "")));
    return { service, ok: open.length ? "slow" : "up", ms: h.ms, detail: open.map((s: { serviceName: string }) => s.serviceName).join(", ").slice(0, 200) };
  } catch { return { service, ok: "unknown", ms: h.ms, detail: "status page format changed" }; }
}

async function runChecks(): Promise<Result[]> {
  const SB = env("SUPABASE_URL"), ANON = env("SUPABASE_ANON_KEY"), SERVICE = env("SUPABASE_SERVICE_ROLE_KEY");
  const OPENAI = env("OPENAI_API_KEY"), RESEND = env("RESEND_API_KEY");
  const anonH = { apikey: ANON, Authorization: `Bearer ${ANON}` };
  // a server function is up if it answers at all (405 for a GET, 401 without sign-in); 404 means not deployed
  const fn = (name: string) => web(`fn:${name}`, `${SB}/functions/v1/${name}`, (s) => s > 0 && s < 500 && s !== 404, { headers: anonH });
  const checks: Promise<Result>[] = [
    web("website", "https://hellodemo.app/", (s) => s === 200),
    web("share", "https://listen.hellodemo.app/", (s) => s > 0 && s < 500),
    web("auth", `${SB}/auth/v1/health`, (s) => s === 200, { headers: { apikey: ANON } }),
    web("storage", `${SB}/storage/v1/bucket`, (s) => s === 200, { headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}` } }),
    (async (): Promise<Result> => {
      const t0 = performance.now();
      const sb = createClient(SB, SERVICE, { auth: { persistSession: false } });
      const { error } = await sb.from("service_checks").select("id", { head: true, count: "exact" }).limit(1);
      const ms = Math.round(performance.now() - t0);
      return { service: "database", ok: speed(!error, ms), ms, detail: error ? error.message.slice(0, 200) : "" };
    })(),
    fn("ai-proxy"), fn("lyric-sync"), fn("beta"),
    OPENAI
      ? (async (): Promise<Result> => {
        const h = await hit("https://api.openai.com/v1/models", { headers: { Authorization: `Bearer ${OPENAI}` } });
        if (h.status === 200) return { service: "openai", ok: speed(true, h.ms), ms: h.ms, detail: "" };
        if (h.status === 401) return { service: "openai", ok: "down", ms: h.ms, detail: "OpenAI rejected the API key" };
        if (h.status === 429) return { service: "openai", ok: "slow", ms: h.ms, detail: "rate limited or out of credit" };
        return { service: "openai", ok: "down", ms: h.ms, detail: why(h) };
      })()
      : Promise.resolve({ service: "openai", ok: "down" as Ok, ms: null, detail: "OPENAI_API_KEY isn't set" }),
    RESEND
      ? (async (): Promise<Result> => {
        const h = await hit("https://api.resend.com/domains", { headers: { Authorization: `Bearer ${RESEND}` } });
        // a "sending access" key can't list domains: that 401 still proves the key is valid
        if (h.status === 200) {
          let d = ""; try { const dom = (JSON.parse(h.text).data || []).find((x: { name: string }) => x.name === "hellodemo.app"); if (dom && dom.status !== "verified") d = `hellodemo.app is ${dom.status}`; } catch { /* ignore */ }
          return { service: "resend", ok: d ? "slow" : speed(true, h.ms), ms: h.ms, detail: d };
        }
        if (h.status === 401 && /restricted/i.test(h.text)) return { service: "resend", ok: speed(true, h.ms), ms: h.ms, detail: "" };
        if (h.status === 401 || h.status === 400) return { service: "resend", ok: "down", ms: h.ms, detail: "Resend rejected the API key" };
        return { service: "resend", ok: "down", ms: h.ms, detail: why(h) };
      })()
      : Promise.resolve({ service: "resend", ok: "down" as Ok, ms: null, detail: "RESEND_API_KEY isn't set" }),
    web("datamuse", "https://api.datamuse.com/words?rel_rhy=time&max=1", (s) => s === 200),
    statusPage("supabase-status", "https://status.supabase.com/api/v2/status.json"),
    statusPage("vercel-status", "https://www.vercel-status.com/api/v2/status.json"),
    statusPage("github-status", "https://www.githubstatus.com/api/v2/status.json"),
    statusPage("openai-status", "https://status.openai.com/api/v2/status.json"),
    appleStatus(),
  ];
  return await Promise.all(checks);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "Use POST." }, 405);
  let body: Record<string, unknown> = {};
  try { body = await req.json(); } catch { /* empty body is fine */ }

  // who's asking: the schedule (shared token) or an admin (signed in)
  const token = env("STATUS_CRON_TOKEN");
  let allowed = !!token && req.headers.get("x-cron-token") === token;
  if (!allowed) {
    const user = createClient(env("SUPABASE_URL"), env("SUPABASE_ANON_KEY"), { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } });
    const { data } = await user.rpc("is_admin");
    allowed = data === true;
  }
  if (!allowed) return json({ error: "Only the schedule or an admin can run checks." }, 403);

  const results = await runChecks();
  const sb = createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"), { auth: { persistSession: false } });
  const { error } = await sb.from("service_checks").insert(results.map((r) => ({ ...r, detail: r.detail || null })));
  if (error) console.error("Couldn't save the checks:", error.message);
  if (Math.random() < 0.05) await sb.from("service_checks").delete().lt("at", new Date(Date.now() - 30 * 864e5).toISOString());
  const down = results.filter((r) => r.ok === "down").map((r) => r.service);
  if (down.length) console.log("Down:", down.join(", "));
  return json({ results, saved: !error, action: body.action || "check" });
});
