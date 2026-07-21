# Sales Technician — SMS + Push build plan
Closing the last ~30% that makes the dispatch loop feel like Uber Eats:
**automated customer SMS scheduling** and **real-time job-ping notifications.**

Grounded in what already exists: Supabase (Postgres + RLS + Edge Functions +
Storage), static JS pages, and the technician track already built
(`sales_reps`, `assessments`, `technician_availability`, `grab_job` /
`schedule_visit` / `submit_assessment`, and the route-efficient window
generator currently running client-side in `tech.html`).

---

> **Status: Part A is BUILT** (migration `0022_sms_scheduling_engine.sql`, five
> `sms-*` Edge Functions, `tech-badge.html`, and the tech/HQ wiring). Decisions
> locked in: numbered replies **+ keywords** (RESCHEDULE/CANCEL/STOP), reminders
> via **Twilio Scheduled Messages**, windows generated **server-side** by the
> `technician_windows` RPC. What's left is config, not code — Twilio secrets +
> the inbound webhook (see `JOHAN_TODO.md` §2a). Part B (push) is still a plan.

## Part A — Twilio SMS scheduling engine (scope §3C, §5.1)

### What Johan provides first
- Twilio account; a **Messaging Service** (preferred) or a dedicated AU number.
- Sender registration for AU (Twilio handles ACMA sender-ID; confirm alphanumeric
  vs number — AU allows both, number needed for two-way).
- Supabase Edge Function secrets: `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`,
  `TWILIO_MESSAGING_SERVICE_SID` (or `TWILIO_FROM_NUMBER`).
