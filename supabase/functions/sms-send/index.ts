// sms-send — the single outbound SMS point (Kudosity / Transmit SMS API).
// Every other SMS function calls this so there is exactly one place that talks
// to the provider and one place that writes the sms_messages log (§6).
//
// POST { to, body, lead_id?, assessment_id?, kind?, send_at? }
//   send_at (ISO 8601) -> scheduled send (Kudosity `send_at`, account-timezone).
//
// Honours per-customer STOP opt-out and a quiet-hours guard (no live sends
// 21:00–08:00 Australia/Sydney; scheduled sends are exempt).
//
// Secrets: KUDOSITY_API_KEY, KUDOSITY_API_SECRET, KUDOSITY_FROM_NUMBER,
// optional KUDOSITY_API_BASE (default https://api.transmitsms.com).
// SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY injected automatically.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const SB_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const K_KEY = Deno.env.get("KUDOSITY_API_KEY");
const K_SECRET = Deno.env.get("KUDOSITY_API_SECRET");
const K_FROM = Deno.env.get("KUDOSITY_FROM_NUMBER");
const K_BASE = (Deno.env.get("KUDOSITY_API_BASE") || "https://api.transmitsms.com").replace(/\/+$/, "");

// last-9-digits normaliser so +61412…, 0412…, 412… compare equal
export function normPhone(n: string) {
  return String(n || "").replace(/\D/g, "").slice(-9);
}
// to E.164-ish AU international (61XXXXXXXXX) that Kudosity expects
function toIntl(n: string) {
  let d = String(n || "").replace(/\D/g, "");
  if (d.startsWith("0")) d = "61" + d.slice(1);
  else if (d.length === 9) d = "61" + d;           // bare 4XXXXXXXX
  return d;
}
// ISO -> "YYYY-MM-DD HH:MM:SS" in Australia/Sydney (Kudosity send_at is account-tz)
function toKudosityWhen(iso: string) {
  const parts = new Intl.DateTimeFormat("en-CA", {
    year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", second: "2-digit",
    hour12: false, timeZone: "Australia/Sydney",
  }).formatToParts(new Date(iso));
  const g = (t: string) => parts.find((p) => p.type === t)?.value || "00";
  return `${g("year")}-${g("month")}-${g("day")} ${g("hour")}:${g("minute")}:${g("second")}`;
}

async function sbFetch(path: string, init: RequestInit = {}) {
  return fetch(`${SB_URL}/rest/v1/${path}`, {
    ...init,
    headers: {
      apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`,
      "Content-Type": "application/json", Prefer: "return=representation",
      ...(init.headers || {}),
    },
  });
}
function inQuietHours(): boolean {
  const h = Number(new Intl.DateTimeFormat("en-AU", {
    hour: "2-digit", hour12: false, timeZone: "Australia/Sydney",
  }).format(new Date()));
  return h >= 21 || h < 8;
}
async function logSms(row: Record<string, unknown>) {
  try { await sbFetch("sms_messages", { method: "POST", body: JSON.stringify(row) }); }
  catch (_) { /* logging must never block a send */ }
}

export async function sendSms(opts: {
  to: string; body: string; lead_id?: string | null; assessment_id?: string | null;
  kind?: string; send_at?: string | null;
}) {
  if (!K_KEY || !K_SECRET || !K_FROM) return { ok: false, status: 503, error: "kudosity not configured" };

  // opt-out gate
  const digits = normPhone(opts.to);
  if (digits) {
    const rows = await (await sbFetch(`customers?sms_opt_out=eq.true&select=mobile`)).json().catch(() => []);
    if (Array.isArray(rows) && rows.some((r: { mobile?: string }) => normPhone(r.mobile || "") === digits)) {
      return { ok: false, status: 403, error: "recipient opted out" };
    }
  }
  const scheduled = !!opts.send_at;
  if (!scheduled && inQuietHours()) return { ok: false, status: 425, error: "quiet hours — send deferred" };

  const form = new URLSearchParams();
  form.set("to", toIntl(opts.to));
  form.set("from", K_FROM);
  form.set("message", opts.body);
  if (scheduled) form.set("send_at", toKudosityWhen(opts.send_at!));

  const auth = btoa(`${K_KEY}:${K_SECRET}`);
  const res = await fetch(`${K_BASE}/send-sms.json`, {
    method: "POST",
    headers: { Authorization: `Basic ${auth}`, "Content-Type": "application/x-www-form-urlencoded" },
    body: form,
  });
  const data = await res.json().catch(() => ({}));
  const errCode = data?.error?.code;
  const ok = res.ok && (!errCode || errCode === "SUCCESS" || errCode === 0 || errCode === "0" || data?.message_id);

  await logSms({
    lead_id: opts.lead_id ?? null, assessment_id: opts.assessment_id ?? null,
    direction: "out", to_number: opts.to, from_number: K_FROM,
    body: opts.body, twilio_sid: data?.message_id ? String(data.message_id) : null,
    status: ok ? (scheduled ? "scheduled" : "sent") : "failed",
    kind: opts.kind ?? "out",
  });
  if (!ok) return { ok: false, status: 502, error: data?.error?.description || "kudosity send failed", detail: data };
  return { ok: true, sid: data?.message_id, status: scheduled ? "scheduled" : "sent" };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const json = (b: unknown, s = 200) =>
    new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });
  try {
    const b = await req.json().catch(() => ({}));
    if (!b.to || !b.body) return json({ error: "to and body required" }, 400);
    const r = await sendSms(b);
    return json(r, r.ok ? 200 : (r.status ?? 500));
  } catch (e) {
    return json({ error: String((e as Error).message || e) }, 500);
  }
});
