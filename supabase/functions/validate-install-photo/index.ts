// validate-install-photo — compliance check on an INSTALL evidence photo.
//
// Different job from validate-assessment-photo. That one checks a pre-install
// site photo is usable (right subject, legible, in frame). This one asks the
// harder question: does the installed work look COMPLIANT, and against which
// clause?
//
// EVIDENCE-INTEGRITY RULE (CLAUDE.md #8): no standards text and no manufacturer
// manual text is ever stored or returned. A finding carries
//   - the clause REFERENCE   e.g. "AS/NZS 5033 cl 4.4"
//   - the PARAMETER extracted from it, in our own words  e.g. "DC cable supported
//     at regular intervals, protected from sharp edges"
//   - what was OBSERVED in the photo
// The requirement is paraphrased as a parameter, never quoted. That keeps the
// output usable as an audit trail without reproducing copyrighted standards.
//
// A verdict is ADVISORY. It never blocks capture and never mutates a photo —
// install_photos is append-only evidence. The verdict is written once alongside
// the row it describes, and the installer keeps working regardless.
//
// POST { photo_id }  — everything else is looked up server-side.

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
const MODEL = Deno.env.get("ANTHROPIC_MODEL") || "claude-sonnet-4-5";

/**
 * What each install step is checked against.
 *
 * `clauses` lists the clause references in scope for that step. `params` states
 * the requirement as a PARAMETER in our own words — never the standard's text.
 * The model is told to cite only from this list, so it cannot invent a clause
 * number or paste standards wording it may have memorised.
 */
