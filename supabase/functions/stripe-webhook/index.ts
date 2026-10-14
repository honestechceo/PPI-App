// Supabase Edge Function: stripe-webhook
// Receives Stripe events and keeps public.subscriptions up to date.
// Secrets needed (Supabase → Edge Functions → Secrets): STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET,
// and optionally STRIPE_TEAM_PRICES (comma-separated price IDs that count as the Team plan).
// Deploy with "Verify JWT" turned OFF (Stripe can't send a Supabase login).
import Stripe from "https://esm.sh/stripe@14.25.0?target=deno";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, { apiVersion: "2024-06-20", httpClient: Stripe.createFetchHttpClient() });
const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const TEAM = (Deno.env.get("STRIPE_TEAM_PRICES") || "").split(",").map((s) => s.trim()).filter(Boolean);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

async function saveSub(sub: Stripe.Subscription, shopId?: string | null) {
  const items = sub.items?.data || [];
  const isTeam = items.some((i) => TEAM.includes(i.price.id)) || items.some((i) => /team/i.test(String(i.price.nickname || i.price.lookup_key || "")));
  const seats = items.reduce((n, i) => n + (TEAM.includes(i.price.id) ? 0 : (i.quantity || 0)), 0);
  const row: Record<string, unknown> = {
    status: sub.status, plan: isTeam ? "team" : "solo", seats: Math.max(1, seats),
    stripe_customer: typeof sub.customer === "string" ? sub.customer : sub.customer?.id,
    stripe_subscription: sub.id,
    current_period_end: sub.current_period_end ? new Date(sub.current_period_end * 1000).toISOString() : null,
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

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("ok");
  const sig = req.headers.get("stripe-signature") || "";
  const body = await req.text();
  let event: Stripe.Event;
  try { event = await stripe.webhooks.constructEventAsync(body, sig, Deno.env.get("STRIPE_WEBHOOK_SECRET")!); }
  catch (e) { return new Response(`Bad signature: ${(e as Error).message}`, { status: 400 }); }
  try {
    if (event.type === "checkout.session.completed") {
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
