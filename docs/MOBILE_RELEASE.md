# Taking the sales-tech & installer apps to Apple (iOS)

> Planning note. Verify against current Apple guidelines (App Store Review Guidelines,
> App Store Connect) before committing — Apple's rules change.

## Where we are today
- **Sales-tech app** = `tech.html`, a live web app (camera, GPS, Supabase auth/storage,
  SHA-256 hashing). Not yet packaged for iOS.
- **Installer app** = **not built yet** — the install-evidence pipeline (guided photo set +
  completion report + the same lock/hash/verify chain) is still backlog. Build it before
  packaging.

## First decision — distribution (these are B2B tools for our own contractors)
| Path | Use when | Review friction |
|------|----------|-----------------|
| **TestFlight** | Roll out to our techs/installers now (≤10k testers, 90-day builds) | Minimal — start here |
| **Apple Business Manager – Custom App** | Private, org-only, no public listing | Light |
| **Public App Store** | Anyone can download | Highest — Apple rejects B2B tools the public can't use (G4.2/4.3); needs a demo login |

**Recommended:** TestFlight → Custom App (private). Public App Store only if non-contractors
should find it, and then supply a working demo account for review.

## Technical path — wrap, don't rebuild
Use **Capacitor** to wrap the existing web app in a native WKWebView shell with native
plugins (Camera, Geolocation, Push, Filesystem). Reuses `tech.html` almost as-is. Apple
rejects "just a website" wrappers (G4.2), so the app must genuinely use native features —
ours does (camera, GPS).

## Apple checklist
- **Apple Developer Program** — US$99/yr; **Organization** account (company D-U-N-S number).
- **Mac + Xcode**, or a CI builder (Codemagic / EAS / Xcode Cloud) to sign & submit.
- App icons, launch screen, bundle IDs.
- **Info.plist permission strings** (mandatory): `NSCameraUsageDescription`,
  `NSLocationWhenInUseUsageDescription`, `NSPhotoLibraryUsageDescription`.
- **Privacy policy URL** + **App Privacy labels** in App Store Connect (we collect location,
  photos, identifiers).
- **In-app account deletion** (G5.1.1(v)) — required for any app with logins.
- **Sign in with Apple** — only required if we offer other social logins (Google/Facebook);
  email/OTP via Supabase alone doesn't trigger it.
- **Demo/reviewer account** if going public.

## Gaps to close before submitting (exist in the current web app)
1. **Auth in WebView** — Supabase magic-link redirects are painful in WKWebView; move to OTP
   codes or native deep links.
2. **Offline capture queue** — field dead zones; today photos upload live and fail on poor
   signal. Queue locally, upload when back online (also protects GPS/hash capture).
3. **Native push (APNs)** for job offers/ETA — needs the Capacitor Push plugin + server APNs.
4. **Native camera plugin** — more reliable than `<input capture>`; cleaner control of the
   image bytes we hash.
5. **Build the installer app** — nothing to ship until the install-evidence pipeline exists.

## Sequence
1. Close the gaps (offline queue is the big field-reliability one).
2. Wrap `tech.html` in Capacitor; add native camera/GPS/push + account deletion.
3. Apple Developer org account → build → **TestFlight** to techs.
4. Build the installer app; wrap it the same way.
5. Choose public vs private distribution per the table.

(Capacitor also outputs an **Android** build from the same wrap — near-free if we want Play too.)
