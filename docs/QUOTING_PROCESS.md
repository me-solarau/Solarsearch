# Solarsearch — lead → quote → deal → install process

The canonical pipeline. Each stage names the system artifact that carries it, so
quoting is fast and repeatable. Revenue model at the bottom.

## Stages

| # | Stage | Who | System artifact | Output |
|---|-------|-----|-----------------|--------|
| 1 | **Lead** | Customer / funnel | `capture_lead` → `leads` (`existing`/`wants` scope) | `captured` |
| 2 | **Book + site capture** | Sales tech | SMS scheduling → `tech.html` 12-step guided photos + AI validate | `inspected` |
| 3 | **Quote & design** | Consultant | Pylon BOM → **Instant quote** (`quote_estimate`) → `create_design` | `designed` |
| 4 | **Open board** | HQ | `open_board` | `quoted` |
| 5 | **Installer seats** | Installers | `buy_seat` — **$80/seat** to quote | quotes on board |
| 6 | **Customer quoted** | — | `choose.html` (comparison) | — |
| 7 | **Customer selection** | Customer | `sign.html` | `signed` |
| 8 | **Winner fee** | me-solar | **7% of deal value (ex-GST subtotal)**, charged to the winning installer | — |
| 9 | **Install** | Installer **or subcontractor** | **installer-app photo set + completion report (MANDATORY)** | `installed` |
| 10 | **Job complete + reports** | HQ / installer | compliance pack, handover pack, customer report | `closed` |

## Install evidence — customer protection (MANDATORY GATE)
**Every installation must produce an installer-app photo set + completion report
before the job can move to `installed`/`closed` or the installer is paid.** This is
the evidence trail that protects the customer against poor installations and backs
warranty/compliance claims.

- Applies to **both pipelines**:
  1. **Installer pipeline** — the accredited installer who won the seat.
  2. **Subcontractor pipeline** — any subcontractor the installer engages. The sub
     captures the same photo set + report, so the quality chain holds even when
     work is subbed out. The winning installer remains accountable for the sub's evidence.
- Mirrors the sales-tech capture: a guided, geotagged, time-stamped photo protocol
  (array, string/isolators, switchboard, inverter/battery install, labelling,
  earthing, final tidy) + a signed completion report.
- **Roof condition is verified here, by the licensed installer** — the sales visit only
  reads roof *material* (ground/drone/satellite, no roof access). The installer inspects
  and records the roof's condition/suitability on the day, before any load or penetration.
  See `docs/ROOF_SAFETY_AND_LIABILITY.md` (WHS s272 can't be contracted out; sales techs
  never climb).
- **Hard gate:** no photo set + report → no `job complete`, no payout, no report send.
- **Evidence is locked once submitted** — the sales-tech capture set + no-access evidence
  become immutable on submission (DB trigger; admin override only), so the audit trail can't
  be altered after the fact. The installer-app evidence should lock the same way.

## The quote engine (stage 3) — the speed-up
`quote_estimate(payload)` prices any system instantly:

```
customer total (incl GST) =
   ( materials_cost x (1 + material_margin)          -- catalog price x margin (34%)
   + solar labour ($/W by roof x storey, 6.6kW min)
   + DC run ($550/25m + material x1.45 over)
   + AC run (<=10kW flat; >10kW 16mm cable x1.45)
   + battery install ($2000/4-module base +$180/module +$450/stack)
   + backup wiring ($350 3ph / $280 1ph)
   + admin (STC/SAA/CES) )
   x 1.10 (GST)
   - STC rebate   (solar: kW x zone x deeming; battery: CHB tiers x6.8) x $37
```
Validated to the dollar against Pylon ($16,600) and SimPro ($16,672) on Jason Dawe.
Prices are kept current automatically by the **invoice inbox loop** (`ingest-invoice`).

## Revenue model (me-solar)
- **Seat fee: $80** per installer per job (each installer pays to quote; losers only risk $80).
- **Winner fee: 7%** of the deal value (ex-GST subtotal), charged to the installer the customer selects.
- Config: `pricing_config.seat_fee`, `pricing_config.winner_fee_pct`, `pricing_config.winner_fee_base`.
- The **installer's** margin is separate — the 34% material markup + labour rate card (their price to the customer). me-solar earns only seat + winner fee.

## Payment milestones (job value)
Payment is released in three milestones against the job:
- **10% deposit** on **job acceptance** (installer/subcontractor accepts the job).
- **60%** on the **day of completion** — gated by the mandatory install evidence
  (`submit_install`: full photo set + completion report, locked + hashed).
- **30%** on **STC verification** (certificates confirmed/created).

These map to system events: acceptance → deposit; `install.submitted` (status `installed`)
→ 60%; STC verification → final 30%. The payment rails (Stripe) are still stubbed — this is
the schedule to implement.

## Retailer subcontract pipeline
A **retailer** has sold their own job and subcontracts the **installation** to a Solarsearch
accredited installer. They receive the full **compliant installation report** (the guided
install photo set + completion report, start to finish — geotagged, hashed, locked) as their
compliance / warranty / handover record. Same install-evidence gate as every install.

## Gaps still to build (were missing from the first pass)
These sit between the stages above and are needed to make the pipeline complete:

- **Deposit + balance payments** — implement the 10% / 60% / 30% milestone schedule above (Pylon `gateway_payments` / Stripe). Nothing collects money yet.
- **DNSP pre-approval** — Ausgrid export approval before install (Pylon has the field).
- **Install scheduling** — book the install date with customer + installer.
- **STC assignment** — customer assigns STCs to realise the rebate (paperwork).
- **Commissioning / meter / DER registration (DERR)** — grid connection + metering post-install.
- **Compliance sign-off** — SAA design + electrical certificate.
- **Installer payout** — deal value − seat − winner fee → payout ledger (Stripe transfer still stubbed).
- **Structured site facts at capture** — phase, roof type, switchboard spare capacity, existing inverter kW. The quote engine currently *assumes* tin/single/3-phase; these must come from the sales-tech capture so the quote isn't a guess.
- **Installer-app install-evidence capture (mandatory gate, both pipelines)** — the
  guided install photo set + completion report in the installer app, for the
  installer *and* subcontractor pipelines. Gates `job complete` + payout + report
  send. Same AI-validated, geotagged protocol as the sales-tech capture.
