// sms-inbound — Kudosity reply webhook ("Reply options → Forward to URL").
// Kudosity has no request signature, so we authenticate with a shared secret in
// the URL (?secret=…) that matches the SMS_INBOUND_SECRET function secret. Parses
// the customer's reply and drives the schedule state machine:
//   1|2|3            -> sms_confirm_visit + confirm SMS (+ schedule day-of reminder)
//   RESCHEDULE       -> sms_mark_reschedule + re-run sms-offer-windows
//   CANCEL           -> sms_release_assessment (lead back to pool)
//   STOP/UNSUBSCRIBE -> set customers.sms_opt_out
//   anything else    -> fallback reply
// Kudosity can't reply inline (no TwiML), so every reply is sent as a normal
// outbound message via sms-send. The confirm path calls SECURITY DEFINER RPCs
// granted to service_role only, so no browser can forge a confirmation.
//
// Set the number's Reply option "Forward to URL" to:
//   https://<project>.supabase.co/functions/v1/sms-inbound?secret=<SMS_INBOUND_SECRET>

import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const SB_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const INBOUND_SECRET = Deno.env.get("SMS_INBOUND_SECRET");

const normPhone = (n: string) => String(n || "").replace(/\D/g, "").slice(-9);

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
async function reply(to: string, body: string, assessment_id?: string | null, lead_id?: string | null, kind = "confirm") {
  if (!to || !body) return;
  await callFn("sms-send", { to, body, assessment_id: assessment_id ?? null, lead_id: lead_id ?? null, kind }).catch(() => {});
}
function fmtWhen(iso: string) {
  return new Date(iso).toLocaleString("en-AU", {
    weekday: "short", day: "numeric", month: "short", hour: "numeric", minute: "2-digit",
    timeZone: "Australia/Sydney",
  });
}
const ok = () => new Response("OK", { status: 200 });

Deno.serve(async (req) => {
  try {
    // gather params from query string AND body (Kudosity may GET or POST)
    const u = new URL(req.url);
    const params: Record<string, string> = {};
    u.searchParams.forEach((v, k) => { params[k] = v; });
    if (req.method === "POST") {
      const ct = req.headers.get("content-type") || "";
      if (ct.includes("application/json")) {
        const j = await req.json().catch(() => ({}));
        for (const k of Object.keys(j || {})) params[k] = String((j as Record<string, unknown>)[k] ?? "");
      } else {
        const raw = await req.text();
        new URLSearchParams(raw).forEach((v, k) => { params[k] = v; });
      }
    }

    // authenticate via shared secret
    if (!INBOUND_SECRET || params.secret !== INBOUND_SECRET) return new Response("forbidden", { status: 403 });

    const from = params.mobile || params.msisdn || params.from || "";
    const bodyRaw = (params.response || params.message || params.body || params.sms || "").trim();
    const upper = bodyRaw.toUpperCase();
    const fromDigits = normPhone(from);
    if (!from) return ok();

    // log inbound
    await sbFetch("sms_messages", { method: "POST", body: JSON.stringify({
      direction: "in", from_number: from, to_number: params.longcode || params.to || null,
      body: bodyRaw, twilio_sid: params.message_id ? String(params.message_id) : null,
      status: "received", kind: "inbound",
    }) }).catch(() => {});

    // STOP / opt-out (Kudosity also handles this on its side)
    if (/^(STOP|STOPALL|UNSUBSCRIBE|CANCEL ALL|END|QUIT)$/.test(upper)) {
      const custs = await (await sbFetch(`customers?select=id,mobile`)).json().catch(() => []);
      const ids = (custs || []).filter((c: { mobile?: string }) => normPhone(c.mobile || "") === fromDigits).map((c: { id: string }) => c.id);
      for (const id of ids) await sbFetch(`customers?id=eq.${id}`, { method: "PATCH", body: JSON.stringify({ sms_opt_out: true }) });
      return ok();
    }

    // find this number's open offer
    const rows = await (await sbFetch(
      `assessments?schedule_state=in.(offered,reschedule,confirmed)&status=in.(claimed,scheduled)` +
      `&select=id,lead_id,offered_windows,schedule_state,status,leads(customers(id,mobile,full_name))&order=claimed_at.desc`
    )).json().catch(() => []);
    const match = (Array.isArray(rows) ? rows : []).find(
      (r: any) => normPhone(r.leads?.customers?.mobile || "") === fromDigits,
    );
    if (!match) { await reply(from, "Thanks — we couldn't match this to a booking. We'll call you shortly.", null, null, "fallback"); return ok(); }

    const wins: { iso: string; label: string }[] = match.offered_windows || [];
    const first = (match.leads?.customers?.full_name || "").split(" ")[0];

    if (/^(CANCEL|NO|NOT INTERESTED)$/.test(upper)) {
      await rpc("sms_release_assessment", { p_assessment_id: match.id, p_reason: "customer_cancel" });
      await reply(from, "No problem — your visit is cancelled. Reply anytime to rebook.", match.id, match.lead_id, "cancel");
      return ok();
    }
    if (/^(RESCHEDULE|OTHER|DIFFERENT|CHANGE)$/.test(upper)) {
      await rpc("sms_mark_reschedule", { p_assessment_id: match.id });
      const r = await callFn("sms-offer-windows", { assessment_id: match.id });
      if (!r.ok) await reply(from, "We'll text you fresh times shortly.", match.id, match.lead_id, "reschedule");
      return ok();
    }
    const num = upper.match(/^([1-9])\b/);
    const chosen = num ? wins[Number(num[1]) - 1] : undefined;
    if (chosen) {
      const res = await rpc("sms_confirm_visit", { p_assessment_id: match.id, p_scheduled_at: chosen.iso });
      if (!res.ok) { await reply(from, "Sorry — that slot just closed. Reply RESCHEDULE for fresh times.", match.id, match.lead_id, "confirm"); return ok(); }
      // day-of reminder as a scheduled send (~3h before, if >15 min out)
      const visit = new Date(chosen.iso);
      const remind = new Date(visit); remind.setHours(remind.getHours() - 3);
      if (remind > new Date(Date.now() + 16 * 60 * 1000)) {
        await callFn("sms-send", {
          to: from, assessment_id: match.id, lead_id: match.lead_id, kind: "reminder",
          send_at: remind.toISOString(),
          body: `Reminder${first ? " " + first : ""}: your Solarsearch home assessment is today at ${fmtWhen(chosen.iso)}. Reply RESCHEDULE if the time no longer suits.`,
        });
        await sbFetch(`assessments?id=eq.${match.id}`, { method: "PATCH", body: JSON.stringify({ reminder_sent_at: new Date().toISOString() }) });
      }
      await reply(from, `Confirmed${first ? " " + first : ""}! Your assessment is booked for ${fmtWhen(chosen.iso)}. See you then.`, match.id, match.lead_id, "confirm");
      return ok();
    }

    await reply(from, "Thanks! To confirm reply with a number (1, 2 or 3). Reply RESCHEDULE for other times or CANCEL to release.", match.id, match.lead_id, "fallback");
    return ok();
  } catch (e) {
    console.error("sms-inbound (kudosity) error", e);
    return ok(); // never error back to the provider
  }
});
