// Stripe Connect onboarding for a money-receiving party (installer or retailer).
// Creates an Express connected account if they don't have one, stores stripe_account_id,
// and returns a hosted Account Link the caller opens to complete KYC + bank details.
// Test mode: uses whatever STRIPE_SECRET_KEY is set (sk_test_... in sandbox).
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
// Where Stripe returns the user after onboarding (your deployed site).
const SITE_URL = Deno.env.get("PUBLIC_SITE_URL") || "https://www.solarsearch.com.au";

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

    // Which party is this — installer or retailer? Look up by the signed-in user.
    const body = await req.json().catch(() => ({}));
    let party = body?.party as string | undefined; // optional hint: 'installer' | 'retailer'

    // installers link to the auth user via auth_uid; retailers via user_id.
    const { data: inst } = await admin.from("installers")
      .select("id, contact_email, stripe_account_id").eq("auth_uid", uid).maybeSingle();
    const { data: ret } = await admin.from("retailers")
      .select("id, contact_email, stripe_account_id").eq("user_id", uid).maybeSingle();

    let table: "installers" | "retailers";
    let row: { id: string; contact_email: string | null; stripe_account_id: string | null };
    if (party === "installer" && inst) { table = "installers"; row = inst; }
    else if (party === "retailer" && ret) { table = "retailers"; row = ret; }
    else if (inst) { table = "installers"; row = inst; }
    else if (ret) { table = "retailers"; row = ret; }
    else return json({ error: "no installer or retailer record for this user" }, 403);

    // Create the connected account once, then reuse.
    let acctId = row.stripe_account_id;
    if (!acctId) {
      const acct = await stripe.accounts.create({
        type: "express",
        country: "AU",
        email: row.contact_email || u?.user?.email || undefined,
        capabilities: { transfers: { requested: true }, card_payments: { requested: true } },
        business_type: "company",
        metadata: { party: table, party_id: row.id },
      });
      acctId = acct.id;
      await admin.from(table).update({ stripe_account_id: acctId }).eq("id", row.id);
    }

    const link = await stripe.accountLinks.create({
      account: acctId,
      refresh_url: `${SITE_URL}/stripe-return.html?state=refresh`,
      return_url: `${SITE_URL}/stripe-return.html?state=done`,
      type: "account_onboarding",
    });

    // Report where they are in KYC so the UI can show "connected" vs "finish setup".
    const acct = await stripe.accounts.retrieve(acctId);
    return json({
      party: table,
      stripe_account_id: acctId,
      onboarding_url: link.url,
      charges_enabled: acct.charges_enabled,
      payouts_enabled: acct.payouts_enabled,
      details_submitted: acct.details_submitted,
    });
  } catch (e) {
    return json({ error: String((e as Error)?.message || e) }, 500);
  }
});
