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

### Edge protection (mandatory height-safety) — INSTALLER-BILLED, not a customer quote line
- Solarsearch provides edge protection via the **Edge Protection Installer** contractor and
  **bills the installer**: **$180 incl per 20m linear, rounded up to whole 20m blocks**, based on
  the **roof edge/perimeter length captured at the site assessment**. **$30/day** after **3
  included days**.
- The **installer** may pass this on to their customer as a variation — Solarsearch does **not**
  put edge protection on the customer-facing quote.
- Runway build: capture roof perimeter at assessment; an edge-protection job billed to the
  installer + paid to the contractor.

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
