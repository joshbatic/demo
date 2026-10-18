// *[demo] beta: the waitlist (supabase/beta-access.sql).
//
//   { action: "request", email, name, role, heard, link, note, website, t }
//       From hellodemo.app/beta.html (no sign-in). Saves the request, emails the person that it arrived,
//       and tells you there's a new one. "website" is a hidden field only bots fill in; "t" is how long
//       the form was open (ms), and very fast submissions are treated as bots too.
//   { action: "decide", id, approve }
//       From the app (Account › Beta Requests), admins only. Approving emails the TestFlight link and a
//       personal invite code; declining sends a short, kind note.
//
// Deploy:  supabase functions deploy beta        (or paste this into Edge Functions › New function › "beta")
// Secrets (Edge Functions › Secrets):
//   RESEND_API_KEY   from resend.com (after verifying hellodemo.app there)
//   BETA_FROM        the sender, e.g.  *[demo] <beta@hellodemo.app>
//   TESTFLIGHT_URL   your public TestFlight link, e.g. https://testflight.apple.com/join/AbCdEf12
//   ADMIN_EMAIL      where "new request" notices go (your own address; kept out of the code)
// Without RESEND_API_KEY everything still works; emails just aren't sent, and the app tells you so.

import { createClient } from "jsr:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

const env = (k: string) => (Deno.env.get(k) || "").trim();
const esc = (s: unknown) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
const str = (v: unknown, n: number) => (typeof v === "string" ? v.trim().slice(0, n) : "");

// a few requests per address per minute is plenty for a person filling in a form
const HITS = new Map<string, number[]>();
function tooMany(ip: string) {
  const now = Date.now(), a = (HITS.get(ip) || []).filter((t) => now - t < 60_000);
  a.push(now); HITS.set(ip, a);
  if (HITS.size > 5000) HITS.clear();
  return a.length > 5;
}

function page(title: string, body: string) {
  return `<!doctype html><html><body style="margin:0;background:#f5f4f7;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;color:#1c1c1e">
<div style="max-width:520px;margin:0 auto;padding:32px 20px">
<div style="background:#fff;border-radius:18px;padding:28px 24px">
<div style="font-weight:800;font-size:18px;margin-bottom:18px">*[demo]</div>
<h1 style="font-size:22px;line-height:1.3;margin:0 0 12px">${title}</h1>
${body}
</div>
<p style="font-size:12px;color:#8e8e93;text-align:center;margin-top:16px">*[demo] · <a href="https://hellodemo.app" style="color:#8e8e93">hellodemo.app</a></p>
</div></body></html>`;
}
const p = (t: string) => `<p style="font-size:15.5px;line-height:1.5;margin:0 0 14px">${t}</p>`;

