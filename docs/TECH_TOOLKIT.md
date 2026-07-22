# Sales-tech required toolkit (+ drone financing)

Like a rideshare driver needs a licence and a car, an approved Solarsearch sales tech
needs a defined kit before they can grab jobs. The **drone is mandatory** — it's how we
eliminate the roof-climbing WHS risk (a risk that **cannot** be contracted away; see
`docs/ROOF_SAFETY_AND_LIABILITY.md`). No drone + legals → not an approved tech.

## Required kit
| Item | Rule |
|------|------|
| **Smartphone** | Runs the whole capture. Clean glass, good light. |
| **Drone (sub-250g)** | **Mandatory.** Roof planes/material from the air — the tech **never** gets on the roof. Sub-250g (e.g. DJI Neo, ~135 g) is the deliberate choice: it's legally exempt from the 30 m-from-people rule, so it can work tight suburban blocks. |
| **CASA legals to fly for work** | **Mandatory.** See below. |
| **Tape measure** | Ground-truth tool for the `needs_measure` gate on tight equipment locations. |
| **Vehicle** | To reach jobs; also a coarse scale reference (AU plate 372×134 mm). |

## CASA legal requirements (flying a drone *for work*)
Flying to capture roofs for Solarsearch is **commercial** use, so even a sub-250g drone
needs the commercial legals (recreational exemptions do **not** apply):
1. **CASA drone registration** — required for any drone flown for business. Free for
   drones ≤500 g, renewed annually. Record the registration ref.
2. **RPA Operator Accreditation** — free online course + quiz, valid **3 years**. Required
   to fly sub-2 kg commercially without a RePL.
3. **Standard Operating Conditions** — day, visual line of sight, ≤120 m AGL, one drone at
   a time, clear of controlled aerodromes/emergencies.
4. **Sub-250g relief** — exempt from the 30 m-from-people rule (must still not create a
   hazard), which is what makes close residential roof shots legal.

Non-compliance is enforced: CASA on-the-spot fines up to **$1,650/offence**, court up to
**$16,500/offence**. This is a hard onboarding gate, not a nicety.

> Verify current rules at [casa.gov.au](https://www.casa.gov.au) — drone rules change
> (e.g. CASA has reclassified some "sub-250g" models as over-250g). Confirm the specific
> model qualifies before relying on the 250 g exemptions.

## Onboarding gate
`tech_kit_ready(rep_id)` returns true only when the tech has: a `drone_model`,
`drone_registered = true`, a current `casa_accreditation` (not past `casa_accred_expiry`),
and a current police check. An approved/active tech must be kit-ready.

## Drone earn-to-own — a RATE DIFFERENTIAL, not a deduction
Having a drone is a **condition of engagement** (the tech's obligation — they may supply
their own; `tech_kit_ready()` checks the kit). Solarsearch can provide one, earned out via a
**rate differential** — deliberately NOT a pay deduction, which sidesteps the Fair Work
s324/326 deduction rules entirely.

| Tech | Completed-job rate | Drone |
|------|--------------------|-------|
| **Own drone** | **$50** from day one | already theirs |
| **Company drone, first 50 completed jobs** | **$45** | company-owned |
| **Company drone, after 50 completed jobs** | **$50** | **becomes theirs** |

- The $5 lower rate is effectively a **tool allowance** the own-drone tech receives — a
  recognised, lawful concept — not money taken out of the company-drone tech's pay.
- 50 × $5 = $250 recoups the ~$209 drone (DJI Neo) with a small buffer.
- **Stop before earning it out?** The tech posts the (still company-owned) drone back from the
  nearest post office and **Solarsearch pays the postage**. No deduction, no debt, no
  out-of-pocket for anyone.

### Superannuation — a specified line item (fee + 12%)
Even a genuine sole-trader contractor is deemed an **employee for super** when the contract
is **wholly or principally for their labour** (Superannuation Guarantee (Administration) Act
**s12(3)**) — a regular assessment tech is exactly that. So super is owed on the labour fee,
regardless of ABN/contractor status. We pay it as its **own line**, not baked into the rate:
- `pricing_config.super_rate_pct` = **12%** (SG rate from 1 Jul 2025). `submit_assessment`
  stores `assessments.super_cents = round(fee × 12%)` per job and returns/logs it.
- So a completed job is **$50 fee + $6 super** (own drone) or **$45 + $5.40** (earning). A
  no-access ($0) accrues $0 super. Shown to the tech as a separate "super" line in earnings.
- Confirm with an accountant: the **base** (labour, ex-GST) and payment/reporting via a
  super fund. This is owed even though the tech is a contractor for other purposes.

### Data model (`drone_assignments`, one per tech)
- `source` `company_provided` | `own`; `status` `earning` | `owned` | `returned`;
  `jobs_target` (50), `jobs_done`.
- `drone_job_rate(rep)` → 4500 while `earning`, else 5000 (read-only, for UI/preview).
- `submit_assessment` bills a **completed** job at $45 while `earning` and advances
  `jobs_done`; the 50th job is still $45, then `status` flips to `owned` (drone is theirs)
  and job 51+ bills $50. Only completed jobs count toward the 50.
- **`no_access` is a $0 logged exception, gated to be genuine.** Access is confirmed up
  front, so to log no-access `submit_assessment` requires ALL of: a confirmed booking
  (`scheduled_at`), on-site GPS (`start_gps` within **300 m** of `sites.lat/lng`), a written
  reason, and **≥1 geotagged `no_access_evidence` photo** (locked gate / no-one home /
  call-log screenshot). No payout, but a solid audit trail; ops gets an
  `assessment.no_access` event with the reason + GPS distance to reschedule.
- **Evidence is locked + hashed** — two layers of tamper-evidence:
  1. **Immutability:** once submitted, photos (capture set + no-access evidence, with their
     GPS/timestamps) can't be inserted/updated/deleted (DB trigger `assessment_photos_lock`;
     admin override for legal holds).
  2. **Content hash:** a **SHA-256** of the image bytes is captured at upload
     (`assessment_photos.sha256`, `bytes`) and frozen with the row. The **`verify-evidence`**
     edge function (admin) re-downloads each stored file, recomputes the hash and compares —
     a `MISMATCH` proves the image was swapped after upload. `all_intact` = clean.
  Together: a defensible, court-grade audit trail for disputes and customer protection.
