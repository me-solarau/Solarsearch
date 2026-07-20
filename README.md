# Solarsearch — solar & battery comparison (solarsearch.com.au)

Static two-page prototype, vanilla HTML/CSS/JS. No framework, no build-time dependencies — Vite is dev server + bundler only.

## Pages
- `hq.html` — Solarsearch HQ ops app, Supabase-backed, admin-only (`requireRole(['admin'])`)
- `field.html` — field app for on-site visits, Supabase-backed, same admin-only guard. Two job types share one JSON photo protocol: `presale` (a **consultant**'s sales visit ahead of a quote — never call this person an inspector) and `solarsafe` (a genuine post-install compliance **inspection**, sub-mode inferred from the customer's booking reason: safety / battery-ready / battery-installed)
- `schema.sql` / `seed.sql` / `platform_functions.sql` / `rls_hardening.sql` — database: run in Supabase SQL editor in that order for a fresh project; `supabase/migrations/` holds the incremental changes already applied to the live project
- `index.html` — consumer site: instant estimate entry, 4-step model, Solarsafe, rebate calculator; funnel ends in free home-assessment booking with a consultant
- `quote.html` — instant roof-scan quote app; "Compare 3 installers" hands off to index.html via URL params (?src=iq&addr=&bill=&kw=&bat=)
- `solarsafe.html` — Solarsafe consumer site (deploys separately to solarsafe.au); booking funnel creates a real `solarsafe`-mode inspection via `book_assessment`

## Shared conventions (do not break)
- Rebate maths live in the `RULES` object in each page's script (federal Cheaper Home Batteries tiers: 100% ≤14 kWh, 60% 14–28, 15% 28–50; STC factor 6.8, $37/STC, window Jul–Dec 2026). Update in ONE place per file when the factor steps down.
- Design tokens are CSS custom properties in `:root` (eucalypt ink #0F2E27, solar amber #FFB100). All prices/kW/kWh render in Spline Sans Mono.
- All data is demo data and labelled as such. Consent flow: max 3 installers, explicit checkbox before any share.

## Run
npm install && npm run dev
