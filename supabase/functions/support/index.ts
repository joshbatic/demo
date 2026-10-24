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
const toText = (html: string) => html.replace(/<br\s*\/?>/gi, "\n").replace(/<\/p>/gi, "\n\n").replace(/<[^>]+>/g, "")
  .replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/\n{3,}/g, "\n\n").trim();
const paras = (t: string) => t.split(/\n{2,}/).map((p) => `<p>${esc(p).replace(/\n/g, "<br>")}</p>`).join("");

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
    const emailed = await send(t.email, `Re: your *[demo] message (#${t.id})`, page(
      `${t.name ? `<p>Hi ${esc(String(t.name).split(/\s+/)[0])},</p>` : ""}${paras(text)}
       <div style="margin-top:24px;padding:12px 14px;border-left:3px solid #ddd;color:#666;font-size:14px">${paras(t.message)}</div>
       <p style="color:#888;font-size:13px">Reply to this email to keep the conversation going.</p>`));
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
    const emailed = await send(to, subject, page(`${name ? `<p>Hi ${esc(name.split(/\s+/)[0])},</p>` : ""}${paras(text)}
      <p style="color:#888;font-size:13px">Reply to this email to answer.</p>`));
    const { data: t } = await db.from("support_tickets").insert({
      user_id: user, email: to, name, topic: "other", message: `(You wrote to them) ${subject}`, status: "replied",
      replies: [{ at: new Date().toISOString(), by: "admin", text, emailed }],
    }).select("id").single();
    await pushTo(user, subject, text, { kind: "support", ticket: t?.id });
    return json({ ok: true, emailed, id: t?.id, emailReady: !!env("RESEND_API_KEY") });
  }

  return json({ error: "Unknown action." }, 400);
});
