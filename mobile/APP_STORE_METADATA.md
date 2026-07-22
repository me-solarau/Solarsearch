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
| Support URL | https://[host]/apply.html | https://[host]/apply.html |
| Marketing URL | https://[host] | https://[host] |
| Privacy Policy URL | https://[host]/app-privacy.html | https://[host]/app-privacy.html |

## Access notes for App Review (important)
These are **not public apps** — access is by application + admin approval. In "App Review
Information" provide **a demo account that is already granted** (an approved sales_rep /
installer login) or reviewers will be blocked at the access gate and reject under 2.1 / 2.3.
Add a note: "Access is by application; use the supplied demo login. Account deletion is under
Earnings → Delete my account (tech) / list screen (installer)."

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
