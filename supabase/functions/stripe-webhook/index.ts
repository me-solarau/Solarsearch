// Stripe webhook — the source of truth for milestone state. Verifies the signature with
// STRIPE_WEBHOOK_SECRET, dedups on the Stripe event id, and reconciles the milestone row.
// No auth header (Stripe calls it); trust comes from the signature, not a JWT.
// Point this at:  https://<project>.functions.supabase.co/stripe-webhook
// and subscribe to: payment_intent.succeeded, payment_intent.payment_failed,
//                   charge.refunded, account.updated
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import Stripe from "npm:stripe@17";

const SB_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const STRIPE_KEY = Deno.env.get("STRIPE_SECRET_KEY");
const WH_SECRET = Deno.env.get("STRIPE_WEBHOOK_SECRET");

Deno.serve(async (req) => {
  const admin = createClient(SB_URL, SERVICE_KEY, { auth: { persistSession: false } });
  if (!STRIPE_KEY || !WH_SECRET) return new Response("stripe not configured", { status: 500 });
  const stripe = new Stripe(STRIPE_KEY, { apiVersion: "2024-12-18.acacia" });

  const sig = req.headers.get("stripe-signature");
  const raw = await req.text();
  let event: Stripe.Event;
  try {
    // constructEventAsync — Deno's crypto is async-only.
    event = await stripe.webhooks.constructEventAsync(raw, sig!, WH_SECRET);
  } catch (e) {
    return new Response(`bad signature: ${String((e as Error)?.message || e)}`, { status: 400 });
  }

  // Idempotency: first insert wins; a duplicate delivery no-ops.
  const { error: dupErr } = await admin.from("stripe_events")
    .insert({ id: event.id, type: event.type });
  if (dupErr) return new Response("duplicate", { status: 200 });

  try {
    switch (event.type) {
      case "payment_intent.succeeded": {
        const pi = event.data.object as Stripe.PaymentIntent;
        const mid = pi.metadata?.milestone_id;
        await admin.from("payment_milestones")
          .update({ status: "paid", paid_at: new Date().toISOString(), stripe_payment_intent_id: pi.id })
          .eq(mid ? "id" : "stripe_payment_intent_id", mid || pi.id);
        break;
      }
      case "payment_intent.payment_failed": {
        const pi = event.data.object as Stripe.PaymentIntent;
        const mid = pi.metadata?.milestone_id;
        await admin.from("payment_milestones")
          .update({ status: "failed" })
          .eq(mid ? "id" : "stripe_payment_intent_id", mid || pi.id);
        break;
      }
      case "charge.refunded": {
        const ch = event.data.object as Stripe.Charge;
        if (ch.payment_intent)
          await admin.from("payment_milestones")
            .update({ status: "refunded" })
            .eq("stripe_payment_intent_id", ch.payment_intent as string);
        break;
      }
      case "account.updated": {
        // Keep a light record of onboarding progress; the onboard function reads live status.
        // Nothing to persist beyond stripe_account_id (already stored); no-op for now.
        break;
      }
    }
  } catch (e) {
    // Don't 500 on a handled event — that makes Stripe retry a poison message forever.
    console.error("webhook handler error", event.type, String((e as Error)?.message || e));
  }
  return new Response("ok", { status: 200 });
});
