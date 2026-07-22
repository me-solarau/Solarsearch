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

## Drone financing — Solarsearch fronts it, tech pays it back per job
Solarsearch buys the drone once-off (e.g. **DJI Neo ~$209**) so cost is never the reason a
tech skips the drone. Repayment is a small per-job deduction, not an up-front hit:
- **`drone_loans`** row: `principal_cents` (what we paid), `per_job_cents` (**$5 = 500c**
  default), `paid_cents`, `status`.
- On every **billable job** (`completed`/`no_access`), `submit_assessment` calls
  `drone_loan_accrue()` which deducts **$5** toward the balance and logs it on the event
  trail (`drone_repay_cents`). At $5/job a $209 drone clears in ~42 jobs.
- When `paid_cents` reaches the principal the loan flips to **`paid`** — **the drone is
  theirs.**
- **If they stop taking jobs:** the outstanding balance (`principal − paid`) is payable, or
  the drone is returned to Solarsearch (`status = 'returned'`). The single active-loan
  index means one drone loan per tech at a time.

This is a **ledger accrual** — it tracks what's owed vs repaid; the actual money nets in
the tech's payout. The tech can read their own loan (RLS `drone_loans_own`).
