// Supabase Edge Function: stripe-webhook
// Receives Stripe events and keeps public.subscriptions up to date.
// Secrets needed (Supabase → Edge Functions → Secrets): STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET,
// STRIPE_TEAM_PRICES is optional now: the Team plan is recognized by its product name.
// Deploy with "Verify JWT" turned OFF (Stripe can't send a Supabase login).
// Card payments on invoices: add a second Stripe webhook for "Connected accounts" (event checkout.session.completed)
// pointing here, and save its signing secret as STRIPE_CONNECT_WEBHOOK_SECRET.
import webpush from "npm:web-push@3.6.7";
import Stripe from "https://esm.sh/stripe@14.25.0?target=deno";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, { apiVersion: "2024-06-20", httpClient: Stripe.createFetchHttpClient() });
const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const TEAM = (Deno.env.get("STRIPE_TEAM_PRICES") || "").split(",").map((s) => s.trim()).filter(Boolean);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

async function saveSub(sub: Stripe.Subscription, shopId?: string | null) {
  const items = sub.items?.data || [];
  const names: Record<string, string> = {};
  for (const i of items) {
    const pid = typeof i.price.product === "string" ? i.price.product : i.price.product?.id;
    if (pid && !(pid in names)) { try { names[pid] = (await stripe.products.retrieve(pid)).name || ""; } catch { names[pid] = ""; } }
  }
  const nameOf = (i: Stripe.SubscriptionItem) => names[typeof i.price.product === "string" ? i.price.product : i.price.product?.id || ""] || "";
  const teamItem = (i: Stripe.SubscriptionItem) => TEAM.includes(i.price.id) || (/team/i.test(nameOf(i)) && !/technician/i.test(nameOf(i)));
  const isTeam = items.some(teamItem);
  const seats = items.reduce((n, i) => n + (teamItem(i) ? 0 : (i.quantity || 0)), 0);
  const row: Record<string, unknown> = {
    status: sub.status, plan: isTeam ? "team" : "solo",
    // seats = technicians allowed: Team includes 2, plus any extra technician seats
    seats: isTeam ? 2 + items.filter((i) => !teamItem(i)).reduce((n, i) => n + (i.quantity || 0), 0) : 0,
    stripe_customer: typeof sub.customer === "string" ? sub.customer : sub.customer?.id,
    stripe_subscription: sub.id,
    current_period_end: (() => { const t = (sub as any).current_period_end || (items[0] as any)?.current_period_end; return t ? new Date(t * 1000).toISOString() : null; })(),
    updated_at: new Date().toISOString(),
  };
  let target = shopId || (sub.metadata?.shop_id as string | undefined) || null;
  if (!target) {
    const { data } = await db.from("subscriptions").select("shop_id").or(`stripe_subscription.eq.${sub.id},stripe_customer.eq.${row.stripe_customer}`).limit(1).maybeSingle();
    target = data?.shop_id || null;
  }
  if (!target || !UUID.test(target)) { console.log("No shop for subscription", sub.id); return; }
  const { error } = await db.from("subscriptions").upsert({ shop_id: target, ...row }, { onConflict: "shop_id" });
  if (error) throw error;
}

