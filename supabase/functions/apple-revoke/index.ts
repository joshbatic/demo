// *[demo] apple-revoke: when someone deletes their account, cut the link between their Apple ID and *[demo]
// (App Store Review Guideline 5.1.1(v): apps that offer Sign in with Apple must revoke the user's tokens on deletion).
//
// The iPhone app asks Apple for a fresh authorization code just before deleting the account and sends it here
// as { code }. This exchanges it for a token and revokes that token with Apple, then the app deletes the account.
//
// Secrets (Edge Functions › Secrets), from the Sign in with Apple key (the .p8 file):
//   APPLE_TEAM_ID       the Apple Developer team ID
//   APPLE_KEY_ID        the key's ID
//   APPLE_PRIVATE_KEY   the whole .p8 file, BEGIN/END lines included
//   APPLE_CLIENT_ID     optional; the iPhone app's bundle ID (default app.hellodemo.demo)
// Without them it answers { ok: false, skipped: true } and the app deletes the account anyway.
// Callers must be signed in.

import { createClient } from "jsr:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
const env = (k: string) => (Deno.env.get(k) || "").trim();
const b64url = (b: Uint8Array | string) => {
  const bytes = typeof b === "string" ? new TextEncoder().encode(b) : b;
  let s = ""; for (const x of bytes) s += String.fromCharCode(x);
  return btoa(s).replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_");
};

// the client secret Apple wants: a short-lived ES256 JWT signed with the Sign in with Apple key
async function clientSecret(team: string, keyId: string, pem: string, clientId: string) {
  const body = pem.replace(/-----[^-]+-----/g, "").replace(/\\n/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const now = Math.floor(Date.now() / 1000);
  const head = b64url(JSON.stringify({ alg: "ES256", kid: keyId, typ: "JWT" }));
  const claims = b64url(JSON.stringify({ iss: team, iat: now, exp: now + 300, aud: "https://appleid.apple.com", sub: clientId }));
  const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(head + "." + claims)));
  return head + "." + claims + "." + b64url(sig);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "Use POST." }, 405);

  let body: { code?: unknown; check?: unknown } = {};
  try { body = await req.json(); } catch { /* empty */ }
  const team = env("APPLE_TEAM_ID"), keyId = env("APPLE_KEY_ID"), pem = env("APPLE_PRIVATE_KEY");
  const clientId = env("APPLE_CLIENT_ID") || "app.hellodemo.demo";

  // { check: true }: are the secrets right? Apple answers invalid_grant to a made-up code when the key is good,
  // and invalid_client when the team, key ID or key is wrong. Nothing about anyone's account is involved.
  if (body.check === true) {
    if (!team || !keyId || !pem) return json({ ok: false, error: "secrets not set" });
    try {
      const secret = await clientSecret(team, keyId, pem, clientId);
      const t = await fetch("https://appleid.apple.com/auth/token", {
        method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({ client_id: clientId, client_secret: secret, code: "check", grant_type: "authorization_code" }).toString(),
      });
      const tj = await t.json().catch(() => ({}));
      return json({ ok: tj?.error === "invalid_grant", apple: tj?.error ?? t.status });
    } catch (e) {
      return json({ ok: false, error: (e as Error)?.message });
    }
  }

  const sb = createClient(env("SUPABASE_URL"), env("SUPABASE_ANON_KEY"), {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
  });
  const { data: who } = await sb.auth.getUser();
  if (!who?.user) return json({ error: "Sign in first." }, 401);

  const code = typeof body.code === "string" ? body.code.trim() : "";
  if (!code) return json({ error: "No authorization code." }, 400);

  if (!team || !keyId || !pem) { console.warn("apple-revoke: secrets not set"); return json({ ok: false, skipped: true }); }

  try {
    const secret = await clientSecret(team, keyId, pem, clientId);
    const form = (o: Record<string, string>) => new URLSearchParams(o).toString();
    const headers = { "Content-Type": "application/x-www-form-urlencoded" };
    const t = await fetch("https://appleid.apple.com/auth/token", {
      method: "POST", headers,
      body: form({ client_id: clientId, client_secret: secret, code, grant_type: "authorization_code" }),
    });
    const tj = await t.json().catch(() => ({}));
    const token: string = tj.refresh_token || tj.access_token || "";
    if (!t.ok || !token) { console.error("apple-revoke token", t.status, tj?.error); return json({ ok: false, error: tj?.error || `token ${t.status}` }); }
    const r = await fetch("https://appleid.apple.com/auth/revoke", {
      method: "POST", headers,
      body: form({ client_id: clientId, client_secret: secret, token, token_type_hint: tj.refresh_token ? "refresh_token" : "access_token" }),
    });
    if (!r.ok) { console.error("apple-revoke revoke", r.status); return json({ ok: false, error: `revoke ${r.status}` }); }
    return json({ ok: true });
  } catch (e) {
    console.error("apple-revoke", (e as Error)?.message);
    return json({ ok: false, error: "Couldn't reach Apple." });
  }
});
