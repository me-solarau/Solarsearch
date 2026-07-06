# Solarsearch — solar & battery comparison (solarsearch.com.au)

Static two-page prototype, vanilla HTML/CSS/JS. No framework, no build-time dependencies — Vite is dev server + bundler only.

## Pages
- `hq.html` — Solarsearch HQ ops app (demo data; wire to Supabase per platform notes below)
- `schema.sql` / `seed.sql` — database: run in Supabase SQL editor in order
- `index.html` — consumer site: instant estimate entry, 4-step model, Solarsafe, rebate calculator; funnel ends in free home-assessment booking
- `quote.html` — instant roof-scan quote app; "Compare 3 installers" hands off to index.html via URL params (?src=iq&addr=&bill=&kw=&bat=)

## Shared conventions (do not break)
- Rebate maths live in the `RULES` object in each page's script (federal Cheaper Home Batteries tiers: 100% ≤14 kWh, 60% 14–28, 15% 28–50; STC factor 6.8, $37/STC, window Jul–Dec 2026). Update in ONE place per file when the factor steps down.
- Design tokens are CSS custom properties in `:root` (eucalypt ink #0F2E27, solar amber #FFB100). All prices/kW/kWh render in Spline Sans Mono.
- All data is demo data and labelled as such. Consent flow: max 3 installers, explicit checkbox before any share.

## Run
npm install && npm run dev
