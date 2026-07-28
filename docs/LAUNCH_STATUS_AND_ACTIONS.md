# SolarSearch — Launch Status & Co-Pilot Action Card

_Live-verified snapshot. Supersedes the notification/deploy sections of
`JOHAN_TODO.md`, which predate the current state (functions ARE deployed,
migrations ARE applied)._

## ✅ Verified working (live)
- **Leads dashboard** — 12 leads across the pipeline (5 booked · 3 inspected ·
  3 captured · 1 signed). Now visible to admin (see fix below).
- **All Edge Functions deployed & ACTIVE** — `admin-leads`, email senders,
  `notify-pool`, the five `sms-*`, `validate-assessment-photo`, onboarding,
  stripe, invoice/evidence.
- **All migrations applied** (SMS engine, push, role applications, compliance
  pack, edge protection/cleaning, etc.).
- **SMS (Kudosity) — LIVE.** `sms-send` returns 200; `sms-inbound` is processing
  real customer STOP/confirm replies. Secrets set, webhook wired.

## ✅ Fixed this session
- **Admin access → leads now bubble.** The HQ dashboard is gated by `is_admin()`
  (reads single-role `user_roles`). `johan@me-solar.com.au` was mis-roled as
  `sales_rep`, so `is_admin()` was false and RLS hid every lead. Promoted it to
  `admin` (idempotent, for all active admin-staff). `admin@solarsearch.com.au`
  was already admin. Both now see all leads; multi-role capabilities unaffected
  (sales_rep/installer/retailer derive from their own identity tables).

## 🔑 Co-pilot actions — the only things blocking full notifications (~15 min)
Both are Supabase/Vercel **secret settings** — no API, must be done in-dashboard.

### 1. Email (Resend) — `send-booking-confirmation` currently returns 503
- Supabase → project **Solarsearch** → Edge Functions → Secrets → set
  **`RESEND_API_KEY`**.
- ⚠️ **Verify `solarsearch.com.au` at resend.com/domains first.** The Resend
  account is in testing mode — until the domain is verified it can only email
  `johan@me-solar.com.au`, so customer booking confirmations will keep failing.
- Once set: the 5 already-booked leads won't retro-send, but every new booking
  emails the customer + the "quotes ready" magic link works.

### 2. Web push (VAPID) — `notify-pool` currently returns 503
- Repo: `npm install && npm run gen-vapid` → prints a keypair.
- Supabase Edge secrets: `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`,
  `VAPID_SUBJECT=mailto:hello@solarsearch.com.au`.
- Vercel env (Prod+Preview): `VITE_VAPID_PUBLIC_KEY` = the public key → redeploy.
- Then techs get "new job near you" pushes (iOS needs Add-to-Home-Screen first).

## 🧭 Decisions for Johan (unblock the marketing campaign)
From `MARKETING_CAMPAIGN.md` — confirm and the plan is ready to execute:
1. **Geography** — NSW-first assumed. Correct?
2. **Launch paid budget tier** — Seed ($3–5k) / Launch ($8–15k) / Scale ($25k+)?
3. **Demand:supply ratio** — 70:30 assumed for launch.

## ⚠️ Recommended hardening (needs a decision — production auth)
The signup trigger `link_staff_on_signup` matches a **hardcoded email**
(`neo.venom02@gmail.com`) that matches *no current account*, and `staff` has no
`email` column to match on — which is how the owner got mis-roled. A durable fix
(e.g. add `staff.email` + match on it, or an explicit admin-invite flow) needs
your call on the intended mechanism before touching production auth. Flagging,
not guessing.

## 📦 Delivered this session (branch `claude/lead-engine-fix-and-campaign`)
- `docs/MARKETING_CAMPAIGN.md` — full go-to-market strategy.
- `docs/MARKETING_LAUNCH_ASSETS.md` — Google/Meta ad copy, SEO pages, runbook.
- `docs/LAUNCH_STATUS_AND_ACTIONS.md` — this file.
- DB: admin role fix applied to the live project.
