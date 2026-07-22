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
  meter: "An electricity meter and the metering arrangement, with the meter face/nameplate legible AND the service fuse (or clear evidence there is none) in view. Reject if no meter is shown or the shot can't establish the metering setup.",
  main_earth: "The main earth connection / earth electrode / earthing conductor at the switchboard. Reject if no earthing is visible.",
  inverter_loc: "A wall or location proposed for mounting a solar inverter, with surrounding clearances visible. Reject if it is not a plausible mounting location.",
  battery_loc: "A location proposed for a home battery, with enough surroundings to judge clearance and ventilation. Reject if surroundings are not visible.",
  cable_route: "A cable route indication — roof-to-board or board-to-inverter path. Reject if no plausible route is shown.",
  existing_system: "Existing solar equipment (panels, inverter, isolators). Reject only if the shot is unusable; absence of a system should be marked N/A in-app, not sent here.",
  existing_inverter: "An existing solar inverter mounted on site, ideally with its make/model/rating nameplate label legible (or a close-up of that label). Reject if it is not an inverter, or if it is too far/blurry to read the nameplate on a nameplate close-up.",
  existing_panels: "An existing solar panel array on a roof (or a legible close-up of a panel's rating label). Reject if no solar panels are visible.",
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
      // graceful fallback so the app keeps working before the key is set. The app
      // surfaces this as "Not verified" (amber), NOT a green pass.
      await admin.from("assessment_photos").update({ ai_verdict: "pass", ai_reasons: ["AI validation not configured — not checked"] }).eq("id", photo_id);
      return json({ verdict: "pass", reasons: ["AI validation not configured — not checked"], configured: false });
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

    // The meter step also extracts structured facts that drive the quote: meter kind
    // (old dial meters need an upgrade before solar), supply phase (read off the smart
    // meter nameplate: 230V x1 = single, 230V x3 = three), and whether a supply-authority
    // service fuse is present (absent => a Level 2 electrician is required).
    const METER_EXTRACT = photo.step_key === "meter" ? `

This is the METER + SERVICE FUSE step. As well as the pass/fail, READ the metering and report what you see, using these rules:
- METER KIND: "dial" if it is an old electromechanical meter with spinning discs and mechanical number wheels (e.g. "Watthour Meter Type M3", accumulation meters). "smart" if it is a modern electronic/digital meter with an LCD (e.g. EDMI Atlas, or any digital readout). "unknown" if you can't tell.
  - An old DIAL meter ALWAYS means a meter upgrade is required before solar -> set meter_upgrade_required=true. A smart meter does not need upgrading -> false.
- PHASE (only if a smart-meter nameplate is legible): the nameplate voltage tells you the phase. "230V x1" (a single 230/240V element) = single phase -> 1. "230V x3" (three elements) or a 400V/3-phase nameplate = three phase -> 3. If you cannot read it, use null.
- SERVICE FUSE: the sealed supply-authority service fuse / service protection device (often a black fuse carrier, sometimes labelled "SERVICE FUSE"). "present" if you can see one, "absent" if the metering is clearly shown and there is none, "unknown" if the shot doesn't establish it.
  - If service_fuse is "absent", a Level 2 electrician is required (external work).` : "";

    // Inverter/battery location steps: estimate real clearances from the photo using
    // whatever is a known-size reference — Australian brickwork is the reliable ruler.
    const LOC_STEPS = new Set(["inverter_loc", "battery_loc"]);
    const isBat = photo.step_key === "battery_loc";
    const CLEARANCE_REQS = isBat
      ? `Home battery (BESS) siting, per AS/NZS 5139 and manufacturer rules — flag if the spot looks non-compliant:
- Keep a ~600mm exclusion zone clear of building exits/entries, opening windows, vents, HVAC/air intakes, and other appliances/heat sources.
- NOT in a restricted location: under stairs, on/over an exit or escape path, in a ceiling space, subfloor, roof or wall cavity.
- Not mounted on the wall of a habitable room without a fire-rated barrier; not in unventilated cupboards; keep off direct west/afternoon sun where possible.
- Manufacturer side/top clearances (typ. 100-300mm) and rated mounting height/surface.`
      : `Solar inverter siting, per manufacturer ventilation rules + good practice — flag if the spot looks tight:
- Ventilation gaps: typically >=300mm above and below, >=100-200mm each side; ~1m clear working space in front.
- Not boxed into an unventilated cavity, not directly above/below a heat source, avoid direct west/afternoon sun (heat derating).
- Outdoors needs an IP-rated unit; keep clear of gas meters (~600mm) and out of habitable-room noise zones.`;
    const LOC_EXTRACT = LOC_STEPS.has(photo.step_key) ? `

This is a PROPOSED ${isBat ? "BATTERY" : "INVERTER"} LOCATION step. As well as pass/fail, ESTIMATE the available clearances and give the sales tech feedback.
SCALE REFERENCE — use a known-size object in frame to turn pixels into millimetres. Australian brickwork is ideal:
- A standard clay brick is 230mm long x 110mm wide x 76mm high, laid with 10mm mortar joints.
- So one brick COURSE (height) is about 86mm, and one brick + perpend joint (length) is about 240mm. Count courses/bricks to estimate distances.
- If no brick is visible, use another known reference (a power point/GPO is ~115mm tall, a standard door ~2040mm, a downpipe ~90mm) and say which you used.
STANDARDS TO CHECK:
${CLEARANCE_REQS}
Estimate the space above/below/left/right (and in front) of the marked spot in mm. If a required clearance does not appear to be there, add a short, practical ADVISORY for the tech in a tradesperson's words (what's tight, by roughly how much, and what to do — e.g. move it, pick another wall, or measure it). If it looks fine, say so. Advisories are FEEDBACK, not a photo failure — still PASS the photo if the location context is clearly visible.` : "";

    const EXTRACT = METER_EXTRACT + LOC_EXTRACT;
    const RETURN_SHAPE = photo.step_key === "meter"
      ? `Return ONLY compact JSON: {"verdict":"pass"|"fail","reasons":[...],"observations":{"meter_kind":"dial"|"smart"|"unknown","phase":1|3|null,"service_fuse":"present"|"absent"|"unknown","meter_upgrade_required":true|false}}.`
      : LOC_STEPS.has(photo.step_key)
      ? `Return ONLY compact JSON: {"verdict":"pass"|"fail","reasons":[...],"observations":{"scale_reference":"what you measured against","est_clearances_mm":{"above":n|null,"below":n|null,"left":n|null,"right":n|null,"front":n|null},"clearance_ok":true|false|"unsure","advisories":["short plain-English feedback for the tech", ...]}}.`
      : `Return ONLY compact JSON: {"verdict":"pass"|"fail","reasons":["short plain-English reason", ...]}.`;

    const prompt = `You are the on-site QA checker for a solar site assessment and the LAST line of defence before a design team quotes a job off these photos. Judge ONLY this one photo, for the step "${photo.step_key}".

A PASS requires ALL of the following:
1. The photo clearly shows: ${criteria}
2. The specific items that matter for this step are actually identifiable in frame — not too far away, too dark, blurry, glared-out, or obstructed to verify.
3. It is a genuine on-site photo of that subject. FAIL immediately if it is a screenshot, a phone/car dashboard, a person, a random indoor scene, a blank wall, a hand, or anything clearly unrelated to this step.

Bias toward FAIL when unsure. A re-shoot while the technician is still on the property costs nothing; a wrong or missing detail that reaches a quote is expensive. Do not "give benefit of the doubt" — if you cannot positively verify the required subject, it is a FAIL.${EXTRACT}

${RETURN_SHAPE} On fail give at most two specific, actionable reasons in a tradesperson's words, e.g. "This looks like a car dashboard, not the front of the house — retake facing the property" or "Switchboard labels aren't legible — move closer and fill the frame".`;

    const resp = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "x-api-key": ANTHROPIC_API_KEY, "anthropic-version": "2023-06-01", "content-type": "application/json" },
      body: JSON.stringify({
        model: MODEL, max_tokens: 400,
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
    let observations: Record<string, unknown> | null = null;
    try {
      const m = text.match(/\{[\s\S]*\}/);
      const parsed = JSON.parse(m ? m[0] : text);
      verdict = parsed.verdict === "pass" ? "pass" : "fail";
      reasons = Array.isArray(parsed.reasons) ? parsed.reasons.slice(0, 3).map(String) : [];
      if ((photo.step_key === "meter" || LOC_STEPS.has(photo.step_key)) && parsed.observations && typeof parsed.observations === "object") {
        observations = parsed.observations as Record<string, unknown>;
      }
    } catch { /* keep fail default */ }

    const update: Record<string, unknown> = { ai_verdict: verdict, ai_reasons: reasons };
    if (observations) update.ai_observations = observations;
    await admin.from("assessment_photos").update(update).eq("id", photo_id);
    return json({ verdict, reasons, observations, configured: true });
  } catch (e) {
    return json({ error: String((e as Error).message || e) }, 500);
  }
});
