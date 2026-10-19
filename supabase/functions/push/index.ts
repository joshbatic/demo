// *[demo] push notifications to iPhones, through Apple (APNs). Phones register in public.push_tokens (supabase/push.sql).
//
//   { action: "invite", song_id, invitee }       The app, right after inviting someone: tells the invitee's phones.
//                                                Only works for an invite the caller sent in the last 10 minutes.
//   { action: "send", user, title, body, data }  Other functions (the support function, for help desk replies), with the
//                                                service role key.
//   { action: "admin_send", user, title, body }  Admins, from Admin › Users › someone › Send a Notification.
//   { action: "test" }                           Admins: a test notification to their own phones (Admin › Debug).
//
// Secrets (Edge Functions › Secrets):
//   APNS_KEY      the whole .p8 file from Apple (Keys › *[demo] Push), including the BEGIN/END lines
//   APNS_KEY_ID   the 10-character Key ID shown next to it
//   APNS_TEAM_ID  optional, defaults to KZL3T52VV3
// Deploy with "Verify JWT" on.

import { createClient } from "jsr:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
const env = (k: string) => (Deno.env.get(k) || "").trim();
const str = (v: unknown, n: number) => (typeof v === "string" ? v.trim().slice(0, n) : "");
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const db = () => createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"), { auth: { persistSession: false } });

// ---------- Apple's sign-in token: an ES256 JWT made from the .p8 key, good for up to an hour ----------
const b64u = (b: Uint8Array) => btoa(String.fromCharCode(...b)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const utf8 = (s: string) => new TextEncoder().encode(s);
let cached = { jwt: "", at: 0 };
async function appleJwt(): Promise<string> {
  if (cached.jwt && Date.now() - cached.at < 40 * 60e3) return cached.jwt;
  const pem = env("APNS_KEY").replace(/\\n/g, "\n");
  const b64 = pem.replace(/-----[A-Z ]+-----/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const head = b64u(utf8(JSON.stringify({ alg: "ES256", kid: env("APNS_KEY_ID") })));
  const claims = b64u(utf8(JSON.stringify({ iss: env("APNS_TEAM_ID") || "KZL3T52VV3", iat: Math.floor(Date.now() / 1000) })));
  const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, utf8(`${head}.${claims}`)));
  cached = { jwt: `${head}.${claims}.${b64u(sig)}`, at: Date.now() };
  return cached.jwt;
}
const ready = () => !!(env("APNS_KEY") && env("APNS_KEY_ID"));

type Tok = { token: string; topic: string; env: string | null };
type Sent = { ok: boolean; env: string | null; reason?: string; dead?: boolean };

// Xcode builds get "sandbox" tokens, TestFlight and App Store builds "production" ones; a new token is tried on both.
async function sendOne(t: Tok, payload: unknown): Promise<Sent> {
  const tries = t.env ? [t.env] : ["production", "sandbox"];
  let last: Sent = { ok: false, env: t.env, reason: "not sent" };
  for (const e of tries) {
    const host = e === "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com";
    let r: Response;
    try {
      r = await fetch(`https://${host}/3/device/${t.token}`, {
        method: "POST",
        headers: {
          authorization: `bearer ${await appleJwt()}`, "apns-topic": t.topic, "apns-push-type": "alert",
          "apns-priority": "10", "apns-expiration": String(Math.floor(Date.now() / 1000) + 86400), "content-type": "application/json",
        },
        body: JSON.stringify(payload),
      });
    } catch (err) { return { ok: false, env: t.env, reason: "Couldn't reach Apple: " + String((err as Error)?.message || err).slice(0, 120) }; }
    if (r.status === 200) return { ok: true, env: e };
    const reason = String((await r.json().catch(() => ({})))?.reason || r.status);
    last = { ok: false, env: t.env, reason, dead: r.status === 410 || ["Unregistered", "BadDeviceToken", "DeviceTokenNotForTopic"].includes(reason) };
    if (reason === "BadDeviceToken" && !t.env && e === "production") continue;   // maybe a sandbox token
    break;
  }
  return last;
}

