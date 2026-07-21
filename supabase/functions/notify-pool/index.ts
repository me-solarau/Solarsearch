// notify-pool — "ping, new job near you." When a lead becomes pool-eligible
// (booked a visit, state='appointment_set'), find every approved technician
// whose regions cover the suburb and web-push their devices. Called
// fire-and-forget from the booking path (index.html / solarsafe.html) and from
// an HQ "Ping available techs" action. Dead endpoints (410/404) are pruned.
//
// Secrets: VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT (mailto:/https:).
// SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY injected automatically.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const SB_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const VAPID_PUBLIC = Deno.env.get("VAPID_PUBLIC_KEY");
const VAPID_PRIVATE = Deno.env.get("VAPID_PRIVATE_KEY");
const VAPID_SUBJECT = Deno.env.get("VAPID_SUBJECT") || "mailto:hello@solarsearch.com.au";

if (VAPID_PUBLIC && VAPID_PRIVATE) {
  webpush.setVapidDetails(VAPID_SUBJECT, VAPID_PUBLIC, VAPID_PRIVATE);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const json = (b: unknown, s = 200) =>
    new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });
  const admin = createClient(SB_URL, SERVICE_KEY, { auth: { persistSession: false } });

  try {
    if (!VAPID_PUBLIC || !VAPID_PRIVATE) return json({ error: "web push not configured" }, 503);

    // Accept a service-role bearer (booking path) or an admin JWT (HQ button).
    const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    if (jwt !== SERVICE_KEY) {
      const { data: u } = await admin.auth.getUser(jwt);
      const uid = u?.user?.id;
      const { data: role } = uid ? await admin.from("user_roles").select("role").eq("user_id", uid).maybeSingle() : { data: null };
      if (role?.role !== "admin") return json({ error: "admin or service only" }, 403);
    }

    const { lead_id } = await req.json().catch(() => ({}));
    if (!lead_id) return json({ error: "lead_id required" }, 400);

    const { data: lead } = await admin.from("leads")
      .select("id,state,lead_type,sites(postcode,address)")
      .eq("id", lead_id).maybeSingle();
    if (!lead) return json({ error: "lead not found" }, 404);
    if (lead.state !== "appointment_set") return json({ ok: true, skipped: `state ${lead.state}` });

    const postcode = (lead as any).sites?.postcode;
    if (!postcode) return json({ ok: true, skipped: "no postcode" });
    const suburb = (String((lead as any).sites?.address || "").split(",").slice(-1)[0] || "").trim() || postcode;

    const { data: targets } = await admin.rpc("push_targets_for_postcode", { p_postcode: postcode });
    const rows: { endpoint: string; p256dh: string; auth: string; platform: string }[] = targets || [];
    if (!rows.length) return json({ ok: true, sent: 0, note: "no subscribed techs cover this postcode" });

    const payload = JSON.stringify({
      title: "New $50 job near you",
      body: `Assessment in ${suburb} — first to grab it wins.`,
      url: "/tech.html#pool",
      tag: "job-pool",
    });

    let sent = 0, pruned = 0;
    await Promise.all(rows.filter((r) => r.platform === "web").map(async (r) => {
      try {
        await webpush.sendNotification(
          { endpoint: r.endpoint, keys: { p256dh: r.p256dh, auth: r.auth } },
          payload,
        );
        sent++;
      } catch (e: any) {
        const code = e?.statusCode;
        if (code === 404 || code === 410) { await admin.rpc("prune_push_endpoint", { p_endpoint: r.endpoint }); pruned++; }
      }
    }));

    return json({ ok: true, sent, pruned, suburb });
  } catch (e) {
    return json({ error: String((e as Error).message || e) }, 500);
  }
});
