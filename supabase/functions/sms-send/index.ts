// sms-send — the single outbound SMS point. Every other SMS function calls this
// so there is exactly one place that talks to Twilio and one place that writes
// the sms_messages log (dispute protection, §6). Service-role: it trusts its
// caller (other Edge Functions / admin), looks up nothing about ownership.
//
// POST { to, body, lead_id?, assessment_id?, kind?, send_at? }
//   send_at (ISO 8601, 15min–7d out) -> Twilio Scheduled Message (ScheduleType=fixed)
//
// Honours per-customer STOP opt-out (never texts an opted-out number) and a
// quiet-hours guard (no live sends 21:00–08:00 Australia/Sydney; scheduled
// sends are exempt — Twilio holds them to SendAt).
//
// Secrets: TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_MESSAGING_SERVICE_SID
// (or TWILIO_FROM_NUMBER). SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY injected.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const SB_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const TWILIO_SID = Deno.env.get("TWILIO_ACCOUNT_SID");
const TWILIO_TOKEN = Deno.env.get("TWILIO_AUTH_TOKEN");
const MSG_SVC = Deno.env.get("TWILIO_MESSAGING_SERVICE_SID");
const FROM_NUMBER = Deno.env.get("TWILIO_FROM_NUMBER");

// last-9-digits normaliser so +61412…, 0412…, 412… compare equal
export function normPhone(n: string) {
  return String(n || "").replace(/\D/g, "").slice(-9);
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
  // 21:00–07:59 Australia/Sydney
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
  if (!TWILIO_SID || !TWILIO_TOKEN || (!MSG_SVC && !FROM_NUMBER)) {
    return { ok: false, status: 503, error: "twilio not configured" };
  }
  // opt-out gate: has any customer on this number said STOP?
  const digits = normPhone(opts.to);
  if (digits) {
    const rows = await (await sbFetch(
      `customers?sms_opt_out=eq.true&select=mobile`
    )).json().catch(() => []);
    if (Array.isArray(rows) && rows.some((r: { mobile?: string }) => normPhone(r.mobile || "") === digits)) {
      return { ok: false, status: 403, error: "recipient opted out" };
    }
  }
  const scheduled = !!opts.send_at;
  if (!scheduled && inQuietHours()) {
    return { ok: false, status: 425, error: "quiet hours — send deferred" };
  }

  const form = new URLSearchParams();
  form.set("To", opts.to);
  form.set("Body", opts.body);
  if (MSG_SVC) form.set("MessagingServiceSid", MSG_SVC);
  else form.set("From", FROM_NUMBER!);
  if (scheduled) {
    if (!MSG_SVC) return { ok: false, status: 400, error: "scheduled send needs a Messaging Service" };
    form.set("ScheduleType", "fixed");
    form.set("SendAt", opts.send_at!);
  }

  const auth = btoa(`${TWILIO_SID}:${TWILIO_TOKEN}`);
  const res = await fetch(
    `https://api.twilio.com/2010-04-01/Accounts/${TWILIO_SID}/Messages.json`,
    { method: "POST", headers: { Authorization: `Basic ${auth}`, "Content-Type": "application/x-www-form-urlencoded" }, body: form },
  );
  const data = await res.json().catch(() => ({}));
  await logSms({
    lead_id: opts.lead_id ?? null, assessment_id: opts.assessment_id ?? null,
    direction: "out", to_number: opts.to, from_number: MSG_SVC || FROM_NUMBER,
    body: opts.body, twilio_sid: data?.sid ?? null,
    status: res.ok ? (scheduled ? "scheduled" : (data?.status ?? "sent")) : "failed",
    kind: opts.kind ?? "out",
  });
  if (!res.ok) return { ok: false, status: 502, error: data?.message || "twilio send failed" };
  return { ok: true, sid: data?.sid, status: data?.status };
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
