// Supabase Edge Function: intake
// Turns website form submissions and forwarded emails into requests in the app.
// Deploy with "Verify JWT" OFF. Two ways in:
//   1) Website forms (Netlify, Jotform, Zapier…):  POST .../functions/v1/intake?k=SHOPKEY   (JSON or form data)
//   2) Forwarded email (Resend receiving):         POST .../functions/v1/intake?src=resend  (Resend "email.received" webhook)
//      Each shop forwards to r-SHOPKEY@<receiving domain>. Needs secrets RESEND_API_KEY and RESEND_WEBHOOK_SECRET.
// Requests with no usable phone or email (spam calls, "Not provided") and blocked numbers go to the shop's Filtered list
// with no notification.
import webpush from "npm:web-push@3.6.7";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";
import Stripe from "https://esm.sh/stripe@14.25.0?target=deno";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY") || "", { apiVersion: "2024-06-20", httpClient: Stripe.createFetchHttpClient() });
const FEE_BPS = Math.max(0, Math.min(500, Number(Deno.env.get("PLATFORM_FEE_BPS") || 0)));   // optional app fee per card payment, in 1/100 of a percent
const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info", "Access-Control-Allow-Methods": "GET, POST, OPTIONS" };
const out = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...CORS, "Content-Type": "application/json" } });
const clip = (s: unknown, n: number) => String(s ?? "").slice(0, n);
const EMPTY = /^\s*(not provided|n\/?a|none( reported| given)?|unknown|no(t)? (given|available)|-+|\.+)?\s*$/i;

// ---------- turning a submission or an email into plain "Label: value" text ----------
function fromForm(body: Record<string, unknown>): string {
  const lines: string[] = [];
  const skip = /^(ip|user_agent|referrer|form-name|form_name|bot-field|g-recaptcha-response|_.*)$/i;
  const add = (k: string, v: unknown) => {
    if (v == null || typeof v === "object") return;
    const label = String(k).replace(/\s*\*\s*$/, "").replace(/[_-]+/g, " ").trim();
    if (!label || skip.test(k)) return;
    lines.push(`${label}: ${String(v).trim()}`);
  };
  const ohf = body.ordered_human_fields;
  if (Array.isArray(ohf) && ohf.length) ohf.forEach((f: Record<string, unknown>) => add(String(f.title || f.name || ""), f.value));
  else if (body.human_fields && typeof body.human_fields === "object") Object.entries(body.human_fields as Record<string, unknown>).forEach(([k, v]) => add(k, v));
  else if (body.data && typeof body.data === "object") Object.entries(body.data as Record<string, unknown>).forEach(([k, v]) => add(k, v));
  else Object.entries(body).forEach(([k, v]) => add(k, v));
  return lines.join("\n");
}
function htmlToText(h: string): string {
  return h.replace(/<(style|script)[\s\S]*?<\/\1>/gi, "").replace(/<br\s*\/?>/gi, "\n").replace(/<\/(p|div|tr|li|h\d|table)>/gi, "\n")
    .replace(/<\/t[dh]>/gi, "\t").replace(/<[^>]+>/g, "").replace(/&nbsp;/g, " ").replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">")
    .replace(/&#39;|&apos;/g, "'").replace(/&quot;/g, '"').replace(/[ \t]+\n/g, "\n").replace(/\n{3,}/g, "\n\n").trim();
}
// drop "---------- Forwarded message ---------" header blocks and quoted reply junk
function cleanEmail(t: string): string {
  return t.replace(/\r/g, "").replace(/-{5,}\s*Forwarded message\s*-{5,}\n(?:(?:From|Date|Sent|Subject|To|Cc):.*\n)+/gi, "")
    .replace(/^Begin forwarded message:\n(?:(?:From|Date|Sent|Subject|To|Cc|Reply-To):.*\n)+/gim, "").trim();
}

// ---------- spam check ----------
function contactOf(text: string, own: string[]) {
  const lines = text.split("\n");
  const val = (re: RegExp) => { for (let i = 0; i < lines.length; i++) { const m = lines[i].match(/^\s*([^:]{1,40}):\s*(.*)$/); if (m && re.test(m[1])) { let v = m[2].trim(); if (!v && lines[i + 1]) v = lines[i + 1].trim(); return v; } } return ""; };
  const phoneField = val(/phone|cell|mobile|tel/i);
  const phones = (EMPTY.test(phoneField) ? "" : phoneField || text).match(/(?:\+?1[\s.-]?)?\(?\d{3}\)?[\s.-]?\d{3}[\s.-]?\d{4}/g) || [];
  const digits = phones.map((p) => p.replace(/\D/g, "").replace(/^1(?=\d{10}$)/, "")).filter((d) => d.length === 10 && !own.includes(d));
  const emailField = val(/e-?mail/i);
  const emails = ((EMPTY.test(emailField) ? "" : emailField) || "").match(/[\w.+-]+@[\w-]+\.[\w.-]+/g) || [];
  return { phone: digits[0] || "", email: emails[0] || "" };
}

async function shopFor(key: string) {
  if (!/^[a-z0-9]{8,32}$/i.test(key)) return null;
  const { data } = await db.from("intake_keys").select("shop_id").eq("key", key.toLowerCase()).maybeSingle();
  return data?.shop_id as string | undefined || null;
}

