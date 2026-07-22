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

### Data model (`drone_assignments`, one per tech)
- `source` `company_provided` | `own`; `status` `earning` | `owned` | `returned`;
  `jobs_target` (50), `jobs_done`.
- `drone_job_rate(rep)` → 4500 while `earning`, else 5000 (read-only, for UI/preview).
- `submit_assessment` bills a **completed** job at $45 while `earning` and advances
  `jobs_done`; the 50th job is still $45, then `status` flips to `owned` (drone is theirs)
  and job 51+ bills $50. `no_access` is a **$0 logged exception** (access is confirmed up
  front — see below), and only completed jobs count toward the 50.
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
- **Classification (employee vs contractor):** still the big one — drives super, leave,
  workers' comp, sham-contracting risk (s357). *Uber precedent:* Australian Uber drivers are
  **independent contractors**, and since 26 Aug 2024 also **"employee-like workers"** (FWC can
  set minimum standards). **The label doesn't decide it** — the real substance does (Fair Work
  Act s15AA: control, financial risk, who supplies tools, integration). Our control factors
  (assigned "grab" jobs, mandated process, required kit) lean employee, so confirm before
  scaling.