const STEP_RULES: Record<string, { title: string; clauses: string[]; params: string; count?: string }> = {
  array: {
    title: "Panel array on roof",
    clauses: ["AS/NZS 5033 cl 4.3", "AS/NZS 5033 cl 4.4", "AS/NZS 1170.2"],
    params: `- Modules mechanically fastened to rail with the manufacturer's clamps at the specified clamping zones; no packers or improvised fixings.
- Rows aligned and evenly spaced; no module overhanging rail ends beyond the clamp zone.
- DC cable off the roof surface, supported at regular intervals, not draped over sharp edges or trapped under frames.
- Cable entries weatherproofed; no exposed conductor or unprotected loops.
- Roof penetrations flashed and sealed; brackets landing on structure, not on sheeting alone.`,
  },
  isolators: {
    title: "String / DC isolators",
    clauses: ["AS/NZS 5033 cl 4.4", "AS/NZS 5033 cl 5.3", "AS/NZS 5033 cl 5.4"],
    params: `- Isolator enclosure rated for outdoor UV/weather exposure where mounted outside, lid closed and fastened.
- Glanded entries; no open knockouts, no unsealed penetrations, no water path into the enclosure.
- Durable labelling identifying it as a PV DC isolator, legible and permanently fixed (not handwritten tape).
- Mounted so it is accessible and not obstructed; conductors not strained at the gland.`,
  },
  switchboard: {
    title: "Switchboard + breakers",
    clauses: ["AS/NZS 3000 cl 2.3", "AS/NZS 3000 cl 8.3", "AS/NZS 4777.1"],
    params: `- Dedicated, correctly rated solar supply breaker; not sharing a circuit or fed from an unrated spare.
- Breaker clearly and durably labelled for the PV supply.
- Terminations tight with no exposed copper past the terminal; no signs of overheating or discolouration.
- Cable entries protected; escutcheon able to refit; no unfilled openings.`,
  },
  inverter: {
    title: "Inverter installed",
    clauses: ["AS/NZS 5033 cl 4.4", "AS/NZS 4777.1", "manufacturer installation manual"],
    params: `- Mounted on a solid surface, level and secure, with ventilation clearance around the heatsink (typically >=300mm above and below, >=100-200mm sides — confirm against the specific manual).
- Not enclosed in an unventilated cavity, not above/below a heat source, ideally shaded from direct afternoon sun.
- Outdoor installation uses an IP-rated unit; conduit and glands sealed at every entry.
- Working space clear in front; nameplate visible and legible.`,
  },
  labelling: {
    title: "Labelling & signage",
    clauses: ["AS/NZS 5033 cl 5.5", "AS/NZS 4777.1 cl 7", "AS/NZS 3000 cl 2.5"],
    params: `- Durable, weather-resistant, machine-printed labels — not handwritten and not paper.
- Shutdown procedure displayed at the main switchboard.
- PV array and inverter warning/identification signage present at the switchboard, inverter and isolators.
- Text legible at normal viewing distance; labels fixed so they will not lift or fade.`,
  },
  mounting_feet: {
    title: "Mounting feet",
    count: "mounting feet",
    clauses: ["AS/NZS 5033 cl 4.3", "AS/NZS 1170.2", "manufacturer installation manual"],
    params: `- Foot fixed into roof STRUCTURE — rafter, batten or purlin — not into sheeting alone and not into a tile with no support beneath.
- Manufacturer's own foot and fastener for that roof type; no substituted screws, no improvised packers or washers stacked to make up height.
- Fastener driven square and fully seated, not over-driven through the sheet and not standing proud.
- Seal or EPDM washer under the foot, compressed evenly, covering the fixing hole.
- Foot bearing flat on the roof surface with no rock or twist.`,
  },
  tile_seating: {
    title: "Tile foot & tile seating",
    count: "tile feet with the tile seated over them",
    clauses: ["AS/NZS 5033 cl 4.3", "AS/NZS 1170.2", "manufacturer installation manual"],
    params: `THE PRIMARY THING TO CONFIRM: the tile has been GROUND / RELIEVED so the foot fits beneath it and the tile still seats flat. Skipping that grind is the classic lazy shortcut on a tile roof — the bracket then holds the tile up, it rocks, and it cracks or lets water past. Report specifically on whether you can see relief work.
- Look for a ground or cut relief pocket in the underside or edge of the tile where the bracket passes, with a clean cut line and fresh grind marks or dust rather than a factory edge.
- The tile above must lay back DOWN FLAT and follow the course line: not lifted at one corner, not bridged, not visibly propped or rocking on the bracket.
- No cracked, chipped or split tile around the foot. Any cut edge should be clean and still supported.
- Tile foot fixed to the batten or rafter so load goes into structure, never onto the tile itself.
- Water path preserved — nothing dams or diverts flow across the course.
If the tile is sitting proud, tilted, or riding on the bracket, that is NOT compliant even when nothing is broken yet.`,
  },
  rails_straps: {
    title: "Rails & straps overview",
    clauses: ["AS/NZS 5033 cl 4.3", "AS/NZS 1170.2", "manufacturer installation manual"],
    params: `- Rail runs straight and continuous, joiners fitted where lengths meet and fully engaged.
- Rail supported at the manufacturer's maximum foot spacing; no long unsupported spans.
- Rail end overhang within the manufacturer's limit past the outermost foot.
- Straps or bracing where specified, fixed to structure and tensioned, not loose.
- No cut rail left unfinished where it creates a sharp edge against cable.`,
  },
  penetrations: {
    title: "Roof penetrations",
    count: "roof penetrations",
    clauses: ["AS/NZS 5033 cl 4.4", "AS/NZS 3500.3", "manufacturer installation manual"],
    params: `- Every penetration flashed, with the flashing dressed OVER the roof profile in the direction of water flow, never under it.
- Flashing sized and shaped for the roof type; sealant is a supplement to correct flashing, never a substitute for it.
- Penetration positioned in the pan of a corrugated sheet, not through a rib, and clear of laps where practical.
- Cable entry sleeved or grommeted so the conductor is not bearing on a cut edge.
- No unsealed old or abandoned holes left in the sheet.`,
  },
  earthing: {
    title: "Earthing, clamps & galvanic protection",
    clauses: ["AS/NZS 5033 cl 4.5", "AS/NZS 3000 cl 5.3", "AS/NZS 3000 cl 5.4"],
    params: `- Array frame bonded with a correctly sized earthing conductor, continuous across rails and rows.
- Purpose-made earthing lug with a tooth washer biting through the anodising to clean metal.
- GALVANIC / COLD-GALVANISING PROTECTION VISIBLY APPLIED over the clamp and the bared metal at the connection — this is the specific thing to look for and report on. Say plainly whether you can see evidence of it (a dull grey/zinc coating over the joint) or whether the bare metal is still exposed.
- Corrosion protection wherever dissimilar metals meet, which matters most near the coast.
- Conductor supported and protected along its run; terminations tight with no strands escaping the lug.`,
  },
  final_tidy: {
    title: "Final tidy / make good",
    clauses: ["AS/NZS 5033 cl 4.4", "AS/NZS 3000 cl 1.7"],
    params: `- No offcuts, packaging, screws or swarf left on roof, in gutters or on the ground.
- All covers, lids and escutcheons refitted and fastened.
- Cable management dressed and secured; nothing left loose, hanging or temporary.
- Roof and surrounds left undamaged; no cracked tiles or displaced sheeting visible.`,
  },
  battery_install: {
    title: "Battery installed",
    clauses: ["AS/NZS 5139 cl 4", "AS/NZS 5139 cl 6", "manufacturer installation manual"],
    params: `- Sited outside restricted locations: not under stairs, not on an exit path, not in a ceiling space, subfloor or wall cavity.
- Clearance kept from exits, opening windows, vents and HVAC intakes (typically ~600mm).
- Not fixed to a habitable-room wall without the required fire-rated barrier.
- Manufacturer side/top clearances and mounting height respected; fixings into structure.
- Isolation and labelling present at the battery.`,
  },
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const json = (b: unknown, s = 200) =>
    new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });

  const admin = createClient(SB_URL, SERVICE_KEY, { auth: { persistSession: false } });

  try {
    const { photo_id } = await req.json().catch(() => ({ photo_id: null }));
    if (!photo_id) return json({ error: "photo_id required" }, 400);

    const { data: photo } = await admin
      .from("install_photos")
      .select("id, install_id, step_key, storage_path, ai_verdict, ai_count")
      .eq("id", photo_id).maybeSingle();
    if (!photo) return json({ error: "photo not found" }, 404);
    if (!photo.storage_path) return json({ error: "photo has no file" }, 400);

    // Evidence is append-only: a verdict is written once and never rewritten.
    if (photo.ai_verdict) {
      return json({ photo_id, verdict: photo.ai_verdict, count: photo.ai_count, already_checked: true });
    }

    const rule = STEP_RULES[photo.step_key];
    if (!rule) return json({ photo_id, verdict: "not_checked", reasons: [`No compliance rules defined for step '${photo.step_key}'`] });

    if (!ANTHROPIC_API_KEY) {
      return json({ photo_id, verdict: "not_checked", configured: false,
        reasons: ["AI verification is not configured (ANTHROPIC_API_KEY missing)"] });
    }

    // Install evidence shares the assessment-photos bucket under an install/ prefix.
    const { data: file, error: dlErr } = await admin.storage.from("assessment-photos").download(photo.storage_path);
    if (dlErr || !file) return json({ error: `could not read the photo: ${dlErr?.message || "missing"}` }, 400);
    const bytes = new Uint8Array(await file.arrayBuffer());
    // Chunked: String.fromCharCode(...bytes) blows the call stack on a
    // phone-sized photo (a few MB is far past the argument limit).
    let bin = "";
    for (let i = 0; i < bytes.length; i += 0x8000) {
      bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    }
    const b64 = btoa(bin);
    const mediaType = photo.storage_path.endsWith(".png") ? "image/png" : "image/jpeg";

    const prompt = `You are auditing a photograph of completed solar installation work in New South Wales, Australia.

STEP UNDER REVIEW: ${rule.title}

REQUIREMENT PARAMETERS IN SCOPE (these are our own paraphrased parameters, not quoted text):
${rule.params}

CLAUSE REFERENCES YOU MAY CITE — use ONLY these, verbatim, and never invent another:
${rule.clauses.map((c) => `- ${c}`).join("\n")}

HOW TO ANSWER
- Judge ONLY what is genuinely visible. If the photo does not establish something, say so rather than assuming it is wrong OR right.
- For each finding, give: the clause reference, the parameter it relates to (in your own words), and what you actually observed.
- NEVER quote or reproduce the text of any Standard or manufacturer manual. Paraphrase the requirement as a parameter. This is a hard rule.
- Be a tradesperson talking to a tradesperson: specific, practical, no lecturing.
- "compliant" = what is visible looks correct. "non_compliant" = you can see a specific defect. "indeterminate" = the photo cannot settle it.

${rule.count ? `COUNT: also report "count" — how many ${rule.count} are CLEARLY visible and assessable in this photo. Count only ones you can actually judge; a blurred or half-cropped one does not count. One good wide shot may legitimately show several.\n` : ""}
Return ONLY compact JSON:
{"verdict":"compliant"|"non_compliant"|"indeterminate",
 "summary":"one short sentence",${rule.count ? `\n "count":<integer, how many ${rule.count} are clearly visible>,` : ""}
 "findings":[{"clause":"<one of the references above>","parameter":"<requirement in your own words>","observed":"<what you can see>","status":"met"|"not_met"|"cannot_tell"}],
 "retake_advice":"<only if the photo itself is the problem, else empty string>"}
Give at most four findings, most important first.`;

    const resp = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "x-api-key": ANTHROPIC_API_KEY, "anthropic-version": "2023-06-01", "content-type": "application/json" },
      body: JSON.stringify({
        model: MODEL,
        max_tokens: 900,
        messages: [{
          role: "user",
          content: [
            { type: "image", source: { type: "base64", media_type: mediaType, data: b64 } },
            { type: "text", text: prompt },
          ],
        }],
      }),
    });

    if (!resp.ok) {
      const detail = (await resp.text().catch(() => "")).slice(0, 300);
      return json({ photo_id, verdict: "not_checked", error: `AI call failed: ${resp.status} ${detail}` }, 200);
    }

    const out = await resp.json();
    const text = (out?.content || []).map((c: Record<string, unknown>) => c?.text || "").join("").trim();

    let verdict = "indeterminate";
    let summary = "Could not interpret the photo.";
    let findings: unknown[] = [];
    let retake = "";
    let count: number | null = null;
    try {
      const parsed = JSON.parse(text.replace(/^```(?:json)?|```$/g, "").trim());
      verdict = ["compliant", "non_compliant", "indeterminate"].includes(parsed.verdict) ? parsed.verdict : "indeterminate";
      summary = String(parsed.summary || "").slice(0, 300);
      findings = Array.isArray(parsed.findings) ? parsed.findings.slice(0, 4) : [];
      retake = String(parsed.retake_advice || "").slice(0, 200);
      // Coverage is counted in items, not photographs: one wide shot of four
      // feet evidences four. Clamped so a hallucinated number cannot inflate a
      // coverage target — nobody frames 40 assessable feet in one photo.
      if (rule.count && Number.isFinite(Number(parsed.count))) {
        count = Math.max(0, Math.min(24, Math.round(Number(parsed.count))));
      }
    } catch {
      // Leave the defaults — an unparseable answer is "indeterminate", not a fail.
    }

    // ai_reasons is text[]; flatten each finding into one auditable line.
    const reasons = (findings as Record<string, string>[]).map((f) =>
      `[${f.clause}] ${f.parameter} — observed: ${f.observed} (${f.status})`);

    await admin.from("install_photos")
      .update({ ai_verdict: verdict, ai_reasons: [summary, ...reasons].filter(Boolean),
                ai_count: rule.count ? (count ?? 1) : null })
      .eq("id", photo_id);

    return json({ photo_id, step: photo.step_key, verdict, summary, findings,
                  count: rule.count ? (count ?? 1) : null,
                  retake_advice: retake, configured: true });
  } catch (e) {
    return json({ error: String((e as Error).message || e) }, 500);
  }
});
