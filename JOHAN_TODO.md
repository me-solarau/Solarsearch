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

Already deployed & live (no action): `send-booking-confirmation`,
`send-quotes-ready`, `onboard-installer`.

## 3. Apply the one migration that wasn't applied
- [ ] `supabase/migrations/0012_installer_self_read_policy.sql` — declined this
      session. Portal works without it; only the installer-portal header company
      name stays blank until applied. Run it in the SQL editor.

Migrations `0001`–`0011` and `0013`–`0018` are already applied.

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
- [ ] **Twilio SMS** — the scheduling engine's *logic* is built, but there's no
      live SMS send here. Wire real Twilio creds to auto-text customers; today the
      tech offers windows by phone.
- [ ] **Stripe Connect** — payout ledger + batching built; the actual transfer is
      stubbed. Connect Stripe to make `mark_payout_paid` move money.
- [ ] **Business/legal (from the specs)**: WHS roof-access policy (ground + pole
      cam for MVP, §9.1); casual-employment contract + award (§9.2); confirm the
      12-photo set kills the second truck roll with the design team (§9.4); seat
      consent + surveillance-notice wording (solicitor); Pylon export format.
