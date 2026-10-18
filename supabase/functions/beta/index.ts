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

// tolerant of the usual paste slips: spaces, quotes around the value, or a "Bearer " prefix
const env = (k: string) => (Deno.env.get(k) || "").trim().replace(/^["'`]|["'`]$/g, "").replace(/^Bearer\s+/i, "").trim();
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

// ---------- emails, styled like the app ----------
// Built with tables and inline styles so they hold up in Gmail, Outlook and Apple Mail. A pastel cover gradient
// with "lyric lines" (like a song's default cover) heads each one; Apple Mail also gets a dark version.
const ICON = "https://hellodemo.app/icon-192.png";
const COVERS: Record<string, [string, string, string]> = {
  lavender: ["#D7C4FF", "#9CC8FF", "#B9B3FF"],
  sunrise:  ["#FFD3BE", "#E3CCFF", "#BFDDFF"],
  mint:     ["#BFF0D4", "#7FCCDB", "#9FE0D2"],
  amber:    ["#FFE9A8", "#FFAA7F", "#FFC994"],
};
// darker washes for dark mode (Apple Mail), the same pairs the website uses
const DARK: Record<string, [string, string]> = {
  lavender: ["#4E3F7A", "#2F4E72"], sunrise: ["#6B4A5E", "#2F4E72"], mint: ["#2E5A4C", "#245560"], amber: ["#6A5A30", "#6E4430"],
};
// "*[demo]" never breaks across a line
const nb = (t: string) => t.replace(/\*\[demo\]/g, '<span style="white-space:nowrap">*[demo]</span>');
const FONT = "-apple-system,BlinkMacSystemFont,'SF Pro Text','Segoe UI',Helvetica,Arial,sans-serif";

function mail(o: { preheader: string; cover: keyof typeof COVERS; title: string; body: string; foot?: string }) {
  const [c1, c2, mid] = COVERS[o.cover];
  // the cover's "lyric lines": white bars of different lengths, like a song without artwork
  const bars = [62, 44, 70, 0, 52, 36].map((w) => w
    ? `<div style="height:5px;width:${w}%;background:#ffffff;opacity:.85;border-radius:3px;margin:0 0 9px;font-size:0;line-height:0">&nbsp;</div>`
    : `<div style="height:8px;font-size:0;line-height:0">&nbsp;</div>`).join("");
  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light dark"><meta name="supported-color-schemes" content="light dark">
<title>${esc(o.title)}</title>
<style>
  body{margin:0;padding:0;-webkit-text-size-adjust:100%}
  a{color:inherit}
  @media (max-width:520px){ .pad{padding-left:22px!important;padding-right:22px!important} .h1{font-size:26px!important} }
  @media (prefers-color-scheme:dark){
    .bg{background:#000000!important} .card{background:#1C1C1E!important} .ink{color:#FFFFFF!important}
    .body{color:#EBEBF5!important} .mute{color:#8E8E93!important} .tile{background:#2C2C2E!important}
    .rule{border-color:#38383A!important} .btn{background:#FFFFFF!important} .btn a{color:#000000!important}
    .lnk{color:#C9B8FF!important}
    .cover-${o.cover}{background-image:linear-gradient(140deg,${DARK[o.cover][0]},${DARK[o.cover][1]})!important;background-color:${DARK[o.cover][1]}!important}
    .bars div{opacity:.5!important}
  }
</style></head>
<body class="bg" style="margin:0;padding:0;background:#F2F2F7">
<div style="display:none;max-height:0;overflow:hidden;opacity:0;color:transparent">${esc(o.preheader)}&#8199;&#847;&#8199;&#847;&#8199;&#847;&#8199;&#847;&#8199;&#847;</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" class="bg" style="background:#F2F2F7">
<tr><td align="center" style="padding:28px 12px 36px">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:520px">
    <tr><td style="padding:0 6px 16px">
      <table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr>
        <td style="padding-right:10px"><img src="${ICON}" width="36" height="36" alt="" style="display:block;border:0;border-radius:9px"></td>
        <td class="ink" style="font:800 18px/1 ${FONT};color:#000000;letter-spacing:-.2px">*[demo]</td>
      </tr></table>
    </td></tr>
    <tr><td class="card" style="background:#FFFFFF;border-radius:24px;overflow:hidden">
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">
        <tr><td bgcolor="${mid}" class="cover-${o.cover}" style="background-color:${mid};background-image:linear-gradient(140deg,${c1},${c2});border-radius:24px 24px 0 0;padding:30px 30px 22px" class="pad">
          <table role="presentation" width="62%" cellpadding="0" cellspacing="0" border="0"><tr><td class="bars">${bars}</td></tr></table>
        </td></tr>
        <tr><td class="pad" style="padding:30px 32px 32px">
          <h1 class="ink h1" style="margin:0 0 14px;font:800 28px/1.15 ${FONT};color:#000000;letter-spacing:-.5px">${esc(o.title)}</h1>
          ${o.body}
        </td></tr>
      </table>
    </td></tr>
    <tr><td class="mute" style="padding:20px 18px 0;text-align:center;font:400 12.5px/1.5 ${FONT};color:#8E8E93">
      ${nb(o.foot ?? "You're getting this because you asked to join the *[demo] beta.")}<br>
      <a href="https://hellodemo.app" style="color:#8E8E93;text-decoration:none">hellodemo.app</a> &nbsp;·&nbsp;
      <a href="https://hellodemo.app/privacy.html" style="color:#8E8E93;text-decoration:none">Privacy</a> &nbsp;·&nbsp;
      <a href="mailto:help@hellodemo.app" style="color:#8E8E93;text-decoration:none">help@hellodemo.app</a>
    </td></tr>
  </table>
</td></tr></table>
</body></html>`;
}
const p = (t: string) => `<p class="body" style="margin:0 0 16px;font:400 16px/1.55 ${FONT};color:#3A3A3C">${nb(t)}</p>`;
const small = (t: string) => `<p class="mute" style="margin:18px 0 0;font:400 14px/1.5 ${FONT};color:#8E8E93">${nb(t)}</p>`;
const button = (href: string, label: string) => `<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:8px 0 22px"><tr>
  <td class="btn" bgcolor="#1C1C1E" style="background:#1C1C1E;border-radius:999px"><a href="${esc(href)}" style="display:inline-block;padding:15px 30px;font:700 16px/1 ${FONT};color:#FFFFFF;text-decoration:none;border-radius:999px">${esc(label)}</a></td></tr></table>`;
// an inset grouped list, like a Settings section, with a numbered gradient badge on each row
function steps(rows: string[], cover: keyof typeof COVERS) {
  const [c1, c2, mid] = COVERS[cover];
  return `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" class="tile" style="background:#F2F2F7;border-radius:16px;margin:4px 0 22px">` +
    rows.map((r, i) => `<tr><td style="padding:${i ? "0" : "4px"} 16px ${i === rows.length - 1 ? "4px" : "0"}"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"${i ? ` class="rule" style="border-top:.5px solid #D1D1D6"` : ""}><tr>
      <td width="38" valign="top" style="padding:14px 0"><div bgcolor="${mid}" style="width:26px;height:26px;border-radius:13px;background-color:${mid};background-image:linear-gradient(140deg,${c1},${c2});color:#2B2140;font:800 13.5px/26px ${FONT};text-align:center">${i + 1}</div></td>
      <td class="body" style="padding:15px 0;font:400 15.5px/1.45 ${FONT};color:#1C1C1E">${nb(r)}</td></tr></table></td></tr>`).join("") + `</table>`;
}
const codeTile = (code: string) => `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" class="tile" style="background:#F2F2F7;border-radius:16px;margin:0 0 6px"><tr><td align="center" style="padding:18px 12px 16px">
  <div class="mute" style="font:600 12px/1 ${FONT};color:#8E8E93;letter-spacing:.4px;margin-bottom:10px">YOUR INVITE CODE</div>
  <div class="ink" style="font:700 28px/1 ui-monospace,'SF Mono',Menlo,Consolas,monospace;color:#000000;letter-spacing:5px">${esc(code)}</div></td></tr></table>`;
const detail = (k: string, v: string) => v ? `<tr><td class="mute" width="96" valign="top" style="padding:7px 0;font:400 14px/1.45 ${FONT};color:#8E8E93">${k}</td><td class="body" style="padding:7px 0;font:400 15px/1.45 ${FONT};color:#1C1C1E">${v}</td></tr>` : "";

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
      await send(email, "You're on the list for *[demo]", mail({
        preheader: "Thanks for asking to try *[demo]. We'll email you when there's a spot.",
        cover: "lavender", title: "You're on the list",
        body: p(`Hi ${first}, thanks for asking to try *[demo]. We're letting songwriters in a few at a time, so everyone gets a good first run.`) +
          p("When there's a spot for you, we'll send you a link to install the beta with TestFlight, and your own invite code.") +
          small("Nothing else to do for now. Questions? Just reply."),
      }));
      const admin = env("ADMIN_EMAIL");
      const lk = str(body.link, 300);
      if (admin) await send(admin, `New beta request: ${name || email}`, mail({
        preheader: `${name || email} asked to join the beta.`,
        cover: "amber", title: "New beta request", foot: "Sent to you as the *[demo] beta admin.",
        body: `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="margin:0 0 18px">` +
          detail("Name", esc(name)) + detail("Email", esc(email)) + detail("They are", esc(str(body.role, 60))) +
          detail("Heard from", esc(str(body.heard, 200))) +
          detail("Music", /^https?:\/\//i.test(lk) ? `<a class="lnk" href="${esc(lk)}" style="color:#5B3FD6">${esc(lk)}</a>` : esc(lk)) +
          detail("Note", esc(str(body.note, 1000)).replace(/\n/g, "<br>")) + `</table>` +
          small("Approve or decline it in the app: Account › Beta Requests."),
      }));
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
      emailed = await send(r.email, "You're in: welcome to the *[demo] beta", mail({
        preheader: "There's a spot for you. Install *[demo] with TestFlight and start writing.",
        cover: "sunrise", title: "You're in",
        body: p(`Hi ${first}, there's a spot for you in the *[demo] beta. We can't wait to hear what you write.`) +
          (tf ? button(tf, "Install with TestFlight") : small("Your TestFlight link is on its way in a separate email.")) +
          steps([
            "Tap the button above on your <b>iPhone</b>. It installs TestFlight first, then *[demo].",
            "Sign in with <b>Apple</b> or <b>Google</b>. Use this email address and you're straight in.",
            "Used a different email, or <b>Hide My Email</b>? Enter your invite code when *[demo] asks.",
          ], "sunrise") +
          (shown ? codeTile(shown) : "") +
          small("Found something confusing, slow or broken? Take a screenshot in *[demo] to send it through TestFlight, or just reply to this email."),
        foot: "You're getting this because you asked to join the *[demo] beta.",
      }));
    } else {
      emailed = await send(r.email, "About your *[demo] beta request", mail({
        preheader: "Thanks for asking to try *[demo]. We'll be in touch when it opens up.",
        cover: "mint", title: "Not this round",
        body: p(`Hi ${first}, thanks for asking to try *[demo]. We're keeping this round of the beta small, so we can't add you just yet.`) +
          p("We'll let you know as soon as *[demo] opens up more widely. Thanks for your patience, and keep writing."),
      }));
    }
    if (emailed) await sb.rpc("beta_admin_mark_emailed", { p_id: id });
    return json({ ok: true, status: r.status, code: r.code, email: r.email, emailed, emailReady: !!env("RESEND_API_KEY") });
  }

  return json({ error: "Unknown action." }, 400);
});
