// Supabase Edge Function: assist
// Writes customer messages for the shop with Google's Gemini: replies to requests, and short texts from a job
// ("tell her the part comes Thursday"). The mechanic always reviews and edits before anything is sent.
// Secret: GEMINI_API_KEY (Google AI Studio → Get API key). Optional: GEMINI_MODEL.
// Deploy with "Verify JWT" OFF (this function checks the signed-in user itself).
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const out = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...CORS, "Content-Type": "application/json" } });
const clip = (s: unknown, n: number) => String(s ?? "").slice(0, n);

async function mfaBlocked(token: string, uid: string) {
  let aal = "aal1";
  try { let p = token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/"); p += "=".repeat((4 - p.length % 4) % 4); aal = JSON.parse(atob(p)).aal || "aal1"; } catch (_) { /* aal1 */ }
  if (aal === "aal2") return false;
  const { data } = await db.auth.admin.mfa.listFactors({ userId: uid });
  return (data?.factors || []).some((f: { status: string }) => f.status === "verified");
}

// a shop can ask for up to 60 drafts an hour (keeps a stuck button from running up the bill)
const USE = new Map<string, number[]>();
function overLimit(shop: string) {
  const now = Date.now(), list = (USE.get(shop) || []).filter((t) => now - t < 3600e3);
  if (list.length >= 60) { USE.set(shop, list); return true; }
  list.push(now); USE.set(shop, list); return false;
}

const MODELS = () => [Deno.env.get("GEMINI_MODEL"), "gemini-flash-latest", "gemini-3.1-flash-lite", "gemini-3-flash-preview"].filter(Boolean) as string[];

async function gemini(system: string, prompt: string): Promise<string> {
  const key = Deno.env.get("GEMINI_API_KEY");
  if (!key) throw { msg: "AI writing isn't set up yet (the shop owner adds a Google AI key).", code: 503 };
  let last = "";
  for (const model of MODELS()) {
    const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model)}:generateContent`, {
      method: "POST", headers: { "Content-Type": "application/json", "x-goog-api-key": key },
      body: JSON.stringify({
        systemInstruction: { parts: [{ text: system }] },
        contents: [{ role: "user", parts: [{ text: prompt }] }],
        generationConfig: { temperature: 0.6, maxOutputTokens: 600 },
      }),
    });
    if (r.status === 404 || r.status === 400) { last = await r.text().catch(() => ""); continue; }   // model name retired: try the next
    if (r.status === 429) throw { msg: "The AI is busy right now. Try again in a minute.", code: 429 };
    if (!r.ok) { last = await r.text().catch(() => ""); console.error("gemini", r.status, last.slice(0, 300)); throw { msg: "Couldn't write a draft right now. Try again.", code: 502 }; }
    const j = await r.json().catch(() => ({}));
    const text = (j?.candidates?.[0]?.content?.parts || []).map((p: { text?: string }) => p.text || "").join("").trim();
    if (!text) throw { msg: "The AI didn't return a draft. Try rewording.", code: 502 };
    return text;
  }
  console.error("gemini: no model worked", last.slice(0, 300));
  throw { msg: "Couldn't write a draft right now. Try again.", code: 502 };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return out({ error: "POST only" }, 405);
  try {
    const token = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
    const { data: ud } = await db.auth.getUser(token);
    const me = ud?.user;
    if (!me) return out({ error: "Please sign in again" }, 401);
    if (await mfaBlocked(token, me.id)) return out({ error: "Enter your sign-in code first" }, 403);
    const { data: mem } = await db.from("shop_members").select("shop_id").eq("user_id", me.id).order("created_at", { ascending: false }).limit(1).maybeSingle();
    if (!mem) return out({ error: "No shop" }, 400);
    if (overLimit(mem.shop_id)) return out({ error: "That's a lot of drafts this hour. Try again a bit later." }, 429);

    const b = await req.json().catch(() => ({}));
    const lang = b.lang === "es" ? "Spanish" : "English";
    const biz = clip(b.biz, 80) || "our shop", owner = clip(b.owner, 60);
    const system = [
      `You write short text messages for ${biz}, a mobile mechanic business${owner ? ` run by ${owner}` : ""}. The mechanic will read and edit your draft before sending it.`,
      `Write in ${lang}. Sound like a friendly, professional local mechanic: plain words, no corporate filler, no emojis unless the customer used them, no hashtags.`,
      "Keep it to 2-5 short sentences, ready to send as a text message. No subject line, no placeholders like [Name] unless a detail is truly unknown, and never invent prices, dates, times, diagnoses or promises that aren't in the notes.",
      "If the customer asked something the notes don't answer, say the mechanic will confirm. Sign off with the business name only if it fits naturally.",
      "Return only the message text.",
    ].join("\n");
    const facts = [
      b.customer && `Customer: ${clip(b.customer, 80)}`,
      b.vehicle && `Vehicle: ${clip(b.vehicle, 120)}`,
      b.work && `Work: ${clip(b.work, 300)}`,
      b.when && `Appointment: ${clip(b.when, 80)}`,
      b.total && `Estimate/invoice total: ${clip(b.total, 30)}`,
      b.services && `Services offered: ${clip(b.services, 600)}`,
      b.area && `Service area: ${clip(b.area, 200)}`,
      b.bookLink && `Online booking link: ${clip(b.bookLink, 200)}`,
      b.phone && `Shop phone: ${clip(b.phone, 30)}`,
    ].filter(Boolean).join("\n");
    let prompt = "";
    if (b.kind === "reply") prompt = `A customer sent this request:\n"""\n${clip(b.message, 3000)}\n"""\n\nWhat we know:\n${facts || "(nothing else)"}\n\n${b.note ? `What the mechanic wants to say: ${clip(b.note, 600)}\n\n` : ""}Write the reply text.`;
    else if (b.kind === "job") prompt = `What we know about this job:\n${facts || "(nothing else)"}\n\nWhat the mechanic wants to tell the customer: ${clip(b.note, 800) || "a quick update on the job"}\n\nWrite the text message.`;
    else if (b.kind === "polish") prompt = `Rewrite this message so it reads clearly and professionally, keeping every fact and the same meaning:\n"""\n${clip(b.message, 2000)}\n"""`;
    else return out({ error: "Unknown request" }, 400);
    const text = await gemini(system, prompt);
    return out({ text: clip(text.replace(/^["']|["']$/g, ""), 1600) });
  } catch (e) {
    const x = e as { msg?: string; code?: number; message?: string };
    if (x.msg) return out({ error: x.msg }, x.code || 500);
    console.error(e);
    return out({ error: "Couldn't write a draft right now. Try again." }, 500);
  }
});
