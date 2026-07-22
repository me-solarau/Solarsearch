// Tamper check for an assessment's evidence. For each photo it re-downloads the stored
// object, recomputes SHA-256, and compares it to the hash captured at upload (assessment_photos.sha256).
// Combined with the immutability lock (0050), a post-submission swap of any image is detectable:
// the locked hash is the trusted baseline, and a mismatch here proves the file changed.
// Admin only.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const SB_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

async function sha256Hex(bytes: Uint8Array) {
  const h = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(h)].map((b) => b.toString(16).padStart(2, "0")).join("");
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

    const { assessment_id } = await req.json().catch(() => ({}));
    if (!assessment_id) return json({ error: "assessment_id required" }, 400);

    const { data: photos } = await admin.from("assessment_photos")
      .select("id, step_key, storage_path, sha256, bytes")
      .eq("assessment_id", assessment_id);

    const results: Array<Record<string, unknown>> = [];
    for (const p of photos || []) {
      if (!p.storage_path) continue;
      const row: Record<string, unknown> = { id: p.id, step_key: p.step_key, has_hash: !!p.sha256 };
      if (!p.sha256) { row.status = "no_baseline_hash"; results.push(row); continue; }
      const { data: blob, error } = await admin.storage.from("assessment-photos").download(p.storage_path);
      if (error || !blob) { row.status = "missing_file"; results.push(row); continue; }
      const actual = await sha256Hex(new Uint8Array(await blob.arrayBuffer()));
      row.status = actual === p.sha256 ? "match" : "MISMATCH";
      if (actual !== p.sha256) { row.stored = p.sha256; row.actual = actual; }
      results.push(row);
    }
    const checked = results.filter((r) => r.status === "match" || r.status === "MISMATCH");
    const tampered = results.filter((r) => r.status === "MISMATCH");
    return json({
      assessment_id,
      photos: results.length,
      verified: checked.length,
      tampered: tampered.length,
      all_intact: tampered.length === 0,
      results,
    });
  } catch (e) {
    return json({ error: String((e as Error).message || e) }, 500);
  }
});
