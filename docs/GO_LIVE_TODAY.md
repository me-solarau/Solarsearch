# Go live today — decisions locked, and the 4 things only a human can do

Everything I could decide or execute is **done and live**. What remains is a
short list that is physically impossible for me (dashboard secrets, DNS, and one
commercial number). Work top to bottom.

---

## 🛑 BLOCKER #1 — a price that will sell jobs at a loss

**Do not let a real quote go out until this is confirmed.**

ME-SOLAR's price book has:

```
solar_per_kw_cents = 35000     ->  $350 per kW
```

Pilot Installer's book, identical in **every other field**, has:

```
solar_per_kw_cents = 135000    ->  $1,350 per kW   (also the code default)
```

That looks like a **missing leading "1"**. It is why the end-to-end test quote
came out at **$4,106** for 6.6 kW + 10 kWh (before rebate $14,910, rebate
$10,804 — arithmetic verified). At $350/kW a real job is sold roughly **$6,600
under** where the reference rate puts it.

**I deliberately did not "fix" this** — inventing someone's commercial pricing is
worse than surfacing it. Set the real number in HQ / the installer's price book
before any customer sees a quote. Two price books carry the suspect value
(`8a2b8b06…` and `54e90b70…`, both ME-SOLAR).

---

## ✅ Decisions I made for you (data-driven, change any of them)

| Decision | Locked as | Why |
|---|---|---|
| **Geography** | **Newcastle & Greater Hunter only** (not all NSW) | It is the *only* region with postcodes configured (45) and the only one with any supply. Advertising outside it sends leads nowhere. |
| **Budget tier** | **Seed ($3–5k/mo), Google Search only** | You currently have **one** installer able to log in and **one** sales tech. Seed is what that capacity can absorb without breaking the reliability promise. Step up once supply grows. |
| **Demand : supply split** | **30 : 70 for now** (not the 70:30 in the campaign doc) | Supply is the binding constraint, not demand. Flip to 70:30 once each target postcode has ≥2 active installers + 1 tech. |
| **Launch postcodes** | Only where supply exists today | Hard rule from the campaign plan: never advertise into a postcode without an installer. |

Rationale in full: `MARKETING_CAMPAIGN.md`. Creative is ready to run in
`MARKETING_LAUNCH_ASSETS.md`.

---

## 🔧 The 4 human-only actions

### 1. Turn on new-lead alerts — 2 minutes, biggest immediate win
Supabase → project **Solarsearch** → Edge Functions → **Secrets**:

```
HQ_ALERT_SMS = 61430251786          (or whichever mobile should be texted)
```

That alone gets you **texted the moment any lead lands**. It needs nothing else —
Kudosity is already live and proven. The `notify-new-lead` function is deployed
and wired into the site; it is inert only because this secret is missing.

### 2. Turn on email
Same Secrets screen:

```
RESEND_API_KEY  = <from resend.com -> API Keys>
HQ_ALERT_EMAIL  = hello@solarsearch.com.au
```

⚠️ **First verify `solarsearch.com.au` at resend.com/domains.** Resend is in
testing mode and can currently only send to `johan@me-solar.com.au`, so booking
confirmations and "quotes ready" links will keep failing until the domain is
verified. This is the one step with a DNS dependency — start it early.

### 3. Turn on tech push (optional today)
```bash
npm install && npm run gen-vapid
```
Supabase secrets: `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`,
`VAPID_SUBJECT=mailto:hello@solarsearch.com.au`
Vercel env (Prod+Preview): `VITE_VAPID_PUBLIC_KEY` → redeploy.

### 4. Fix the price (see BLOCKER #1) and grow supply
- Confirm the real `$/kW`.
- Onboard **Pilot Installer Pty Ltd** — it has 44 service postcodes but **no
  login**, so it can never see a job (HQ → Vetting → Onboard installer).
- Decide the **1 pending sales_tech application** sitting in HQ → Vetting.
- Merge the **duplicate ME-SOLAR installer record** (`2a8f5d1a…` vs
  `4179e524…`, created 4 minutes apart). I left both intact rather than delete
  business data.

---

## ✅ Already done and live (no action needed)

- **Leads visible in HQ** — admin role repaired; 12 leads showing.
- **Auth hardened** (`0070`) — staff match by email, admin role granted
  automatically. The hardcoded-email landmine that locked you out is gone.
- **Sales-rep pool** — 0 → 5 jobs (empty `regions` fixed).
- **Installer board** — 0 → 1 job (missing service areas + price book fixed).
- **`customer_board()` bug fixed** (`0071`) — it crashed for **every** customer
  opening their comparison link. Found only because the funnel was finally run
  end to end.
- **Full funnel proven**: capture → booked → inspected → designed → quoted →
  seat → customer chose → **signed**, producing the first ever design, seat,
  quote, proposal and deal (demo lead **SS-1017**, marked `is_demo`).
- **`notify-new-lead`** deployed; site now alerts on capture, not just booking.
- **Notification failures now visible** — the old `.catch(()=>{})` hid the 503s
  for weeks; all notify calls now log.
- **Merged to `main`** — production build verified, Vercel deploying.

---

## Order of play today

1. Set **`HQ_ALERT_SMS`** → feel the lead engine working immediately.
2. Start the **Resend domain verification** (DNS takes time) → then the key.
3. Confirm the **$/kW price**.
4. Onboard the second installer + clear the pending application.
5. Only then point any ad spend at Hunter postcodes.

Leads and the dashboard are live now. Steps 1–2 make them *audible*. Step 3 is
what makes them *safe to sell*.
