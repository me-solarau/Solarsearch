# SolarSearch — Launch Marketing Assets

Ready-to-deploy creative for the 1 Aug launch. Companion to `MARKETING_CAMPAIGN.md`.
Positioning throughout: **vetted installers + proven-compliant installs, and the
customer always chooses.** Geography assumed **NSW**; swap suburb/DNSP tokens for
other markets. Nothing here is legal/rebate advice — verify rebate figures with
the rebate owner before publishing exact dollar claims.

---

## 1. Google Search — Responsive Search Ads

**Account structure:** one campaign per intent, tight ad groups by keyword theme,
all pointing at `quote.html` (instant estimate) with the assessment booking as the
conversion. Start **exact/phrase match**, NSW geo, and negative-keyword *"free",
"jobs", "wholesale", "DIY"* to protect intent.

### Ad group A — "solar quotes" (new solar)
**Headlines (mix, pin 1–2 to position 1):**
1. Compare Solar Quotes — NSW
2. Vetted Installers Only
3. Every Install Verified Compliant
4. Free On-Roof Assessment
5. You Choose the Quote — No Pressure
6. Solar Quotes You Can Trust
7. Get 3 Real Quotes, Not Cold Calls
8. Backed by a Compliance Pack
9. NSW Solar, Done Right
10. See Your Estimate in 60 Seconds
11. Cheaper Home Batteries Rebate
12. Accredited. Audited. Guaranteed.
13. No Cowboy Installers
14. Instant Roof-Scan Estimate
15. Book a Free Solar Assessment

**Descriptions:**
1. Every installer is vetted and every job is verified compliant. Get a free on-roof assessment and choose your own quote — no pressure, no cold calls.
2. Instant roof-scan estimate. Real quotes from accredited NSW installers. You pick the winner; we guarantee the standard.
3. Solar without the risk: accredited installers, audit-proof compliance packs, honest rebate maths. Book your free assessment today.
4. Not a lead-seller. A vetted marketplace where the customer always chooses. Start with a 60-second estimate.

### Ad group B — "home battery / battery rebate"
**Headlines:** Add a Home Battery — NSW · Cheaper Home Batteries Rebate · Checked For Your Inverter First · No Guesswork, Honest Quote · Vetted Battery Installers · Free Battery Assessment · Will a Battery Suit Your Solar? · You Choose the Quote · Compliant Battery Installs · Instant Battery Estimate
**Descriptions:**
1. Get the battery rebate the right way — we check your existing inverter before quoting, so the price is honest. Free assessment, vetted installers.
2. Add storage to your solar with accredited installers and a verified-compliant install. Book a free on-roof assessment.

### Ad group C — "solar installer [suburb]" (local intent)
Dynamic-keyword-insertion headline: `{KeyWord:Solar Installers} Near You` +
"Vetted & Accredited" + "Free Assessment". Description leads with local trust +
"you choose the quote."

**Sitelinks:** How it works · Free assessment · Rebates explained · Why vetted matters
**Callouts:** Accredited installers · Compliance pack · No pressure · NSW-wide

---

## 2. Meta (Facebook / Instagram) — ad concepts

Geo-fence to launch postcodes with live supply. Objective: lead (assessment booking).
Retarget `quote.html` visitors who didn't book.

### Angle 1 — "The cowboy-installer fear" (cold, demand creation)
- **Hook (first line):** "Half of Australia's solar complaints trace back to a dodgy install you can't see from the ground."
- **Primary text:** SolarSearch only works with vetted, accredited installers — and every job is photo-verified against the standard and sealed in a compliance pack. You compare real quotes and choose your own. No cold calls, no pressure.
- **Headline:** Solar you can actually trust
- **CTA:** Get a free assessment
- **Creative:** split image — a cracked-tile/dodgy-cabling install vs a clean, labelled, compliant one. Overlay: "Verified compliant."

### Angle 2 — "You choose" (trust / control)
- **Hook:** "What if you picked the solar quote — instead of being sold one?"
- **Primary text:** Free on-roof assessment → real quotes from vetted installers → you choose the winner. We guarantee the install is compliant. That's it.
- **Headline:** The customer always chooses
- **CTA:** Compare quotes free

### Angle 3 — "Rebate, honestly" (rational / battery)
- **Hook:** "The Cheaper Home Batteries rebate is real — but only if your system's quoted honestly."
- **Primary text:** We check your existing inverter *before* quoting, so your battery estimate isn't a guess. Vetted installers, compliant installs, and rebate maths you can see.
- **Headline:** Add a battery the right way
- **CTA:** Get your estimate

### Angle 4 — retargeting (warm)
- **Hook:** "Still comparing? Your free assessment is one tap away."
- Short, social-proof-led ("vetted installers · compliant installs · you choose"), CTA straight to booking.

---

## 3. Cornerstone SEO / trust pages (5)

Publish now; they compound and feed the "trust" angle no competitor writes.

| Page | Target query | Angle |
|---|---|---|
| **Cheaper Home Batteries Rebate NSW 2026 — how it actually works** | "home battery rebate NSW 2026" | Honest, no-hype explainer; incremental-only maths; CTA to estimate |
| **Is my solar installer accredited? How to check (and why it matters)** | "check solar installer accredited" | The trust wedge as content; positions vetting as table-stakes |
| **What a compliant solar install looks like (and the 6 things cowboys skip)** | "solar installation standards Australia" | Visual, authority-building; showcases the compliance pack |
| **How much does solar cost in NSW in 2026?** | "solar cost NSW" | High-volume commercial; funnels to instant estimate |
| **Adding a battery to existing solar — will it work with your inverter?** | "add battery to existing solar" | Scenario ③/⑤ content; the honest-assessment differentiator |

**Draft intro (page 2, to set the voice):**
> Anyone can call themselves a solar installer. Not everyone is accredited to
> certify the work — and the difference shows up years later, on your roof, in
> weather you didn't think about. Here's how to check an installer's accreditation
> in two minutes, what "accredited" actually guarantees, and why SolarSearch
> won't list anyone who isn't.

Each page: one clear CTA to `quote.html` (instant estimate), schema markup,
internal links to the other four.

---

## 4. Landing conversion checklist — `quote.html`

The instant estimate is the money page. Before spend, confirm:
- [ ] Above the fold: address field + "60-second estimate, free assessment" promise.
- [ ] Trust strip immediately visible: "vetted installers · compliant installs · you choose."
- [ ] The estimate result shows the **honest** figure (new capacity, not bill-guessed — see CUSTOMER_SCENARIOS.md) and a single strong CTA to book the assessment.
- [ ] `capture_lead` fires on submit; booking confirmation email works (needs `RESEND_API_KEY` — see punch-list).
- [ ] Conversion event fires to Google/Meta on **assessment booked** (not page view).
- [ ] Mobile-first; sub-2s load (most ad traffic is mobile).

---

## 5. Launch-week runbook

1. **T-7:** supply check — ≥2 installers + 1 sales tech live per launch postcode. Pause any postcode that fails.
2. **T-3:** Google Search live at 20% budget (learning); conversion tracking verified end-to-end with a real test booking.
3. **T-1:** Meta trust creative live, geo-fenced; retargeting audience seeded from Google traffic.
4. **Launch:** full budget on winning ad groups; daily lead→installer ratio check.
5. **T+7:** first cost-per-booked-assessment read; cut losers, scale winners; first compliance packs → case-study + referral assets.
