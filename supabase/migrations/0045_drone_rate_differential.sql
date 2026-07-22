-- Replace the drone PAY-DEDUCTION model with a RATE DIFFERENTIAL (no deduction -> avoids
-- Fair Work s324/326 entirely). See docs/TECH_TOOLKIT.md.
--   * Having a drone is a condition of engagement (the tech's obligation).
--   * A tech on their OWN drone earns the full completed-job rate: $50.
--   * A tech on a COMPANY-provided drone earns $45 for their first 50 completed jobs
--     (the $5 lower rate = an effective tool allowance that recoups the ~$209 drone).
--   * After 50 completed jobs the drone becomes THEIRS and their rate goes to $50.
--   * If they stop before earning it out, they post the (company-owned) drone back and
--     Solarsearch pays the postage — no deduction, no debt, no out-of-pocket.

-- Drop the old loan/deduction model (no prod data).
drop function if exists public.drone_loan_accrue(uuid, int);
drop function if exists public.drone_loan_set_authorisation(uuid, boolean, text);
drop table if exists public.drone_loans;

create table if not exists public.drone_assignments (
  id uuid primary key default gen_random_uuid(),
  rep_id uuid not null unique references public.sales_reps(id) on delete cascade,
  drone_model text,
  source text not null default 'company_provided' check (source in ('company_provided','own')),
  status text not null default 'earning' check (status in ('earning','owned','returned')),
  jobs_target int not null default 50,     -- completed jobs to earn ownership
  jobs_done int not null default 0,
  assigned_at timestamptz not null default now(),
  owned_at timestamptz,
  returned_at timestamptz
);

alter table public.drone_assignments enable row level security;
drop policy if exists drone_assign_admin on public.drone_assignments;
create policy drone_assign_admin on public.drone_assignments for all
  using (public.is_admin()) with check (public.is_admin());
drop policy if exists drone_assign_own on public.drone_assignments;
create policy drone_assign_own on public.drone_assignments for select
  using (rep_id = public.current_sales_rep_id());

-- Completed-job rate for a tech: $45 while still earning a company drone, else $50.
create or replace function public.drone_job_rate(p_rep uuid)
returns int language sql stable security definer set search_path=public as $$
  select case when exists (
    select 1 from drone_assignments where rep_id = p_rep and status = 'earning'
  ) then 4500 else 5000 end;
$$;

-- Admin: tech stopped before earning the drone out -> mark it returned (they post it back,
-- we pay postage). Only an in-progress earn-out can be returned; an owned drone is theirs.
create or replace function public.drone_assignment_return(p_rep uuid)
returns void language plpgsql security definer set search_path=public as $$
begin
  if not public.is_admin() then raise exception 'not authorised'; end if;
  update drone_assignments set status = 'returned', returned_at = now()
    where rep_id = p_rep and status = 'earning';
end $$;

-- submit_assessment: completed-job fee follows the rate differential and advances the
-- earn-to-own counter; no pay deduction anywhere.
create or replace function public.submit_assessment(p_assessment_id uuid, p_outcome text, p_site_data jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare
  v_rep uuid := current_sales_rep_id(); v_a record; v_fee int; v_status text; v_bad int;
  v_asg_id uuid; v_jobs_done int; v_jobs_target int; v_new_status text := null;
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

  -- completed-job rate: $45 while earning a company drone (and advance the earn-out),
  -- else $50 (own drone / already owned). no_access flat $25; partial keeps prior fee.
  if p_outcome = 'completed' then
    select id into v_asg_id from drone_assignments where rep_id = v_rep and status = 'earning' for update;
    if v_asg_id is not null then
      v_fee := 4500;
      update drone_assignments set
        jobs_done = jobs_done + 1,
        status    = case when jobs_done + 1 >= jobs_target then 'owned' else status end,
        owned_at  = case when jobs_done + 1 >= jobs_target then now() else owned_at end
      where id = v_asg_id
      returning jobs_done, jobs_target, status into v_jobs_done, v_jobs_target, v_new_status;
    else
      v_fee := 5000;
    end if;
  elsif p_outcome = 'no_access' then
    v_fee := 2500;
  else
    v_fee := v_a.fee_cents;
  end if;

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

  insert into events (site_id, lead_id, actor_type, actor_id, event_type, payload)
  select l.site_id, v_a.lead_id, 'sales_rep', v_rep::text, 'assessment.submitted',
         jsonb_build_object('assessment_id', p_assessment_id, 'outcome', p_outcome, 'fee_cents', v_fee,
                            'drone_jobs_done', v_jobs_done, 'drone_jobs_target', v_jobs_target,
                            'drone_earned', (v_new_status = 'owned'))
  from leads l where l.id = v_a.lead_id;

  return jsonb_build_object('ok', true, 'outcome', p_outcome, 'fee_cents', v_fee,
                            'drone_jobs_done', v_jobs_done, 'drone_jobs_target', v_jobs_target,
                            'drone_earned', (v_new_status = 'owned'));
end $function$;
