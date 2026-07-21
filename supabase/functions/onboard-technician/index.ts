// Onboards a Sales Technician in one call: creates the sales_reps row
// (approved), maps their service postcodes to regions, seeds availability, and
// provisions the login (auth user + temp password) which the signup trigger
// links to the rep row and grants the 'sales_rep' role. Returns the temp
// password once. Admin-only.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const SB_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

function tempPassword() {
  const chars = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789";
  const bytes = crypto.getRandomValues(new Uint8Array(14));
  return Array.from(bytes, (b) => chars[b % chars.length]).join("");
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
    const { data: role } = await admin.from("user_roles").select("role").eq("user_id", uid).maybeSingle();
    if (role?.role !== "admin") return json({ error: "admin only" }, 403);

    const body = await req.json().catch(() => ({}));
    const full_name = String(body.full_name || "").trim();
    const email = String(body.email || "").trim().toLowerCase();
    const phone = String(body.phone || "").trim() || null;
    const postcodes: string[] = Array.isArray(body.postcodes)
      ? body.postcodes.map((p: unknown) => String(p).trim()).filter((p: string) => /^\d{4}$/.test(p))
      : [];
    if (full_name.length < 2) return json({ error: "full name required" }, 400);
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return json({ error: "valid email required" }, 400);
    if (!postcodes.length) return json({ error: "at least one valid postcode required" }, 400);

    const { data: existing } = await admin.from("sales_reps").select("id").eq("email", email).maybeSingle();
    if (existing) return json({ error: "a technician with that email already exists" }, 409);

    // postcodes -> distinct regions (fallback to pilot region)
    const { data: rp } = await admin.from("region_postcodes").select("region_id,postcode").in("postcode", postcodes);
    let regionIds = [...new Set((rp || []).map((r: { region_id: string }) => r.region_id))];
    if (!regionIds.length) {
      const { data: fb } = await admin.from("regions").select("id").order("created_at").limit(1).maybeSingle();
      if (fb?.id) regionIds = [fb.id];
    }
    if (!regionIds.length) return json({ error: "no region resolved for those postcodes" }, 400);

    const { data: rep, error: repErr } = await admin.from("sales_reps")
      .insert({
        full_name, email, phone, regions: regionIds, status: "approved",
        police_check_ref: body.police_check_ref || null,
        police_check_expiry: body.police_check_expiry || null,
      })
      .select("id").single();
    if (repErr) return json({ error: "sales_rep insert failed: " + repErr.message }, 500);

    await admin.from("technician_availability").insert({
      sales_rep_id: rep.id, base_postcode: postcodes[0], windows: {}, blackout_dates: [],
    });

    const password = tempPassword();
    const { error: userErr } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
    if (userErr) {
      return json({ ok: true, sales_rep_id: rep.id, login_created: false, login_error: userErr.message, regions: regionIds.length }, 207);
    }
    return json({ ok: true, sales_rep_id: rep.id, login_created: true, email, temp_password: password, regions: regionIds.length });
  } catch (e) {
    return json({ error: String((e as Error).message || e) }, 500);
  }
});
