-- Required sales-tech kit + drone financing.
-- Hard rule: an approved tech must carry a drone and hold the CASA legals to fly it
-- for work (register the drone + RPA Operator Accreditation). The drone is how we
-- ELIMINATE the roof-climbing WHS risk (see docs/ROOF_SAFETY_AND_LIABILITY.md), so it
-- is mandatory kit like a car+licence is for a rideshare driver.
-- Solarsearch fronts the drone once-off; the tech repays it as a $5 (500c) deduction
-- per billable job until it's paid off, then it's theirs. If they stop taking jobs,
-- the outstanding balance is payable or the drone is returned.

alter table public.sales_reps add column if not exists drone_model text;
alter table public.sales_reps add column if not exists drone_registered boolean not null default false;   -- CASA drone registration (commercial, ≤500g free, annual)
alter table public.sales_reps add column if not exists drone_rego_ref text;
alter table public.sales_reps add column if not exists casa_accreditation boolean not null default false;  -- RPA Operator Accreditation (free, 3yr)
alter table public.sales_reps add column if not exists casa_accred_expiry date;

-- Is the tech's mandatory kit complete enough to be activated / grab jobs?
create or replace function public.tech_kit_ready(p_rep uuid)
returns boolean language sql stable security definer set search_path=public as $$
  select coalesce(bool_and(x), false) from (
    select r.drone_model is not null and r.drone_model <> '' as x from sales_reps r where r.id = p_rep
    union all select r.drone_registered from sales_reps r where r.id = p_rep
    union all select r.casa_accreditation and coalesce(r.casa_accred_expiry, current_date) >= current_date
             from sales_reps r where r.id = p_rep
    union all select coalesce(r.police_check_expiry, current_date) >= current_date
             from sales_reps r where r.id = p_rep
  ) q;
$$;

-- LEGAL CAUTION (see docs/TECH_TOOLKIT.md): pay deductions are restricted. For EMPLOYEES,
-- Fair Work Act s324/326 likely make a deduction for a required work tool unlawful (cf. AEU
-- v Victoria). For CONTRACTORS a commercial finance deal is generally OK with a signed,
-- optional, revocable agreement (mind sham-contracting s357). A drone_loans row must only
-- be created AFTER a lawyer-cleared agreement for that tech's classification; no row = no
-- deduction. The safest option is a company-OWNED loaner with no deduction at all.
--
-- One drone loan per tech. principal is what Solarsearch paid; paid_cents accrues
-- via per-job deductions; per_job_cents is the deduction ($5 default).
create table if not exists public.drone_loans (
  id uuid primary key default gen_random_uuid(),
  rep_id uuid not null references public.sales_reps(id) on delete cascade,
  drone_model text,
  principal_cents int not null check (principal_cents >= 0),
  paid_cents int not null default 0 check (paid_cents >= 0),
  per_job_cents int not null default 500,
  status text not null default 'active' check (status in ('active','paid','returned','written_off')),
  created_at timestamptz not null default now(),
  paid_at timestamptz
);
create unique index if not exists drone_loans_one_active on public.drone_loans(rep_id) where status = 'active';

alter table public.drone_loans enable row level security;
drop policy if exists drone_loans_admin on public.drone_loans;
create policy drone_loans_admin on public.drone_loans for all
  using (public.is_admin()) with check (public.is_admin());
drop policy if exists drone_loans_own on public.drone_loans;
create policy drone_loans_own on public.drone_loans for select
  using (rep_id = public.current_sales_rep_id());

-- Accrue one per-job repayment against the tech's active loan; caps at the balance,
-- flips to 'paid' when cleared. Returns cents accrued (0 if no active loan). This is a
-- LEDGER accrual — actual money nets at tech payout.
create or replace function public.drone_loan_accrue(p_rep uuid, p_job_cents int)
returns int language plpgsql security definer set search_path=public as $$
declare v_loan record; v_amt int;
begin
  select * into v_loan from drone_loans where rep_id = p_rep and status = 'active' for update;
  if not found then return 0; end if;
  v_amt := least(v_loan.per_job_cents, v_loan.principal_cents - v_loan.paid_cents, greatest(coalesce(p_job_cents,0),0));
  if v_amt <= 0 then return 0; end if;
  update drone_loans set
    paid_cents = paid_cents + v_amt,
    status     = case when paid_cents + v_amt >= principal_cents then 'paid' else 'active' end,
    paid_at    = case when paid_cents + v_amt >= principal_cents then now() else paid_at end
  where id = v_loan.id;
  return v_amt;
end $$;

-- Wire the deduction into job settlement: on a billable submit (completed/no_access),
-- accrue $5 toward the drone loan and log it on the event trail.
create or replace function public.submit_assessment(p_assessment_id uuid, p_outcome text, p_site_data jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare v_rep uuid := current_sales_rep_id(); v_a record; v_fee int; v_status text; v_bad int; v_drone int := 0;
begin
  if p_outcome not in ('completed','no_access','partial') then raise exception 'invalid outcome'; end if;
  select * into v_a from assessments where id = p_assessment_id;
  if v_a.id is null then raise exception 'assessment not found'; end if;
  if v_a.sales_rep_id <> v_rep then raise exception 'not your job'; end if;
  if v_a.status not in ('in_progress','scheduled') then raise exception 'cannot submit from status %', v_a.status; end if;

  if p_outcome = 'completed' then
    select count(*) into v_bad from assessment_photos
      where assessment_id = p_assessment_id and (ai_verdict is distinct from 'pass') and na_reason is null;
    if v_bad > 0 then raise exception '% photo step(s) still need a passing shot or an N/A reason', v_bad; end if;
  end if;

  v_status := p_outcome;
  v_fee := case p_outcome when 'completed' then 5000 when 'no_access' then 2500 else v_a.fee_cents end;

  update assessments set status = v_status, outcome = p_outcome, submitted_at = now(),
    fee_cents = v_fee, site_data = coalesce(p_site_data, '{}'::jsonb)
  where id = p_assessment_id;

  update sites s set
    phases = case p_site_data->>'phase' when 'three' then 3 when 'single' then 1 else s.phases end,
    storeys = case p_site_data->>'storeys' when 'single' then 1 when 'double' then 2
                                           when 'multi' then 3 else s.storeys end,
    roof_type = coalesce(nullif(p_site_data->>'roof_type',''), s.roof_type)
  from leads l where l.id = v_a.lead_id and s.id = l.site_id;

  if p_outcome = 'completed' then
    update leads set state = 'inspected' where id = v_a.lead_id and state = 'appointment_set';
  end if;

  -- $5 drone-loan repayment on billable jobs
  if p_outcome in ('completed','no_access') then
    v_drone := public.drone_loan_accrue(v_rep, v_fee);
  end if;

  insert into events (site_id, lead_id, actor_type, actor_id, event_type, payload)
  select l.site_id, v_a.lead_id, 'sales_rep', v_rep::text, 'assessment.submitted',
         jsonb_build_object('assessment_id', p_assessment_id, 'outcome', p_outcome,
                            'fee_cents', v_fee, 'drone_repay_cents', v_drone)
  from leads l where l.id = v_a.lead_id;

  return jsonb_build_object('ok', true, 'outcome', p_outcome, 'fee_cents', v_fee, 'drone_repay_cents', v_drone);
end $function$;
