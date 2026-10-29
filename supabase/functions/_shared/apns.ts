// Apple push notifications (APNs) for the iPhone app.
// Needs Supabase secrets: APNS_KEY_P8 (the .p8 file's text), APNS_KEY_ID, APNS_TEAM_ID.
// Optional: APNS_TOPIC (defaults to the app's bundle ID).
// Without those secrets, iPhone-app phones are simply skipped.

export type PushMsg = { title: string; body: string; url?: string; tag?: string };

let cached: { jwt: string; at: number; kid: string } | null = null;

const b64u = (b: Uint8Array) => btoa(String.fromCharCode(...b)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const enc = (s: string) => new TextEncoder().encode(s);

export function apnsReady(): boolean {
  const env = (globalThis as any).Deno?.env;
  return !!(env?.get("APNS_KEY_P8") && env?.get("APNS_KEY_ID") && env?.get("APNS_TEAM_ID"));
}

// A signed token Apple accepts for up to an hour; reused for 45 minutes.
export async function apnsJwt(p8: string, kid: string, team: string, now = Date.now()): Promise<string> {
  if (cached && cached.kid === kid && now - cached.at < 45 * 60e3) return cached.jwt;
  const pem = p8.replace(/\\n/g, "\n").replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const head = b64u(enc(JSON.stringify({ alg: "ES256", kid })));
  const claims = b64u(enc(JSON.stringify({ iss: team, iat: Math.floor(now / 1000) })));
  const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, enc(`${head}.${claims}`)));
  const jwt = `${head}.${claims}.${b64u(sig)}`;
  cached = { jwt, at: now, kid };
  return jwt;
}

// Sends one notification. Returns "ok", "gone" (the phone removed the app: delete it) or "fail".
export async function apnsSend(token: string, msg: PushMsg): Promise<"ok" | "gone" | "fail"> {
  const env = (globalThis as any).Deno.env;
  const p8 = env.get("APNS_KEY_P8"), kid = env.get("APNS_KEY_ID"), team = env.get("APNS_TEAM_ID");
  if (!p8 || !kid || !team) return "fail";
  const topic = env.get("APNS_TOPIC") || "com.honestechmobileapp.app";
  const jwt = await apnsJwt(p8, kid, team);
  const body = JSON.stringify({ aps: { alert: { title: msg.title, body: msg.body }, sound: "default" }, url: msg.url || "./" });
  const headers: Record<string, string> = {
    authorization: `bearer ${jwt}`, "apns-topic": topic, "apns-push-type": "alert", "apns-priority": "10",
    "apns-expiration": String(Math.floor(Date.now() / 1000) + 86400), "content-type": "application/json",
  };
  if (msg.tag) headers["apns-collapse-id"] = msg.tag.slice(0, 64);
  // App Store and TestFlight phones use Apple's main server; builds run from Xcode use the sandbox one.
  for (const host of ["api.push.apple.com", "api.sandbox.push.apple.com"]) {
    const r = await fetch(`https://${host}/3/device/${encodeURIComponent(token)}`, { method: "POST", headers, body });
    if (r.ok) return "ok";
    const why = await r.json().then((j) => j?.reason || "").catch(() => "");
    if (r.status === 410 || why === "Unregistered") return "gone";
    if (why === "BadDeviceToken" && host === "api.push.apple.com") continue;
    console.error("apns failed", r.status, why);
    return "fail";
  }
  return "fail";
}