async function notifyManagers(shop: string, title: string, body: string, url = "./?view=requests", tag = "request") {
  try {
    const { data: k } = await db.from("push_keys").select("public_key, private_key").eq("id", 1).maybeSingle();
    if (!k) return;
    const { data: members } = await db.from("shop_members").select("user_id, role").eq("shop_id", shop);
    const ids = (members || []).filter((m) => m.role === "owner" || m.role === "admin").map((m) => m.user_id);
    if (!ids.length) return;
    webpush.setVapidDetails("mailto:info@honestechservice.com", k.public_key, k.private_key);
    const { data: subs } = await db.from("push_subs").select("endpoint, p256dh, auth").in("user_id", ids);
    const payload = JSON.stringify({ title: clip(title, 80), body: clip(body, 240), url, tag });
    await Promise.all((subs || []).map(async (s) => {
      try { await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload, { TTL: 86400, urgency: "high" }); }
      catch (e) { const c = (e as { statusCode?: number }).statusCode; if (c === 404 || c === 410) await db.from("push_subs").delete().eq("endpoint", s.endpoint); }
    }));
  } catch (e) { console.error("notify failed", e); }
}

async function save(shop: string, raw: string, source: string, extra: Record<string, unknown> = {}) {
  raw = clip(raw, 20000);
  // flood guard: at most 60 automatic requests per shop per hour
  const since = new Date(Date.now() - 3600_000).toISOString();
  const { count } = await db.from("records").select("id", { count: "exact", head: true }).eq("shop_id", shop).eq("kind", "request").like("id", "in%").gt("updated_at", since);
  if ((count || 0) >= 60) return { ok: false, reason: "too many" };
  const { data: st } = await db.from("records").select("data").eq("shop_id", shop).eq("kind", "settings").eq("id", "main").maybeSingle();
  const s = (st?.data || {}) as Record<string, unknown>;
  const own = [String(s.phone || "")].map((p) => p.replace(/\D/g, "").replace(/^1(?=\d{10}$)/, "")).filter(Boolean);
  const blocked = (Array.isArray(s.blocked) ? s.blocked : []).map((b: unknown) => String(b).replace(/\D/g, ""));
  const c = contactOf(raw, own);
  let filtered = "";
  if (!extra.notice) {
    if (c.phone && blocked.includes(c.phone)) filtered = "blocked";
    else if (!c.phone && !c.email) filtered = "nocontact";
  }
  const id = "in" + crypto.randomUUID().replace(/-/g, "").slice(0, 14);
  const data = { id, at: Date.now(), status: "new", raw, source, auto: true, parsed: false, ...(filtered ? { filtered } : {}), ...extra };
  const { error } = await db.from("records").insert({ shop_id: shop, kind: "request", id, data, deleted: false });
  if (error) throw error;
  if (!filtered && !extra.notice) {
    const name = (raw.match(/^\s*(?:full name|name|customer(?: name)?|your name)\s*\*?\s*:\s*(.+)$/im) || [])[1] || "";
    await notifyManagers(shop, source === "booking" ? "📅 New online booking" : "New request" + (source === "website" ? " from your website" : ""), [EMPTY.test(name) ? "" : name.trim(), c.phone].filter(Boolean).join(" · ") || "Open the app to see it");
  }
  return { ok: true, id, filtered: filtered || undefined };
}

