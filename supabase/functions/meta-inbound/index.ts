// meta-inbound — one webhook for Billy's Meta channels: Facebook Messenger
// (object "page") and WhatsApp Cloud API (object "whatsapp_business_account").
//
// GET  — Meta's verification handshake: echoes hub.challenge when
//        hub.verify_token matches MESSENGER_VERIFY_TOKEN.
// POST — signed events. X-Hub-Signature-256 (HMAC-SHA256 of the raw body with
//        META_APP_SECRET) is REQUIRED — unsigned or mis-signed posts are
//        rejected, so nobody can puppet Billy by forging events. Each text
//        message is forwarded to lead-agent as { channel_inbound }, which owns
//        thread/lead creation, Billy's reply, and all caps and guards.
//
// Attachments become [photo: …] lines (Messenger media URLs are direct;
// WhatsApp media needs a token fetch, so v1 records the media id).
// Echoes of our own sends (message.is_echo) and delivery/read events are
// ignored. Always answers 200 fast — Meta disables webhooks that error.
//
// Secrets: MESSENGER_VERIFY_TOKEN, META_APP_SECRET.
// SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY injected automatically.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const SB_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const VERIFY_TOKEN = Deno.env.get("MESSENGER_VERIFY_TOKEN");
const APP_SECRET = Deno.env.get("META_APP_SECRET");

const ok = (body = "OK") => new Response(body, { status: 200 });

async function callFn(name: string, payload: Record<string, unknown>) {
  return fetch(`${SB_URL}/functions/v1/${name}`, {
    method: "POST",
    headers: { Authorization: `Bearer ${SERVICE_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });
}

async function validSignature(raw: string, header: string | null): Promise<boolean> {
  if (!APP_SECRET || !header?.startsWith("sha256=")) return false;
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(APP_SECRET),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(raw));
  const hex = [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, "0")).join("");
  const given = header.slice(7).toLowerCase();
  if (hex.length !== given.length) return false;
  let diff = 0;
  for (let i = 0; i < hex.length; i++) diff |= hex.charCodeAt(i) ^ given.charCodeAt(i);
  return diff === 0;
}

Deno.serve(async (req) => {
  try {
    // --- Meta webhook verification handshake ---
    if (req.method === "GET") {
      const u = new URL(req.url);
      if (u.searchParams.get("hub.mode") === "subscribe" &&
          VERIFY_TOKEN && u.searchParams.get("hub.verify_token") === VERIFY_TOKEN) {
        return ok(u.searchParams.get("hub.challenge") || "");
      }
      // Admin diagnostic (gated by the same verify token): asks Meta which
      // WhatsApp number our secrets are bound to and whether this app is
      // subscribed to its WABA — the two usual reasons inbound stays silent.
      if (VERIFY_TOKEN && u.searchParams.get("diag") === VERIFY_TOKEN) {
        const waToken = Deno.env.get("WA_TOKEN") || "";
        const phoneId = Deno.env.get("WA_PHONE_NUMBER_ID") || "";
        const g = async (path: string) => {
          const r = await fetch(`https://graph.facebook.com/v21.0/${path}`, {
            headers: { Authorization: `Bearer ${waToken}` },
          });
          return { status: r.status, body: await r.json().catch(() => null) };
        };
        const num = phoneId ? await g(`${phoneId}?fields=display_phone_number,verified_name,code_verification_status,platform_type`) : { status: 0, body: "WA_PHONE_NUMBER_ID not set" };
        const me = await g("me?fields=id,name");
        const wabaId = u.searchParams.get("waba") || "";
        const subs = wabaId ? await g(`${wabaId}/subscribed_apps`) : null;
        // Is the Messenger page token still alive? (short-lived page tokens die overnight)
        const pageToken = Deno.env.get("META_PAGE_TOKEN") || "";
        const pageProbe = pageToken
          ? await (await fetch(`https://graph.facebook.com/v21.0/me?fields=id,name&access_token=${encodeURIComponent(pageToken)}`)).json().catch(() => null)
          : "META_PAGE_TOKEN not set";
        return new Response(JSON.stringify({ phone_number_id: phoneId ? "set" : "missing", wa_token: waToken ? "set" : "missing", number: num, token_owner: me, waba_subscribed_apps: subs, page_token_probe: pageProbe }), {
          status: 200, headers: { "Content-Type": "application/json" },
        });
      }
      return new Response("forbidden", { status: 403 });
    }
    if (req.method !== "POST") return ok();

    const raw = await req.text();
    const sigOk = await validSignature(raw, req.headers.get("x-hub-signature-256"));
    const objName = (() => { try { return String(JSON.parse(raw || "{}").object || ""); } catch { return "unparseable"; } })();
    // Trace every POST — delivery problems are invisible without this.
    fetch(`${SB_URL}/rest/v1/meta_webhook_log`, {
      method: "POST",
      headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, "Content-Type": "application/json" },
      body: JSON.stringify({ sig_ok: sigOk, object: objName, note: raw.slice(0, 500) }),
    }).catch(() => {});
    if (!sigOk) {
      console.warn("meta-inbound: bad or missing signature");
      return new Response("forbidden", { status: 403 });
    }
    const body = JSON.parse(raw || "{}");

    const forwards: Record<string, unknown>[] = [];

    if (body.object === "page") {
      for (const entry of body.entry || []) {
        for (const ev of entry.messaging || []) {
          const msg = ev.message;
          if (!msg || msg.is_echo) continue;
          const psid = ev.sender?.id;
          if (!psid) continue;
          let text = String(msg.text || "").trim();
          const media = (msg.attachments || [])
            .filter((a: { type?: string }) => a?.type === "image")
            .map((a: { payload?: { url?: string } }) => a?.payload?.url).filter(Boolean);
          if (media.length) text = (text + "\n" + media.map((u: string) => `[photo: ${u}]`).join("\n")).trim();
          if (!text) continue;
          forwards.push({ channel_inbound: { channel: "messenger", sender: String(psid), text } });
        }
      }
    } else if (body.object === "whatsapp_business_account") {
      for (const entry of body.entry || []) {
        for (const change of entry.changes || []) {
          const val = change.value || {};
          const names: Record<string, string> = {};
          for (const c of val.contacts || []) if (c?.wa_id) names[c.wa_id] = c?.profile?.name || "";
          for (const m of val.messages || []) {
            const from = m?.from;
            if (!from) continue;
            let text = "";
            if (m.type === "text") text = String(m.text?.body || "").trim();
            else if (m.type === "image") text = `[photo: whatsapp media ${m.image?.id || "unknown"}]`;
            else if (m.type === "button") text = String(m.button?.text || "").trim();
            else if (m.type === "interactive") text = String(m.interactive?.button_reply?.title || m.interactive?.list_reply?.title || "").trim();
            if (!text) continue;
            forwards.push({ channel_inbound: { channel: "whatsapp", sender: String(from), text, name: names[from] || "" } });
          }
        }
      }
    }

    // Fire-and-forget so Meta gets its 200 quickly; lead-agent owns the rest.
    for (const f of forwards) callFn("lead-agent", f).catch((e) => console.error("meta-inbound: forward failed", e));
    return ok();
  } catch (e) {
    console.error("meta-inbound error", e);
    return ok(); // never error back to Meta — they disable flapping webhooks
  }
});
