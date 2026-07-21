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
- [ ] Set Edge Function secrets: `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, and
      `TWILIO_MESSAGING_SERVICE_SID` (a Messaging Service is required for the
      scheduled day-of reminder; a bare `TWILIO_FROM_NUMBER` also works for
      live sends but not scheduling). Optional: `PUBLIC_SITE_URL` (defaults to
      `https://solarsearch.com.au`) for the trust-badge link in the intro SMS.
- [ ] In the Twilio Console, set the Messaging Service **inbound webhook** to
      the deployed `sms-inbound` URL
      (`https://<project>.supabase.co/functions/v1/sms-inbound`), method POST.
      The function verifies `X-Twilio-Signature` with your auth token, so only
      Twilio can drive scheduling. If a proxy rewrites the URL and signatures
      fail (Twilio error 57012), set the `SMS_INBOUND_URL` secret to the exact
      public webhook URL.
- [ ] (Recommended) A **server-restricted Google key** for Distance Matrix if
      you later want travel-time-optimised windows; today the generator uses
      availability + same-day clustering, no external key needed.
- [ ] Optional: point a scheduler (pg_cron / GitHub Action) at `sms-reminder`
      as a belt-and-braces backstop — the primary reminder already goes out as
      a Twilio Scheduled Message at confirm time.

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

Migrations `0001`–`0011`, `0013`–`0019`, and `0021` are already applied.

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
