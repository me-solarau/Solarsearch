# Stripe — what we need (payment milestones + commission)

Money flows between parties (customer/retailer → installer/subcontractor) and Solarsearch
takes a cut, so the product is **Stripe Connect**, not plain Payments.

## Key decision — who holds the money
- **A (recommended): Solarsearch collects, then pays out.** Customer/retailer pays Solarsearch;
  we route the installer's share and keep our commission as the platform fee. Best for
  milestones, holding funds until completion, and audit.
- B: direct-to-installer with a skimmed fee — harder for milestones/escrow. Not recommended.

## Stripe setup checklist
- [ ] Activate account; enable **Connect** (platform profile + branding).
- [ ] **Express** connected accounts for everyone who receives money (installers,
      subcontractors, retailers on the subcontract side) — Stripe-hosted KYC + bank onboarding.
- [ ] API keys (secret + publishable), **test mode** first.
- [ ] **Webhook endpoint** (a Supabase edge function) + signing secret.
- [ ] Charge model: **one PaymentIntent per milestone** (10/60/30), **destination charges**
      with `application_fee_amount` = commission on that slice.
- [ ] (Optional) Stripe Invoicing / Tax for GST on the commission.

## Supabase secrets to add
- `STRIPE_SECRET_KEY`
- `STRIPE_WEBHOOK_SECRET`

## Milestones ↔ existing events (triggers already exist)
| Milestone | % | Trigger |
|-----------|---|---------|
| Deposit | 10% | `install.accepted` (`accept_install`) |
| Completion | 60% | `install.submitted` (`submit_install`) |
| STC | 30% | STC verification |

## Commission (retailer subcontract)
10% of job value = **5% retailer + 5% subcontractor**. Invoice basis is the
`subcontract_commission` view (0060). Main pipeline is separate: seat $80 + winner 7%.

## Build (edge functions) — DONE, sandbox-ready
Written and committed; they run the moment `STRIPE_SECRET_KEY` (+ later `STRIPE_WEBHOOK_SECRET`)
are in Supabase secrets. DB side is migration **0061_stripe_payments.sql**.
- `stripe-onboard` — creates an **Express** connected account (AU), stores `stripe_account_id`
  on installers/retailers, returns a hosted **Account Link**; return page is `stripe-return.html`.
- `create-milestone-payment` — admin-only; PaymentIntent **destination charge** to the installer's
  connected account, `application_fee_amount` = commission on that slice; flips milestone to `processing`.
- `stripe-webhook` — signature-verified, event-id deduped; `payment_intent.succeeded` → milestone
  `paid`, `payment_failed` → `failed`, `charge.refunded` → `refunded`.

### DB (0061)
- `installers.stripe_account_id`, `retailers.stripe_account_id`; `current_retailer_id()` helper.
- `pricing_config.milestone_deposit_pct / _completion_pct / _stc_pct` (10/60/30).
- `payment_milestones` (one row per milestone per install; RLS: admin + own installer/retailer).
- `build_payment_milestones(install)` — computes the three slices + per-slice application fee.
- `stripe_events` — webhook idempotency ledger.

## To go live in sandbox (your steps)
1. **Add `STRIPE_SECRET_KEY`** (the `sk_test_…` from Developers → API keys) to
   **Supabase → Edge Functions → Secrets**. *(Do not paste it in chat.)*
2. Deploy the three functions.
3. Add the webhook endpoint in Stripe → `https://<project>.functions.supabase.co/stripe-webhook`,
   subscribe to `payment_intent.succeeded/…failed`, `charge.refunded`, `account.updated`, then
   add its signing secret as **`STRIPE_WEBHOOK_SECRET`**.
4. (Optional) `PUBLIC_SITE_URL` secret so Account-Link return URLs point at your domain.
