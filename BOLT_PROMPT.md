PASTE THIS AS YOUR FIRST MESSAGE IN BOLT AFTER IMPORTING:

---
This is Solarsearch (solarsearch.com.au) — an AI-powered solar lead & deal
engine for the Newcastle/Hunter pilot. Vanilla HTML/CSS/JS pages served by
Vite, plus a Supabase schema.

Pages:
- index.html  — consumer site. Funnel ends in a FREE HOME ASSESSMENT BOOKING
  (not an instant installer comparison — quotes happen after inspection).
- quote.html  — instant roof-scan estimate (ad landing); hands off to
  index.html funnel via ?src=iq params.
- hq.html     — Solarsearch HQ (lead inbox, pipeline, board, deals, campaigns).
- field.html  — Inspector field app: JSON photo protocol (PROTOCOL const),
  both modes, completion gate, offline queue stub. Mobile-first.
- installer.html — Installer portal: Site Quoted board with $200 seat purchase,
  price book (Path-1), rectifications, billing.
- choose.html — Customer magic-link page: identical-design quote comparison,
  consent-gated choice (agent-model wording — do not alter legal lines).
- solarsafe.html — Solarsafe consumer site (deploys separately to solarsafe.au).

Database:
- schema.sql then seed.sql — run in the Supabase SQL editor, in that order.
  Business invariants live in the DB (append-only events, 3-seat cap,
  reviewer-required audit release). Do not re-implement them client-side only.

Rules for working on this project:
1. Keep it vanilla — no React/Tailwind conversion unless I ask.
2. Never alter the RULES rebate objects or :root design tokens.
3. Preserve consent flows and the "customer always chooses" mechanics.
4. First task: npm install && npm run dev, verify all three pages and the
   quote→index handoff, then connect hq.html's data layer to Supabase
   (the adapter is clearly marked at the top of its script; mapping notes
   are in README.md). Then wait for instructions.
---
