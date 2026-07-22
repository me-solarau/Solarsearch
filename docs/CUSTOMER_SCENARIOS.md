# Customer scenarios — existing system × what they want

The customer's situation is **two facts, not one label**: what they *have now*
and what they *want to add*. Everything downstream (intake typing, the
technician capture checklist, the rebate maths, the design) is **derived** from
those two facts instead of an ever-growing list of `lead_type`s.

## Data model (the two facts)
Stored on the lead:

- `existing`: `{ solar: bool, solar_kw: number|null, battery: bool,
  battery_kwh: number|null, inverter_model: text|null }`
- `wants`: `{ solar: bool, battery: bool }`

(Today's ad-hoc `lead_type` — `solar`, `solar_battery`, `battery_retrofit` —
becomes a *derived label* for display/reporting, computed from these.)

## The six scenarios

| # | Have now | Wants | Notes |
|---|----------|-------|-------|
| ① | nothing | solar and/or battery | fresh install (default full checklist) |
| ② | solar | + solar | solar expansion |
| ③ | solar | + battery | battery retrofit — **built** |
| ④ | solar | + solar + battery | expansion + battery |
| ⑤ | solar + battery | + solar | add panels to an existing hybrid/battery home |
| ⑥ | solar + battery | + solar + battery | grow both |

## What changes per scenario

| # | Must photograph (existing kit) | The critical technical gate | Rebate counts |
|---|--------------------------------|-----------------------------|---------------|
| ① | — | roof space, switchboard capacity | full new kW + kWh |
| ② | existing **inverter nameplate**, existing array | Inverter spare capacity / free MPPTs, or upsize? DNSP export-limit headroom? | **new kW only** |
| ③ | existing **inverter nameplate**, existing array | hybrid-capable vs AC-couple the battery | battery kWh |
| ④ | existing inverter, existing array | inverter headroom **and** battery coupling | new kW + kWh |
| ⑤ | existing inverter, array, **existing battery model** | can new panels feed the existing hybrid, or need a 2nd inverter? | new kW |
| ⑥ | existing inverter, array, **existing battery model** | expandable battery (stackable / same brand) vs separate system | new kW + new kWh |

### Two linchpin shots
- **Existing inverter nameplate** — required for anything touching existing
  solar (② ③ ④ ⑤ ⑥). Decides expansion headroom and battery coupling.
- **Existing battery model** — required whenever a battery already exists
  (⑤ ⑥). Decides "stack modules" vs "add a separate system."

## Composable capture checklist
Steps are building blocks toggled by the two facts, not a fixed list:

- **Always:** front, switchboard (closed / open / main switch), meter, main
  earth, cable route
- **If `existing.solar`:** + existing inverter (nameplate, **required**) +
  existing array
- **If `existing.battery`:** + existing battery (nameplate / model, **required**)
- **If `wants.solar`:** + roof planes for new panels + roof material
- **If `wants.battery`:** + battery location
- **If a new/replacement inverter is likely:** + new inverter spot

This one rule generates the correct list for all six and extends cleanly to any
future combination.

## Rebate: only ever the increment
STCs and battery rebate compute on **new capacity only** — never the existing
kit.

> ⚠️ **Business/compliance flag:** adding panels to an existing system has
> specific CER **"augmentation vs new system"** STC rules. Pin these down with
> the rebate owner before the auto-quote is trusted for ② ④ ⑤ ⑥.

This also fixes the current "System (est.)" bug: today the estimate is guessed
from the quarterly bill and ignores what the customer entered. Derived from
`existing` + `wants` + increment, it becomes honest (e.g. a battery-add shows
0 new kW, not a bill-based 8.8 kW).

## Inverter sizing rules (design engine must honour)
Driven off the catalog `spec` (`kw`, `phase`, `hybrid`) + the site's phase count:

- **Per-phase export cap:** DNSPs require inverter **export strictly below 10 kW
  per phase** (some lower). This is why single-phase inverters are badged
  **9.99 kW** — it sits *under* the <10 kW threshold and avoids export-limiting /
  a full network study.
  - **Single-phase site:** 9.99 kW is the practical inverter ceiling (<10 kW export).
    More PV than that must **export-limit** or move to 3-phase.
  - **Three-phase site:** just under 10 kW *per phase* → ~30 kW total headroom —
    unlocks the larger 3-phase inverters (Goodwe ETA, Sungrow, SMA Tripower, Solis GC).
