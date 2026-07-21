// sms-inbound — the Twilio inbound webhook and the conversational engine.
// Twilio POSTs (application/x-www-form-urlencoded) every customer reply here.
// We validate X-Twilio-Signature so only Twilio can drive scheduling, match the
// number to an open offer, and act:
//   1|2|3 (or a matched time) -> sms_confirm_visit + confirm SMS (+ schedule the
//                                day-of reminder as a Twilio Scheduled Message)
//   RESCHEDULE                 -> sms_mark_reschedule + re-run sms-offer-windows
//   CANCEL                     -> sms_release_assessment (lead returns to pool)
//   STOP/UNSUBSCRIBE           -> set customers.sms_opt_out, never message again
//   anything else              -> fallback reply + leave for HQ to phone
// Reply is TwiML so Twilio delivers our confirmation in-thread.
//
// Set the Messaging Service inbound webhook to this function's URL. Because the
// confirm path calls SECURITY DEFINER RPCs granted to service_role only, no
// browser can forge a confirmation.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const SB_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const TWILIO_TOKEN = Deno.env.get("TWILIO_AUTH_TOKEN")!;
const WEBHOOK_URL_OVERRIDE = Deno.env.get("SMS_INBOUND_URL"); // set if a proxy rewrites the URL

const normPhone = (n: string) => String(n || "").replace(/\D/g, "").slice(-9);

