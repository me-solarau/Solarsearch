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

## Build (edge functions, when ready)
- `stripe-onboard` — Account Links; store `stripe_account_id` on installers/retailers.
- `create-milestone-payment` — PaymentIntent + application fee for a milestone.
- `stripe-webhook` — mark milestones paid, release payouts, reconcile to the DB.
