# Solarsearch — solar & battery lead + deal engine (solarsearch.com.au)

Vanilla HTML/CSS/JS pages served by Vite, backed by Supabase (Postgres + RLS +
Edge Functions + Storage). No framework. Every page is a Vite input in
`vite.config.js`.

## The pipeline (all real, end to end)

`captured → contacted → qualified → appointment_set (booked) → inspected →
designed → quoted (on board) → customer_chose → signed → connection_approved →
installed → der_registered → closed`

The front of the pipeline has **two site-visit paths that both hand off at
`inspected`** and then share everything downstream:

- **Sales Technician** — a gig field operator (`sales_reps` + `assessments`)
  who claims validated jobs, attends, and takes a **guided 12-step photo set**
  with AI validation. No selling. App: `tech.html`.
- **Consultant** — a staff member (`staff` role `consultant`, `inspections`)
  who sits down with the customer and consults/sells. App: `field.html`.

They coexist — one is guided photo capture, the other is a sales consultation.

## Pages
- `index.html` — consumer funnel; ends in a free home-assessment booking.
- `quote.html` — instant roof-scan estimate (ad landing) → hands to index.html.
- `solarsafe.html` — Solarsafe consumer site (deploys separately to solarsafe.au).
- `choose.html` — customer magic-link quote comparison (`?token=`).
- `sign.html` — customer magic-link e-signature of the chosen proposal.
- `hq.html` — Solarsearch HQ (admin): lead inbox, board, deals, **Field ops**
  (technician dispatch, reliability, payouts), Vetting + onboarding, campaigns.
- `tech.html` — Sales Technician app (`sales_rep` login): pool, grab, run sheet
  with route economics, capture, availability, earnings.
- `installer.html` — Installer portal (`installer` login): Site Quoted board,
  seat purchase + auto-quote. Price-book/rectifications/billing tabs still demo.
- `field.html` — Consultant/Solarsafe inspection capture app.
- `login.html` — role-routed sign-in. `privacy.html`, `collection-notice.html`.

## Database
- Base: `schema.sql`, `seed.sql`, `platform_functions.sql`, `rls_hardening.sql`
  (run in that order for a fresh project).
- Incremental changes already applied to the live project: `supabase/migrations/`
  (`0001`–`0019`, `0021`). **Not yet applied / declined:** `0012` (installer
  self-read policy — portal works without it), `0020` (compliance_pack RPC),
  `0022` (Twilio SMS scheduling engine). See `JOHAN_TODO.md`.
- Edge Functions in `supabase/functions/`: `send-booking-confirmation`,
  `send-quotes-ready` (Resend email); `onboard-installer`, `onboard-technician`
  (account provisioning); `validate-assessment-photo` (Claude-vision photo
  check); `sms-send`, `sms-offer-windows`, `sms-inbound`, `sms-reminder`,
  `sms-eta` (Twilio SMS scheduling engine — the customer books a visit by
  replying to a text; `sms-inbound` is the Twilio webhook, signature-verified).
  **The onboarding, vision, and sms-* functions were not deployed this session —
  deploy from the Supabase dashboard before those flows work.**

## Config the deployment needs
Vercel env (Production + Preview): `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`,
`VITE_GOOGLE_MAPS_API_KEY` (Places + Distance Matrix/Routes enabled; restrict by
referrer). Supabase Edge Function secrets: `RESEND_API_KEY` (booking + quotes
emails), `ANTHROPIC_API_KEY` (live technician photo validation — auto-passes
until set), `TWILIO_ACCOUNT_SID` / `TWILIO_AUTH_TOKEN` /
`TWILIO_MESSAGING_SERVICE_SID` (SMS scheduling — a Messaging Service is required
for scheduled reminders), optional `PUBLIC_SITE_URL` (trust-badge link base).

## Conventions (do not break)
- Rebate maths live in the `RULES` object in each page's script and in the
  `buy_seat` RPC (federal Cheaper Home Batteries tiers 100% ≤14 kWh / 60% /
  15%; STC factor 6.8, $37/STC; solar 34 STC/kW). Keep client and RPC in step.
- Design tokens are CSS custom properties in `:root` (eucalypt ink #0F2E27,
  solar amber #FFB100). Prices/kW/kWh render in Spline Sans Mono.
- Consent flows and the "customer always chooses" mechanics are load-bearing;
  the agent-model legal lines on `choose.html`/`sign.html` are not to be altered.
- All installer/technician/customer access to other people's data goes through
  `SECURITY DEFINER` RPCs; base tables stay locked to admin/self under RLS.

## Run
`npm install && npm run dev`
