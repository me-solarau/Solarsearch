-- ============================================================================
-- Sales Technician core loop (scope v1.2 §2, §8 Phase 1): job pool -> grab ->
-- schedule -> start visit -> submit. All technician access is via SECURITY
-- DEFINER RPCs scoped to current_sales_rep_id(); the pool masks address until
-- a visit is scheduled. A completed submission rejoins the existing pipeline
-- at lead state 'inspected' (the doc's "assessed"), so design->board->sign are
-- unchanged. Fees: $50 completed, $25 no-access (§2 exception path).
-- ============================================================================

-- One non-cancelled assessment per lead = single-claimant lock (§2 Stage B).
create unique index if not exists assessments_one_active_per_lead
  on public.assessments (lead_id) where status <> 'cancelled';

-- Which postcodes the calling technician covers (from their regions).
create or replace function public.rep_postcodes(p_rep uuid)
returns setof text language sql stable security definer set search_path = public as $$
  select rp.postcode from region_postcodes rp
  where rp.region_id in (select unnest(regions) from sales_reps where id = p_rep);
$$;

-- Job pool: validated leads (booked a visit) in the tech's postcodes with no
-- live claim. Address masked to suburb+postcode; $50 fee shown.
create or replace function public.technician_pool()
returns table (lead_id uuid, ss_ref text, suburb text, postcode text, lead_type text,
               roof_type text, storeys smallint, fee_cents int, age_hours numeric)
language sql stable security definer set search_path = public as $$
  with me as (select current_sales_rep_id() as rid)
  select l.id, s.ss_ref,
         nullif(trim(split_part(s.address, ',', -1)), '') as suburb,
         s.postcode, l.lead_type, s.roof_type, s.storeys, 5000 as fee_cents,
         round(extract(epoch from (now() - l.created_at))/3600.0, 1) as age_hours
  from leads l
  join sites s on s.id = l.site_id
  where (select rid from me) is not null
    and l.state = 'appointment_set'
    and s.postcode in (select public.rep_postcodes((select rid from me)))
    and not exists (
      select 1 from assessments a
      where a.lead_id = l.id and a.status <> 'cancelled'
        and not (a.status = 'claimed' and a.scheduled_at is null and a.claim_expires_at < now())
    )
  order by l.created_at asc;
$$;
grant execute on function public.technician_pool() to authenticated;

-- The technician's own claimed/scheduled/in-progress jobs. Full address is
-- revealed only once the visit is scheduled (§2 Stage C address gating).
create or replace function public.technician_my_jobs()
returns table (assessment_id uuid, lead_id uuid, ss_ref text, status text,
               scheduled_at timestamptz, claim_expires_at timestamptz, started_at timestamptz,
               suburb text, postcode text, address text, customer_name text, customer_mobile text,
               lead_type text, roof_type text, storeys smallint, fee_cents int)
language sql stable security definer set search_path = public as $$
  with me as (select current_sales_rep_id() as rid)
  select a.id, l.id, s.ss_ref, a.status, a.scheduled_at, a.claim_expires_at, a.started_at,
         nullif(trim(split_part(s.address, ',', -1)), '') as suburb, s.postcode,
         case when a.status in ('scheduled','in_progress','completed','no_access','partial') then s.address else null end,
         case when a.status in ('scheduled','in_progress','completed','no_access','partial') then c.full_name else null end,
         case when a.status in ('scheduled','in_progress','completed','no_access','partial') then c.mobile else null end,
         l.lead_type, s.roof_type, s.storeys, coalesce(a.fee_cents, 5000)
  from assessments a
  join leads l on l.id = a.lead_id
  join sites s on s.id = l.site_id
  left join customers c on c.id = l.customer_id
  where a.sales_rep_id = (select rid from me)
    and a.status in ('claimed','scheduled','in_progress')
  order by coalesce(a.scheduled_at, a.claimed_at) asc;
$$;
grant execute on function public.technician_my_jobs() to authenticated;

-- Grab a job: claims it for the caller with a 48h clock. Any expired unscheduled
-- claim on the lead is cancelled first so it can be re-grabbed; the partial
-- unique index guarantees a single live claimant under race.
create or replace function public.grab_job(p_lead_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_rep uuid := current_sales_rep_id(); v_state lead_state; v_pc text; v_aid uuid; v_exp timestamptz;
begin
  if v_rep is null then raise exception 'not an active sales technician'; end if;
  select state into v_state from leads where id = p_lead_id;
  if v_state is null then raise exception 'lead not found'; end if;
  if v_state <> 'appointment_set' then raise exception 'this job is no longer available'; end if;
  select postcode into v_pc from sites s join leads l on l.site_id = s.id where l.id = p_lead_id;
  if v_pc not in (select public.rep_postcodes(v_rep)) then raise exception 'job is outside your postcodes'; end if;

  update assessments set status = 'cancelled'
    where lead_id = p_lead_id and status = 'claimed' and scheduled_at is null and claim_expires_at < now();

  v_exp := now() + interval '48 hours';
  begin
    insert into assessments (lead_id, sales_rep_id, status, claimed_at, claim_expires_at, fee_cents)
    values (p_lead_id, v_rep, 'claimed', now(), v_exp, 5000)
    returning id into v_aid;
  exception when unique_violation then
    raise exception 'another technician just grabbed this job';
  end;

  insert into events (site_id, lead_id, actor_type, actor_id, event_type, payload)
  select l.site_id, p_lead_id, 'sales_rep', v_rep::text, 'assessment.claimed',
         jsonb_build_object('assessment_id', v_aid, 'claim_expires_at', v_exp)
  from leads l where l.id = p_lead_id;

  return jsonb_build_object('assessment_id', v_aid, 'claim_expires_at', v_exp);
end $$;
grant execute on function public.grab_job(uuid) to authenticated;

-- Confirm a visit time (SMS-confirm or manual). Reveals address to the tech.
create or replace function public.schedule_visit(p_assessment_id uuid, p_scheduled_at timestamptz)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_rep uuid := current_sales_rep_id(); v_a record;
begin
  select * into v_a from assessments where id = p_assessment_id;
  if v_a.id is null then raise exception 'assessment not found'; end if;
  if v_a.sales_rep_id <> v_rep and not is_admin() then raise exception 'not your job'; end if;
  if v_a.status not in ('claimed','scheduled') then raise exception 'cannot schedule from status %', v_a.status; end if;
  update assessments set scheduled_at = p_scheduled_at, status = 'scheduled' where id = p_assessment_id;
  insert into events (site_id, lead_id, actor_type, actor_id, event_type, payload)
  select l.site_id, v_a.lead_id, 'sales_rep', v_rep::text, 'assessment.scheduled', jsonb_build_object('scheduled_at', p_scheduled_at)
  from leads l where l.id = v_a.lead_id;
  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.schedule_visit(uuid, timestamptz) to authenticated;

-- Start the visit: attendance proof (GPS + timestamp).
create or replace function public.start_visit(p_assessment_id uuid, p_lat double precision, p_lng double precision)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_rep uuid := current_sales_rep_id(); v_a record;
begin
  select * into v_a from assessments where id = p_assessment_id;
  if v_a.id is null then raise exception 'assessment not found'; end if;
  if v_a.sales_rep_id <> v_rep then raise exception 'not your job'; end if;
  if v_a.status <> 'scheduled' then raise exception 'confirm a visit time first'; end if;
  update assessments set status = 'in_progress', started_at = now(),
    start_gps = jsonb_build_object('lat', p_lat, 'lng', p_lng)
  where id = p_assessment_id;
  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.start_visit(uuid, double precision, double precision) to authenticated;

-- Submit: completeness-gated for 'completed' (no pending/fail photos), records
-- outcome + fee, and on completion advances the lead to 'inspected' so the
-- design team picks up a quote-ready pack.
create or replace function public.submit_assessment(p_assessment_id uuid, p_outcome text, p_site_data jsonb default '{}')
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_rep uuid := current_sales_rep_id(); v_a record; v_fee int; v_status text; v_bad int;
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

  if p_outcome = 'completed' then
    update leads set state = 'inspected' where id = v_a.lead_id and state = 'appointment_set';
  end if;

  insert into events (site_id, lead_id, actor_type, actor_id, event_type, payload)
  select l.site_id, v_a.lead_id, 'sales_rep', v_rep::text, 'assessment.submitted',
         jsonb_build_object('assessment_id', p_assessment_id, 'outcome', p_outcome, 'fee_cents', v_fee)
  from leads l where l.id = v_a.lead_id;

  return jsonb_build_object('ok', true, 'outcome', p_outcome, 'fee_cents', v_fee);
end $$;
grant execute on function public.submit_assessment(uuid, text, jsonb) to authenticated;
