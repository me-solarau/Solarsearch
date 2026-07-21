# Solarsearch native apps — iOS/Android prep (Capacitor)

Two App Store apps wrap the existing web experience. They load the hosted
launcher pages over the network (so the apps update over-the-air, no
resubmission for content changes) while adding the native capabilities Apple
expects — push, camera, geolocation — through Capacitor plugins.

| App | Bundle ID | Wraps | Launcher | Roles |
|-----|-----------|-------|----------|-------|
| **Solarsearch Field** | `au.com.solarsearch.field` | `tech.html` + `field.html` | `/app-field.html` | Sales Technician, Consultant |
| **Solarsearch for Installers** | `au.com.solarsearch.installer` | `installer.html` | `/app-installer.html` | Installer |

Project skeletons live in `mobile/field/` and `mobile/installer/`. The native
Xcode/Android projects are **generated on demand** (`npx cap add ios`) — they're
not committed, so nothing here is Mac-specific until build time.

## What each launcher does (already built + deployed with the web app)
- Checks the Supabase session and routes by role
  (`sales_rep → tech.html`, `admin → field.html`, `installer → installer.html`).
- Shows a **Sign in** button **and** an **Apply** form for people with no
  account yet — this satisfies Apple Guideline 5.1.1/4.3 (a pure login wall is
  rejected). Applications land in the `role_applications` table (migration
  `0024`) and surface in HQ Vetting.
- Registers for native push on launch (`src/lib/native-push.js`) and stores the
  APNs/FCM token in `push_subscriptions` (`platform='ios'|'android'`) — the same
  table web push uses.

## What Johan must set up (accounts — not code)
1. **Apple Developer Program** membership (US$99/yr).
2. **App Store Connect**: create both apps with the bundle IDs above.
3. **APNs Auth Key** (.p8) in Certificates, IDs & Profiles — for push.
4. **Google Play** account + (optional now) an Android track.
5. **Codemagic** account, connected to the repo, with:
   - the App Store Connect integration saved as `solarsearch_appstore`,
   - an environment group named `appstore`.
6. **Firebase (FCM)** project — only needed for Android push and (optionally) as
   a unified push sender. iOS push can go straight through APNs.

## Build & ship (Codemagic — no Mac required)
`codemagic.yaml` at the repo root defines two workflows (`field-ios`,
`installer-ios`). Each: installs Capacitor deps, runs `cap add ios` + `cap sync`,
injects the iOS permission strings, signs with your App Store Connect
integration, builds the IPA, and submits to **TestFlight**. Trigger a workflow
from the Codemagic UI (or wire it to a git tag).

To build locally instead (if you do have a Mac):
```bash
cd mobile/field         # or mobile/installer
npm install
npx cap add ios
npx cap sync ios
npx cap open ios        # opens Xcode → set your team, Archive → upload
```

## Remaining server-side piece for native push (B2)
`notify-pool` currently sends **web** push (VAPID). Native tokens are already
being captured in `push_subscriptions` (`platform` ios/android). To deliver to
native devices, extend `notify-pool` to also POST to **FCM** (Firebase can relay
to both APNs and Android) for rows where `platform <> 'web'`. That needs the
Firebase server key as an Edge Function secret — do it when the apps are in
TestFlight and you're ready to test device push.

## Guardrails baked in
- **No in-app purchases** anywhere (installer seats + payouts are billed outside
  the app via Stripe), so Apple's IAP obligations never trigger.
- iOS permission usage strings are set at build time (camera / location / photos)
  — Apple rejects builds that use those APIs without them.
- The apps admit only their intended roles; everyone else gets the apply path.

## Store-listing narrative (helps review pass)
- **Field app**: "Field tool for verified Solarsearch technicians and
  consultants to receive nearby job assignments, capture guided site photos, and
  record attendance." Demo account required — provide a TestFlight/review login
  with a seeded job in the pool.
- **Installer app**: "Portal for accredited solar installers to view
  pre-designed, site-verified jobs and manage quotes." Provide a review login.
