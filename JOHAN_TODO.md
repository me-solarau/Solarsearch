# Johan — to-do when you're home

Everything on your side to make this session's build fully live + testable.
Ordered so you can go top to bottom. (Claude built the code; these are the
deploy/config/verify steps only Claude couldn't do from the sandbox.)

## 1. Set Edge Function secrets (Supabase → Project → Edge Functions → Secrets)
- [ ] `RESEND_API_KEY` — turns on real email (booking confirmation + "quotes
      ready" magic link). Get it from resend.com → API Keys. Until set, those
      functions return 503 and the funnels degrade silently.
- [ ] `ANTHROPIC_API_KEY` — turns on live technician photo AI validation. Until
      set, `validate-assessment-photo` auto-passes every photo.

## 2. Deploy the Edge Functions that weren't deployed this session
(These deploys were declined mid-session, so the code is in `supabase/functions/`
but not live. Deploy from the Supabase dashboard or CLI.)
- [ ] `onboard-technician` — **required** for HQ → Vetting → "Onboard technician".
- [ ] `validate-assessment-photo` — the Claude-vision photo check (§9.4). App
      falls back to auto-pass until this is live.
- [ ] `sms-send`, `sms-offer-windows`, `sms-inbound`, `sms-reminder`, `sms-eta`
      — the Twilio SMS scheduling engine (below). Deploy all five.

Already deployed & live (no action): `send-booking-confirmation`,
`send-quotes-ready`, `onboard-installer`.

### 2a. Twilio SMS engine — turn it on
The whole conversational scheduling loop is built (server generates windows →
texts the customer → they reply 1/2/3 → it books itself → day-of reminder →
"On my way"). To make it send for real:
Provider = **Kudosity** (Transmit SMS API, `https://api.transmitsms.com`), AU
2-way number **61430251786**. (Twilio was dropped — US 10DLC compliance pain.)
- [ ] Set Edge Function secrets (Supabase → Edge Functions → Secrets):
      `KUDOSITY_API_KEY` + `KUDOSITY_API_SECRET` (from Kudosity → Developers →
      API Settings), `KUDOSITY_FROM_NUMBER` = `61430251786`, and
      `SMS_INBOUND_SECRET` = any long random string (webhook auth). Optional:
      `PUBLIC_SITE_URL` (defaults `https://solarsearch.com.au`) for the badge link,
      `KUDOSITY_API_BASE` only if the API host ever changes.
- [ ] In Kudosity → Developers → **API Settings** → **Receive Message Callback
      URL**, paste:
      `https://vbpzigwgfmchdpvxetge.supabase.co/functions/v1/sms-inbound?secret=<SMS_INBOUND_SECRET>`
      (same secret value as the function secret). This is the reply webhook —
      `sms-inbound` authenticates on that `?secret=` since Kudosity doesn't sign
      requests. "Global Opt Out List" stays Enabled (Kudosity honours STOP too).
- [ ] Reminders go out as Kudosity scheduled sends (`send_at`), computed in
      Australia/Sydney — keep the Kudosity account timezone on Sydney so the
      day-of reminder lands at the right time.
- [ ] (Recommended) A **server-restricted Google key** for Distance Matrix if
      you later want travel-time-optimised windows; today the generator uses
      availability + same-day clustering, no external key needed.

### 2b. Web push — "ping, new job near you" (B1)
No external account needed — VAPID keys are self-generated.
- [ ] `npm install` then `npm run gen-vapid` — prints a VAPID keypair.
- [ ] Vercel env (Prod + Preview): `VITE_VAPID_PUBLIC_KEY` = the public key,
      then redeploy (Vite bakes env at build).
- [ ] Supabase Edge Function secrets: `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`
      (keep secret), `VAPID_SUBJECT` = `mailto:hello@solarsearch.com.au`.
- [ ] Apply migration `0023_push_subscriptions.sql`.
- [ ] Deploy the `notify-pool` Edge Function.
- Then: in `tech.html` the pool shows **"Turn on job alerts"**; once a tech
  enables it, every new booked job in their postcodes pushes to their phone
  (auto-fired from the booking path; HQ can also re-ping via **appointment_set
  → "Ping available techs"**). iPhone note: web push needs the tech to **Add to
  Home Screen** first (iOS 16.4+); Android works in-browser. Native app (B2)
  removes that caveat — see `MOBILE.md`.

## 3. Apply the migrations that weren't applied
- [ ] `supabase/migrations/0012_installer_self_read_policy.sql` — portal works
      without it; only the installer-portal header company name stays blank.
- [ ] `supabase/migrations/0020_compliance_pack.sql` — the `compliance_pack`
      RPC that `pack.html` renders. Until applied, the "Compliance pack" action
      in HQ opens a page that can't load.
- [ ] `supabase/migrations/0022_sms_scheduling_engine.sql` — the SMS engine's
      data model: `sms_messages` log, assessment scheduling columns, the
      `technician_windows` window generator, the service-role confirm/cancel/
      reschedule RPCs, `customers.sms_opt_out`, and the public `tech_badge` RPC.
      Required before the five `sms-*` functions do anything.
- [ ] `supabase/migrations/0023_push_subscriptions.sql` — web/native push
      subscriptions + the service-role targeting RPCs (see §2b).
- [ ] `supabase/migrations/0024_role_applications.sql` — the public "apply to
      work with us" table the native apps post to (anon insert, admin read).
      Required for the App Store apps' in-app signup path.

Migrations `0001`–`0011`, `0013`–`0019`, and `0021` are already applied.

## 3b. Native apps (iOS / Android) — see `MOBILE.md`
Two App Store apps are scaffolded (`mobile/field`, `mobile/installer`) with
launchers, native push wiring, in-app apply, and a Codemagic pipeline. It's all
code + config; the rest is your accounts (Apple Developer, App Store Connect,
APNs key, Codemagic, optional Firebase). Nothing here blocks tomorrow's web
testing — the apps are the next-step packaging, not needed for the pilot.

## 4. Verify config (probably already fine)
- [ ] Vercel env (Production + Preview): `VITE_SUPABASE_URL`,
      `VITE_SUPABASE_ANON_KEY`, `VITE_GOOGLE_MAPS_API_KEY` all present.
- [ ] Google Maps key referrer allowlist includes `solarsearch.com.au`,
      `www.solarsearch.com.au`, `solarsafe.au` (and `localhost` for dev). Places
      + Distance Matrix/Routes are already enabled on it.

## 5. End-to-end pilot walk-through (proves the whole pipeline)
Nobody has run the full chain live yet — the sandbox can't reach the browser
→ Supabase path. This is the real first test.
- [ ] HQ → Vetting → **Onboard installer** (postcode that has a real booked
      lead, e.g. 2324 / 2290). Save the temp password.
- [ ] HQ → Vetting → **Onboard technician** (same postcode). Save temp password.
- [ ] Log into **tech.html** as the technician → set **Availability** → the
      booked lead shows in the **Job pool** → **Grab** → **Confirm time** (pick a
      generated window) → **Start visit** → capture the 12 steps (AI checks each)
      → **Submit**. Lead should move to `inspected`.
- [ ] Back in HQ: the lead → **Create design** → **Open installer board**.
- [ ] Log into **installer.html** as the installer → the site appears →
      **Buy seat** (generates the Path-1 auto-quote).
- [ ] HQ → the quoted lead → **Email comparison to customer** (needs
      `RESEND_API_KEY`) or **Copy customer board link**.
- [ ] Open **choose.html?token=…** → pick the quote → **sign.html** → sign →
      lead at `signed`.
- [ ] HQ → post-sale actions: Connection approved → Mark installed → Register
      DERR → Close job. And Field ops → **Batch last 7 days** → Mark paid.

Report anything that breaks and Claude will fix it.

## 6. Still genuinely blocked (need your accounts / decisions — not code)
- [ ] **Twilio SMS** — now fully built end-to-end (5 functions + data model +
      HQ/tech wiring). Only your Twilio creds + inbound webhook are left; see
      §2a above. Until then the tech offers windows by phone (manual confirm
      still works).
- [ ] **Stripe Connect** — payout ledger + batching built; the actual transfer is
      stubbed. Connect Stripe to make `mark_payout_paid` move money.
- [ ] **Business/legal (from the specs)**: WHS roof-access policy (ground + pole
      cam for MVP, §9.1); casual-employment contract + award (§9.2); confirm the
      12-photo set kills the second truck roll with the design team (§9.4); seat
      consent + surveillance-notice wording (solicitor); Pylon export format.
