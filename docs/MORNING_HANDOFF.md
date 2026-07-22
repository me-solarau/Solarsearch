# Morning handoff — apply + verify

Overnight work is committed to `main`. The **DB migrations below could not be applied**
(the Supabase tooling was offline), so apply them first, then the rest works.

## 1. Apply migrations (in order)
Run via Supabase SQL editor / CLI (0054 is already applied):
- `supabase/migrations/0055_install_photos_storage.sql` — installer storage policy
  (install/ prefix in the existing `assessment-photos` bucket).
- `supabase/migrations/0056_access_applications.sql` — access-application + T&C gate
  (`access_applications`, `apply_for_access`, `decide_access`).
- `supabase/migrations/0057_account_deletion.sql` — `account_deletions` +
  `request_account_deletion` (Apple in-app deletion).

If the Supabase MCP is back, they'll also apply cleanly via `apply_migration`.

## 2. What's live once applied
- **Access is by application** — `apply.html`: a signed-in user applies for sales_tech /
  installer / inspector, **must accept the T&Cs**, sees status. Admin grants in
  **HQ → Vetting → "App access applications"** (Grant is blocked until T&Cs accepted).
  After granting, complete provisioning with the existing Onboard technician/installer.
- **Account deletion** — "Delete my account" in `tech.html`, `install.html`, `apply.html`.
- **Installer app** (`install.html`) — install evidence capture (0054 backend already applied);
  uploads work once 0055's storage policy is in.

## 3. Apple / TestFlight (Mac)
`mobile/` has both apps scaffolded (`capacitor.config.ts` = tech,
`capacitor.installer.config.ts` = installer). Follow `mobile/README.md`:
`npm install → copy web → cap add ios → cap open ios → Archive → TestFlight`.
You already run TestFlight (inspector, voya), so the org account is set.

## 4. Open decisions (yours)
- **Install-photo storage**: 0055 reuses the `assessment-photos` bucket (a dedicated
  bucket was declined). Fine to keep, or switch to a dedicated bucket later.
- **Grant → provisioning**: granting an application records the decision; the active role
  is still created by the existing Onboard flow. Say if you want grant to auto-provision.
- **Inspector app** lives outside this repo; the same `apply.html` records its applications,
  but its provisioning/app is separate.

## 5. Sanity checks after applying
- HQ → Vetting shows the "App access applications" panel.
- Submit a test application from `apply.html` → it appears in HQ → Grant works only with
  T&Cs accepted.
- Installer uploads a photo in `install.html` → lands in `install/<id>/...` and a row in
  `install_photos` with sha256.