// every phone signed in to this account
async function sendTo(user: string, title: string, body: string, data: Record<string, unknown> = {}) {
  if (!ready()) return { sent: 0, failed: 0, devices: 0, error: "Push isn't set up yet: add the APNS_KEY and APNS_KEY_ID secrets." };
  const sb = db();
  const { data: toks } = await sb.from("push_tokens").select("token, topic, env").eq("user_id", user);
  let sent = 0, failed = 0;
  const reasons: string[] = [];
  const payload = { aps: { alert: { title, body }, sound: "default", "thread-id": String(data.kind || "demo") }, ...data };
  for (const t of (toks || []) as Tok[]) {
    const r = await sendOne(t, payload);
    if (r.ok) { sent++; await sb.from("push_tokens").update({ env: r.env, last_sent: new Date().toISOString(), last_error: null }).eq("token", t.token); }
    else {
      failed++; reasons.push(r.reason || "failed");
      await sb.from("push_tokens").update({ last_error: (r.reason || "failed").slice(0, 200), ...(r.dead ? { user_id: null } : {}) }).eq("token", t.token);
    }
  }
  return { sent, failed, devices: (toks || []).length, reasons };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "Use POST." }, 405);
  let b: Record<string, unknown>;
  try { b = await req.json(); } catch { return json({ error: "Expected JSON." }, 400); }
  const auth = req.headers.get("Authorization") ?? "";
  const service = env("SUPABASE_SERVICE_ROLE_KEY");

  // ---------- other functions ----------
  if (service && auth === `Bearer ${service}`) {
    if (b.action !== "send" || typeof b.user !== "string" || !UUID.test(b.user)) return json({ error: "Bad request." }, 400);
    const data = b.data && typeof b.data === "object" ? b.data as Record<string, unknown> : {};
    return json({ ok: true, ...(await sendTo(b.user, str(b.title, 80) || "*[demo]", str(b.body, 240), data)) });
  }

  const userClient = createClient(env("SUPABASE_URL"), env("SUPABASE_ANON_KEY"), { global: { headers: { Authorization: auth } } });
  const { data: who } = await userClient.auth.getUser();
  const me = who?.user;
  if (!me) return json({ error: "Sign in first." }, 401);

  // ---------- someone just invited a co-writer ----------
  if (b.action === "invite") {
    const invitee = str(b.invitee, 64), song = str(b.song_id, 100);
    if (!UUID.test(invitee) || !song) return json({ error: "Bad request." }, 400);
    const sb = db();
    const { data: inv } = await sb.from("collab_invites").select("id, song_title, owner_name")
      .eq("owner_id", me.id).eq("invitee_user_id", invitee).eq("song_id", song).eq("status", "pending")
      .gte("created_at", new Date(Date.now() - 10 * 60e3).toISOString()).order("created_at", { ascending: false }).limit(1).maybeSingle();
    if (!inv) return json({ ok: true, sent: 0 });
    const { data: blocked } = await sb.from("user_blocks").select("blocker").eq("blocker", invitee).eq("blocked", me.id).maybeSingle();
    if (blocked) return json({ ok: true, sent: 0 });
    const { data: prof } = await sb.from("profiles").select("display_name, username").eq("user_id", me.id).maybeSingle();
    const meta = (me.user_metadata || {}) as Record<string, string>;
    const from = prof?.display_name || inv.owner_name || (prof?.username ? "@" + prof.username : "") || meta.full_name || meta.name || "Someone";
    const r = await sendTo(invitee, `${from} invited you`, `to write “${inv.song_title || "a song"}” together`, { kind: "invite", invite: inv.id, song: song });
    return json({ ok: true, sent: r.sent });
  }

  // ---------- admins only from here ----------
  const { data: isAdmin } = await userClient.rpc("is_admin");
  if (isAdmin !== true) return json({ error: "Admins only." }, 403);

  if (b.action === "test") {
    const r = await sendTo(me.id, "*[demo]", "Push notifications are working.", { kind: "test" });
    return r.error ? json({ error: r.error }, 503) : json({ ok: true, ...r });
  }
  if (b.action === "admin_send") {
    const user = str(b.user, 64), body = str(b.body, 240);
    if (!UUID.test(user) || body.length < 2) return json({ error: "Write the notification first." }, 400);
    const r = await sendTo(user, str(b.title, 80) || "*[demo]", body, { kind: "message" });
    return r.error ? json({ error: r.error }, 503) : json({ ok: true, ...r });
  }
  return json({ error: "Unknown action." }, 400);
});
