-- Engagement model: genuine sole-trader contractors. A tech must hold their own ABN and
-- have accepted the contractor terms & conditions before they can be activated / grab jobs.
-- NOTE: an ABN + signed T&Cs do NOT by themselves make someone a contractor — the ATO and
-- Fair Work both apply a "whole-of-relationship" test. These fields are onboarding evidence,
-- not a determination of status. See docs/TECH_TOOLKIT.md.
alter table public.sales_reps add column if not exists abn text;
alter table public.sales_reps add column if not exists abn_verified boolean not null default false;  -- admin/ABN Lookup confirmed active
alter table public.sales_reps add column if not exists contractor_terms_ref text;                     -- signed T&Cs id/link
alter table public.sales_reps add column if not exists contractor_terms_at timestamptz;

-- Activation gate: drone + CASA legals + police check (from 0043) AND now ABN + accepted terms.
create or replace function public.tech_kit_ready(p_rep uuid)
returns boolean language sql stable security definer set search_path=public as $$
  select coalesce(bool_and(x), false) from (
    select r.drone_model is not null and r.drone_model <> '' as x from sales_reps r where r.id = p_rep
    union all select r.drone_registered from sales_reps r where r.id = p_rep
    union all select r.casa_accreditation and coalesce(r.casa_accred_expiry, current_date) >= current_date
             from sales_reps r where r.id = p_rep
    union all select coalesce(r.police_check_expiry, current_date) >= current_date
             from sales_reps r where r.id = p_rep
    union all select r.abn is not null and r.abn <> '' from sales_reps r where r.id = p_rep
    union all select r.contractor_terms_at is not null from sales_reps r where r.id = p_rep
  ) q;
$$;
