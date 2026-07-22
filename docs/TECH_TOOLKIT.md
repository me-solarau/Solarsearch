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

## The framing: drone = condition, finance = optional privilege
- **Having a drone is a CONDITION of engagement** — the tech's own obligation, like a
  rideshare driver's car. They may **supply their own drone**; `tech_kit_ready()` checks the
  kit, never the loan. Meeting the condition is on the tech.
- **Solarsearch's financial assistance is an OPTIONAL PRIVILEGE** the tech may take up to
  help meet that obligation — they get an asset they own outright once repaid, and can
  decline it and buy their own instead.

This framing puts the repayment on the right side of the law: a **voluntary opt-in, for the
tech's own benefit (they end up owning the drone), revocable** — which is what Fair Work
**s324** requires — rather than the employer deducting for its own tool (the risky pattern
struck down in *AEU v State of Victoria*).

## ⚠️ Still get legal sign-off (not legal advice)
The framing is much stronger, but before any deduction runs:
- Capture a **written, voluntary authorisation** from the tech (s324) — the system records
  it (`authorised_at`, `authorisation_ref`) and a deduction runs ONLY when it's present and
  not revoked. The tech can **revoke** any time; deductions stop immediately and the residual
  becomes an ordinary debt settled off-ledger (not a forced deduction).
- Confirm the deduction is **reasonable** and the drone is genuinely optional (own-drone
  accepted) so it isn't caught by s325/326.
- **Check any applicable award/agreement** — some restrict requiring employees to supply or
  pay for equipment.
- Confirm the tech's **classification** (employee vs contractor) — it drives super, leave,
  workers' comp and sham-contracting risk (s357), not just this deduction.
  - *Uber precedent:* Australian Uber drivers are **independent contractors** (Fair Work
    Ombudsman 2019; FWC *Gupta* 2020), and since 26 Aug 2024 also **"employee-like workers"**
    — still contractors for tax/most law, but the FWC can set minimum standards. **The label
    doesn't decide it** — the *real substance* of the relationship does (Fair Work Act s15AA):
    control over how/when work is done, financial risk, who supplies tools, integration.
    Our model (assigned "grab" jobs, mandated capture process, required kit, pay deductions)
    carries employee-leaning factors, so don't assume "like Uber = contractor." Get it
    confirmed before scaling.
- **Safest fallback** if in doubt: a **company-OWNED loaner** (Solarsearch keeps title, tech
  returns it on exit, no deduction) — sidesteps s324/326 entirely.

**Design guard:** `drone_loan_accrue()` deducts ONLY when an *active* loan carries a live,
recorded authorisation (`deduction_authorised = true` + `authorised_at`). Creating the loan
and setting the authorisation IS the opt-in — do it only after a lawyer-cleared, signed
agreement. No authorisation (or revoked) = no deduction.

## Drone financing — optional assistance, repaid per job
If the tech takes up the assistance, Solarsearch fronts the drone once-off (e.g. **DJI Neo
~$209**) so cost is never the barrier. Repayment is a small per-job amount, not an up-front hit:
- **`drone_loans`** row: `principal_cents` (what we paid), `per_job_cents` (**$5 = 500c**
  default), `paid_cents`, `status`, plus the authorisation (`deduction_authorised`,
  `authorised_at`, `authorisation_ref`).
- Admin records the signed, voluntary authorisation via `drone_loan_set_authorisation(loan,
  true, ref)`; the tech can revoke (admin sets it `false`) and deductions stop at once.
- On every **billable job** (`completed`/`no_access`), `submit_assessment` calls
  `drone_loan_accrue()` which — **only if the authorisation is live** — deducts **$5** toward
  the balance and logs it on the event trail (`drone_repay_cents`). At $5/job a $209 drone
  clears in ~42 jobs.
- When `paid_cents` reaches the principal the loan flips to **`paid`** — **the drone is
  theirs.**
- **If they stop taking jobs:** the outstanding balance (`principal − paid`) is payable, or
  the drone is returned to Solarsearch (`status = 'returned'`). One active loan per tech
  (enforced by a partial unique index).

This is a **ledger accrual** — it tracks what's owed vs repaid; the actual money nets in
the tech's payout. The tech can read their own loan (RLS `drone_loans_own`).
