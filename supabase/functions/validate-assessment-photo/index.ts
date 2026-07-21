// Validates a single Sales Technician capture photo with Claude vision: is it
// the right subject, legible, well-framed? Returns pass/fail + plain-English
// reasons and writes them onto the assessment_photos row. The technician app
// calls this right after upload; a 'fail' prompts an on-site reshoot, which is
// the whole point of §9.4 (kill the second truck roll before the tech leaves).
//
// Requires the ANTHROPIC_API_KEY secret. Scoped: the caller must own the
// assessment the photo belongs to (or be admin).

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const SB_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY");
const MODEL = "claude-haiku-4-5-20251001"; // fast + cheap for high-volume per-photo checks

// Per-step "what a good shot proves" — drives the validation prompt.
const STEP_CRITERIA: Record<string, string> = {
  front: "The front elevation of a house, showing the property and its street access. Reject if it is not a house exterior.",
  roof_planes: "A roof plane (or planes) of a house where solar panels could be mounted, shot from ground or ladder height. Reject if the roof is not clearly visible.",
  roof_material: "A close-up of the roof surface where the material (tile, metal/Colorbond, terracotta) and its condition are identifiable. Reject if too far to tell the material.",
  board_closed: "An electrical switchboard/meter box with its door closed, in its surrounding location context. Reject if no switchboard is visible.",
  board_open: "An electrical switchboard with the door open showing the breakers and circuit labels; the labels must be readable. Reject if labels are blurry/unreadable or the door is shut.",
  main_switch: "A close-up of the main switch and existing circuit labelling on the switchboard, readable. Reject if not close enough to read.",
  meter: "An electricity meter and/or the metering arrangement, with the meter face visible. Reject if no meter is shown.",
  main_earth: "The main earth connection / earth electrode / earthing conductor at the switchboard. Reject if no earthing is visible.",
  inverter_loc: "A wall or location proposed for mounting a solar inverter, with surrounding clearances visible. Reject if it is not a plausible mounting location.",
  battery_loc: "A location proposed for a home battery, with enough surroundings to judge clearance and ventilation. Reject if surroundings are not visible.",
  cable_route: "A cable route indication — roof-to-board or board-to-inverter path. Reject if no plausible route is shown.",
  existing_system: "Existing solar equipment (panels, inverter, isolators). Reject only if the shot is unusable; absence of a system should be marked N/A in-app, not sent here.",
};

async function fetchImageBase64(admin: ReturnType<typeof createClient>, path: string) {
  const { data, error } = await admin.storage.from("assessment-photos").download(path);
  if (error || !data) throw new Error("could not read photo");
  const buf = new Uint8Array(await data.arrayBuffer());
  let bin = "";
  for (let i = 0; i < buf.length; i += 0x8000) bin += String.fromCharCode(...buf.subarray(i, i + 0x8000));
  return { b64: btoa(bin), mime: data.type || "image/jpeg" };
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

    const { photo_id } = await req.json().catch(() => ({}));
    if (!photo_id) return json({ error: "photo_id required" }, 400);
    if (!ANTHROPIC_API_KEY) {
      // graceful fallback so the app keeps working before the key is set
      await admin.from("assessment_photos").update({ ai_verdict: "pass", ai_reasons: ["AI validation not configured — auto-passed"] }).eq("id", photo_id);
      return json({ verdict: "pass", reasons: ["AI validation not configured — auto-passed"], configured: false });
    }

    // load photo + ownership check
    const { data: photo } = await admin.from("assessment_photos")
      .select("id, step_key, storage_path, assessments(sales_rep_id)").eq("id", photo_id).maybeSingle();
    if (!photo?.storage_path) return json({ error: "photo not found" }, 404);
    const repOwner = (photo.assessments as { sales_rep_id: string } | null)?.sales_rep_id;
    const { data: role } = await admin.from("user_roles").select("role").eq("user_id", uid).maybeSingle();
    if (role?.role !== "admin") {
      const { data: rep } = await admin.from("sales_reps").select("id").eq("user_id", uid).maybeSingle();
      if (!rep || rep.id !== repOwner) return json({ error: "not your photo" }, 403);
    }

    const criteria = STEP_CRITERIA[photo.step_key] || "A clear, legible, well-framed photo relevant to a solar site assessment.";
    const { b64, mime } = await fetchImageBase64(admin, photo.storage_path);

    const prompt = `You are the on-site photo checker for a solar site assessment. Judge ONLY this one photo for the step "${photo.step_key}".\n\nA passing photo shows: ${criteria}\n\nAlso require it to be in focus, well-lit, and not obstructed. Be practical, not pedantic — a usable field photo passes.\n\nReturn ONLY compact JSON: {"verdict":"pass"|"fail","reasons":["short plain-English reason", ...]}. On fail, give at most two reasons a tradesperson can act on immediately (e.g. "Get closer — labels not readable").`;

    const resp = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "x-api-key": ANTHROPIC_API_KEY, "anthropic-version": "2023-06-01", "content-type": "application/json" },
      body: JSON.stringify({
        model: MODEL, max_tokens: 300,
        messages: [{ role: "user", content: [
          { type: "image", source: { type: "base64", media_type: mime, data: b64 } },
          { type: "text", text: prompt },
        ] }],
      }),
    });
    if (!resp.ok) return json({ error: "vision call failed", detail: await resp.text() }, 502);
    const data = await resp.json();
    const text = (data.content || []).map((c: { text?: string }) => c.text || "").join("").trim();
    let verdict = "fail", reasons = ["Could not read the photo — please retake"];
    try {
      const m = text.match(/\{[\s\S]*\}/);
      const parsed = JSON.parse(m ? m[0] : text);
      verdict = parsed.verdict === "pass" ? "pass" : "fail";
      reasons = Array.isArray(parsed.reasons) ? parsed.reasons.slice(0, 3).map(String) : [];
    } catch { /* keep fail default */ }

    await admin.from("assessment_photos").update({ ai_verdict: verdict, ai_reasons: reasons }).eq("id", photo_id);
    return json({ verdict, reasons, configured: true });
  } catch (e) {
    return json({ error: String((e as Error).message || e) }, 500);
  }
});