// Twilio signature: base64( HMAC-SHA1( authToken, url + sorted(key+value)... ) )
async function validSignature(url: string, params: Record<string, string>, sig: string) {
  if (!sig) return false;
  const data = url + Object.keys(params).sort().map((k) => k + params[k]).join("");
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(TWILIO_TOKEN),
    { name: "HMAC", hash: "SHA-1" }, false, ["sign"],
  );
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(data));
  const b64 = btoa(String.fromCharCode(...new Uint8Array(mac)));
  // constant-time-ish compare
  if (b64.length !== sig.length) return false;
  let diff = 0;
  for (let i = 0; i < b64.length; i++) diff |= b64.charCodeAt(i) ^ sig.charCodeAt(i);
  return diff === 0;
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
async function rpc(fn: string, args: Record<string, unknown>) {
  return fetch(`${SB_URL}/rest/v1/rpc/${fn}`, {
    method: "POST",
    headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify(args),
  });
}
async function callFn(name: string, payload: Record<string, unknown>) {
  return fetch(`${SB_URL}/functions/v1/${name}`, {
    method: "POST",
    headers: { Authorization: `Bearer ${SERVICE_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });
}

function twiml(msg?: string) {
  const body = msg
    ? `<Response><Message>${msg.replace(/[<&>]/g, (c) => ({ "<": "&lt;", "&": "&amp;", ">": "&gt;" }[c]!))}</Message></Response>`
    : `<Response></Response>`;
  return new Response(body, { status: 200, headers: { "Content-Type": "text/xml" } });
}
function fmtWhen(iso: string) {
  return new Date(iso).toLocaleString("en-AU", {
    weekday: "short", day: "numeric", month: "short", hour: "numeric", minute: "2-digit",
    timeZone: "Australia/Sydney",
  });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("method not allowed", { status: 405 });
  try {
    const raw = await req.text();
    const params: Record<string, string> = {};
    new URLSearchParams(raw).forEach((v, k) => { params[k] = v; });

    // Reconstruct the exact URL Twilio signed (honour proxy headers).
    const proto = req.headers.get("x-forwarded-proto");
    const host = req.headers.get("x-forwarded-host") || req.headers.get("host");
    const u = new URL(req.url);
    const url = WEBHOOK_URL_OVERRIDE || (proto && host ? `${proto}://${host}${u.pathname}${u.search}` : req.url);

    const sig = req.headers.get("X-Twilio-Signature") || "";
    if (!(await validSignature(url, params, sig))) return new Response("invalid signature", { status: 403 });

    const from = params.From || "";
    const bodyRaw = (params.Body || "").trim();
    const upper = bodyRaw.toUpperCase();
    const fromDigits = normPhone(from);

    // Log the inbound line first (dispute protection), regardless of parse.
    await sbFetch("sms_messages", { method: "POST", body: JSON.stringify({
      direction: "in", from_number: from, to_number: params.To || null, body: bodyRaw,
      twilio_sid: params.MessageSid || null, status: "received", kind: "inbound",
    }) }).catch(() => {});

    // STOP / opt-out (Twilio also enforces this at the carrier level).
    if (/^(STOP|STOPALL|UNSUBSCRIBE|CANCEL ALL|END|QUIT)$/.test(upper)) {
      const custs = await (await sbFetch(`customers?select=id,mobile`)).json().catch(() => []);
      const ids = (custs || []).filter((c: { mobile?: string }) => normPhone(c.mobile || "") === fromDigits).map((c: { id: string }) => c.id);
      for (const id of ids) await sbFetch(`customers?id=eq.${id}`, { method: "PATCH", body: JSON.stringify({ sms_opt_out: true }) });
      return twiml(); // Twilio sends the standard opt-out confirmation
    }

    // Find this number's open offer.
    const rows = await (await sbFetch(
      `assessments?schedule_state=in.(offered,reschedule,confirmed)&status=in.(claimed,scheduled)` +
      `&select=id,lead_id,offered_windows,schedule_state,status,leads(customers(id,mobile,full_name))&order=claimed_at.desc`
    )).json().catch(() => []);
    const match = (Array.isArray(rows) ? rows : []).find(
      (r: any) => normPhone(r.leads?.customers?.mobile || "") === fromDigits,
    );
    if (!match) return twiml("Thanks — we couldn't match this to a booking. We'll call you shortly.");

    const wins: { iso: string; label: string }[] = match.offered_windows || [];
    const first = (match.leads?.customers?.full_name || "").split(" ")[0];

    // CANCEL -> release the claim back to the pool.
    if (/^(CANCEL|NO|NOT INTERESTED)$/.test(upper)) {
      await rpc("sms_release_assessment", { p_assessment_id: match.id, p_reason: "customer_cancel" });
      return twiml("No problem — your visit is cancelled. Reply anytime to rebook.");
    }
    // RESCHEDULE -> fresh windows.
    if (/^(RESCHEDULE|OTHER|DIFFERENT|CHANGE)$/.test(upper)) {
      await rpc("sms_mark_reschedule", { p_assessment_id: match.id });
      const r = await callFn("sms-offer-windows", { assessment_id: match.id });
      if (r.ok) return twiml(); // offer function sends the new windows
      return twiml("We'll text you fresh times shortly.");
    }
    // Numbered choice 1|2|3.
    const num = upper.match(/^([1-9])\b/);
    let chosen: { iso: string; label: string } | undefined;
    if (num) chosen = wins[Number(num[1]) - 1];
    if (chosen) {
      const res = await rpc("sms_confirm_visit", { p_assessment_id: match.id, p_scheduled_at: chosen.iso });
      if (!res.ok) return twiml("Sorry — that slot just closed. Reply RESCHEDULE for fresh times.");
      // Day-of reminder as a Twilio Scheduled Message (fires 08:00 Sydney on visit day, if >15 min out).
      const visit = new Date(chosen.iso);
      const remind = new Date(visit); remind.setHours(remind.getHours() - 3);
      const nowPlus = new Date(Date.now() + 16 * 60 * 1000);
      if (remind > nowPlus) {
        await callFn("sms-send", {
          to: from, assessment_id: match.id, lead_id: match.lead_id, kind: "reminder",
          send_at: remind.toISOString(),
          body: `Reminder${first ? " " + first : ""}: your Solarsearch home assessment is today at ${fmtWhen(chosen.iso)}. Reply RESCHEDULE if the time no longer suits.`,
        });
        await sbFetch(`assessments?id=eq.${match.id}`, { method: "PATCH", body: JSON.stringify({ reminder_sent_at: new Date().toISOString() }) });
      }
      return twiml(`Confirmed${first ? " " + first : ""}! Your assessment is booked for ${fmtWhen(chosen.iso)}. See you then.`);
    }

    // Unparseable -> fallback + leave flagged (schedule_state stays 'offered' for HQ).
    return twiml(`Thanks! To confirm reply with a number (1, 2 or 3). Reply RESCHEDULE for other times or CANCEL to release. We'll also call if needed.`);
  } catch (e) {
    console.error("sms-inbound error", e);
    return twiml(); // never 500 back to Twilio; log and move on
  }
});
