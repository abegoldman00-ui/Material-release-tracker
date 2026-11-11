// ULETrack — "notify" Edge Function (Supabase)
// Sends release updates, new-request alerts and the Friday summary via Resend.
// Called only by the database (stage5-notifications.sql) with a shared secret.
//
// Secrets to set in Supabase → Edge Functions → Secrets:
//   RESEND_API_KEY   (required)
//   NOTIFY_FROM      (optional, default "ULETrack <notify@uletrack.com>")
//   SITE_URL         (optional, default "https://uletrack.com")
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided by Supabase automatically.

const SB = Deno.env.get("SUPABASE_URL")!;
const KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const RESEND_KEY = Deno.env.get("RESEND_API_KEY") ?? "";
const RESEND_URL = Deno.env.get("RESEND_URL") ?? "https://api.resend.com";
const FROM = Deno.env.get("NOTIFY_FROM") ?? "ULETrack <notify@uletrack.com>";
const SITE = (Deno.env.get("SITE_URL") ?? "https://uletrack.com").replace(/\/$/, "");
const NOW = () => { const v = Deno.env.get("NOTIFY_NOW"); return v ? new Date(v) : new Date(); };

// ── Database (service role: bypasses row security; this code runs server-side only) ──
async function db(path: string, init: RequestInit = {}) {
  const r = await fetch(`${SB}/rest/v1/${path}`, {
    ...init,
    headers: { apikey: KEY, Authorization: `Bearer ${KEY}`, "Content-Type": "application/json", Prefer: "return=representation", ...(init.headers ?? {}) },
  });
  if (!r.ok) throw new Error(`DB ${r.status} ${path}: ${await r.text()}`);
  const t = await r.text();
  return t ? JSON.parse(t) : null;
}
const inList = (xs: (string | number)[]) => `(${xs.map((x) => `"${String(x).replace(/"/g, '\\"')}"`).join(",")})`;
const enc = encodeURIComponent;

// ── Helpers ──
type U = { id: string; username: string; role: string; email?: string; company?: string; notify_pref?: string; notify_requests?: boolean; rep_name?: string; rep_phone?: string; rep_email?: string };
const esc = (s: unknown) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
const n = (x: unknown) => (parseInt(String(x)) || 0).toLocaleString("en-US");
const fmtDate = (d?: string | null) => {
  if (!d) return "";
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(d);
  return m ? new Date(Date.UTC(+m[1], +m[2] - 1, +m[3])).toLocaleDateString("en-US", { month: "short", day: "numeric", timeZone: "UTC" }) : d;
};
const validEmail = (e?: string | null) => !!e && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(e.trim());
function uniqEmails(list: (string | null | undefined)[]) {
  const seen = new Set<string>(); const out: string[] = [];
  for (const e of list) { if (!validEmail(e)) continue; const k = e!.trim().toLowerCase(); if (!seen.has(k)) { seen.add(k); out.push(e!.trim()); } }
  return out;
}

// Customer logins on a job who want emails (prefs: all | weekly | off)
async function customerRecipients(jobId: string, prefs: string[]): Promise<U[]> {
  const asn = await db(`job_assignments?job_id=eq.${enc(jobId)}&select=user_id`);
  const ids = asn.map((a: { user_id: string }) => a.user_id);
  if (!ids.length) return [];
  const us: U[] = await db(`users?id=in.${enc(inList(ids))}&role=eq.customer&select=id,username,email,company,notify_pref,rep_name,rep_phone,rep_email`);
  return us.filter((u) => validEmail(u.email) && prefs.includes(u.notify_pref ?? "all"));
}

async function jobProgress(jobId: string) {
  const items = await db(`job_items?job_id=eq.${enc(jobId)}&select=item_name,total_qty,co_type`);
  const rels = await db(`releases?job_id=eq.${enc(jobId)}&select=item_id,qty`);
  const releasable = new Set(items.filter((i: any) => i.co_type !== "deduct").map((i: any) => i.item_name));
  const total = items.reduce((s: number, i: any) => s + (i.co_type === "deduct" ? -1 : 1) * (parseInt(i.total_qty) || 0), 0);
  const released = rels.filter((r: any) => releasable.has(r.item_id)).reduce((s: number, r: any) => s + (parseInt(r.qty) || 0), 0);
  return { total, released, pct: total > 0 ? Math.round((released / total) * 100) : 0 };
}

