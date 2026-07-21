// sms-eta — the "On my way" text. The technician taps On-my-way in tech.html
// once they leave for the visit; this texts the customer an ETA and stamps
// eta_sent_at. Owner-tech or admin only.
//
// POST { assessment_id, eta_minutes? }

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

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const json = (b: unknown, s = 200) =>
    new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });
  const admin = createClient(SB_URL, SERVICE_KEY, { auth: { persistSession: false } });

  try {
    const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    if (!jwt) return json({ error: "unauthenticated" }, 401);
    const { data: u } = await admin.auth.getUser(jwt);
    const uid = u?.user?.id;
    if (!uid) return json({ error: "unauthenticated" }, 401);

    const { assessment_id, eta_minutes } = await req.json().catch(() => ({}));
    if (!assessment_id) return json({ error: "assessment_id required" }, 400);

    const { data: role } = await admin.from("user_roles").select("role").eq("user_id", uid).maybeSingle();
    const { data: a } = await admin.from("assessments")
      .select("id,lead_id,eta_sent_at,leads(customers(mobile,full_name,sms_opt_out)),sales_reps(user_id,full_name)")
      .eq("id", assessment_id).maybeSingle();
    if (!a) return json({ error: "assessment not found" }, 404);
    const isOwner = (a as any).sales_reps?.user_id === uid;
    if (role?.role !== "admin" && !isOwner) return json({ error: "not your job" }, 403);

    const cust = (a as any).leads?.customers;
    if (!cust?.mobile) return json({ error: "no mobile on file" }, 422);
    if (cust.sms_opt_out) return json({ error: "customer opted out" }, 409);

    const first = (cust.full_name || "").split(" ")[0];
    const techFirst = ((a as any).sales_reps?.full_name || "Your technician").split(" ")[0];
    const eta = Number(eta_minutes);
    const when = Number.isFinite(eta) && eta > 0 ? `about ${eta} min away` : "on the way now";
    const body = `Hi${first ? " " + first : ""}, ${techFirst} from Solarsearch is ${when} for your home assessment. See you soon!`;

    const sent = await callSmsSend({ to: cust.mobile, lead_id: a.lead_id, assessment_id, kind: "eta", body });
    if (!sent.ok) return json({ error: "send failed", detail: sent.body }, 502);
    await admin.from("assessments").update({ eta_sent_at: new Date().toISOString() }).eq("id", assessment_id);
    return json({ ok: true });
  } catch (e) {
    return json({ error: String((e as Error).message || e) }, 500);
  }
});