// a customer paid an invoice on a shop's own Stripe account: mark it paid and tell the owner
async function invoicePaid(s: Stripe.Checkout.Session) {
  const shop = s.metadata?.shop, job = s.metadata?.job;
  if (!shop || !job || s.payment_status !== "paid") return;
  const { data: row } = await db.from("records").select("data, deleted").eq("shop_id", shop).eq("kind", "job").eq("id", job).maybeSingle();
  if (!row || row.deleted) return;
  const j = row.data as Record<string, any>;
  j.invoice = j.invoice || {};
  const dep = s.metadata?.kind === "deposit";
  if ((dep ? j.invoice.deposit : j.invoice.online)?.session === s.id) return;
  const amt = (s.amount_total || 0) / 100, day = new Intl.DateTimeFormat("en-CA", { timeZone: "America/New_York" }).format(new Date());
  const pi = typeof s.payment_intent === "string" ? s.payment_intent : s.payment_intent?.id || "";
  if (dep) j.invoice.deposit = { amount: amt, at: Date.now(), date: day, via: "Card", session: s.id, pi };
  else {
    j.invoice.paid = true; j.invoice.paidVia = "Card"; j.invoice.paidDate = day;
    j.invoice.online = { at: Date.now(), amount: amt, session: s.id, pi };
  }
  (j.log = Array.isArray(j.log) ? j.log : []).push({ ev: dep ? "deposit paid online" : "paid online", at: Date.now(), by: "Customer" });
  const { error } = await db.from("records").update({ data: j }).eq("shop_id", shop).eq("kind", "job").eq("id", job);
  if (error) throw error;
  try {
    const { data: k } = await db.from("push_keys").select("public_key, private_key").eq("id", 1).maybeSingle();
    const { data: members } = await db.from("shop_members").select("user_id, role").eq("shop_id", shop);
    const ids = (members || []).filter((m) => m.role === "owner" || m.role === "admin").map((m) => m.user_id);
    if (!k || !ids.length) return;
    webpush.setVapidDetails("mailto:info@honestechservice.com", k.public_key, k.private_key);
    const { data: subs } = await db.from("push_subs").select("endpoint, p256dh, auth").in("user_id", ids);
    const payload = JSON.stringify({ title: `💳 ${j.info?.customer || "A customer"} paid ${dep ? "a " : ""}$${amt.toFixed(2)}${dep ? " deposit" : ""}`, body: dep ? `Estimate ${j.est?.num || ""}. It comes off the final invoice.` : `Invoice ${j.invoice.num || ""} is marked paid.`, url: "./?job=" + encodeURIComponent(job), tag: "paid-" + job });
    await Promise.all((subs || []).map((x) => webpush.sendNotification({ endpoint: x.endpoint, keys: { p256dh: x.p256dh, auth: x.auth } }, payload, { TTL: 86400 }).catch(() => {})));
  } catch (e) { console.error("notify", e); }
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("ok");
  const sig = req.headers.get("stripe-signature") || "";
  const body = await req.text();
  const secrets = [Deno.env.get("STRIPE_WEBHOOK_SECRET"), Deno.env.get("STRIPE_CONNECT_WEBHOOK_SECRET")].filter(Boolean) as string[];
  let event: Stripe.Event | null = null, lastErr = "";
  for (const sec of secrets) { try { event = await stripe.webhooks.constructEventAsync(body, sig, sec); break; } catch (e) { lastErr = (e as Error).message; } }
  if (!event) return new Response(`Bad signature: ${lastErr}`, { status: 400 });
  try {
    if (event.account && (event.type === "checkout.session.completed" || event.type === "checkout.session.async_payment_succeeded")) {
      const s = event.data.object as Stripe.Checkout.Session;
      if (s.metadata?.kind === "invoice" || s.metadata?.kind === "deposit") await invoicePaid(s);
    } else if (event.type === "checkout.session.completed") {
      const s = event.data.object as Stripe.Checkout.Session;
      const shopId = s.client_reference_id;
      if (s.subscription && shopId && UUID.test(shopId)) {
        const sub = await stripe.subscriptions.retrieve(String(s.subscription));
        await stripe.subscriptions.update(sub.id, { metadata: { ...sub.metadata, shop_id: shopId } });
        await saveSub(sub, shopId);
      }
    } else if (event.type.startsWith("customer.subscription.")) {
      await saveSub(event.data.object as Stripe.Subscription);
    }
    return new Response(JSON.stringify({ received: true }), { headers: { "Content-Type": "application/json" } });
  } catch (e) {
    console.error(e);
    return new Response("error", { status: 500 });
  }
});
