# What's Left — full state of play

_Written from live-verified data (database, Edge Function logs, deployed
functions), not from older to-do files. Two products are in play:_

- **SolarSearch** (`solarsearch.com.au`) — the consumer lead & deal engine. **This
  is the revenue engine and the priority.**
- **Solarsafe Installer** — the B2B compliance SaaS sold to other retailers. A
  separate, secondary track.

---

## PART A — Where things actually stand (verified)

### ✅ Working
| Thing | Evidence |
|---|---|
| Lead capture | 12 leads captured, 7 in the last 7 days |
| **Leads dashboard** | Fixed this session — admin role repaired, leads now visible |
| SMS (Kudosity) | 27 messages logged; `sms-send` 200s; real customer replies (STOP/confirm) processed by `sms-inbound` |
| All Edge Functions | Every function deployed and ACTIVE |
| All migrations | Applied through to today |
| Assessments / tech app | 4 assessments completed; 3 leads reached `inspected` |
| Solarsafe Installer site | Live, public, building on every push |

### ⚠️ The big finding: **the back half of the funnel has never run**

```
designs = 0     quotes = 0     seats = 0
```

Leads flow **capture → booked → inspected** and then stop. The chain
**design → installer board → buy seat → quote → customer chooses → sign** has
never been exercised with real data. (The single `signed` lead did not come
through that chain — there are no quotes behind it.)

This matters more than anything else on this list: **it is the part of the
pipeline that produces revenue**, and it is entirely unproven. `GO_LIVE_PLAN.md`
flagged this ("nobody has run the full chain live yet"); it is still true.

### ⚠️ Supply side is not ready
| Gap | Detail |
|---|---|
| Installers can't log in | 2 of 3 installer records have **no `auth_uid`** — including "Pilot Installer Pty Ltd". They cannot open `installer.html`, so they cannot buy seats or quote. |
| Johan's tech profile has **no regions** | `sales_reps.regions = []` → the job pool is region/postcode-scoped, so he will see an empty pool. |
| 1 access application **pending** | Someone applied for `sales_tech` and is waiting on a decision in HQ → Vetting. |
| No push subscriptions | 0 techs have enabled job alerts (blocked by VAPID config below). |

---

## PART B — What's left, by track

### 1. Notifications — blocked only on secrets _(co-pilot, ~15 min)_
All code is written and deployed. Each item is a dashboard setting:

| Set this | Where | Unblocks |
|---|---|---|
| **`HQ_ALERT_SMS`** (e.g. `61430251786`) | Supabase → Edge Functions → Secrets | **Text on every new lead.** Highest value, works today — Kudosity is already live, needs nothing else. |
| `HQ_ALERT_EMAIL` = `hello@solarsearch.com.au` | same | Email on every new lead (needs Resend below) |
| `RESEND_API_KEY` | same | Booking confirmations + "quotes ready" magic link (currently **503**) |
| `VAPID_PUBLIC_KEY` / `VAPID_PRIVATE_KEY` / `VAPID_SUBJECT` | same (`npm run gen-vapid` first) | Tech job-alert push (currently **503**) |
| `VITE_VAPID_PUBLIC_KEY` | Vercel env + redeploy | Lets techs subscribe at all |

⚠️ **Resend is in testing mode** — until `solarsearch.com.au` is verified at
resend.com/domains it can only email `johan@me-solar.com.au`. Verify the domain
or customer emails keep failing.

### 2. Merge the branch _(Johan's call)_
Branch **`claude/lead-engine-fix-and-campaign`** (6 commits) holds the new-lead
alert wiring, the notification error-surfacing fix, and all campaign docs. The
client changes only reach the live site when this merges to `main`. No PR opened.

### 3. Prove the money half of the funnel _(Johan + co-pilot, highest priority)_
Nothing about revenue is trustworthy until this runs once, end to end:
1. Give the approved installers **logins** (HQ → Vetting → Onboard installer) —
   without `auth_uid` they cannot participate at all.