- `drone_assignment_return(rep)` (admin) marks a stopped earn-out `returned`. An `owned`
  drone is theirs and can't be recalled. Tech can read their own row (RLS `drone_assign_own`).

## ✅ Why this is the cleaner legal footing (still get sign-off)
No wage deduction happens anywhere, so the s324/326 deduction problem is avoided. Remaining
checks for the lawyer:
- **Minimum wage / award:** the $45 completed-job rate must still meet the applicable minimum
  for the time worked (a ~10–20 min job at $45 clears it comfortably) — confirm against the
  relevant award, and that a differential/own-tools allowance is permitted under it.
- **Asset transfer (after 50 jobs):** giving the tech the ~$209 drone is a minor,
  work-related benefit — likely FBT-exempt (minor benefits < $300 / work-related item), but
  confirm.
- **Classification (employee vs contractor):** still the big one — see the engagement model below.

## Engagement model: sole-trader contractors
Chosen structure: each tech is a **genuine sole-trader contractor** — holds their own **ABN**,
signs **contractor terms & conditions**, and **invoices** Solarsearch per job (the $45/$50
rate is a contractor fee, not wages). Onboarding gate (`tech_kit_ready`) now requires `abn` +
accepted terms (`contractor_terms_at`) on top of drone + CASA + police check.

### ⚠️ The trap: an ABN + a signed contract do NOT make someone a contractor
Both the **ATO** and **Fair Work** apply a **whole-of-relationship test** — no single factor
(not the ABN, not the contract wording, not invoicing) decides it. If the *substance* looks
like employment, they're an employee regardless, and mislabelling is **sham contracting**
(Fair Work s357; up to $16,500/$82,500 per contravention). And status can **differ by regime**:
a worker can be a contractor for tax/super (ATO **TR 2023/4**) yet an employee for Fair Work
(**s15AA**), so both must be checked — **super may be owed even on a genuine ABN contractor.**

**Where our model already leans contractor:** they supply their own tools (drone/phone),
pay is **result-based per job** (invoiced via ABN, not hourly), they carry **commercial risk**
(no drone → lower rate; no leave/super safety net), and they **choose** which jobs to grab and
set their own availability.

**Where it leans employee — needs care:** the capture app **mandates the process** (control),
there's **no delegation** (they must do it personally), and to the customer they **represent
Solarsearch** (integration). To support genuine contractor status: frame the photo protocol as
the **deliverable/output spec** (what to hand over), not minute-to-minute control; allow a
qualified substitute where practical; and make it real that they can work for others.

### The $45/year business-name fee — you probably don't need to pay it
A sole trader trading under **their own name** needs **no business-name registration ($0)**.
The **$45/yr (or $104/3yr)** ASIC fee only applies if they trade under a *different* name. So
covering it is usually **unnecessary** — most techs operate as their own name + ABN. Offer it
only if a tech genuinely wants a registered business name; don't budget it for everyone.

**Get a lawyer/accountant to draft the T&Cs and confirm the whole-of-relationship supports
contractor status** (and the super position) before scaling — the paperwork is necessary but
not sufficient.