- **DC oversize:** panels can exceed inverter AC rating up to the inverter's array
  limit (typically ~133% DC:AC) with export limiting — surface this as an explicit
  design choice, don't silently cap the array.
- The estimate must therefore read the **site phase count** as an input, not assume
  single-phase.

## Suggested build order
1. **Intake** — replace the single "goal" question with two: *"What do you have
   now?"* and *"What do you want to add?"* → writes `existing` + `wants`.
2. **Capture** — make the checklist composable off those two facts (generalises
   what ③ already does).
3. **Estimate / design / rebate** — drive off `existing` + `wants` + the
   increment; retire the bill-based guess.

## Meter + service fuse — AI photo learning (drives the quote)
The **meter capture step is non-negotiable** (no N/A) and the vision checker
(`validate-assessment-photo`) reads three facts off it into
`assessment_photos.ai_observations`, which `quote_prefill` then pre-flags on the
instant quote. Three states, from real site photos:

1. **Old dial meter** — electromechanical, spinning disc + mechanical number
   wheels (e.g. "Watthour Meter Type M3"). **Always needs a meter upgrade** before
   solar (`meter_upgrade_required=true`). These older setups typically also have
   **no service fuse** → a Level 2 electrician is required as well.
2. **Smart meter** — modern electronic/LCD meter (e.g. EDMI Atlas Mk7A). No
   upgrade needed. Its **nameplate voltage tells you the phase**:
   **`230V x1` = single phase**, **`230V x3` (or a 400V/3-phase nameplate) = three
   phase**. This feeds the inverter sizing / export rules above.
3. **Service fuse present vs absent** — the sealed supply-authority service fuse
   (black fuse carrier, sometimes labelled "SERVICE FUSE"). **Absent → a Level 2
   electrician is required** (external resource, **~$350–$500**). Smart meter +
   service fuse present = the clean case, no extra electrical.

Pricing hooks (`chargeables`): `meter_upgrade` (retailer swaps the meter — carried
as a $0 requirement flag, must be actioned before install) and `service_fuse_l2`
(Level 2 / ASP install, baseline **$425** = midpoint of $350–500, range in `meta`).
Both flow through `quote_estimate` as their own quote lines and auto-tick on the
instant quote when the meter photo detected them.

