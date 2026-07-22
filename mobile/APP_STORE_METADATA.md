# App Store Connect — metadata & privacy labels (both apps)

Prepared so the App Store Connect / TestFlight forms are copy‑paste. Two apps, same
Apple org account you already use for inspector + voya.

## Bundle IDs
- Sales Technician — `net.solarme.solarsearch.tech`
- Installer — `net.solarme.solarsearch.installer`

## Listing (fill/adjust)
| Field | Sales Technician | Installer |
|-------|------------------|-----------|
| Name | Solarsearch Tech | Solarsearch Installer |
| Subtitle | Solar site assessments | Solar install evidence |
| Category | Business | Business |
| Description | Field app for engaged Solarsearch sales technicians: accept jobs, capture guided, geotagged site photos, and submit assessments. | Field app for engaged Solarsearch installers: capture the mandatory install photo set + completion report. |
| Keywords | solar, assessment, field, installer | solar, install, evidence, field |
| Support URL | https://www.solarsearch.com.au/apply.html | https://www.solarsearch.com.au/apply.html |
| Marketing URL | https://www.solarsearch.com.au | https://www.solarsearch.com.au |
| Privacy Policy URL | https://www.solarsearch.com.au/app-privacy.html | https://www.solarsearch.com.au/app-privacy.html |

## Access notes for App Review (important)
These are **not public apps** — access is by application + admin approval. In "App Review
Information" provide **a demo account that is already granted** or reviewers will be blocked at
the access gate and reject under 2.1 / 2.3.

> **Demo login must be single-role.** Do NOT hand Apple an admin account (it routes to HQ, not
> the field app). Create a dedicated reviewer account whose only role is the app under review —
> `user_roles.role = 'sales_rep'` for the Field app, `'installer'` for the Installer app — so
> sign-in lands directly in the app being reviewed. (johan@me-solar.com.au is an admin and is
> **not** suitable as a demo login.)

Reviewer note to paste: "Access is by application; use the supplied demo login, which is already
approved. In-app account deletion: Field app → Earnings → Delete my account; Installer app →
menu → Delete my account. No purchase is required to use the app."

## App Privacy labels (must match app-privacy.html)
- **Data used to track you:** None.
- **Data linked to you** (purpose: App Functionality):
  - Contact Info — name, email, phone
  - Location — Precise Location
  - User Content — Photos (site/install evidence)
  - Identifiers — User ID
  - Diagnostics — optional
- **Data not linked to you:** Diagnostics (if any).
- No third‑party advertising; no data sold.

## Apple requirements checklist
- [ ] Apple Developer **Organization** account (you have one — inspector/voya).
- [ ] Info.plist usage strings (camera / location / photo library) — see README.
- [ ] **Privacy Policy URL** live at `/app-privacy.html` (replace the [bracketed] fields first).
- [ ] **In‑app account deletion** — already built (`request_account_deletion`).
- [ ] **Sign in with Apple** — only if you add Google/Facebook login; email/OTP alone doesn't need it.
- [ ] Demo login for reviewers (approved + granted).
- [ ] App icons + launch screen.