// ── Email layout ──
function meter(pct: number) {
  const p = Math.max(0, Math.min(100, pct));
  return `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;margin:6px 0 2px"><tr>
    <td style="height:10px;width:${p}%;background:#f5b301;border-radius:3px 0 0 3px;font-size:0;line-height:0">&nbsp;</td>
    <td style="height:10px;width:${100 - p}%;background:#e5eaf1;border-radius:0 3px 3px 0;font-size:0;line-height:0">&nbsp;</td></tr></table>`;
}
function layout(opts: { preheader: string; heading: string; sub?: string; body: string; cta?: { label: string; url: string }; footerNote?: string }) {
  return `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${esc(opts.heading)}</title></head>
<body style="margin:0;padding:0;background:#f3f5f8;font-family:Arial,Helvetica,sans-serif;color:#13203a">
<span style="display:none!important;opacity:0;color:transparent;max-height:0;overflow:hidden">${esc(opts.preheader)}</span>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f3f5f8;padding:24px 12px"><tr><td align="center">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:600px;background:#ffffff;border-radius:14px;overflow:hidden;border:1px solid #e2e7ee">
  <tr><td style="background:#0f2240;padding:18px 24px">
    <img src="${SITE}/logo-email.png" width="84" alt="ULE Group" style="display:inline-block;vertical-align:middle;background:#fff;border-radius:8px;padding:5px 7px">
    <span style="color:#fff;font-size:16px;font-weight:bold;vertical-align:middle;margin-left:10px">ULETrack</span>
  </td></tr>
  <tr><td style="height:4px;background:#f5b301;font-size:0;line-height:0">&nbsp;</td></tr>
  <tr><td style="padding:26px 24px 8px">
    <div style="font-size:21px;font-weight:bold;line-height:1.25;color:#13203a">${esc(opts.heading)}</div>
    ${opts.sub ? `<div style="font-size:14px;color:#4a5871;margin-top:6px">${opts.sub}</div>` : ""}
  </td></tr>
  <tr><td style="padding:10px 24px 8px;font-size:14px;line-height:1.5">${opts.body}</td></tr>
  ${opts.cta ? `<tr><td style="padding:14px 24px 26px"><a href="${opts.cta.url}" style="display:inline-block;background:#1c56a5;color:#ffffff;text-decoration:none;font-weight:bold;font-size:14px;padding:12px 20px;border-radius:10px">${esc(opts.cta.label)}</a></td></tr>` : ""}
  <tr><td style="padding:16px 24px 22px;border-top:1px solid #e2e7ee;font-size:12px;color:#7f8ca2;line-height:1.5">
    ${opts.footerNote ? opts.footerNote + "<br>" : ""}
    ULE Group · Powered by Partnerships · <a href="${SITE}/?settings=email" style="color:#7f8ca2">Email settings</a>
  </td></tr>
</table></td></tr></table></body></html>`;
}
const itemTable = (rows: string[][], heads: string[]) => `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;font-size:13px;margin-top:6px">
  <tr>${heads.map((h, i) => `<td style="padding:7px 6px;border-bottom:2px solid #13203a;font-weight:bold;${i ? "text-align:right" : ""}">${esc(h)}</td>`).join("")}</tr>
  ${rows.map((r) => `<tr>${r.map((c, i) => `<td style="padding:7px 6px;border-bottom:1px solid #e2e7ee;${i ? "text-align:right;white-space:nowrap" : ""}">${c}</td>`).join("")}</tr>`).join("")}</table>`;
