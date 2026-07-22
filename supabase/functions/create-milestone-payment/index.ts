// Charge one milestone (deposit 10% / completion 60% / stc 30%) for an install.
// Destination charge: Solarsearch collects, the connected account (installer OR, on the
// subcontract pipeline, the subcontractor) receives the slice, and application_fee_amount
// = Solarsearch's commission on that slice. Returns a PaymentIntent client_secret for the
// payer's checkout. The webhook flips the milestone to 'paid' on success.
//
// The milestone row must already exist (build_payment_milestones) and the receiving party
// must have finished Stripe onboarding (charges_enabled). Admin-only trigger — money moves
// only when HQ (or an automated event handler) explicitly calls this.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import Stripe from "npm:stripe@17";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const SB_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const STRIPE_KEY = Deno.env.get("STRIPE_SECRET_KEY");

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const json = (b: unknown, s = 200) =>
    new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });

  if (!STRIPE_KEY) return json({ error: "STRIPE_SECRET_KEY not configured" }, 500);
  const stripe = new Stripe(STRIPE_KEY, { apiVersion: "2024-12-18.acacia" });
  const admin = createClient(SB_URL, SERVICE_KEY, { auth: { persistSession: false } });

  try {
    const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    if (!jwt) return json({ error: "unauthenticated" }, 401);
    const { data: u } = await admin.auth.getUser(jwt);
    const uid = u?.user?.id;
    if (!uid) return json({ error: "unauthenticated" }, 401);
    const { data: role } = await admin.from("user_roles").select("role").eq("user_id", uid).maybeSingle();
    if (role?.role !== "admin") return json({ error: "admin only" }, 403);

    const { install_id, milestone } = await req.json().catch(() => ({}));
    if (!install_id || !milestone) return json({ error: "install_id and milestone required" }, 400);
    if (!["deposit", "completion", "stc"].includes(milestone))
      return json({ error: "milestone must be deposit|completion|stc" }, 400);

    const { data: pm } = await admin.from("payment_milestones")
      .select("id, amount_cents, application_fee_cents, status, stripe_payment_intent_id")
      .eq("install_id", install_id).eq("milestone", milestone).maybeSingle();
    if (!pm) return json({ error: "milestone row not found — build_payment_milestones first" }, 404);
    if (pm.status === "paid") return json({ error: "already paid" }, 409);

    // Who receives this slice: subcontractor pipeline -> the installer doing the work.
    const { data: inst } = await admin.from("installs")
      .select("id, pipeline, installer_id, retailer_id, job_value_cents").eq("id", install_id).maybeSingle();
    if (!inst) return json({ error: "install not found" }, 404);

    const { data: installer } = await admin.from("installers")
      .select("id, stripe_account_id").eq("id", inst.installer_id).maybeSingle();
    const dest = installer?.stripe_account_id;
    if (!dest) return json({ error: "installer has not completed Stripe onboarding" }, 409);

    const pi = await stripe.paymentIntents.create({
      amount: pm.amount_cents,
      currency: "aud",
      automatic_payment_methods: { enabled: true },
      application_fee_amount: pm.application_fee_cents || undefined,
      transfer_data: { destination: dest },
      metadata: { install_id, milestone, milestone_id: pm.id },
    }, { idempotencyKey: `pm_${pm.id}` });

    await admin.from("payment_milestones")
      .update({ status: "processing", stripe_payment_intent_id: pi.id })
      .eq("id", pm.id);

    return json({
      milestone_id: pm.id,
      amount_cents: pm.amount_cents,
      application_fee_cents: pm.application_fee_cents,
      payment_intent_id: pi.id,
      client_secret: pi.client_secret,
    });
  } catch (e) {
    return json({ error: String((e as Error)?.message || e) }, 500);
  }
});
