# Morning handoff

Everything below is **committed to `main` and live** unless marked PARKED or NEEDS YOU.
Overnight the DB tooling was intermittently declining writes, so anything requiring a new
migration that wasn't already applied is called out explicitly.

## ✅ Shipped & live tonight
- **Email signups fixed** — Supabase SMTP now uses username `resend` + the branded sender
  `noreply@solarsearch.com.au` (domain verified in Resend). Confirmation emails deliver;
  Confirm-email can stay ON. This was the last hard blocker. (Dashboard change — no code.)
- **`admin@solarsearch.com.au` is the admin** — `user_roles.role = 'admin'` set. Sign in with
  it → HQ. `johan@me-solar.com.au` was **repurposed** (see next).
- **Multi-role access** (migration `0065` applied + `auth-guard.js` + build pushed):
  - `my_access()` returns every role a login holds (admin via `user_roles`; sales_rep /
    installer / retailer via approved identity records).
  - `requireRole()` now admits a page if the user holds ANY of its allowed roles — one login
    can enter every app it legitimately holds. Admin pages still require admin; field pages
    admit identity-holders. No RLS change.
  - **`johan@me-solar.com.au`** is now a multi-role test account: `sales_rep` + `installer` +
    `retailer` (all approved), primary landing = Tech. **No longer admin.** Verified via
    impersonation: `my_access` = {sales_rep:true, installer:true, retailer:true, admin:false}.
- **Role switcher** — a small floating "Apps ▾" control appears for multi-role logins
  (`mountRoleSwitcher`), wired into `tech.html` / `install.html` / `installer.html`. No-op for
  single-role users. (Retailer has no portal page yet, so it's omitted from the switcher.)

## ✅ Already live from earlier (unchanged)
- **Stripe Connect (sandbox)** — `stripe-onboard`, `create-milestone-payment`, `stripe-webhook`
  deployed; migration `0061` (10/60/30 milestone ledger); webhook Active; both secrets set.
- **apply→grant→provision** fixed (`0062`) — installer provisioning uses `auth_uid` (was the
  silent-failure bug).
- **Installer contact reveal** (`0063`) — `installer_jobs()` reveals customer name/mobile/email
  + address to the **assigned** installer only; `install.html` wired; DB-verified (owner sees,
  rival sees nothing).
- **Apple prep** — two clean Capacitor projects (`mobile/field`, `mobile/installer`), correct
  `www` domain, T&C apply flow, `app-privacy.html` filled. See `docs/APPLE_TESTFLIGHT_TODAY.md`.

## ⏸️ PARKED (written, not applied, not committed) — your call
- **Retailer STC link** — `supabase/migrations/0064_stc_verification.sql` holds the
  **retailer-approval** design: `submit_stc_photo()` (subcontractor uploads the formal STC
  photo) + `verify_stc()` (retailer reviews, approves → emits `stc.verified` to authorise the
  final 30%). Subcontract pipeline only; money movement stays a separate step. **Not applied,
  not committed** (repeatedly parked). Apply when you're ready; then the 30% has an auditable
  trigger like the 10%/60% do.
- **Connection-approval (DNSP) gate** — the rule "install can't start until the DNSP app is
  approved" is not enforced (`start_install` only checks status). Noted, not built.

## ⏳ NEEDS YOU (can't be done from here)
- **Demo accounts for TestFlight** — 3 single-role accounts (Field `sales_rep`, Installer
  `installer`, Installer rival). Now that email works, sign each up through the app, submit an
  application, and grant in HQ. Ping me the emails and I'll verify + build a demo assigned-
  install for the reveal check.
- **TestFlight** — Mac + Xcode. Runbook: `docs/APPLE_TESTFLIGHT_TODAY.md`. Decisions in there:
  confirm bundle IDs, installer app home, app icon.
- **Stripe sandbox card charge** — needs a KYC-completed connected account + card confirmation
  (`4242…`). I'll drive the DB/function side when you're ready.
- **Retailer portal** — there's no `retailer.html` yet; the retailer STC approve button + STC
  photo viewer live there when it's built.

## Sanity checks when you're back
- Sign in as `admin@solarsearch.com.au` → lands in HQ.
- Sign in as `johan@me-solar.com.au` → lands in Tech; the "Apps ▾" switcher (top-right) lets
  you hop to Installer. (Retailer has no page yet.)
- A brand-new signup → confirmation email arrives from `noreply@solarsearch.com.au` → confirm →
  `/apply.html` → submit application → appears in HQ → Vetting → grant → auto-provisions.