// ---------- Resend (forwarded email) ----------
async function verifySvix(req: Request, body: string): Promise<boolean> {
  const secret = Deno.env.get("RESEND_WEBHOOK_SECRET");
  if (!secret) return false;
  const id = req.headers.get("svix-id"), ts = req.headers.get("svix-timestamp"), sig = req.headers.get("svix-signature");
  if (!id || !ts || !sig) return false;
  if (Math.abs(Date.now() / 1000 - Number(ts)) > 600) return false;
  const keyBytes = Uint8Array.from(atob(secret.replace(/^whsec_/, "")), (ch) => ch.charCodeAt(0));
  const key = await crypto.subtle.importKey("raw", keyBytes, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${id}.${ts}.${body}`)));
  const expected = btoa(String.fromCharCode(...mac));
  return sig.split(" ").some((p) => p.split(",")[1] === expected);
}

async function fromResend(req: Request) {
  const text = await req.text();
  if (!(await verifySvix(req, text))) return out({ error: "Bad signature" }, 401);
  const ev = JSON.parse(text);
  if (ev.type !== "email.received") return out({ ok: true, skipped: ev.type });
  const d = ev.data || {};
  const addrs: string[] = [...(d.received_for || []), ...(d.to || []), ...(d.cc || [])].map(String);
  const key = addrs.map((a) => (a.match(/\br-([a-z0-9]{8,32})@/i) || [])[1]).find(Boolean);
  const shop = key ? await shopFor(key) : null;
  if (!shop) return out({ ok: true, skipped: "no shop" });
  const r = await fetch(`https://api.resend.com/emails/receiving/${d.email_id}`, { headers: { Authorization: `Bearer ${Deno.env.get("RESEND_API_KEY")}` } });
  if (!r.ok) throw new Error("Couldn't read the email from Resend: " + r.status);
  const em = await r.json();
  const from = String(em.from || d.from || ""), subject = String(em.subject || d.subject || "");
  let body = String(em.text || "").trim() || htmlToText(String(em.html || ""));
  body = cleanEmail(body);
  // Gmail asks the new address to confirm forwarding: show the code in the app instead of making it a request
  if (/forwarding-noreply@google\.com/i.test(from) || /Gmail Forwarding Confirmation/i.test(subject)) {
    const code = (subject.match(/#(\d{6,})/) || body.match(/Confirmation code:\s*(\d{6,})/i) || [])[1] || "";
    const link = (body.match(/https:\/\/mail(?:-settings)?\.google\.com\/mail\/[^\s<>"]+/) || [])[0] || "";
    return out(await save(shop, `Gmail forwarding confirmation\n${subject}`, "email", { notice: "gmail", code, link: clip(link, 600) }));
  }
  return out(await save(shop, (subject ? `Subject: ${subject}\n` : "") + body, "email", { from: clip(from, 200) }));
}

// two-step sign-in: a login that has an authenticator set up must have entered its code (aal2)
async function mfaBlocked(token: string, uid: string) {
  let aal = "aal1";
  try { let p = token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/"); p += "=".repeat((4 - p.length % 4) % 4); aal = JSON.parse(atob(p)).aal || "aal1"; } catch (_) { /* treat as aal1 */ }
  if (aal === "aal2") return false;
  const { data } = await db.auth.admin.mfa.listFactors({ userId: uid });
  return (data?.factors || []).some((f: { status: string }) => f.status === "verified");
}

// ---------- online estimate approval (honestechmobileapp.com/e/?CODE) ----------
type Slot = { d: string; t?: string };
type Link = { path?: string; exp?: number; shop?: string; job?: string; est?: Record<string, unknown>; pay?: Record<string, unknown> };
async function readLink(code: string): Promise<Link | null> {
  code = code.replace(/[^A-Za-z0-9]/g, "").slice(0, 16);
  if (code.length < 6) return null;
  const { data: f } = await db.storage.from("media").download(`_links/${code}.json`);
  if (!f) return null;
  try { const m = JSON.parse(await f.text()) as Link; if (!m.path || (m.exp && Date.now() > m.exp)) return null; return m; } catch (_) { return null; }
}
function slotsOf(j: Record<string, any>): Slot[] {
  const info = j.info || {};
  const list: Slot[] = Array.isArray(j.slots) ? j.slots : info.date ? [{ d: info.date, t: info.time || "" }] : [];
  return list.filter((x) => x && typeof x.d === "string" && x.d).map((x) => ({ d: x.d, t: x.t || "" }))
    .sort((a, b) => (a.d + (a.t || "99")) < (b.d + (b.t || "99")) ? -1 : 1);
}
async function loadJob(m: Link) {
  if (!m.shop || !m.job) return null;
  const { data } = await db.from("records").select("data, deleted").eq("shop_id", m.shop).eq("kind", "job").eq("id", m.job).maybeSingle();
  if (!data || data.deleted) return null;
  return data.data as Record<string, any>;
}
function estState(j: Record<string, any>) {
  const e = j.est || {};
  if (j.declined || e.status === "declined" || j.status === "canceled") return "closed";
  if (e.status === "approved") return "approved";
  if (j.status === "done" || (j.invoice && j.invoice.num && j.docMode === "inv")) return "closed";
  return "open";
}
async function estGet(code: string, sess = "") {
  const m = await readLink(code);
  if (!m || !m.est) return out({ error: "This link has expired. Ask the shop to send it again." }, 404);
  let j = await loadJob(m);
  if (!j) return out({ error: "This estimate is no longer available. Ask the shop to send it again." }, 404);
  // coming back from paying the deposit: confirm it right away
  if (sess && /^cs_[A-Za-z0-9_]+$/.test(sess) && !j.invoice?.deposit) {
    const acct = await payAcct(m.shop!);
    if (acct) {
      try {
        const s = await stripe.checkout.sessions.retrieve(sess, { stripeAccount: acct });
        if (s.payment_status === "paid" && s.metadata?.kind === "deposit" && s.metadata?.job === m.job && s.metadata?.shop === m.shop) { await markDeposit(m.shop!, m.job!, s); j = (await loadJob(m)) || j; }
      } catch (e) { console.error("deposit check", e); }
    }
  }
  const dep = Number((m.est as any).deposit) || 0, depPaid = Number(j.invoice?.deposit?.amount) || 0;
  const today = new Date(Date.now() - 5 * 3600_000).toISOString().slice(0, 10);
  const { data: sg } = await db.storage.from("media").createSignedUrl(m.path!, 60 * 60);
  const state = estState(j);
  return out({
    ...m.est, ...(await shopBrand(m.shop!)), state, pdf: sg?.signedUrl || "",
    slots: j.pending ? slotsOf(j).filter((x) => x.d >= today) : [],
    booked: !j.pending && j.info?.date ? { d: j.info.date, t: j.info.time || "" } : null,
    approved: state === "approved" ? { name: j.est?.online?.name || j.sig?.est?.name || "", at: j.est?.online?.at || 0, ask: j.est?.online?.ask || "" } : null,
    deposit: dep, depositPaid: depPaid, canPay: dep > 0 && !depPaid && !j.invoice?.paid && !!(await payAcct(m.shop!)),
  });
}
async function estApprove(req: Request) {
  try {
    const body = await req.json().catch(() => ({}));
    const m = await readLink(String(body.code || ""));
    if (!m || !m.est || !m.shop || !m.job) return out({ error: "This link has expired. Ask the shop to send it again." }, 404);
    const name = clip(body.name, 80).trim();
    const sig = String(body.sig || "");
    if (name.length < 2) return out({ error: "Type your name" }, 400);
    if (!/^data:image\/(jpeg|png);base64,[A-Za-z0-9+/=]+$/.test(sig) || sig.length > 250000) return out({ error: "Sign in the box" }, 400);
    const { data: row } = await db.from("records").select("data, deleted").eq("shop_id", m.shop).eq("kind", "job").eq("id", m.job).maybeSingle();
    if (!row || row.deleted) return out({ error: "This estimate is no longer available." }, 404);
    const j = row.data as Record<string, any>;
    const state = estState(j);
    if (state === "approved") return out({ ok: true, already: true });
    if (state !== "open") return out({ error: "This estimate is closed. Text the shop if you have questions." }, 409);
    const today = new Date(Date.now() - 5 * 3600_000).toISOString().slice(0, 10);
    let pick: Slot | null = null;
    const ask = clip(body.ask, 300).trim();
    if (body.slot && typeof body.slot === "object") {
      const want = body.slot as Slot;
      pick = slotsOf(j).find((x) => x.d === want.d && (x.t || "") === (want.t || "")) || null;
      if (!pick) return out({ error: "That time isn't available anymore. Pick another one." }, 409);
    }
    const now = Date.now(), total = Number((m.est as any).total) || 0;
    j.est = j.est || { num: (m.est as any).num || "", date: today };
    Object.assign(j.est, { status: "approved", approvedDate: today, total, online: { at: now, name, ask: pick ? "" : ask, total } });
    j.sig = j.sig || {};
    j.sig.est = { data: sig, name, at: now, online: true };
    if (pick && j.pending) { j.info = j.info || {}; j.info.date = pick.d; j.info.time = pick.t || ""; j.pending = false; j.bookedAt = now; }
    (j.log = Array.isArray(j.log) ? j.log : []).push({ ev: "approved online", at: now, by: name });
    const { error } = await db.from("records").update({ data: j }).eq("shop_id", m.shop).eq("kind", "job").eq("id", m.job);
    if (error) throw error;
    if (pick) {
      // the request this job came from is now booked
      const { data: rq } = await db.from("records").select("id, data").eq("shop_id", m.shop).eq("kind", "request").eq("deleted", false).eq("data->>jobId", m.job);
      for (const r of rq || []) { const d = r.data as Record<string, unknown>; d.status = "booked"; await db.from("records").update({ data: d }).eq("shop_id", m.shop).eq("kind", "request").eq("id", r.id); }
    }
    const who = String(j.info?.customer || name), num = String((m.est as any).num || ""), when = pick ? fmtSlot(pick) : "";
    await notifyManagers(m.shop, `✓ ${who} approved ${num ? "estimate " + num : "the estimate"}`,
      pick ? `Booked for ${when}. It's on your schedule.` : ask ? `Wants a different time: ${ask}` : "Pick a time with them and book it.", "./?job=" + encodeURIComponent(m.job), "est-" + m.job);
    return out({ ok: true, booked: pick });
  } catch (e) { console.error(e); return out({ error: "Something went wrong. Try again, or text the shop." }, 500); }
}
// ---------- pay an invoice by card (honestechmobileapp.com/p/?CODE) ----------
const nyDate = () => new Intl.DateTimeFormat("en-CA", { timeZone: "America/New_York" }).format(new Date());
async function payAcct(shop: string): Promise<string | null> {
  const { data: f } = await db.storage.from("media").download(`_pay/${shop}.json`);
  if (!f) return null;
  try { return (JSON.parse(await f.text()).acct as string) || null; } catch (_) { return null; }
}
// mark the invoice paid once Stripe says the money came in (also done by stripe-webhook for connected accounts)
async function markPaid(shop: string, job: string, s: Stripe.Checkout.Session) {
  const { data: row } = await db.from("records").select("data, deleted").eq("shop_id", shop).eq("kind", "job").eq("id", job).maybeSingle();
  if (!row || row.deleted) return false;
  const j = row.data as Record<string, any>;
  j.invoice = j.invoice || {};
  if (j.invoice.online && j.invoice.online.session === s.id) return true;
  const amt = (s.amount_total || 0) / 100;
  j.invoice.paid = true; j.invoice.paidVia = "Card"; j.invoice.paidDate = nyDate();
  j.invoice.online = { at: Date.now(), amount: amt, session: s.id, pi: typeof s.payment_intent === "string" ? s.payment_intent : s.payment_intent?.id || "" };
  (j.log = Array.isArray(j.log) ? j.log : []).push({ ev: "paid online", at: Date.now(), by: "Customer" });
  const { error } = await db.from("records").update({ data: j }).eq("shop_id", shop).eq("kind", "job").eq("id", job);
  if (error) throw error;
  await notifyManagers(shop, `💳 ${j.info?.customer || "A customer"} paid $${amt.toFixed(2)}`, `Invoice ${j.invoice.num || ""} is marked paid. The money goes to your Stripe account.`, "./?job=" + encodeURIComponent(job), "paid-" + job);
  return true;
}
async function markDeposit(shop: string, job: string, s: Stripe.Checkout.Session) {
  const { data: row } = await db.from("records").select("data, deleted").eq("shop_id", shop).eq("kind", "job").eq("id", job).maybeSingle();
  if (!row || row.deleted) return false;
  const j = row.data as Record<string, any>;
  j.invoice = j.invoice || {};
  if (j.invoice.deposit && j.invoice.deposit.session === s.id) return true;
  const amt = (s.amount_total || 0) / 100;
  j.invoice.deposit = { amount: amt, at: Date.now(), date: nyDate(), via: "Card", session: s.id, pi: typeof s.payment_intent === "string" ? s.payment_intent : s.payment_intent?.id || "" };
  (j.log = Array.isArray(j.log) ? j.log : []).push({ ev: "deposit paid online", at: Date.now(), by: "Customer" });
  const { error } = await db.from("records").update({ data: j }).eq("shop_id", shop).eq("kind", "job").eq("id", job);
  if (error) throw error;
  await notifyManagers(shop, `💳 ${j.info?.customer || "A customer"} paid a $${amt.toFixed(2)} deposit`, `Estimate ${j.est?.num || ""}. It comes off the final invoice.`, "./?job=" + encodeURIComponent(job), "dep-" + job);
  return true;
}
async function payGet(code: string, sess: string) {
  const m = await readLink(code);
  if (!m || !m.pay) return out({ error: "This link has expired. Ask the shop to send it again." }, 404);
  const j = await loadJob(m);
  if (!j) return out({ error: "This invoice is no longer available. Ask the shop to send it again." }, 404);
  const acct = await payAcct(m.shop!);
  // coming back from Stripe Checkout: confirm the payment right away instead of waiting for the webhook
  if (sess && acct && !j.invoice?.paid && /^cs_[A-Za-z0-9_]+$/.test(sess)) {
    try {
      const s = await stripe.checkout.sessions.retrieve(sess, { stripeAccount: acct });
      if (s.payment_status === "paid" && s.metadata?.kind === "invoice" && s.metadata?.job === m.job && s.metadata?.shop === m.shop) { await markPaid(m.shop!, m.job!, s); j.invoice = { ...(j.invoice || {}), paid: true, online: { amount: (s.amount_total || 0) / 100 } }; }
    } catch (e) { console.error("session check", e); }
  }
  const { data: sg } = await db.storage.from("media").createSignedUrl(m.path!, 60 * 60);
  const paid = !!j.invoice?.paid;
  return out({ ...m.pay, ...(await shopBrand(m.shop!)), pdf: sg?.signedUrl || "", state: paid ? "paid" : acct ? "open" : "nopay", paidAmount: j.invoice?.online?.amount || 0, paidVia: j.invoice?.paidVia || "" });
}
async function payStart(req: Request) {
  try {
    const body = await req.json().catch(() => ({}));
    const code = String(body.code || "").replace(/[^A-Za-z0-9]/g, "").slice(0, 16);
    const m = await readLink(code);
    if (body.kind === "deposit") return await depositStart(m, code);
    if (!m || !m.pay || !m.shop || !m.job) return out({ error: "This link has expired. Ask the shop to send it again." }, 404);
    const j = await loadJob(m);
    if (!j) return out({ error: "This invoice is no longer available." }, 404);
    if (j.invoice?.paid) return out({ error: "This invoice is already paid. Thank you!" }, 409);
    const acct = await payAcct(m.shop);
    if (!acct) return out({ error: "The shop doesn't take card payments online yet. Text them to pay another way." }, 409);
    const p = m.pay as Record<string, any>;
    const cents = Math.round((Number(p.total) || 0) * 100);
    if (cents < 50) return out({ error: "Nothing to pay on this invoice." }, 400);
    const back = `https://honestechmobileapp.com/p/?c=${code}`;
    const s = await stripe.checkout.sessions.create({
      mode: "payment",
      line_items: [{ quantity: 1, price_data: { currency: "usd", unit_amount: cents, product_data: { name: `Invoice ${clip(p.num, 40)}`.trim() + (p.veh ? ` · ${clip(p.veh, 60)}` : ""), description: clip(p.biz, 120) || undefined } } }],
      payment_intent_data: { description: `Invoice ${clip(p.num, 40)} · ${clip(p.custFull || p.cust, 60)}`, metadata: { shop: m.shop, job: m.job, num: clip(p.num, 40) }, ...(FEE_BPS ? { application_fee_amount: Math.floor(cents * FEE_BPS / 10000) } : {}) },
      metadata: { kind: "invoice", shop: m.shop, job: m.job, code },
      locale: p.lang === "es" ? "es" : "en",
      success_url: back + "&s={CHECKOUT_SESSION_ID}",
      cancel_url: back,
    }, { stripeAccount: acct });
    return out({ url: s.url });
  } catch (e) { console.error(e); return out({ error: "Couldn't open the card payment page. Try again in a minute." }, 500); }
}

async function depositStart(m: Link | null, code: string) {
  if (!m || !m.est || !m.shop || !m.job) return out({ error: "This link has expired. Ask the shop to send it again." }, 404);
  const j = await loadJob(m);
  if (!j) return out({ error: "This estimate is no longer available." }, 404);
  if (j.invoice?.deposit) return out({ error: "The deposit is already paid. Thank you!" }, 409);
  if (estState(j) !== "approved") return out({ error: "Approve the estimate first." }, 409);
  const acct = await payAcct(m.shop);
  if (!acct) return out({ error: "The shop doesn't take card payments online yet." }, 409);
  const p = m.est as Record<string, any>;
  const cents = Math.round((Number(p.deposit) || 0) * 100);
  if (cents < 50) return out({ error: "No deposit is needed for this estimate." }, 400);
  const back = `https://honestechmobileapp.com/e/?c=${code}`;
  const s = await stripe.checkout.sessions.create({
    mode: "payment",
    line_items: [{ quantity: 1, price_data: { currency: "usd", unit_amount: cents, product_data: { name: `Deposit · Estimate ${clip(p.num, 40)}`.trim() + (p.veh ? ` · ${clip(p.veh, 60)}` : ""), description: clip(p.biz, 120) || undefined } } }],
    payment_intent_data: { description: `Deposit · Estimate ${clip(p.num, 40)} · ${clip(p.custFull || p.cust, 60)}`, metadata: { shop: m.shop, job: m.job, num: clip(p.num, 40), kind: "deposit" }, ...(FEE_BPS ? { application_fee_amount: Math.floor(cents * FEE_BPS / 10000) } : {}) },
    metadata: { kind: "deposit", shop: m.shop, job: m.job, code },
    locale: p.lang === "es" ? "es" : "en",
    success_url: back + "&s={CHECKOUT_SESSION_ID}",
    cancel_url: back,
  }, { stripeAccount: acct });
  return out({ url: s.url });
}

// ---------- online booking page (honestechmobileapp.com/b/?KEY) ----------
// Customers pick a service and an open time from the shop's schedule. It arrives in Requests (nothing is booked by itself).
type BookCfg = { days: number[]; start: string; end: string; len: number; lead: number; ahead: number; svcs: { n: string; p: string }[] };
function bookCfg(s: Record<string, any>): BookCfg {
  const days = Array.isArray(s.bookDays) && s.bookDays.length ? s.bookDays.map(Number).filter((d: number) => d >= 0 && d <= 6) : [1, 2, 3, 4, 5, 6];
  const tm = (v: unknown, d: string) => /^\d{2}:\d{2}$/.test(String(v || "")) ? String(v) : d;
  const svcs = String(s.bookSvcs || "").split("\n").map((l) => l.trim()).filter(Boolean).slice(0, 30).map((l) => { const [n, p] = l.split("|").map((x) => x.trim()); return { n: clip(n, 80), p: clip(p || "", 30) }; });
  return { days, start: tm(s.bookStart, "08:00"), end: tm(s.bookEnd, "17:00"), len: Math.max(30, Math.min(480, Number(s.bookLen) || 120)), lead: Math.max(0, Math.min(168, Number(s.bookLead) || 12)), ahead: Math.max(3, Math.min(60, Number(s.bookAhead) || 21)), svcs };
}
const toMin = (t: string) => { const [h, m] = t.split(":").map(Number); return h * 60 + (m || 0); };
const nyNow = () => { const p = new Intl.DateTimeFormat("en-CA", { timeZone: "America/New_York", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hour12: false }).formatToParts(new Date()); const g = (t: string) => p.find((x) => x.type === t)?.value || "00"; return { d: `${g("year")}-${g("month")}-${g("day")}`, m: (Number(g("hour")) % 24) * 60 + Number(g("minute")) }; };
const addDay = (d: string, n: number) => new Date(Date.parse(d + "T12:00:00Z") + n * 864e5).toISOString().slice(0, 10);
async function bookSlots(shop: string, cfg: BookCfg) {
  const now = nyNow(), from = now.d, to = addDay(from, cfg.ahead);
  const busy: Record<string, [number, number][]> = {};
  const add = (d: string, t: string, len: number) => { if (!d || !t || !/^\d{2}:\d{2}/.test(t)) return; const a = toMin(t); (busy[d] = busy[d] || []).push([a, a + len]); };
  const { data: jobs } = await db.from("records").select("data").eq("shop_id", shop).eq("kind", "job").eq("deleted", false).gte("data->info->>date", from).lte("data->info->>date", to);
  for (const r of jobs || []) { const j = r.data as Record<string, any>; if (j.pending || ["canceled", "done"].includes(j.status) || j.declined) continue; add(j.info?.date, j.info?.time, Number(j.info?.dur) || cfg.len); }
  const { data: reqs } = await db.from("records").select("data").eq("shop_id", shop).eq("kind", "request").eq("deleted", false).eq("data->>status", "new").eq("data->>booking", "true");
  for (const r of reqs || []) { const q = r.data as Record<string, any>; add(q.date, q.time, cfg.len); }
  const out: { d: string; t: string[] }[] = [];
  for (let k = 0; k <= cfg.ahead; k++) {
    const d = addDay(from, k), dow = new Date(d + "T12:00:00Z").getUTCDay();
    if (!cfg.days.includes(dow)) continue;
    const ts: string[] = [];
    for (let a = toMin(cfg.start); a + cfg.len <= toMin(cfg.end); a += cfg.len) {
      const mins = (k * 1440 + a) - now.m;
      if (mins < cfg.lead * 60) continue;
      if ((busy[d] || []).some(([x, y]) => a < y && x < a + cfg.len)) continue;
      ts.push(`${String(Math.floor(a / 60)).padStart(2, "0")}:${String(a % 60).padStart(2, "0")}`);
    }
    if (ts.length) out.push({ d, t: ts });
  }
  return out;
}
async function bookShop(key: string) {
  const shop = await shopFor(key);
  if (!shop) return null;
  const { data: st } = await db.from("records").select("data").eq("shop_id", shop).eq("kind", "settings").eq("id", "main").maybeSingle();
  const s = (st?.data || {}) as Record<string, any>;
  if (!s.bookOn) return null;
  return { shop, s, cfg: bookCfg(s) };
}
async function bookGet(key: string) {
  const b = await bookShop(key);
  if (!b) return out({ error: "Online booking isn't available right now. Call or text the shop to book." }, 404);
  const { s, cfg } = b;
  return out({ ...(await shopBrand(b.shop, s)), biz: clip(s.biz, 120), phone: clip(s.phone, 40), area: clip(s.bookArea, 200), note: clip(s.bookNote, 400), len: cfg.len, svcs: cfg.svcs, slots: await bookSlots(b.shop, cfg) });
}
async function bookPost(req: Request) {
  try {
    const body = await req.json().catch(() => ({}));
    if (body.website) return out({ ok: true });   // honeypot
    const b = await bookShop(String(body.key || ""));
    if (!b) return out({ error: "Online booking isn't available right now. Call or text the shop to book." }, 404);
    const name = clip(body.name, 80).trim(), phone = clip(body.phone, 30).trim(), digits = phone.replace(/\D/g, "");
    if (name.length < 2) return out({ error: "Type your name" }, 400);
    if (digits.length < 10) return out({ error: "Type a phone number we can text" }, 400);
    const slot = body.slot && typeof body.slot === "object" ? { d: clip(body.slot.d, 10), t: clip(body.slot.t, 5) } : null;
    if (!slot) return out({ error: "Pick a day and time" }, 400);
    const open = await bookSlots(b.shop, b.cfg);
    if (!open.some((x) => x.d === slot.d && x.t.includes(slot.t))) return out({ error: "That time was just taken. Pick another one." }, 409);
    const f = { email: clip(body.email, 120).trim(), location: clip(body.address, 200).trim(), year: clip(body.year, 4).trim(), make: clip(body.make, 40).trim(), model: clip(body.model, 60).trim(), work: clip(body.svc, 120).trim(), notes: clip(body.notes, 1000).trim() };
    const lang = body.lang === "es" ? "es" : "";
    const raw = [`Name: ${name}`, `Phone: ${phone}`, f.email && `Email: ${f.email}`, f.location && `Address: ${f.location}`, (f.year || f.make || f.model) && `Vehicle: ${[f.year, f.make, f.model].filter(Boolean).join(" ")}`, f.work && `Service: ${f.work}`, `Requested time: ${fmtSlot(slot)}`, f.notes && `Notes: ${f.notes}`].filter(Boolean).join("\n");
    const r = await save(b.shop, raw, "booking", { parsed: true, booking: "true", customer: name, phone, ...f, date: slot.d, time: slot.t, type: /pre-?purchase|\bppi\b|inspection before/i.test(f.work) ? "ppi" : "service", ...(lang ? { lang } : {}) });
    if (!r.ok) return out({ error: "Too many requests right now. Call or text the shop." }, 429);
    return out({ ok: true });
  } catch (e) { console.error(e); return out({ error: "Something went wrong. Try again, or call the shop." }, 500); }
}

// the shop's logo and accent color for the customer pages
async function shopBrand(shop: string, s0?: Record<string, any>) {
  let s = s0;
  if (!s) { const { data: st } = await db.from("records").select("data").eq("shop_id", shop).eq("kind", "settings").eq("id", "main").maybeSingle(); s = (st?.data || {}) as Record<string, any>; }
  const logo = typeof s.logo === "string" && /^data:image\/(jpeg|png|webp);base64,/.test(s.logo) && s.logo.length < 400000 ? s.logo : "";
  const accent = /^#[0-9a-f]{6}$/i.test(String(s.themeAccent || "")) ? String(s.themeAccent) : "";
  return { logo, accent };
}

function fmtSlot(x: Slot) {
  const d = new Date(x.d + "T12:00:00Z").toLocaleDateString("en-US", { weekday: "short", month: "short", day: "numeric", timeZone: "UTC" });
  if (!x.t) return d;
  const [h, mi] = x.t.split(":").map(Number);
  return `${d} at ${((h + 11) % 12) + 1}:${String(mi || 0).padStart(2, "0")} ${h < 12 ? "AM" : "PM"}`;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method === "GET" && new URL(req.url).searchParams.get("d")) {
    // short PDF link (honestechmobileapp.com/d/?CODE): look up which PDF it points to and send the phone there
    const code = (new URL(req.url).searchParams.get("d") || "").replace(/[^A-Za-z0-9]/g, "").slice(0, 16);
    const gone = () => new Response("This link has expired. Ask the shop to send it again.", { status: 404, headers: { ...CORS, "Content-Type": "text/plain; charset=utf-8" } });
    if (code.length < 6) return gone();
    const { data: f } = await db.storage.from("media").download(`_links/${code}.json`);
    if (!f) return gone();
    let m: { path?: string; exp?: number } = {};
    try { m = JSON.parse(await f.text()); } catch (_) { return gone(); }
    if (!m.path || (m.exp && Date.now() > m.exp)) return gone();
    const { data: sg } = await db.storage.from("media").createSignedUrl(m.path, 60 * 60);
    if (!sg?.signedUrl) return gone();
    return new Response(null, { status: 302, headers: { ...CORS, Location: sg.signedUrl, "Cache-Control": "no-store" } });
  }
  if (req.method === "POST" && new URL(req.url).searchParams.get("act") === "link") {
    // the app asks for a short link to a PDF it just uploaded to its own shop folder
    try {
      const token = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
      const { data: ud } = await db.auth.getUser(token);
      const me = ud?.user;
      if (!me) return out({ error: "Please sign in again" }, 401);
      if (await mfaBlocked(token, me.id)) return out({ error: "Enter your 6-digit sign-in code first" }, 401);
      const body = await req.json().catch(() => ({}));
      const path = String(body.path || "");
      const shop = path.split("/")[0];
      if (!shop || !/^[^/]+\/[A-Za-z0-9._-]+\.pdf$/.test(path)) return out({ error: "Bad file" }, 400);
      const { data: mem } = await db.from("shop_members").select("user_id").eq("shop_id", shop).eq("user_id", me.id).maybeSingle();
      if (!mem) return out({ error: "Not your shop" }, 403);
      const ABC = "abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789";
      const rnd = crypto.getRandomValues(new Uint8Array(8));
      const code = Array.from(rnd, (b) => ABC[b % ABC.length]).join("");
      // an estimate link also carries a snapshot of the estimate so the customer can approve it online (/e/?CODE)
      const extra: Record<string, unknown> = {};
      if (body.job && body.est && typeof body.est === "object") {
        const jobId = clip(body.job, 80);
        const { data: jr } = await db.from("records").select("id").eq("shop_id", shop).eq("kind", "job").eq("id", jobId).eq("deleted", false).maybeSingle();
        if (jr) { const snap = JSON.stringify(body.est); if (snap.length < 30000) { extra.job = jobId; extra.est = body.est; } }
      }
      if (body.job && body.pay && typeof body.pay === "object") {
        const jobId = clip(body.job, 80);
        const { data: jr } = await db.from("records").select("id").eq("shop_id", shop).eq("kind", "job").eq("id", jobId).eq("deleted", false).maybeSingle();
        if (jr) { const snap = JSON.stringify(body.pay); if (snap.length < 30000) { extra.job = jobId; extra.pay = body.pay; } }
      }
      const rec = JSON.stringify({ path, exp: Date.now() + 366 * 864e5, by: me.id, shop, ...extra });
      const { error } = await db.storage.from("media").upload(`_links/${code}.json`, new Blob([rec], { type: "application/json" }), { upsert: false, contentType: "application/json" });
      if (error) return out({ error: error.message }, 500);
      return out({ code });
    } catch (e) { return out({ error: String((e as Error)?.message || e) }, 500); }
  }
  if (req.method === "GET" && new URL(req.url).searchParams.get("e")) return await estGet(new URL(req.url).searchParams.get("e") || "", new URL(req.url).searchParams.get("s") || "");
  if (req.method === "POST" && new URL(req.url).searchParams.get("act") === "approve") return await estApprove(req);
  if (req.method === "GET" && new URL(req.url).searchParams.get("bk")) return await bookGet(new URL(req.url).searchParams.get("bk") || "");
  if (req.method === "POST" && new URL(req.url).searchParams.get("act") === "book") return await bookPost(req);
  if (req.method === "GET" && new URL(req.url).searchParams.get("p")) return await payGet(new URL(req.url).searchParams.get("p") || "", new URL(req.url).searchParams.get("s") || "");
  if (req.method === "POST" && new URL(req.url).searchParams.get("act") === "pay") return await payStart(req);
  if (req.method === "GET") {
    // "Save to phone": hand the phone a contact card (.vcf) so Contacts offers Create New Contact. Nothing is stored.
    const v = new URL(req.url).searchParams.get("vcard") || "";
    if (!v || v.length > 4000) return out({ error: "bad request" }, 400);
    try {
      const bin = atob(v.replace(/-/g, "+").replace(/_/g, "/"));
      const txt = new TextDecoder().decode(Uint8Array.from(bin, (c) => c.charCodeAt(0)));
      if (!/^BEGIN:VCARD/.test(txt) || !/END:VCARD\s*$/.test(txt)) return out({ error: "bad request" }, 400);
      const sp = new URL(req.url).searchParams, dl = sp.get("dl") === "1";
      const name = (txt.match(/\nFN:([^\r\n]*)/) || [])[1]?.replace(/[^\w ]+/g, "").trim() || "contact";
      return new Response(txt, { headers: { ...CORS, "Content-Type": sp.get("t") === "v" ? "text/vcard; charset=utf-8" : "text/x-vcard; charset=utf-8", "Content-Disposition": `${dl ? "attachment" : "inline"}; filename="${name}.vcf"` } });
    } catch (_) { return out({ error: "bad request" }, 400); }
  }
  if (req.method !== "POST") return out({ error: "POST only" }, 405);
  try {
    const url = new URL(req.url);
    if (url.searchParams.get("src") === "resend") return await fromResend(req);
    const shop = await shopFor(url.searchParams.get("k") || "");
    if (!shop) return out({ error: "Unknown link. Copy it again from the app's Settings." }, 404);
    const ct = req.headers.get("content-type") || "";
    let body: Record<string, unknown> = {};
    if (/json/i.test(ct)) body = await req.json().catch(() => ({}));
    else { const f = await req.formData().catch(() => null); if (f) f.forEach((v, k) => { body[k] = String(v); }); }
    if (body["bot-field"] || body["_gotcha"]) return out({ ok: true });
    const raw = fromForm(body);
    if (!raw.trim()) return out({ error: "Nothing in the submission" }, 400);
    const form = clip(body.form_name || body["form-name"] || "", 60);
    return out(await save(shop, raw, "website", form ? { form } : {}));
  } catch (e) {
    console.error(e);
    return out({ error: (e as Error).message || "Intake error" }, 500);
  }
});
