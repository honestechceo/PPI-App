// Supabase Edge Function: notify
// Sends phone notifications to people in the same shop (for example, "New job assigned").
// Deploy with "Verify JWT" OFF (it checks the signed-in user itself). Web-app phones need no secrets:
// notification keys are created on first use and kept in the push_keys table.
// iPhone-app phones use Apple push, which needs APNS_KEY_P8, APNS_KEY_ID and APNS_TEAM_ID (see _shared/apns.ts).
import webpush from "npm:web-push@3.6.7";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";
import { pushTo } from "../_shared/push.ts";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const out = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...CORS, "Content-Type": "application/json" } });
const clip = (s: unknown, n: number) => String(s ?? "").slice(0, n);

async function keys() {
  const { data } = await db.from("push_keys").select("public_key, private_key").eq("id", 1).maybeSingle();
  if (data) return data;
  const k = webpush.generateVAPIDKeys();
  await db.from("push_keys").upsert({ id: 1, public_key: k.publicKey, private_key: k.privateKey }, { onConflict: "id", ignoreDuplicates: true });
  const { data: again } = await db.from("push_keys").select("public_key, private_key").eq("id", 1).single();
  return again!;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return out({ error: "POST only" }, 405);
  try {
    const body = await req.json().catch(() => ({}));
    const k = await keys();
    if (body.action === "key") return out({ key: k.public_key });

    const token = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
    const { data: ud } = await db.auth.getUser(token);
    const me = ud?.user;
    if (!me) return out({ error: "Please sign in again" }, 401);
    if (body.action !== "send") return out({ error: "Unknown action" }, 400);

    // the caller's shop (newest membership, same as the app)
    const { data: mem } = await db.from("shop_members").select("shop_id, role").eq("user_id", me.id).order("created_at", { ascending: false }).limit(1).maybeSingle();
    if (!mem) return out({ error: "No shop" }, 400);
    const { data: members } = await db.from("shop_members").select("user_id, role").eq("shop_id", mem.shop_id);
    const inShop = new Set((members || []).map((m) => m.user_id));
    let targets: string[] = [];
    if (body.self) targets = [me.id];
    else if (body.to === "managers") targets = (members || []).filter((m) => m.role === "owner" || m.role === "admin").map((m) => m.user_id);
    else targets = (Array.isArray(body.user_ids) ? body.user_ids : []).map(String);
    targets = [...new Set(targets)].filter((u) => inShop.has(u) && (body.self || u !== me.id)).slice(0, 20);
    if (!targets.length) return out({ sent: 0 });

    const { data: subs } = await db.from("push_subs").select("endpoint, p256dh, auth, user_id").in("user_id", targets);
    const sent = await pushTo(db, subs || [], k, { title: clip(body.title || "Honestech", 80), body: clip(body.body, 240), url: clip(body.url || "./", 300), tag: clip(body.tag, 80) });
    return out({ sent, phones: (subs || []).length });
  } catch (e) {
    console.error(e);
    return out({ error: (e as Error).message || "Notify error" }, 500);
  }
});
