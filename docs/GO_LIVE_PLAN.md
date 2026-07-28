# Go-live plan — 1 Aug 2026

**Going live = full marketing + the front of the funnel working** (lead → sales → quote →
sign). Fulfilment has a **~14-day runway**: nothing reaches install until jobs sign and get
accepted, so the install/edge/cleaning/STC/payment machinery can land in the fortnight after
launch, before the first job rolls.

## Go-live critical (must work 1 Aug) — front of funnel
- Marketing site + lead capture (`capture_lead`) — ✅
- Email / signups (Resend SMTP fixed) — ✅
- Sales-tech app: assess + AI photo validation (`tech.html`) — ✅ built; **needs real sales-tech
  accounts provisioned**
- **Quote engine** (`quote_estimate`) — ✅; **no edge-protection line needed** (see below)
- Installer board + seats + quoting — ✅
- Customer comparison → sign (`choose` → `sign`) — ✅
- Access apply → grant → provision — ✅
- **Real go-live accounts** — sales tech(s) + installer(s), granted — ⬜ needs doing

## Fast-follow — 14-day runway (fulfilment)
Install evidence capture · edge-protection job (installer-billed) · cleaning pipeline · STC
retailer approval · 60%/30% milestone payments · Stripe live.

## Locked stream designs

### Edge protection (mandatory height-safety) — customer-visible line, passed through to the crew
> **Spec change (Johan, superseding the earlier provider-billed model).** Edge protection was
> previously hidden from the customer and billed by Solarsearch to the installer or retailer.
> It is now a **visible line on every customer quote**. The old model is recorded below under
> "Superseded" so the change is traceable.

- **Mandatory on EVERY installation, retail and installer** — a Safe Work Australia height-safety
  requirement, not an optional extra and not a negotiable line.
- **$180 incl per 20 linear metres, minimum charge**, rounded up to whole 20m blocks, plus
  **$30/day** after **3 included days**.
- **The customer sees it.** It is added to all quotes as its own line, so the price the customer
  compares and signs already includes the height-safety cost. No post-signature variation.
- **Money path: customer → installer → crew.** The customer pays the installer as part of the
  quoted job; the installer passes that amount to the booked edge-protection crew. Solarsearch
  does not sit in the middle of this leg.
- **Perimeter is measured at the design/assessment stage**, so the quoted distance is known at
  quote time rather than estimated. Stored on `designs.edge_perimeter_m`.

**Superseded (kept for traceability):** Solarsearch billed the winning installer on the main
pipeline, and the **retailer** (not the subcontractor) on the retailer/subcontract pipeline, with
nothing shown to the customer. The customer-visible pass-through above replaces the main-pipeline
leg. **Open question for Johan:** whether the retailer/subcontract pipeline also moves to the
pass-through model or keeps retailer-billed — not yet decided, so nothing has been changed there.

**Build state (as at this writing):**
- `edge_protection_price(perimeter_m)` / `edge_protection_cents(perimeter_m)` — live, `$180` per
  started 20m block, rate in `pricing_config`.
- `instant_quote()` — includes the edge-protection line.
- `customer_board()` / `customer_proposal()` — include `edge_protection_cents`, `edge_perimeter_m`,
  `edge_perimeter_measured` and `total_payable_cents` (migration `0075`). `choose.html` states the
  charge once above the board and folds it into every headline price; `sign.html` shows it as its
  own line above **Total payable** and explains the pass-through in the terms.
- `price_after_cents` is deliberately **unchanged** — it remains the installer's own quoted price,
  so commission, deals and milestone payments keep reading the number they always did. Edge
  protection rides alongside it in `total_payable_cents`.
- `customer_sign()` snapshots the full breakdown (installation, rebate, edge protection, perimeter,
  total) into the append-only `proposal.signed` event, so a later re-measure or price-book change
  cannot rewrite what the customer agreed to.
- Perimeter capture UI in `hq.html` — **still outstanding.** `designs.edge_perimeter_m` exists but
  nothing collects it, so every live quote currently falls back to the one-block $180 minimum and
  the customer copy says the figure is confirmed before signing. This is the next piece of work.
- Runway build: capture roof perimeter at assessment; an edge-protection job that bills the right
  party per pipeline (installer vs retailer) and pays the contractor.

### Solar cleaning — standalone service, lead-based
- Enters as a **lead** (marketing funnel) or **manual lead input** in HQ, on request.
- Quoted by system size (adjustable in `pricing_config`; `cleaning_price(kW)` helper):
  ≤6.6 = $250 · ≤13.2 = $299 · ≤20 = $375 · ≤30 = $499 · >30 = custom quote.
- Assigned to a **Solar Cleaner** contractor.
- Runway build: `cleaning` lead type → cleaning quote view → cleaner job + assignment; HQ price editor.

### Both roles
Independent contractors, **12-month term, renewable on performance**. Applyable via
`apply.html` + listed on "Work with us"; granted in HQ → Vetting. (Live now.)

## Done for these streams (committed)
- Role vacancies (`edge_protection`, `cleaner`) in the access gate + apply/join pages + HQ labels.
- Pricing stored in `pricing_config` (edge protection + cleaning tiers) + `cleaning_price()`.

## Immediate next (go-live critical)
1. Provision real **sales-tech** + **installer** go-live accounts (sign up → apply → grant).
2. End-to-end funnel smoke test: lead → assessment → quote → board → choose → sign.
Then work the 14-day runway list in fulfilment order.