- A **server-restricted Google key** for Distance Matrix (routing moves
  server-side; don't reuse the referrer-restricted browser key).

### Data model (migration)
- `sms_messages` — every message, both directions, for dispute protection (§6):
  `id, lead_id, assessment_id, direction ('out'|'in'), to_number, from_number,
  body, twilio_sid, status, created_at`. RLS: admin all; technician read own
  (via assessment ownership).
- `assessments` add: `offered_windows jsonb` (the 2–3 ISO slots we texted),
  `schedule_state text` ('offered'|'confirmed'|'reschedule'|'cancelled'),
  `reminder_sent_at`, `eta_sent_at`.
- Move the **window generator server-side** (it's client JS today): a
  `technician_windows(p_assessment_id)` RPC or inline in the Edge Function,
  using availability + confirmed run + Distance Matrix (cached in
  `travel_cache`). This is required because the SMS engine, not the browser,
  now proposes the windows.

### Edge Functions
1. **`sms-send`** — thin service-role helper: POST to Twilio, insert an
   `sms_messages` row. Every other function calls this (single log point).
2. **`sms-offer-windows`** — trigger: on `grab_job` (auto) or an HQ/tech
   "text customer" action. Computes 2–3 route-efficient windows, stores them on
   the assessment, sends the intro SMS (tech first name + verification badge
   link + numbered windows), logs.
3. **`sms-inbound`** — the **Twilio inbound webhook** (this is the conversational
   engine). Parses the customer's reply:
   - `1|2|3` or a matched time → call `schedule_visit` server-side, send
     confirmation, unlock address, set `schedule_state='confirmed'`.
   - `RESCHEDULE` / `CANCEL` → re-offer windows or release the claim.
   - `STOP` / opt-out → honour + flag; never message again.
   - Unparseable → fallback reply + flag for HQ to phone.
   Validate Twilio signature (`X-Twilio-Signature`) so only Twilio can post.
4. **`sms-reminder`** — day-of reminder. Fired by a scheduler (pg_cron if
   available, else Twilio Scheduled Messages set at confirm time, else a
   Supabase scheduled Edge Function). Sets `reminder_sent_at`.
5. **`sms-eta`** — the **"On my way"** button in `tech.html` calls it → texts the
   customer an ETA. Sets `eta_sent_at`.

### Flow
grab → `sms-offer-windows` (auto) → customer replies → `sms-inbound` →
`schedule_visit` + confirm SMS + address unlocked → day-of `sms-reminder` →
tech taps On-my-way → `sms-eta` → visit.

### Compliance / guardrails
- Opt-out (STOP) honoured and stored; quiet-hours window (no sends 9pm–8am
  local); the customer already consented to contact at lead capture (record the
  consent version on the thread).
- Rate-limit per lead; never re-text a confirmed or cancelled job.
- Cost: ~2–5 SMS per booked job; Distance Matrix cached per postcode pair.

### Frontend changes
- `tech.html`: replace the manual/phone window flow with "SMS sent — awaiting
  reply" state; add the **On my way** button (calls `sms-eta`); show the thread.
- HQ: a "text customer" fallback + the SMS thread on the lead drawer.

---

## Part B — Push notifications ("ping, new job near you")

Two stages: a fast web-push interim, then the native wrap the doc's Phase 1
actually specifies.

### B1 — Web Push (interim, works on today's `tech.html`, no app store)
- **Prereqs:** generate VAPID keypair (a one-off script; no external account).
- **Data model:** `push_subscriptions` (`sales_rep_id, endpoint, p256dh, auth,
  platform, created_at`). RLS: rep owns their own.
- **Frontend:** a service worker (`sw.js`) + a "Turn on job alerts" prompt in
  `tech.html` that registers the subscription.
- **Dispatch:** an Edge Function `notify-pool` — when a lead becomes
  pool-eligible (`appointment_set` in a postcode), find techs whose regions
  cover it + who are available, and web-push them "New $50 job in {suburb}".
  Trigger it from the booking path (or a lightweight Postgres `NOTIFY` +
  scheduled drain).
- **Caveat:** iOS web push only works if the tech **adds the PWA to their home
  screen** (iOS 16.4+) and is less reliable than native. Fine as an interim /
  Android-first; not the finish line.

### B2 — Native wrap + FCM/APNs push (the real unlock, doc Phase 1)
- **Prereqs (Johan):** Apple Developer account, Google Play account, a
  **Firebase project (FCM)** for push, and a **Codemagic** account (iOS builds
  with no Mac — matches the kickoff doc's stack).
- **Wrap:** Capacitor around `tech.html` (or a trimmed build). Add the
  `@capacitor/push-notifications`, camera, and geolocation plugins; set the iOS
  permission-usage strings (camera/location/notifications) — Apple rejects
  without them. Add the in-app **"apply to become a technician"** path (Apple
  rejects a pure login wall).
- **Push:** device registers an FCM/APNs token → store in `push_subscriptions`
  (reuse the table, `platform='ios'|'android'`). `notify-pool` sends via FCM
  instead of / alongside web push.
- **Payments guardrail (§3.6):** payouts stay Stripe Connect *outside* the app —
  never add an in-app purchasable digital benefit, or Apple IAP obligations
  trigger.
- **CI:** Codemagic pipeline → TestFlight / Play internal testing → store review.

---

## Sequencing & rough effort (build-sessions)
1. **A — SMS engine** (`sms_messages` + 5 Edge Functions + server-side windows +
   `tech.html`/HQ wiring): ~2–3 sessions. *Biggest UX unlock.*
2. **B1 — Web push interim** (VAPID + `push_subscriptions` + `sw.js` +
   `notify-pool`): ~1 session. Fast "it pings" win, Android-solid.
3. **B2 — Native wrap + FCM + Codemagic + store submission**: ~3–4 sessions
   plus store-review calendar time; gated on the dev accounts.

## What blocks each (all yours, not code)
- **A:** Twilio account + AU sender + secrets; server-side Google key.
- **B1:** nothing external (VAPID is self-generated) — buildable immediately.
- **B2:** Apple Developer + Google Play + Firebase + Codemagic accounts.

## Open decisions to confirm before building A
- Reply UX: numbered windows (`1/2/3`) vs natural-language parsing (recommend
  numbered + keywords + human fallback — cheap and robust).
- Scheduler for reminders: pg_cron vs Twilio Scheduled Messages vs Supabase
  scheduled functions (recommend Twilio Scheduled Messages — no cron dependency).
- Verification-badge link in the intro SMS: a public `tech-badge.html?rep=` page
  showing the tech's name/photo/accreditation so the customer trusts the door
  knock.

---

*Recommendation: build **B1 (web push)** first — it's the one piece here with no
external blocker and it delivers the "ping, new job" feel immediately on Android
and installed-PWA iOS. Then **A (SMS)** once Twilio is set up. **B2 (native)**
last, gated on the store/dev accounts.*
