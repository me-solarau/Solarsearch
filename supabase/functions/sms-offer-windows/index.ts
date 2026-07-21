// sms-offer-windows — proposes 2–3 route-efficient visit windows to the customer
// by SMS. Called automatically after grab_job (or from an HQ/tech "text customer"
// action). Computes windows server-side via the technician_windows RPC, stores
// them on the assessment (schedule_state='offered'), and texts the intro:
// tech first name + trust-badge link + numbered windows + reply instructions.
//
// POST { assessment_id }  (caller must be admin or the owning technician)
// Auth: forwards the caller's JWT to enforce role; the heavy lifting is
// service-role (RPC + assessment update + send).

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const SB_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const BADGE_BASE = Deno.env.get("PUBLIC_SITE_URL") || "https://solarsearch.com.au";
const CONSENT_VERSION = "v1-lead-capture";

async function callSmsSend(payload: Record<string, unknown>) {
  const res = await fetch(`${SB_URL}/functions/v1/sms-send`, {
    method: "POST",
    headers: { Authorization: `Bearer ${SERVICE_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });
  return { ok: res.ok, body: await res.json().catch(() => ({})) };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const json = (b: unknown, s = 200) =>
    new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });
  const admin = createClient(SB_URL, SERVICE_KEY, { auth: { persistSession: false } });

  try {
    const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    if (!jwt) return json({ error: "unauthenticated" }, 401);
    // Internal callers (sms-inbound RESCHEDULE) pass the service-role key.
    const isService = jwt === SERVICE_KEY;
    let uid: string | undefined;
    if (!isService) {
      const { data: u } = await admin.auth.getUser(jwt);
      uid = u?.user?.id;
      if (!uid) return json({ error: "unauthenticated" }, 401);
    }

    const { assessment_id } = await req.json().catch(() => ({}));
    if (!assessment_id) return json({ error: "assessment_id required" }, 400);

    // authorise: service-role, admin, or the technician who owns this assessment
    const { data: role } = isService ? { data: null } : await admin.from("user_roles").select("role").eq("user_id", uid).maybeSingle();
    const { data: a } = await admin.from("assessments")
      .select("id,lead_id,sales_rep_id,status,leads(customer_id,customers(full_name,mobile,sms_opt_out)),sales_reps!inner(id,user_id,full_name)")
      .eq("id", assessment_id).maybeSingle();
    if (!a) return json({ error: "assessment not found" }, 404);
    const isOwner = a.sales_reps?.user_id === uid;
    if (!isService && role?.role !== "admin" && !isOwner) return json({ error: "not your job" }, 403);
    if (!["claimed", "scheduled"].includes(a.status)) return json({ error: `cannot offer from status ${a.status}` }, 409);

    const cust = a.leads?.customers;
    if (cust?.sms_opt_out) return json({ error: "customer opted out of SMS" }, 409);
    const mobile = cust?.mobile;
    if (!mobile) return json({ error: "no mobile on file — offer by phone" }, 422);

    // server-side windows
    const { data: windows, error: wErr } = await admin.rpc("technician_windows", { p_assessment_id: assessment_id });
    if (wErr) return json({ error: "window generation failed: " + wErr.message }, 500);
    const wins: { iso: string; label: string; cluster: boolean }[] = windows || [];
    if (!wins.length) return json({ error: "no windows available — set availability or offer by phone" }, 422);

    // store the offer on the assessment
    await admin.from("assessments").update({
      offered_windows: wins, schedule_state: "offered", sms_consent_version: CONSENT_VERSION,
    }).eq("id", assessment_id);

    const techFirst = (a.sales_reps?.full_name || "your technician").split(" ")[0];
    const badge = `${BADGE_BASE}/tech-badge.html?rep=${a.sales_rep_id}`;
    const lines = wins.map((w, i) => `${i + 1}. ${w.label}`).join("\n");
    const body =
      `Hi${cust?.full_name ? " " + String(cust.full_name).split(" ")[0] : ""}, it's Solarsearch. ` +
      `${techFirst} will do your free home assessment. Reply with a number to lock in a time:\n${lines}\n` +
      `Or reply RESCHEDULE for other times, CANCEL to release, STOP to opt out.\n` +
      `Who's knocking: ${badge}`;

    const sent = await callSmsSend({
      to: mobile, body, lead_id: a.lead_id, assessment_id, kind: "offer",
    });
    if (!sent.ok) return json({ error: "send failed", detail: sent.body }, 502);
    return json({ ok: true, windows: wins, sms: sent.body });
  } catch (e) {
    return json({ error: String((e as Error).message || e) }, 500);
  }
});
