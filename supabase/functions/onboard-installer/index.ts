// Onboards an installer in one call: creates the installers row, an active
// price book, service-area postcodes, and provisions the login (auth user with
// a temporary password). Returns the temp password for the admin to hand over
// — no dependency on invite-email config.
//
// Admin-only: the caller's JWT is verified to belong to an 'admin' in
// user_roles before anything is created.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const SB_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const dollarsToCents = (v: unknown) => Math.round((parseFloat(String(v ?? "0")) || 0) * 100);

function tempPassword() {
  // readable-ish temporary password; the installer resets on first login
  const chars = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789";
  const bytes = crypto.getRandomValues(new Uint8Array(14));
  return Array.from(bytes, (b) => chars[b % chars.length]).join("");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

  const admin = createClient(SB_URL, SERVICE_KEY, { auth: { persistSession: false } });

  try {
    // --- verify caller is an admin ---
    const authHeader = req.headers.get("Authorization") || "";
    const jwt = authHeader.replace(/^Bearer\s+/i, "");
    if (!jwt) return json({ error: "unauthenticated" }, 401);
    const { data: userData } = await admin.auth.getUser(jwt);
    const uid = userData?.user?.id;
    if (!uid) return json({ error: "unauthenticated" }, 401);
    const { data: role } = await admin.from("user_roles").select("role").eq("user_id", uid).maybeSingle();
    if (role?.role !== "admin") return json({ error: "admin only" }, 403);

    const body = await req.json().catch(() => ({}));
    const company_name = String(body.company_name || "").trim();
    const contact_email = String(body.contact_email || "").trim().toLowerCase();
    const abn = String(body.abn || "").trim() || null;
    const postcodes: string[] = Array.isArray(body.postcodes)
      ? body.postcodes.map((p: unknown) => String(p).trim()).filter((p: string) => /^\d{4}$/.test(p))
      : [];
    if (company_name.length < 2) return json({ error: "company name required" }, 400);
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(contact_email)) return json({ error: "valid contact email required" }, 400);
    if (!postcodes.length) return json({ error: "at least one valid postcode required" }, 400);

    // --- don't double-onboard ---
    const { data: existing } = await admin.from("installers").select("id").eq("contact_email", contact_email).maybeSingle();
    if (existing) return json({ error: "an installer with that email already exists" }, 409);

    // --- installers row (approved) ---
    const { data: inst, error: instErr } = await admin.from("installers")
      .insert({ company_name, contact_email, abn, status: "approved" })
      .select("id").single();
    if (instErr) return json({ error: "installer insert failed: " + instErr.message }, 500);
    const installer_id = inst.id;

    // --- price book (active, verified now) ---
    const base_rates = {
      solar_per_kw_cents: dollarsToCents(body.solar_per_kw ?? 1350),
      solar_fixed_cents: dollarsToCents(body.solar_fixed ?? 1600),
      battery_per_kwh_cents: dollarsToCents(body.battery_per_kwh ?? 820),
      battery_fixed_cents: dollarsToCents(body.battery_fixed ?? 2800),
    };
    const adders = {
      two_storey_cents: dollarsToCents(body.two_storey ?? 450),
      tile_roof_cents: dollarsToCents(body.tile_roof ?? 350),
    };
    await admin.from("price_books").insert({
      installer_id, name: "Default", verified_at: new Date().toISOString(), base_rates, adders, active: true,
    });

    // --- service areas (map each postcode to its region; fall back to pilot region) ---
    const { data: fallbackRegion } = await admin.from("regions").select("id").order("created_at").limit(1).maybeSingle();
    const areas: Array<Record<string, unknown>> = [];
    const skipped: string[] = [];
    for (const pc of postcodes) {
      const { data: rp } = await admin.from("region_postcodes").select("region_id").eq("postcode", pc).limit(1).maybeSingle();
      const region_id = rp?.region_id || fallbackRegion?.id;
      if (!region_id) { skipped.push(pc); continue; }
      areas.push({ installer_id, region_id, postcode: pc, tiers: ["seats"] });
    }
    if (areas.length) await admin.from("installer_service_areas").insert(areas);

    // --- login (temp password; trigger links the auth user to the installers row) ---
    const password = tempPassword();
    const { error: userErr } = await admin.auth.admin.createUser({
      email: contact_email, password, email_confirm: true,
    });
    if (userErr) {
      // installer data is created; report so the admin can retry the login step
      return json({ ok: true, installer_id, login_created: false, login_error: userErr.message, skipped_postcodes: skipped }, 207);
    }

    return json({ ok: true, installer_id, login_created: true, email: contact_email, temp_password: password, service_areas: areas.length, skipped_postcodes: skipped });
  } catch (e) {
    return json({ error: String((e as Error).message || e) }, 500);
  }
});
