// Supabase Edge Function: billing
// Opens Stripe Checkout for a plan, or the Stripe billing page for a paying shop.
// Finds prices by product name, so test → live is just swapping STRIPE_SECRET_KEY.
// Product names must contain "Solo", "Team" or "Technician".
// Secrets: STRIPE_SECRET_KEY (shared with stripe-webhook). Deploy with "Verify JWT" OFF
// (this function checks the signed-in user itself).
import Stripe from "https://esm.sh/stripe@14.25.0?target=deno";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, { apiVersion: "2024-06-20", httpClient: Stripe.createFetchHttpClient() });
const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const out = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...CORS, "Content-Type": "application/json" } });
const ALLOWED_RETURN = /^https:\/\/(honestechmobileapp\.com|www\.honestechmobileapp\.com|[a-z0-9-]+\.github\.io)(\/|$)/i;

async function findPrice(kind: "solo" | "team" | "tech", interval: "month" | "year") {
  const want = kind === "solo" ? /solo/i : kind === "team" ? /team/i : /technician|tech\b/i;
  const res = await stripe.prices.list({ active: true, type: "recurring", limit: 100, expand: ["data.product"] });
  const hits = res.data.filter((p) => {
    const prod = p.product as Stripe.Product;
    return prod && !prod.deleted && prod.active !== false && want.test(prod.name) && p.recurring?.interval === interval &&
      (kind !== "team" || !/technician/i.test(prod.name));
  });
  return hits.sort((a, b) => b.created - a.created)[0] || null;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return out({ error: "POST only" }, 405);
  try {
    const token = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
    const { data: ud, error: ue } = await db.auth.getUser(token);
    if (ue || !ud?.user) return out({ error: "Please sign in again" }, 401);
    const user = ud.user;
    const body = await req.json().catch(() => ({}));
    const ret = ALLOWED_RETURN.test(String(body.return_url || "")) ? String(body.return_url).split(/[?#]/)[0] : "https://honestechmobileapp.com/";

    const { data: mem } = await db.from("shop_members").select("shop_id, role").eq("user_id", user.id).order("created_at", { ascending: false }).limit(1).maybeSingle();
    if (!mem) return out({ error: "No shop found for this account" }, 400);
    if (mem.role !== "owner") return out({ error: "Only the shop owner can manage the plan" }, 403);
    const shopId = mem.shop_id;
    const { data: sub } = await db.from("subscriptions").select("status, stripe_customer").eq("shop_id", shopId).maybeSingle();
    const paying = sub && ["active", "trialing", "past_due"].includes(sub.status);

    if (body.action === "portal" || (body.action === "checkout" && paying && sub?.stripe_customer)) {
      if (!sub?.stripe_customer) return out({ error: "No subscription yet. Pick a plan first." }, 400);
      const s = await stripe.billingPortal.sessions.create({ customer: sub.stripe_customer, return_url: ret });
      return out({ url: s.url });
    }
    if (body.action === "seats") {
      // Read (no seats given) or change the number of extra technicians on a Team plan.
      const { data: row } = await db.from("subscriptions").select("stripe_subscription").eq("shop_id", shopId).maybeSingle();
      if (!paying || !row?.stripe_subscription) return out({ error: "No active Team plan" }, 400);
      const live = await stripe.subscriptions.retrieve(row.stripe_subscription, { expand: ["items.data.price.product"] });
      const its = live.items.data;
      const pname = (i: Stripe.SubscriptionItem) => ((i.price.product as Stripe.Product)?.name || "");
      const techItem = its.find((i) => /technician/i.test(pname(i)));
      const teamItem = its.find((i) => /team/i.test(pname(i)) && !/technician/i.test(pname(i)));
      if (!teamItem) return out({ error: "Extra technicians are part of the Team plan" }, 400);
      const current = techItem?.quantity || 0;
      if (body.seats === undefined || body.seats === null) return out({ extra: current, interval: teamItem.price.recurring?.interval || "month" });
      const want = Math.max(0, Math.min(20, Math.floor(Number(body.seats) || 0)));
      if (want === current) return out({ extra: current });
      let change: Stripe.SubscriptionUpdateParams.Item[];
      if (techItem && want === 0) change = [{ id: techItem.id, deleted: true }];
      else if (techItem) change = [{ id: techItem.id, quantity: want }];
      else {
        const tech = await findPrice("tech", (teamItem.price.recurring?.interval as "month" | "year") || "month");
        if (!tech) return out({ error: "The extra technician price isn't set up in Stripe yet" }, 500);
        change = [{ price: tech.id, quantity: want }];
      }
      await stripe.subscriptions.update(live.id, { items: change, proration_behavior: "always_invoice" });
      return out({ extra: want });
    }
    if (body.action !== "checkout") return out({ error: "Unknown action" }, 400);

    const plan = body.plan === "team" ? "team" : "solo";
    const interval = body.interval === "year" ? "year" : "month";
    const main = await findPrice(plan, interval);
    if (!main) return out({ error: `The ${plan} ${interval}ly price isn't set up in Stripe yet` }, 500);
    const items: Stripe.Checkout.SessionCreateParams.LineItem[] = [{ price: main.id, quantity: 1 }];
    const extra = Math.max(0, Math.min(20, Math.floor(Number(body.seats) || 0)));
    if (plan === "team" && extra > 0) {
      const tech = await findPrice("tech", interval);
      if (!tech) return out({ error: "The extra technician price isn't set up in Stripe yet" }, 500);
      items.push({ price: tech.id, quantity: extra, adjustable_quantity: { enabled: true, minimum: 1, maximum: 20 } });
    }

    // Keep the rest of the free trial: first charge happens when the app trial ends.
    const { data: shop } = await db.from("shops").select("trial_ends").eq("id", shopId).maybeSingle();
    const trialEnd = shop?.trial_ends ? Math.floor(new Date(shop.trial_ends).getTime() / 1000) : 0;
    const subData: Stripe.Checkout.SessionCreateParams.SubscriptionData = { metadata: { shop_id: shopId } };
    if (trialEnd > Math.floor(Date.now() / 1000) + 2 * 86400) subData.trial_end = trialEnd;

    const session = await stripe.checkout.sessions.create({
      mode: "subscription",
      line_items: items,
      client_reference_id: shopId,
      ...(sub?.stripe_customer ? { customer: sub.stripe_customer } : { customer_email: user.email }),
      subscription_data: subData,
      allow_promotion_codes: true,
      success_url: ret + "?paid=1",
      cancel_url: ret,
    });
    return out({ url: session.url });
  } catch (e) {
    console.error(e);
    return out({ error: (e as Error).message || "Billing error" }, 500);
  }
});
