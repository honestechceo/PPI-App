// Sends a notification to a list of phones: web-app phones (web push) and iPhone-app phones (Apple push).
// iPhone-app phones are kept in push_subs with endpoint "apns:<device token>".
import webpush from "npm:web-push@3.6.7";
import { apnsReady, apnsSend, type PushMsg } from "./apns.ts";

export type { PushMsg };
type Sub = { endpoint: string; p256dh: string; auth: string };
type Keys = { public_key: string; private_key: string } | null;

// deno-lint-ignore no-explicit-any
export async function pushTo(db: any, subs: Sub[], keys: Keys, msg: PushMsg): Promise<number> {
  const clip = (s: unknown, n: number) => String(s ?? "").slice(0, n);
  const m: PushMsg = { title: clip(msg.title || "Honestech", 80), body: clip(msg.body, 240), url: clip(msg.url || "./", 300), tag: clip(msg.tag, 80) };
  if (keys) webpush.setVapidDetails("mailto:info@honestechservice.com", keys.public_key, keys.private_key);
  const payload = JSON.stringify(m);
  const drop = (endpoint: string) => db.from("push_subs").delete().eq("endpoint", endpoint);
  let sent = 0;
  await Promise.all(subs.map(async (s) => {
    try {
      if (s.endpoint.startsWith("apns:")) {
        if (!apnsReady()) return;
        const r = await apnsSend(s.endpoint.slice(5), m);
        if (r === "ok") sent++; else if (r === "gone") await drop(s.endpoint);
        return;
      }
      if (!keys) return;
      await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload, { TTL: 86400, urgency: "high" });
      sent++;
    } catch (e) {
      const code = (e as { statusCode?: number }).statusCode;
      if (code === 404 || code === 410) await drop(s.endpoint); else console.error("push failed", code ?? e);
    }
  }));
  return sent;
}
