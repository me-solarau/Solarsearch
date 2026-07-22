# TestFlight this afternoon — ordered runbook

Everything in the repo is now consistent and Apple‑ready. This is the exact order for
getting both apps into TestFlight, plus the handful of items only you can do.

## What's already done (in the repo)
- Two clean Capacitor projects: `mobile/field` + `mobile/installer` (stale duplicate configs removed).
- Correct live host on both: `https://www.solarsearch.com.au`.
- Consistent bundle IDs: `net.solarme.solarsearch.tech` / `net.solarme.solarsearch.installer`.
- Launcher "Apply" buttons route to the T&C application flow (`/apply.html?role=…`).
- In‑app account deletion (5.1.1(v)) present in both apps.
- `app-privacy.html` filled (entity, ABN 95 665 045 465, hosting region); live at `/app-privacy.html`.
- `mobile/APP_STORE_METADATA.md` — listing text, privacy labels, single‑role demo‑login note.

## Decisions to confirm before you archive
1. **Bundle IDs** — confirm `net.solarme.solarsearch.tech` / `…installer` match (or get registered as)
   App IDs under your Apple team. Change `appId` in the two `capacitor.config.ts` first if not.
2. **Installer app home** — currently a signed‑in installer lands on `/installer.html` (the portal:
   browse/win jobs); the install‑evidence capture (`/install.html`) is reached per job. If you'd
   rather the app open straight into capture, say so and I'll switch the route.
3. **Demo login for review** — you need one **single‑role** account per app (not admin). See below.

## Human‑only prerequisites
- **App icon** — a 1024×1024 PNG (no alpha) per app. Add in Xcode's asset catalog. (Not in repo.)
- **Signing** — your Apple Developer Team in Xcode (same org as inspector/voya).
- **Demo accounts** — create two accounts, each with exactly one role:
  - Field reviewer: `user_roles.role = 'sales_rep'` (approved) → lands in `/tech.html`.
  - Installer reviewer: `user_roles.role = 'installer'` (approved) → lands in `/installer.html`.
  (Ask me and I'll provision these cleanly once you've picked emails/passwords.)

## Build → TestFlight (per app, on the Mac)
```bash
cd mobile/field            # then repeat for mobile/installer
npm install
npx cap add ios
npx cap sync
npx cap open ios
```
In Xcode:
1. Signing & Capabilities → select your **Team**; confirm the **bundle id**.
2. Add **Info.plist** usage strings (camera / location / photo library — in `mobile/README.md`).
3. Add the **app icon**.
4. **Product → Archive** → Distribute App → **TestFlight**.
5. In App Store Connect → TestFlight → add internal testers → install via TestFlight app.

## First smoke test in TestFlight
- Launch → you should see the launcher (Field / Installer), then **Sign in**.
- Sign in with a **single‑role** account → lands in the right app.
- Camera + location prompts appear on first capture (proves the Info.plist strings).
- "Delete my account" is reachable.

## Still open elsewhere (not blockers for internal TestFlight)
- New‑user **email signups** (Resend SMTP username `resend`, or keep Confirm‑email off for now).
- **Stripe** sandbox card‑charge test.
- App Privacy **address/phone** in `app-privacy.html` before *public* submission.