const repLine = (u?: U) => u && (u.rep_name || u.rep_email || u.rep_phone)
  ? `Questions? Your ULE Group rep: <b>${esc(u.rep_name ?? "")}</b>${u.rep_phone ? ` · ${esc(u.rep_phone)}` : ""}${u.rep_email ? ` · <a href="mailto:${esc(u.rep_email)}" style="color:#1c56a5">${esc(u.rep_email)}</a>` : ""}` : "";

// ── Resend ──
type Mail = { to: string[]; subject: string; html: string; reply_to?: string };
async function sendAll(mails: Mail[]) {
  const results: string[] = [];
  for (let i = 0; i < mails.length; i += 100) {
    const batch = mails.slice(i, i + 100).map((m) => ({ from: FROM, to: m.to, subject: m.subject, html: m.html, ...(m.reply_to ? { reply_to: m.reply_to } : {}) }));
    const r = await fetch(`${RESEND_URL}/emails/batch`, { method: "POST", headers: { Authorization: `Bearer ${RESEND_KEY}`, "Content-Type": "application/json" }, body: JSON.stringify(batch) });
    const t = await r.text();
    if (!r.ok) throw new Error(`Resend ${r.status}: ${t}`);
    results.push(`sent ${batch.length}`);
  }
  return results.join(", ") || "nothing to send";
}

// ── Builders ──
async function buildReleaseMails(jobId: string, rowIds: string[], delivered: boolean): Promise<Mail[]> {
  const [job] = await db(`jobs?id=eq.${enc(jobId)}&select=id,name,customer`);
  if (!job) return [];
  const rels = await db(`releases?id=in.${enc(inList(rowIds))}&select=item_id,qty,status,release_name,release_date,requested_by_name`);
  if (!rels.length) return [];
  const recips = await customerRecipients(jobId, ["all"]);
  if (!recips.length) return [];
  const prog = await jobProgress(jobId);
  const name = rels.find((r: any) => r.release_name)?.release_name;
  const units = rels.reduce((s: number, r: any) => s + (parseInt(r.qty) || 0), 0);
  const what = name ? name : `${rels.length} item${rels.length === 1 ? "" : "s"}`;
  const heading = delivered ? `${what} was delivered` : `${what} was released`;
  const reqBy = rels.find((r: any) => r.requested_by_name)?.requested_by_name;
  const body = `<div>${rels.length} item${rels.length === 1 ? "" : "s"} · ${n(units)} units${reqBy ? ` · requested by ${esc(reqBy)}` : ""}</div>
    ${itemTable(rels.slice(0, 25).map((r: any) => [esc(r.item_id), n(r.qty)]), ["Item", "Qty"])}
    ${rels.length > 25 ? `<div style="color:#7f8ca2;font-size:12px;margin-top:6px">+ ${rels.length - 25} more in ULETrack</div>` : ""}
    <div style="margin-top:20px;font-weight:bold">${esc(job.name)} is ${prog.pct}% released</div>${meter(prog.pct)}
    <div style="font-size:12px;color:#7f8ca2">${n(prog.released)} of ${n(prog.total)} units</div>`;
  return recips.map((u) => ({
    to: [u.email!],
    subject: `${job.name}: ${heading}`,
    reply_to: validEmail(u.rep_email) ? u.rep_email : undefined,
    html: layout({ preheader: `${what} · ${n(units)} units · ${job.name}`, heading, sub: `${esc(job.name)}${job.customer ? ` · ${esc(job.customer)}` : ""}`, body,
      cta: { label: "View in ULETrack", url: `${SITE}/?job=${enc(jobId)}` }, footerNote: repLine(u) }),
  }));
}

