// sms-reminder — day-of reminder safety net. The primary path schedules the
// reminder as a Twilio Scheduled Message at confirm time (see sms-inbound); this
// function is the fallback/manual trigger and the idempotent backstop: it texts
// any confirmed visit happening today that has no reminder_sent_at yet.
//
// POST {}                    -> scan today's (Australia/Sydney) confirmed visits
// POST { assessment_id }     -> remind that one
// Auth: service-role bearer (a scheduler) or an admin JWT.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const SB_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

async function callSmsSend(payload: Record<string, unknown>) {
  const res = await fetch(`${SB_URL}/functions/v1/sms-send`, {
    method: "POST",
    headers: { Authorization: `Bearer ${SERVICE_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });
  return { ok: res.ok, body: await res.json().catch(() => ({})) };
}
function fmtWhen(iso: string) {
  return new Date(iso).toLocaleString("en-AU", {
    weekday: "short", day: "numeric", month: "short", hour: "numeric", minute: "2-digit",
    timeZone: "Australia/Sydney",
  });
}
function sydneyDayBounds() {
  const parts = new Intl.DateTimeFormat("en-CA", {
    year: "numeric", month: "2-digit", day: "2-digit", timeZone: "Australia/Sydney",
  }).format(new Date()); // YYYY-MM-DD
  // Sydney is UTC+10/+11; use a generous UTC window covering the local day.
  const start = new Date(`${parts}T00:00:00+11:00`).toISOString();
  const end = new Date(`${parts}T23:59:59+10:00`).toISOString();
  return { start, end };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const json = (b: unknown, s = 200) =>
    new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });
  const admin = createClient(SB_URL, SERVICE_KEY, { auth: { persistSession: false } });

  try {
    const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    const isService = jwt === SERVICE_KEY;
    if (!isService) {
      const { data: u } = await admin.auth.getUser(jwt);
      const uid = u?.user?.id;
      const { data: role } = uid ? await admin.from("user_roles").select("role").eq("user_id", uid).maybeSingle() : { data: null };
      if (role?.role !== "admin") return json({ error: "admin or service only" }, 403);
    }

    const { assessment_id } = await req.json().catch(() => ({}));
    let q = admin.from("assessments")
      .select("id,lead_id,scheduled_at,reminder_sent_at,schedule_state,status,leads(customers(mobile,full_name,sms_opt_out))")
      .eq("schedule_state", "confirmed").eq("status", "scheduled").is("reminder_sent_at", null);
    if (assessment_id) q = admin.from("assessments")
      .select("id,lead_id,scheduled_at,reminder_sent_at,schedule_state,status,leads(customers(mobile,full_name,sms_opt_out))")
      .eq("id", assessment_id);
    else {
      const { start, end } = sydneyDayBounds();
      q = q.gte("scheduled_at", start).lte("scheduled_at", end);
    }

    const { data: rows } = await q;
    const out: unknown[] = [];
    for (const a of rows || []) {
      const cust = (a as any).leads?.customers;
      if (!cust?.mobile || cust.sms_opt_out || !a.scheduled_at) continue;
      const first = (cust.full_name || "").split(" ")[0];
      const sent = await callSmsSend({
        to: cust.mobile, lead_id: a.lead_id, assessment_id: a.id, kind: "reminder",
        body: `Reminder${first ? " " + first : ""}: your Solarsearch home assessment is today at ${fmtWhen(a.scheduled_at)}. Reply RESCHEDULE if the time no longer suits.`,
      });
      if (sent.ok) await admin.from("assessments").update({ reminder_sent_at: new Date().toISOString() }).eq("id", a.id);
      out.push({ assessment_id: a.id, ok: sent.ok });
    }
    return json({ ok: true, reminded: out.length, detail: out });
  } catch (e) {
    return json({ error: String((e as Error).message || e) }, 500);
  }
});
