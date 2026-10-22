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

async function notifyManagers(shop: string, title: string, body: string) {
  try {
    const { data: k } = await db.from("push_keys").select("public_key, private_key").eq("id", 1).maybeSingle();
    if (!k) return;
    const { data: members } = await db.from("shop_members").select("user_id, role").eq("shop_id", shop);
    const ids = (members || []).filter((m) => m.role === "owner" || m.role === "admin").map((m) => m.user_id);
    if (!ids.length) return;
    webpush.setVapidDetails("mailto:info@honestechservice.com", k.public_key, k.private_key);
    const { data: subs } = await db.from("push_subs").select("endpoint, p256dh, auth").in("user_id", ids);
    const payload = JSON.stringify({ title: clip(title, 80), body: clip(body, 240), url: "./?view=requests", tag: "request" });
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
    await notifyManagers(shop, "New request" + (source === "website" ? " from your website" : ""), [EMPTY.test(name) ? "" : name.trim(), c.phone].filter(Boolean).join(" · ") || "Open the app to see it");
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
      const body = await req.json().catch(() => ({}));
      const path = String(body.path || "");
      const shop = path.split("/")[0];
      if (!shop || !/^[^/]+\/[A-Za-z0-9._-]+\.pdf$/.test(path)) return out({ error: "Bad file" }, 400);
      const { data: mem } = await db.from("shop_members").select("user_id").eq("shop_id", shop).eq("user_id", me.id).maybeSingle();
      if (!mem) return out({ error: "Not your shop" }, 403);
      const ABC = "abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789";
      const rnd = crypto.getRandomValues(new Uint8Array(8));
      const code = Array.from(rnd, (b) => ABC[b % ABC.length]).join("");
      const rec = JSON.stringify({ path, exp: Date.now() + 366 * 864e5, by: me.id });
      const { error } = await db.storage.from("media").upload(`_links/${code}.json`, new Blob([rec], { type: "application/json" }), { upsert: false, contentType: "application/json" });
      if (error) return out({ error: error.message }, 500);
      return out({ code });
    } catch (e) { return out({ error: String((e as Error)?.message || e) }, 500); }
  }
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
