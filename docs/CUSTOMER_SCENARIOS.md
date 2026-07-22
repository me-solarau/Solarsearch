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