async function buildRequestMails(group: string): Promise<Mail[]> {
  const lines = await db(`release_requests?request_group=eq.${enc(group)}&select=*`);
  if (!lines.length) return [];
  const r0 = lines[0];
  const [job] = await db(`jobs?id=eq.${enc(r0.job_id)}&select=id,name,customer`);
  const requester: U | undefined = r0.requested_by ? (await db(`users?id=eq.${enc(r0.requested_by)}&select=id,username,company,rep_name,rep_email`))[0] : undefined;
  const staff: U[] = await db(`users?role=neq.customer&select=id,username,email,role,notify_requests`);
  let to = uniqEmails([requester?.rep_email, ...staff.filter((s) => s.notify_requests).map((s) => s.email)]);
  if (!to.length) to = uniqEmails(staff.filter((s) => s.role === "admin").map((s) => s.email)); // nobody set up yet → admins
  if (!to.length) return [];
  const who = r0.requester_name || r0.requested_by_username || "A customer";
  const company = r0.company || job?.customer || "";
  const units = lines.reduce((s: number, l: any) => s + (parseInt(l.qty) || 0), 0);
  const contact = [r0.requester_phone, r0.requester_email].filter(Boolean).map(esc).join(" · ");
  const body = `<div><b>${esc(who)}</b>${company ? ` at ${esc(company)}` : ""} requested ${lines.length} item${lines.length === 1 ? "" : "s"} (${n(units)} units).</div>
    ${contact ? `<div style="color:#4a5871;margin-top:2px">${contact}</div>` : ""}
    ${itemTable(lines.map((l: any) => [esc(l.item_id), n(l.qty)]), ["Item", "Qty"])}
    <div style="margin-top:14px">${r0.release_name ? `Release name: <b>${esc(r0.release_name)}</b><br>` : ""}${r0.needed_by ? `Needed on site by: <b>${fmtDate(r0.needed_by)}</b><br>` : ""}${r0.note ? `Note: “${esc(r0.note)}”` : ""}</div>`;
  return [{
    to, subject: `New release request: ${job?.name ?? r0.job_id}${company ? ` (${company})` : ""}`,
    reply_to: validEmail(r0.requester_email) ? r0.requester_email : undefined,
    html: layout({ preheader: `${who} requested ${lines.length} item(s) on ${job?.name ?? ""}`, heading: `New release request`, sub: `${esc(job?.name ?? r0.job_id)}${company ? ` · ${esc(company)}` : ""}`,
      body, cta: { label: "Open requests", url: `${SITE}/?job=${enc(r0.job_id)}&requests=1` } }),
  }];
}

async function buildWeekly(): Promise<Mail[]> {
  const since = new Date(NOW().getTime() - 7 * 86400000).toISOString().slice(0, 10);
  const users: U[] = await db(`users?role=eq.customer&notify_pref=in.(all,weekly)&select=id,username,email,company,rep_name,rep_phone,rep_email`);
  const mails: Mail[] = [];
  for (const u of users.filter((x) => validEmail(x.email))) {
    const asn = await db(`job_assignments?user_id=eq.${enc(u.id)}&select=job_id`);
    if (!asn.length) continue;
    const jobs = await db(`jobs?id=in.${enc(inList(asn.map((a: any) => a.job_id)))}&select=id,name,customer&order=name.asc`);
    const sections: string[] = [];
    for (const job of jobs) {
      const week = await db(`releases?job_id=eq.${enc(job.id)}&release_date=gte.${since}&select=item_id,qty,release_name,bulk_id,release_date&order=release_date.desc`);
      const open = await db(`release_requests?job_id=eq.${enc(job.id)}&status=eq.open&select=request_group`);
      if (!week.length && !open.length) continue; // quiet job → leave it out
      const prog = await jobProgress(job.id);
      const groups = new Map<string, { name: string; units: number; items: number; date: string }>();
      for (const r of week) {
        const k = r.release_name || r.bulk_id || `${r.item_id}|${r.release_date}`;
        const g = groups.get(k) ?? { name: r.release_name || (r.bulk_id ? "Bulk release" : r.item_id), units: 0, items: 0, date: r.release_date };
        g.units += parseInt(r.qty) || 0; g.items++; groups.set(k, g);
      }
      const openN = new Set(open.map((o: any) => o.request_group)).size;
      sections.push(`<div style="margin:18px 0 6px;font-size:16px;font-weight:bold">${esc(job.name)}</div>
        <div style="font-size:13px;color:#4a5871">${prog.pct}% released · ${n(prog.released)} of ${n(prog.total)} units${openN ? ` · ${openN} open request${openN === 1 ? "" : "s"}` : ""}</div>${meter(prog.pct)}
        ${groups.size ? itemTable([...groups.values()].map((g) => [`${esc(g.name)} <span style="color:#7f8ca2">· ${fmtDate(g.date)}</span>`, `${g.items} item${g.items === 1 ? "" : "s"}`, n(g.units)]), ["Released this week", "Items", "Units"])
          : `<div style="font-size:13px;color:#7f8ca2;margin-top:6px">No releases this week.</div>`}
        <div style="margin-top:8px"><a href="${SITE}/?job=${enc(job.id)}" style="color:#1c56a5;font-size:13px">Open ${esc(job.name)}</a></div>`);
    }
    if (!sections.length) continue;
    mails.push({
      to: [u.email!], subject: `Your weekly ULETrack summary`,
      reply_to: validEmail(u.rep_email) ? u.rep_email : undefined,
      html: layout({ preheader: `This week's releases on your jobs`, heading: "Your week in releases", sub: `Week ending ${NOW().toLocaleDateString("en-US", { month: "long", day: "numeric", timeZone: "America/New_York" })}`,
        body: sections.join(""), cta: { label: "Open ULETrack", url: SITE }, footerNote: repLine(u) }),
    });
  }
  return mails;
}

