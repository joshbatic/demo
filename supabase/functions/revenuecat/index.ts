// *[demo] subscriptions: keeps public.plans in step with Apple purchases, via RevenueCat.
//
// Two callers:
//   RevenueCat webhook   POST with  Authorization: <REVENUECAT_WEBHOOK_AUTH>   (set the same value in RevenueCat › Webhooks)
//   An admin             POST { action: "admin_sync", user } re-checks someone else (Admin › Users)
//   The app              POST { action: "sync" } with the signed-in user's token, straight after a purchase or restore,
//                        so Pro switches on without waiting for the webhook.
//
// Either way it doesn't trust the event itself: it asks RevenueCat for the person's current "pro" entitlement and
// writes that to plans (tier 'pro' until it expires). Late, repeated or out-of-order events can't leave anyone wrong.
// Admin-given plans are left alone unless the person actually has (or had) an Apple subscription.
//
// The app logs people in to RevenueCat with their Supabase user id, so RevenueCat ids are user ids.
//
// Secrets (Edge Functions › Secrets):
//   REVENUECAT_WEBHOOK_AUTH  a long random string you make up; paste the same into RevenueCat › Webhooks › Authorization header
//   REVENUECAT_SECRET_KEY    RevenueCat › Project settings › API keys › Secret API key (starts sk_)
// Deploy with "Verify JWT" off (the webhook has no Supabase token; this file checks both callers itself).

import { createClient } from "jsr:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
const env = (k: string) => (Deno.env.get(k) || "").trim();
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ENTITLEMENT = "pro";

const admin = () => createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"), { auth: { persistSession: false } });

// constant-time comparison for the webhook secret
function same(a: string, b: string) {
  if (!a || !b || a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

type Result = { user: string; plan: "pro" | "cleared" | "unchanged"; expires?: string | null; error?: string };

// Ask RevenueCat for this person's "pro" entitlement and write it to plans.
async function sync(user: string): Promise<Result> {
  const key = env("REVENUECAT_SECRET_KEY");
  if (!key) return { user, plan: "unchanged", error: "REVENUECAT_SECRET_KEY isn't set" };
  const r = await fetch(`https://api.revenuecat.com/v1/subscribers/${encodeURIComponent(user)}`, {
    headers: { Authorization: `Bearer ${key}`, Accept: "application/json" },
  });
  if (!r.ok) return { user, plan: "unchanged", error: `RevenueCat answered ${r.status}` };
  const body = await r.json().catch(() => ({}));
  const sub = body?.subscriber || {};
  const ent = sub?.entitlements?.[ENTITLEMENT];
  const hadApple = Object.keys(sub?.subscriptions || {}).length > 0 || !!ent;
  const expires: string | null = ent ? (ent.expires_date ?? null) : null;  // null expiry on an entitlement = lifetime
  const active = !!ent && (expires === null || Date.parse(expires) > Date.now());
  // in the free trial? (for the "trial ends in 2 days" notification, supabase/notify.sql)
  const trial = !!ent && sub?.subscriptions?.[ent.product_identifier]?.period_type === "trial";

  const db = admin();
  const { data: row } = await db.from("plans").select("tier, source").eq("user_id", user).maybeSingle();
  if (active) {
    const { error } = await db.from("plans").upsert({ user_id: user, tier: "pro", source: "apple", expires_at: expires, trial, updated_at: new Date().toISOString() });
    return error ? { user, plan: "unchanged", error: error.message } : { user, plan: "pro", expires };
  }
  // Not subscribed (expired, refunded or never bought). Only undo a plan that came from Apple.
  if (hadApple && row && row.source === "apple" && row.tier === "pro") {
    const { error } = await db.from("plans").update({ tier: "auto", expires_at: null, updated_at: new Date().toISOString() }).eq("user_id", user);
    return error ? { user, plan: "unchanged", error: error.message } : { user, plan: "cleared" };
  }
  return { user, plan: "unchanged" };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "Use POST." }, 405);
  let body: Record<string, any> = {};
  try { body = await req.json(); } catch { /* empty body */ }
  const auth = req.headers.get("Authorization") || "";

  // 1. RevenueCat webhook
  const hook = env("REVENUECAT_WEBHOOK_AUTH");
  if (hook && (same(auth, hook) || same(auth, `Bearer ${hook}`))) {
    const ev = body?.event || {};
    if (ev.type === "TEST") return json({ ok: true, test: true });
    const ids = new Set<string>();
    for (const v of [ev.app_user_id, ev.original_app_user_id, ...(ev.aliases || []), ...(ev.transferred_from || []), ...(ev.transferred_to || [])])
      if (typeof v === "string" && UUID.test(v)) ids.add(v.toLowerCase());
    const results: Result[] = [];
    for (const id of ids) results.push(await sync(id));
    const failed = results.filter((r) => r.error);
    if (failed.length) console.error("revenuecat sync failed", ev.type, JSON.stringify(failed));
    // a 5xx makes RevenueCat retry later
    return json({ ok: !failed.length, type: ev.type, results }, failed.length ? 500 : 200);
  }

  // 2. The app, straight after a purchase or restore
  if (body?.action === "sync") {
    const userClient = createClient(env("SUPABASE_URL"), env("SUPABASE_ANON_KEY"), { global: { headers: { Authorization: auth } } });
    const { data } = await userClient.auth.getUser();
    const uid = data?.user?.id;
    if (!uid) return json({ error: "Sign in first." }, 401);
    const result = await sync(uid);
    return json({ ok: !result.error, ...result }, result.error ? 502 : 200);
  }

  // 3. An admin re-checking someone's subscription (Admin › Users › a user › Re-check Subscription)
  if (body?.action === "admin_sync" && typeof body.user === "string" && UUID.test(body.user)) {
    const userClient = createClient(env("SUPABASE_URL"), env("SUPABASE_ANON_KEY"), { global: { headers: { Authorization: auth } } });
    const { data: isAdmin } = await userClient.rpc("is_admin");
    if (isAdmin !== true) return json({ error: "Admins only." }, 403);
    const result = await sync(body.user.toLowerCase());
    return json({ ok: !result.error, ...result }, result.error ? 502 : 200);
  }

  return json({ error: "Not allowed." }, 401);
});