2. Set **regions/postcodes** on Johan's sales-rep profile so the job pool populates.
3. Decide the **pending sales_tech application**.
4. Then walk one real lead: assessment → **create design** → installer board →
   **buy seat** → quote → `choose.html` → `sign.html`.
5. Fix whatever breaks (this is where I expect to find real bugs — that code has
   never run against live data).

### 4. Marketing — 3 decisions, then execute _(Johan)_
Strategy and creative are written (`MARKETING_CAMPAIGN.md`,
`MARKETING_LAUNCH_ASSETS.md`). Blocked on:
- **Geography** — NSW-first assumed?
- **Budget tier** — Seed $3–5k / Launch $8–15k / Scale $25k+?
- **Demand:supply ratio** — 70:30 assumed?

Then: Google Search live on `quote.html`, conversion tracking on *assessment
booked* (not page views), 5 cornerstone SEO pages, Meta trust creative.

**Hard rule: do not advertise into a postcode with no installers.** Right now
that means *no postcode is ad-ready* until item 3 is done. Spending before then
buys leads nobody can fulfil — and the whole brand promise is reliability.

### 5. Fulfilment runway — the 14 days after launch
Per `GO_LIVE_PLAN.md`, these can land after launch but before the first install:
install evidence capture · edge-protection job billing (installer vs retailer) ·
cleaning pipeline · STC retailer approval · 60/30 milestone payments · Stripe
live. Three of these are the open tasks already on the board (#6, #7, #8).

### 6. Solarsafe Installer (B2B) — secondary track
- Marketing site **live**; lead form wired to `demo_requests` + Resend + a
  Kudosity SMS drop-in.
- **Untested:** I fixed the RLS policy that was rejecting submissions *after*
  your last test, so capture should now work but **has not been confirmed** —
  one test submission on `solarsafe-installer.vercel.app` will prove it (I can
  check the table the moment you submit).
- Email alerts there are blocked by the same Resend testing-mode limit.
- The product itself is a **Phase 0 scaffold** — schema, RLS and stage
  definitions exist; the actual capture app, AI verification and compliance pack
  are Phases 1–5, i.e. a substantial build not yet started.

### 7. Hardening / debt _(needs a decision)_
- **Admin role fragility.** The signup trigger matches a **hardcoded email**
  (`neo.venom02@gmail.com`) that matches no current account, and `staff` has no
  `email` column — which is exactly how the owner account ended up mis-roled and
  locked out of its own dashboard. Needs a decision on the intended mechanism
  (add `staff.email` and match on it, or an explicit admin-invite flow) before I
  touch production auth.
- `supabase/migrations/0064_stc_verification.sql` has an **uncommitted edit** from
  an earlier session, sitting in the working tree. Not mine — someone should
  decide whether it's wanted.
- Notification failures were invisible for weeks because of `.catch(()=>{})`.
  Fixed on the branch, but worth a broader look at silent failure paths.

---

## PART C — Who does what

**Only Johan / co-pilot can do:** set secrets (no API), verify the Resend domain,
grant logins/vetting decisions in HQ, run a browser end-to-end test, merge to
`main`, make the campaign and hardening decisions, spend ad budget.

**I can do next, on request:** open the PR; fix whatever the end-to-end walk
breaks; implement the auth hardening once the mechanism is chosen; build the
runway items (#6–#8); write the SEO page content; continue the Solarsafe
Installer phases.

---

## PART D — Recommended order

1. **Set `HQ_ALERT_SMS`** — 2 minutes, and you feel the lead engine working immediately.
2. **Verify the Resend domain + set `RESEND_API_KEY`** — turns on every customer email.
3. **Give installers logins + set Johan's tech regions + clear the pending application.**
4. **Walk one lead end-to-end through design → seat → quote → sign.** Report breakages; I fix them.
5. **Merge the branch.**
6. **Answer the 3 campaign questions**, then turn on Google in seeded postcodes only.
7. Runway items + hardening.

The gap between "leads arriving" and "money arriving" is step 4. Everything else
is either already working or a switch to flip.