// ── Handlers ──
async function runOutbox() {
  const cutoff = new Date(NOW().getTime() - 45000).toISOString();
  const rows = await db(`notify_outbox?sent_at=is.null&created_at=lt.${enc(cutoff)}&order=id.asc&limit=1000`);
  const groups = new Map<string, any[]>();
  for (const r of rows) { const k = `${r.kind}|${r.job_id}|${r.ref}`; (groups.get(k) ?? groups.set(k, []).get(k)!).push(r); }
  const report: string[] = [];
  for (const [k, list] of groups) {
    const [kind, jobId] = k.split("|");
    let result: string, done = true;
    const attempts = Math.max(...list.map((r) => r.attempts ?? 0)) + 1;
    try {
      const mails = kind === "request" ? await buildRequestMails(list[0].ref)
        : await buildReleaseMails(jobId, list.map((r) => r.row_id), kind === "release_status");
      result = mails.length ? await sendAll(mails) : "no recipients";
    } catch (e) {
      result = `error (try ${attempts}): ${(e as Error).message}`.slice(0, 500);
      done = attempts >= 5; // retry on the next runs, give up after 5 tries
    }
    await db(`notify_outbox?id=in.${enc(inList(list.map((r) => r.id)))}`, { method: "PATCH",
      body: JSON.stringify({ sent_at: done ? NOW().toISOString() : null, result, attempts }) });
    report.push(`${k}: ${result}`);
  }
  return report;
}

Deno.serve(async (req) => {
  try {
    const [cfg] = await db(`notify_config?key=eq.secret&select=value`);
    if (!cfg || req.headers.get("x-notify-secret") !== cfg.value) return new Response("forbidden", { status: 403 });
    const body = await req.json().catch(() => ({}));
    let out: unknown;
    if (body.mode === "outbox") out = await runOutbox();
    else if (body.mode === "weekly") { const m = await buildWeekly(); out = m.length ? await sendAll(m) : "nothing to send"; }
    else if (body.mode === "test") {
      if (!validEmail(body.to)) return new Response("bad address", { status: 400 });
      out = await sendAll([{ to: [body.to], subject: "ULETrack test email", html: layout({ preheader: "Email notifications are working", heading: "Email notifications are working", body: "This is a test from ULETrack. Release updates, request alerts and the Friday summary will look like this.", cta: { label: "Open ULETrack", url: SITE } }) }]);
    } else return new Response("unknown mode", { status: 400 });
    return new Response(JSON.stringify({ ok: true, out }), { headers: { "Content-Type": "application/json" } });
  } catch (e) {
    console.error(e);
    return new Response(JSON.stringify({ ok: false, error: (e as Error).message }), { status: 500, headers: { "Content-Type": "application/json" } });
  }
});