async function send(to: string, subject: string, html: string) {
  const key = env("RESEND_API_KEY"), from = env("BETA_FROM") || "*[demo] <beta@hellodemo.app>";
  if (!key || !to) { console.error(`Not sending "${subject}": ${key ? "no recipient" : "RESEND_API_KEY isn't set"}`); return false; }
  try {
    const r = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
      body: JSON.stringify({ from, to: [to], subject, html, reply_to: "help@hellodemo.app" }),
    });
    if (!r.ok) console.error(`Resend refused the email to ${to}: ${r.status} ${await r.text()}`);
    return r.ok;
  } catch (e) { console.error("Couldn't reach Resend:", e); return false; }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "Use POST." }, 405);
  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ error: "Expected JSON." }, 400); }
  const auth = req.headers.get("Authorization") ?? "";
  const sb = createClient(env("SUPABASE_URL"), env("SUPABASE_ANON_KEY"), { global: { headers: { Authorization: auth } } });

  // ---------- a request from the website ----------
  if (body.action === "request") {
    const ip = (req.headers.get("x-forwarded-for") || "").split(",")[0].trim() || "?";
    if (tooMany(ip)) return json({ error: "Too many tries. Wait a minute and try again." }, 429);
    // bots: pretend it worked
    const hp = str(body.hp_field, 200) || str(body.website, 200);
    if (hp || (typeof body.t === "number" && body.t < 1200)) { console.log(`Dropped as a bot (${hp ? "hidden field filled" : `submitted in ${body.t} ms`})`); return json({ ok: true }); }
    const email = str(body.email, 254).toLowerCase(), name = str(body.name, 100);
    const { data, error } = await sb.rpc("beta_request", {
      p_email: email, p_name: name, p_role: str(body.role, 60), p_heard: str(body.heard, 200),
      p_link: str(body.link, 300), p_note: str(body.note, 1000),
    });
    if (error) return json({ error: /valid email/i.test(error.message) ? "Enter a valid email address." : /a lot of requests/i.test(error.message) ? error.message : "Couldn't save your request. Try again in a moment." }, 400);
    console.log(`Request from ${email}: ${data}`);
    if (data === "new") {
      const first = esc(name.split(/\s+/)[0] || "there");
      await send(email, "We got your request for the *[demo] beta", page("You're on the list",
        p(`Hi ${first}, thanks for asking to try *[demo]. We're letting people in a few at a time.`) +
        p("When there's a spot for you, we'll email you a link to install the beta through TestFlight, with an invite code.") +
        p("Nothing else to do for now.")));
      const admin = env("ADMIN_EMAIL");
      if (admin) await send(admin, `New beta request: ${name || email}`, page("New beta request",
        p(`<b>${esc(name || "(no name)")}</b> · ${esc(email)}`) +
        p([str(body.role, 60), str(body.heard, 200)].filter(Boolean).map(esc).join(" · ") || "") +
        (str(body.link, 300) ? p(esc(str(body.link, 300))) : "") +
        (str(body.note, 1000) ? p(esc(str(body.note, 1000))) : "") +
        p("Approve or decline it in the app: Account › Beta Requests.")));
    }
    return json({ ok: true });
  }

  // ---------- approve / decline, from the app ----------
  if (body.action === "decide") {
    const { data: who } = await sb.auth.getUser();
    if (!who?.user) return json({ error: "Sign in first." }, 401);
    const id = str(body.id, 64), approve = body.approve === true;
    const { data: r, error } = await sb.rpc("beta_admin_decide", { p_id: id, p_approve: approve });
    if (error) return json({ error: /admins only/i.test(error.message) ? "Only admins can do that." : error.message }, 403);
    const first = esc(String(r.name || "").split(/\s+/)[0] || "there");
    let emailed = false;
    if (approve) {
      const tf = env("TESTFLIGHT_URL");
      const code = String(r.code || ""), shown = code ? code.slice(0, 4) + "-" + code.slice(4) : "";
      emailed = await send(r.email, "You're in: the *[demo] beta", page("You're in",
        p(`Hi ${first}, there's a spot for you in the *[demo] beta.`) +
        p(`<b>1.</b> On your iPhone, open this link to install *[demo] with TestFlight:<br><a href="${esc(tf)}" style="color:#5b3fd6;font-weight:600">${esc(tf || "TestFlight link coming soon")}</a>`) +
        p("<b>2.</b> Sign in with Apple or Google. If you sign in with the same email this message went to, you're straight in.") +
        p(`<b>3.</b> Signed in with a different email, or chose "Hide My Email"? Enter your invite code when asked:<br><span style="display:inline-block;margin-top:8px;padding:10px 16px;border-radius:12px;background:#f2f0f7;font:700 20px/1 ui-monospace,Menlo,monospace;letter-spacing:2px">${esc(shown)}</span>`) +
        p("Tell us anything that feels confusing, slow or broken: take a screenshot in the app to send it through TestFlight, or reply to this email.")));
    } else {
      emailed = await send(r.email, "About your *[demo] beta request", page("Not this round",
        p(`Hi ${first}, thanks for asking to try *[demo]. We can't fit everyone into this round of the beta, so we're not able to add you just yet.`) +
        p("We'll let you know when *[demo] opens up more widely.")));
    }
    if (emailed) await sb.rpc("beta_admin_mark_emailed", { p_id: id });
    return json({ ok: true, status: r.status, code: r.code, email: r.email, emailed, emailReady: !!env("RESEND_API_KEY") });
  }

  return json({ error: "Unknown action." }, 400);
});