## Inverter / battery clearances — scale-from-brick + standards (AI feedback)
The proposed-location photos (`inverter_loc`, `battery_loc`) can't be measured with a
tape from a photo, so the vision checker **estimates the clearances using a known-size
reference in frame** and gives the sales tech immediate feedback (an amber "Site check
— clearances" note in the app). Advisories are **feedback, not a photo failure** — the
shot still passes as long as the location context is visible.

**Scale reference library** — anything of known datasheet size in frame is a ruler
(and its size doubles as a spec hint). The shared `SCALE_REFS` block feeds every
measurement step:
- **Australian clay brick**: **230 (L) × 110 (W) × 76 (H) mm** with **10 mm** joints →
  one **course ≈ 86 mm** high, **one brick + perpend ≈ 240 mm** long. Count courses/bricks.
- **NSW meter board / switchboard**: standard **~600 × 600 mm** (260 mm deep); a full
  DIN row is **~12 poles** wide (used to gauge spare capacity).
- **Residential solar panel**: newer high-output (~350 W+) **~1722–1762 (H) × 1134 (W) mm**;
  older ~250 W **~1650 (H) × 1000 (W) mm**. Width tells you the vintage/wattage.
- **Australian roof tile** (the ruler on tiled roofs): concrete **~420–440 (L) × 330–345 (W) mm**;
  terracotta **~420–445 (L) × 265–275 (W) mm** (tiles overlap when laid, so the exposed
  course is a bit less than full length). **Width also IDs the type** — ~330–345 mm =
  concrete, ~265–275 mm = terracotta.
- **Vehicle**: AU number plate **372 × 134 mm** (precise); car ~4.5 × 1.8 m, wheel ~650 mm.
- **Tape measure / ruler** in frame = ground truth (the `needs_measure` fallback below).
- Fallbacks: GPO power point ≈ 115 mm tall, standard door ≈ 2040 mm, downpipe ≈ 90 mm.

**Standards checked (design-review flags, not a compliance sign-off):**
- **Inverter** (manufacturer ventilation + good practice): ≈ **300 mm above & below**,
  **100–200 mm sides**, ~**1 m** working space in front; not boxed in an unventilated
  cavity, not above/below a heat source, avoid west/afternoon sun (derating), IP-rated
  if outdoors, ~600 mm off gas meters.
- **Battery / BESS** (AS/NZS 5139): keep a ~**600 mm exclusion zone** from exits, opening
  windows, vents, HVAC intakes and other appliances/heat sources; **not** under stairs,
  on an escape path, or in a ceiling/subfloor/cavity; no habitable-room wall without a
  fire barrier; manufacturer side/top clearances.

The AI returns `est_clearances_mm` (above/below/left/right/front), a `clearance_ok`
flag, the `scale_reference` it used, and `advisories[]` — stored in
`assessment_photos.ai_observations` and shown to the tech on site (amber **"AI site
check"** note) so a tight or non-compliant spot gets caught before the truck leaves.
Final clearances are still confirmed by the designer/installer against the specific
product datasheet.

**Same scale ruler, other steps** — the reference library also powers rough
estimates that ride back as advisories in the same note:
- **`existing_panels`** — counts the array and reads each panel's **width** to guess
  vintage/wattage (~1134 mm ⇒ newer ~350 W+; ~1000 mm ⇒ older ~250 W), then estimates
  the **existing kW** (`panel_count`, `est_panel_watts`, `panel_vintage`,
  `est_existing_kw`). Confirmed off the inverter nameplate.
- **`roof_planes`** — using a modern panel footprint (~1.13 × 1.76 m) it gives a
  **rough panel-fit** count for the main plane (`est_panels_fit`), heavily hedged and
  noting obstructions — a sizing feel for the designer.
- **`board_open`** — estimates **spare DIN poles** against the ~12-pole standard row
  (`est_spare_poles`); a near-full board raises a *switchboard-upgrade likely* advisory
  that lines up with the `switchboard_upgrade` quote flag.

All of these are **estimates for feedback/triage**, never a compliance or final-design
call — the datasheet and the designer have the last word.

**Ground-truth loop — `needs_measure` (HARD GATE).** A single-photo estimate is only so
good, so on the location steps when a clearance looks **tight/marginal** or the AI
**can't establish scale**, it sets `needs_measure=true`. This is a **hard capture gate**,
not a suggestion: the step won't complete and the job can't be submitted until it's
resolved on site. The deliberate trade-off — **a strong measure requirement on site beats
a return visit**, because the tech can't come back (cost). Two ways to clear it:
1. **Tape photo** (preferred) — hold a tape/ruler across the tightest gap and add one more
   shot; the AI reads the graduations directly (ground truth) and clears the flag.
2. **Log measurement** (fallback, if the tape won't read on camera) — the tech types the
   measured mm, which is logged against the flagged photos (`measured_note`) for the
   designer. Accountable record, not a silent skip.

Keeping the blow-out in check: the gate is **narrow** — only the two location steps, and
only when the shot is genuinely tight or scale-less. With a scale reference habitually in
frame (brick/tile/panel), most visits never trip it, so it costs seconds when it fires and
saves a whole second truck roll when it matters.

## Sales-tech field toolkit
What the tech carries to make the capture (and the AI's job) reliable:
- **A good phone camera** — the whole capture runs off it; clean glass, good light.
- **Tape measure** — the ground-truth tool. Whenever the AI flags a tight fit
  (`needs_measure`), a tape held across the gap beats any pixel estimate.
- **Drone (preferred for roofs)** — gets the roof-plane and array shots without anyone
  going up. **Removes the ladder → WHS/EHS risk reduction**; upload drone frames the same
  way as phone photos.
- **Ladder (least desired)** — only when a drone can't get the shot; height access is the
  main on-site hazard, so avoid it where the drone will do.
- **The vehicle** — parked in frame it's a coarse scale reference (AU number plate is a
  precise 372 × 134 mm) when nothing else of known size is around.
