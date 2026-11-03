// *[demo] help desk (supabase/helpdesk.sql).
//
//   { action: "submit", topic, message, diag }      From Account › Contact Support (signed in). Saves the ticket and
//                                                  emails you. diag is the app's diagnostics, if they left it ticked.
//   { action: "reply", id, text }                   Admins only, from Admin › Help. Emails the person and saves the reply.
//   { action: "email", user, subject, text }        Admins only, from a user's page in Admin › Users: starts a conversation.
// Replies and emails also go to their iPhones as push notifications, once push is set up (supabase/functions/push).
//
// Replies come from help@hellodemo.app and people answer by email (reply-to help@hellodemo.app).
// Secrets: RESEND_API_KEY and ADMIN_EMAIL (already set for the beta function). SUPPORT_FROM is optional.
// Deploy with "Verify JWT" on.

import { createClient } from "jsr:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
const env = (k: string) => (Deno.env.get(k) || "").trim().replace(/^["'`]|["'`]$/g, "").replace(/^Bearer\s+/i, "").trim();
const esc = (s: unknown) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
const str = (v: unknown, n: number) => (typeof v === "string" ? v.trim().slice(0, n) : "");
const TOPICS: Record<string, string> = { bug: "Something's not working", account: "Account or sign-in", billing: "Subscription or billing", idea: "Idea or request", other: "Something else" };

const page = (body: string) => `<div style="font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:15px;line-height:1.5;color:#1a1820;max-width:560px">${body}<p style="color:#888;font-size:13px;margin-top:28px">*[demo] · hellodemo.app</p></div>`;
const toText = (html: string) => html.replace(/<head[\s\S]*?<\/head>/i, "").replace(/<div style="display:none[^>]*>[\s\S]*?<\/div>/i, "").replace(/<\/(td|tr|div|table)>/gi, "\n").replace(/[ \t]+/g, " ").replace(/\n[ \t]+/g, "\n").replace(/<br\s*\/?>/gi, "\n").replace(/<\/p>/gi, "\n\n").replace(/<[^>]+>/g, "")
  .replace(/&nbsp;/g, " ").replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/\n[ \t]+\n/g, "\n\n").replace(/\n{3,}/g, "\n\n").trim();
const paras = (t: string) => t.split(/\n{2,}/).map((p) => `<p>${esc(p).replace(/\n/g, "<br>")}</p>`).join("");

// ---------- the emails people get from support: a clean letter, styled like the app ----------
// Tables and inline styles so they hold up in Gmail, Outlook and Apple Mail; Apple Mail also gets a dark version.
const ICON = "https://hellodemo.app/icon-192.png";
const FONT = "-apple-system,BlinkMacSystemFont,'SF Pro Text','Segoe UI',Helvetica,Arial,sans-serif";
const nb = (t: string) => t.replace(/\*\[demo\]/g, '<span style="white-space:nowrap">*[demo]</span>');
const letterParas = (t: string) => t.split(/\n{2,}/).map((x) =>
  `<p class="body" style="margin:0 0 16px;font:400 16px/1.55 ${FONT};color:#1C1C1E">${esc(x).replace(/\n/g, "<br>")}</p>`).join("");
function letter(o: { name?: string; text: string; quote?: string; ticket?: number | null; preheader?: string }) {
  const first = (o.name || "").trim().split(/\s+/)[0];
  const quote = o.quote ? `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" class="tile" style="background:#F2F2F7;border-radius:14px;margin:8px 0 6px"><tr><td style="padding:14px 16px">
     <div class="mute" style="font:600 12.5px/1 ${FONT};color:#8E8E93;margin-bottom:8px">You wrote</div>
     <div class="body" style="font:400 14.5px/1.5 ${FONT};color:#3A3A3C">${esc(o.quote).replace(/\n/g, "<br>")}</div></td></tr></table>` : "";
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light dark"><meta name="supported-color-schemes" content="light dark"><title>*[demo] Support</title>
<style>body{margin:0;padding:0;-webkit-text-size-adjust:100%}a{color:inherit}@media (max-width:520px){.pad{padding-left:22px!important;padding-right:22px!important}}
@media (prefers-color-scheme:dark){.bg{background:#000000!important}.card{background:#1C1C1E!important}.ink{color:#FFFFFF!important}.body{color:#EBEBF5!important}.mute{color:#8E8E93!important}.tile{background:#2C2C2E!important}.rule{border-color:#38383A!important}}</style></head>
<body class="bg" style="margin:0;padding:0;background:#F2F2F7">
<div style="display:none;max-height:0;overflow:hidden;opacity:0;color:transparent">${esc((o.preheader || o.text).slice(0, 140))}</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" class="bg" style="background:#F2F2F7"><tr><td align="center" style="padding:28px 12px 36px">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:520px"><tr><td class="card" style="background:#FFFFFF;border-radius:24px">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">
<tr><td class="pad" style="padding:26px 30px 0"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"><tr>
  <td width="46"><img src="${ICON}" width="36" height="36" alt="" style="display:block;border:0;border-radius:9px"></td>
  <td class="ink" style="font:700 15.5px/1.25 ${FONT};color:#000000">${nb("*[demo] Support")}<br><span class="mute" style="font-weight:400;font-size:13.5px;color:#8E8E93">help@hellodemo.app</span></td>
  ${o.ticket ? `<td align="right" class="mute" style="font:500 13px ${FONT};color:#8E8E93">#${o.ticket}</td>` : ""}
</tr></table><div class="rule" style="border-top:.5px solid #E5E5EA;margin-top:20px;font-size:0;line-height:0">&nbsp;</div></td></tr>
<tr><td class="pad" style="padding:22px 30px 28px">
${first ? `<p class="body" style="margin:0 0 16px;font:400 16px/1.55 ${FONT};color:#1C1C1E">Hi ${esc(first)},</p>` : ""}
${letterParas(o.text)}
<p class="body" style="margin:4px 0 ${quote ? "20px" : "0"};font:400 16px/1.55 ${FONT};color:#1C1C1E">${nb("The *[demo] team")}</p>
${quote}
</td></tr></table></td></tr>
<tr><td class="mute" style="padding:18px 18px 0;text-align:center;font:400 12.5px/1.5 ${FONT};color:#8E8E93">Just reply to this email to keep the conversation going.<br>
<a href="https://hellodemo.app" style="color:#8E8E93;text-decoration:none">hellodemo.app</a> &nbsp;·&nbsp; <a href="https://hellodemo.app/privacy.html" style="color:#8E8E93;text-decoration:none">Privacy</a></td></tr>
</table></td></tr></table></body></html>`;
}

async function send(to: string, subject: string, html: string) {
  const key = env("RESEND_API_KEY"), from = env("SUPPORT_FROM") || "*[demo] <help@hellodemo.app>";
  if (!key || !to) { console.error(`Not sending "${subject}": ${key ? "no recipient" : "RESEND_API_KEY isn't set"}`); return false; }
  try {
    const r = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
      body: JSON.stringify({ from, to: [to], subject, html, text: toText(html), reply_to: "help@hellodemo.app" }),
    });
    if (!r.ok) console.error(`Resend refused the email to ${to}: ${r.status} ${await r.text()}`);
    return r.ok;
  } catch (e) { console.error("Couldn't reach Resend:", e); return false; }
}

// a push notification to their iPhones too (supabase/functions/push); quietly skipped if push isn't set up
async function pushTo(user: unknown, title: string, body: string, data: Record<string, unknown>) {
  if (typeof user !== "string" || !user) return;
  try {
    const r = await fetch(`${env("SUPABASE_URL")}/functions/v1/push`, {
      method: "POST",
      headers: { Authorization: `Bearer ${env("SUPABASE_SERVICE_ROLE_KEY")}`, "Content-Type": "application/json" },
      body: JSON.stringify({ action: "send", user, title, body: body.length > 180 ? body.slice(0, 177) + "…" : body, data }),
    });
    if (!r.ok) console.error(`Push for ${user} answered ${r.status}: ${await r.text()}`);
  } catch (e) { console.error("Couldn't reach the push function:", e); }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "Use POST." }, 405);
  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ error: "Expected JSON." }, 400); }
  const auth = req.headers.get("Authorization") ?? "";
  const userClient = createClient(env("SUPABASE_URL"), env("SUPABASE_ANON_KEY"), { global: { headers: { Authorization: auth } } });
  const { data: who } = await userClient.auth.getUser();
  const me = who?.user;
  if (!me) return json({ error: "Sign in first." }, 401);
  const db = createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"), { auth: { persistSession: false } });

  // ---------- a message from someone using the app ----------
  if (body.action === "submit") {
    const message = str(body.message, 4000), topic = TOPICS[str(body.topic, 20)] ? str(body.topic, 20) : "other";
    if (message.length < 3) return json({ error: "Write a little more so we can help." }, 400);
    const since = new Date(Date.now() - 86400_000).toISOString();
    const { count } = await db.from("support_tickets").select("id", { head: true, count: "exact" }).eq("user_id", me.id).gte("created_at", since);
    if ((count ?? 0) >= 5) return json({ error: "You've sent a few messages today. We'll get back to you on those first." }, 429);
    let diag = body.diag && typeof body.diag === "object" ? body.diag : null;
    if (diag && JSON.stringify(diag).length > 12000) diag = { note: "diagnostics too large, trimmed", build: (diag as Record<string, unknown>).build };
    const meta = (me.user_metadata || {}) as Record<string, string>;
    const name = str(body.name, 120) || meta.full_name || meta.name || "";
    const { data: t, error } = await db.from("support_tickets").insert({ user_id: me.id, email: me.email, name, topic, message, diag }).select("id").single();
    if (error) { console.error("Couldn't save the ticket:", error.message); return json({ error: "Couldn't send your message. Try again in a moment." }, 500); }
    const admin = env("ADMIN_EMAIL");
    if (admin) await send(admin, `Help desk #${t.id}: ${TOPICS[topic]}`, page(
      `<p><b>${esc(name || me.email)}</b> (${esc(me.email)}) wrote:</p>${paras(message)}<p style="color:#888">Answer it in [developer] › Admin › Help.</p>`));
    return json({ ok: true, id: t.id });
  }

  // ---------- reporting another person (App Store guideline 1.2) ----------
  if (body.action === "report") {
    const REASONS: Record<string, string> = { spam: "Spam", harassment: "Harassment or hate", inappropriate: "Inappropriate content", impersonation: "Impersonation", other: "Something else" };
    const reported = str(body.user, 64), reason = REASONS[str(body.reason, 20)] ? str(body.reason, 20) : "other";
    const details = str(body.details, 2000), songId = str(body.song, 200) || null;
    if (!/^[0-9a-f-]{36}$/i.test(reported) || reported === me.id) return json({ error: "That account can't be reported." }, 400);
    const since = new Date(Date.now() - 86400_000).toISOString();
    const { count } = await db.from("user_reports").select("id", { head: true, count: "exact" }).eq("reporter", me.id).gte("created_at", since);
    if ((count ?? 0) >= 10) return json({ error: "You've sent a lot of reports today. We're reviewing them." }, 429);
    const { data: r, error } = await db.from("user_reports").insert({ reporter: me.id, reported, song_id: songId, reason, details: details || null }).select("id").single();
    if (error) { console.error("Couldn't save the report:", error.message); return json({ error: "Couldn't send the report. Try again in a moment." }, 500); }
    const { data: p } = await db.from("profiles").select("username,display_name").eq("user_id", reported).maybeSingle();
    const who = p?.username ? "@" + p.username : (p?.display_name || reported);
    const admin = env("ADMIN_EMAIL");
    if (admin) await send(admin, `Report #${r.id}: ${REASONS[reason]} (${who})`, page(
      `<p><b>${esc(me.email)}</b> reported <b>${esc(who)}</b> (${esc(reported)}) for <b>${esc(REASONS[reason])}</b>.</p>` +
      (songId ? `<p>Song: ${esc(songId)}</p>` : "") + (details ? paras(details) : "<p style=\"color:#888\">No details given.</p>") +
      `<p style="color:#888">Review within 24 hours: remove the content or the account if it breaks the terms.</p>`));
    return json({ ok: true, id: r.id });
  }

  // ---------- admins only from here ----------
  const { data: isAdmin } = await userClient.rpc("is_admin");
  if (isAdmin !== true) return json({ error: "Admins only." }, 403);

  if (body.action === "reply") {
    const id = Number(body.id), text = str(body.text, 6000);
    if (!id || text.length < 2) return json({ error: "Write a reply first." }, 400);
    const { data: t } = await db.from("support_tickets").select("*").eq("id", id).single();
    if (!t) return json({ error: "No such ticket." }, 404);
    const emailed = await send(t.email, `Re: your *[demo] message (#${t.id})`,
      letter({ name: t.name ? String(t.name) : "", text, quote: String(t.message || "").startsWith("(You wrote to them)") ? "" : String(t.message || ""), ticket: t.id }));
    const replies = [...(Array.isArray(t.replies) ? t.replies : []), { at: new Date().toISOString(), by: "admin", text, emailed }];
    const { error } = await db.from("support_tickets").update({ replies, status: "replied", updated_at: new Date().toISOString() }).eq("id", id);
    if (error) return json({ error: "Couldn't save the reply: " + error.message }, 500);
    await pushTo(t.user_id, "*[demo] Support", text, { kind: "support", ticket: t.id });
    return json({ ok: true, emailed, emailReady: !!env("RESEND_API_KEY") });
  }

  if (body.action === "email") {
    const user = str(body.user, 64), subject = str(body.subject, 160) || "A message from *[demo]", text = str(body.text, 6000);
    if (!user || text.length < 2) return json({ error: "Write a message first." }, 400);
    const { data: u } = await db.auth.admin.getUserById(user);
    const to = u?.user?.email;
    if (!to) return json({ error: "That account has no email address." }, 404);
    const meta = (u.user.user_metadata || {}) as Record<string, string>;
    const name = meta.full_name || meta.name || "";
    const emailed = await send(to, subject, letter({ name, text }));
    const { data: t } = await db.from("support_tickets").insert({
      user_id: user, email: to, name, topic: "other", message: `(You wrote to them) ${subject}`, status: "replied",
      replies: [{ at: new Date().toISOString(), by: "admin", text, emailed }],
    }).select("id").single();
    await pushTo(user, subject, text, { kind: "support", ticket: t?.id });
    return json({ ok: true, emailed, id: t?.id, emailReady: !!env("RESEND_API_KEY") });
  }

  return json({ error: "Unknown action." }, 400);
});
