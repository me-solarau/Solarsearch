-- Retailer → subcontractor milestone payment engine (replaces the old admin-manual
-- 10/60/30 subcontract schedule with the fully-specified 10/40/50 workflow):
--
--   jobs (retailer posts, AVAILABLE)
--     -> accept_job() by a pre-approved OR tendering subcontractor -> installs row created
--          (pipeline='subcontractor'), 10% deposit milestone auto-charged
--     -> schedule_install() (subcontractor sets date) -> notifies retailer
--     -> request_milestone2() -> 40% requested, due 24 BUSINESS hours before the install
--          date or the job is PAUSED
--     -> submit_install_report() -> runs verify_install_evidence() (completeness gate)
--          -> if compliant, 40% auto-releases to the subcontractor, no retailer approval
--     -> confirm_stc_submitted() (subcontractor's Report-2 checkbox; photo optional) ->
--          request_final_payment() -> retailer has 72 BUSINESS hours to approve or
--          lodge_dispute() (evidence required) -> auto-approve + $250 late fee (paid to
--          the subcontractor) if the window lapses with no response
--
-- Scope: subcontractor pipeline only. The main installer pipeline (10/40/50 deposit/
-- materials/completion, direct Solarsearch leads) is untouched.
--
-- "Business hours" = Mon-Fri 9am-5pm Australia/Sydney, no public-holiday calendar yet
-- (flagged as a known simplification, not silently assumed correct).

-- ============================================================================
-- 0. Business-hours arithmetic (used for both deadlines)
-- ============================================================================
-- Walks forward (positive) or backward (negative) through Mon-Fri 9-5 Sydney-time
-- windows. Used both to compute "24 business hours before install" (negative offset
-- from a future date) and "72 business hours from now" (positive offset).
create or replace function public.business_hours_offset(p_start timestamptz, p_hours numeric)
returns timestamptz language plpgsql immutable as $$
declare
  v_tz constant text := 'Australia/Sydney';
  v_cur timestamptz := p_start;
  v_remaining numeric := abs(p_hours);
  v_forward boolean := p_hours >= 0;
  v_local timestamp;
  v_day_start timestamptz;
  v_day_end timestamptz;
  v_avail numeric;
begin
  if p_hours = 0 then return p_start; end if;
  loop
    v_local := v_cur at time zone v_tz;
    if extract(dow from v_local) in (0,6) then
      v_cur := case when v_forward
        then (date_trunc('day', v_local) + interval '1 day' + interval '9 hour') at time zone v_tz
        else (date_trunc('day', v_local) - interval '1 day' + interval '17 hour') at time zone v_tz
      end;
      continue;
    end if;
    v_day_start := (date_trunc('day', v_local) + interval '9 hour') at time zone v_tz;
    v_day_end   := (date_trunc('day', v_local) + interval '17 hour') at time zone v_tz;
    if v_forward then
      if v_cur < v_day_start then v_cur := v_day_start; end if;
      if v_cur >= v_day_end then
        v_cur := (date_trunc('day', v_local) + interval '1 day' + interval '9 hour') at time zone v_tz;
        continue;
      end if;
      v_avail := extract(epoch from (v_day_end - v_cur)) / 3600.0;
      if v_remaining <= v_avail then return v_cur + (v_remaining || ' hours')::interval; end if;
      v_remaining := v_remaining - v_avail;
      v_cur := (date_trunc('day', v_local) + interval '1 day' + interval '9 hour') at time zone v_tz;
    else
      if v_cur > v_day_end then v_cur := v_day_end; end if;
      if v_cur <= v_day_start then
        v_cur := (date_trunc('day', v_local) - interval '1 day' + interval '17 hour') at time zone v_tz;
        continue;
      end if;
      v_avail := extract(epoch from (v_cur - v_day_start)) / 3600.0;
      if v_remaining <= v_avail then return v_cur - (v_remaining || ' hours')::interval; end if;
      v_remaining := v_remaining - v_avail;
      v_cur := (date_trunc('day', v_local) - interval '1 day' + interval '17 hour') at time zone v_tz;
    end if;
  end loop;
end $$;

-- ============================================================================
-- 1. pricing_config: 10/40/50 subcontract split + new window/fee config
-- ============================================================================
update public.pricing_config set
  milestone_completion_pct = 40,
  milestone_stc_pct        = 50;
-- milestone_deposit_pct stays 10 (unchanged).

alter table public.pricing_config add column if not exists milestone2_deadline_business_hours numeric(6,2) not null default 24;
alter table public.pricing_config add column if not exists final_payment_window_business_hours numeric(6,2) not null default 72;
alter table public.pricing_config add column if not exists late_payment_fee_cents int not null default 25000;

-- ============================================================================
-- 2. Contractor onboarding: subcontractor opt-in + rate cards + retailer pre-approval
-- ============================================================================
alter table public.installers add column if not exists subcontractor_opted_in_at timestamptz;
alter table public.installers add column if not exists subcontractor_terms_ref  text;

create table if not exists public.retailer_installer_rates (
  id            uuid primary key default gen_random_uuid(),
  retailer_id   uuid not null references public.retailers(id) on delete cascade,
  installer_id  uuid not null references public.installers(id) on delete cascade,
  job_type      text not null,               -- e.g. 'solar_install','battery_retrofit','solar_battery'
  rate_cents    int not null check (rate_cents >= 0),
  approved_at   timestamptz,                 -- set = this installer is PRE-APPROVED for this retailer/job_type
  created_at    timestamptz not null default now(),
  unique (retailer_id, installer_id, job_type)
);
create index on public.retailer_installer_rates (installer_id);

alter table public.retailer_installer_rates enable row level security;
create policy admin_all_retailer_installer_rates on public.retailer_installer_rates for all
  using (public.is_admin()) with check (public.is_admin());
create policy retailer_own_rates on public.retailer_installer_rates for all
  using (retailer_id = public.current_retailer_id()) with check (retailer_id = public.current_retailer_id());
create policy installer_read_own_rates on public.retailer_installer_rates for select
  using (installer_id = public.current_installer_id());

create or replace function public.is_preapproved_installer(p_retailer uuid, p_installer uuid, p_job_type text)
returns boolean language sql stable security definer set search_path=public as $$
  select exists (
    select 1 from retailer_installer_rates
    where retailer_id = p_retailer and installer_id = p_installer and job_type = p_job_type
      and approved_at is not null
  );
$$;

-- ============================================================================
-- 3. jobs: the retailer's posted work (extends the 0003 table with the fields
--    this workflow needs — customer/site detail, job type, AVAILABLE lifecycle)
-- ============================================================================
alter table public.jobs add column if not exists job_type text not null default 'solar_install'
  check (job_type in ('solar_install','battery_retrofit','solar_battery'));
alter table public.jobs add column if not exists customer_name  text;
alter table public.jobs add column if not exists customer_phone text;
alter table public.jobs add column if not exists customer_email text;
alter table public.jobs add column if not exists job_value_cents int;   -- the pre-approved rate for this job
alter table public.jobs add column if not exists accepted_install_id uuid references public.installs(id);
-- 'open' in the existing check IS the "AVAILABLE" state; 'claimed' IS "ACCEPTED" —
-- reusing the existing enum rather than renaming values live subcontract_commission
-- and other code may already read.

-- Non-pre-approved subcontractors bid for a job as a one-off; retailer approves before
-- the tender converts into an acceptance.
create table if not exists public.job_tenders (
  id           uuid primary key default gen_random_uuid(),
  job_id       uuid not null references public.jobs(id) on delete cascade,
  installer_id uuid not null references public.installers(id) on delete cascade,
  offer_cents  int not null check (offer_cents >= 0),
  message      text,
  status       text not null default 'pending' check (status in ('pending','accepted','rejected','withdrawn')),
  created_at   timestamptz not null default now(),
  decided_at   timestamptz,
  unique (job_id, installer_id)
);
alter table public.job_tenders enable row level security;
create policy admin_all_job_tenders on public.job_tenders for all
  using (public.is_admin()) with check (public.is_admin());
create policy installer_own_tenders on public.job_tenders for all
  using (installer_id = public.current_installer_id()) with check (installer_id = public.current_installer_id());
create policy retailer_read_tenders on public.job_tenders for select
  using (exists (select 1 from jobs j where j.id = job_tenders.job_id and j.retailer_id = public.current_retailer_id()));

-- ============================================================================
-- 4. installs: the new workflow's state, on top of the existing subcontract columns
-- ============================================================================
-- Retailer-posted jobs have no Solarsearch-native lead — relax the NOT NULL that
-- assumed every install traces back to our own consumer funnel. KNOWN GAP: existing
-- submit_stc_photo/verify_stc (0060) log their event via `from leads l where l.id =
-- v_i.lead_id`, which silently inserts zero rows when lead_id is null — those two
-- functions lose their audit-trail event on retailer-originated installs until
-- patched separately (not touched here to keep this migration's diff reviewable).
alter table public.installs alter column lead_id drop not null;
alter table public.installs add column if not exists job_id uuid references public.jobs(id);
alter table public.installs add column if not exists scheduled_install_at    timestamptz;
alter table public.installs add column if not exists schedule_confirmed_at   timestamptz;  -- retailer confirms
alter table public.installs add column if not exists milestone2_requested_at timestamptz;
alter table public.installs add column if not exists milestone2_deadline_at  timestamptz;  -- computed: 24 biz hrs before install
alter table public.installs add column if not exists paused_at   timestamptz;
alter table public.installs add column if not exists pause_reason text;
alter table public.installs add column if not exists ai_verification_status text
  check (ai_verification_status in ('pending','compliant','review_required'));
alter table public.installs add column if not exists ai_verification_at      timestamptz;
alter table public.installs add column if not exists ai_verification_detail jsonb;
alter table public.installs add column if not exists stc_confirmed_at        timestamptz; -- subcontractor's Report-2 checkbox
alter table public.installs add column if not exists final_payment_requested_at timestamptz;
alter table public.installs add column if not exists final_payment_deadline_at  timestamptz;

create table if not exists public.install_disputes (
  id           uuid primary key default gen_random_uuid(),
  install_id   uuid not null references public.installs(id) on delete cascade,
  raised_by_retailer_id uuid not null references public.retailers(id),
  reason       text not null check (reason in ('stc_incomplete','missing_documentation','incorrect_documentation','other')),
  detail       text not null,
  evidence_path text,                         -- required — enforced in lodge_dispute(), not just a DB check, so a clear error message reaches the caller
  status       text not null default 'open' check (status in ('open','upheld','rejected')),
  created_at   timestamptz not null default now(),
  resolved_at  timestamptz,
  resolved_by  uuid references public.staff(id)
);
alter table public.install_disputes enable row level security;
create policy admin_all_install_disputes on public.install_disputes for all
  using (public.is_admin()) with check (public.is_admin());
create policy retailer_own_disputes on public.install_disputes for all
  using (raised_by_retailer_id = public.current_retailer_id())
  with check (raised_by_retailer_id = public.current_retailer_id());
create policy installer_read_disputes on public.install_disputes for select
  using (exists (select 1 from installs i where i.id = install_disputes.install_id and i.installer_id = public.current_installer_id()));

create table if not exists public.late_fees (
  id            uuid primary key default gen_random_uuid(),
  install_id    uuid not null references public.installs(id) on delete cascade,
  amount_cents  int not null,
  reason        text not null default 'final_payment_no_response',
  applied_at    timestamptz not null default now(),
  paid_at       timestamptz,
  stripe_payment_intent_id text
);
alter table public.late_fees enable row level security;
create policy admin_all_late_fees on public.late_fees for all
  using (public.is_admin()) with check (public.is_admin());
create policy own_read_late_fees on public.late_fees for select
  using (exists (select 1 from installs i where i.id = late_fees.install_id
                 and (i.installer_id = public.current_installer_id() or i.retailer_id = public.current_retailer_id())));

-- ============================================================================
-- 5. Workflow functions
-- ============================================================================

-- STEP 2 — accept a posted job. Pre-approved installers go straight through;
-- everyone else must tender (see accept_job_tender below). Creates the installs
-- row that the existing Stripe milestone machinery (build_payment_milestones,
-- create-milestone-payment) already operates on, then fires the 10% deposit.
create or replace function public.accept_job(p_job uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_job record; v_installer_id uuid; v_install_id uuid;
begin
  v_installer_id := public.current_installer_id();
  if v_installer_id is null then raise exception 'not an approved installer'; end if;

  select * into v_job from jobs where id = p_job for update;
  if v_job.id is null then raise exception 'job not found'; end if;
  if v_job.status <> 'open' then raise exception 'job is not available'; end if;

  if not exists (select 1 from installers where id = v_installer_id and subcontractor_opted_in_at is not null) then
    raise exception 'opt in to subcontract work before accepting jobs';
  end if;
  if not public.is_preapproved_installer(v_job.retailer_id, v_installer_id, v_job.job_type) then
    raise exception 'not pre-approved for this retailer/job type — submit a tender instead (accept_job_tender)';
  end if;

  insert into installs (lead_id, installer_id, pipeline, retailer_id, job_id, job_value_cents, status)
  values (null, v_installer_id, 'subcontractor', v_job.retailer_id, p_job, v_job.job_value_cents, 'scheduled')
  returning id into v_install_id;

  update jobs set status = 'claimed', claimed_by_installer_id = v_installer_id, claimed_at = now(),
    accepted_install_id = v_install_id where id = p_job;

  perform public.accept_install(v_install_id);   -- existing fn: stamps accepted_at, emits install.accepted
  perform public.build_payment_milestones(v_install_id);

  return jsonb_build_object('ok', true, 'install_id', v_install_id);
end $$;

-- Retailer approves a tender from a non-pre-approved subcontractor; this both
-- records the one-off approval (so accept_job's pre-approval check passes) and
-- performs the acceptance in one step.
create or replace function public.accept_job_tender(p_tender uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_t record; v_job record;
begin
  select * into v_t from job_tenders where id = p_tender for update;
  if v_t.id is null then raise exception 'tender not found'; end if;
  select * into v_job from jobs where id = v_t.job_id for update;
  if v_job.id is null then raise exception 'job not found'; end if;
  if not (public.is_admin() or v_job.retailer_id = public.current_retailer_id()) then
    raise exception 'only the posting retailer can accept a tender';
  end if;
  if v_t.status <> 'pending' then raise exception 'tender already decided'; end if;
  if v_job.status <> 'open' then raise exception 'job is not available'; end if;

  insert into retailer_installer_rates (retailer_id, installer_id, job_type, rate_cents, approved_at)
  values (v_job.retailer_id, v_t.installer_id, v_job.job_type, v_t.offer_cents, now())
  on conflict (retailer_id, installer_id, job_type) do update set approved_at = now(), rate_cents = excluded.rate_cents;

  update jobs set job_value_cents = v_t.offer_cents where id = v_job.id;
  update job_tenders set status = 'accepted', decided_at = now() where id = p_tender;
  update job_tenders set status = 'rejected', decided_at = now()
    where job_id = v_job.id and id <> p_tender and status = 'pending';

  return public.accept_job(v_job.id);
end $$;

-- STEP 3 — subcontractor sets the install date; notifies retailer (event only —
-- actual SMS/email wiring follows the existing notify-* edge function pattern).
create or replace function public.schedule_install(p_install uuid, p_scheduled_at timestamptz)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_i record; v_cfg record;
begin
  select * into v_i from installs where id = p_install for update;
  if v_i.id is null then raise exception 'install not found'; end if;
  if not (public.is_admin() or v_i.installer_id = public.current_installer_id()) then raise exception 'not your install'; end if;
  if p_scheduled_at <= now() then raise exception 'scheduled date must be in the future'; end if;
  select * into v_cfg from pricing_config limit 1;

  update installs set
    scheduled_install_at = p_scheduled_at,
    milestone2_requested_at = now(),
    milestone2_deadline_at = public.business_hours_offset(p_scheduled_at, -v_cfg.milestone2_deadline_business_hours)
  where id = p_install;

  insert into events (site_id, lead_id, actor_type, actor_id, event_type, payload)
  select null, null, 'installer', v_i.installer_id::text, 'install.scheduled',
         jsonb_build_object('install_id', p_install, 'scheduled_at', p_scheduled_at);

  return jsonb_build_object('ok', true, 'milestone2_deadline_at',
    public.business_hours_offset(p_scheduled_at, -v_cfg.milestone2_deadline_business_hours));
end $$;

create or replace function public.confirm_schedule(p_install uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_i record;
begin
  select * into v_i from installs where id = p_install for update;
  if v_i.id is null then raise exception 'install not found'; end if;
  if not (public.is_admin() or v_i.retailer_id = public.current_retailer_id()) then raise exception 'not your job'; end if;
  if v_i.scheduled_install_at is null then raise exception 'no schedule to confirm yet'; end if;
  update installs set schedule_confirmed_at = now() where id = p_install;
  return jsonb_build_object('ok', true);
end $$;

-- Completeness gate distinct from the existing per-photo compliance-CONTENT checker
-- (validate-install-photo, still runs per-photo underneath this). This checks the
-- evidence SET is present, not whether the work shown is compliant.
create or replace function public.verify_install_evidence(p_install uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_i record; v_missing text[] := '{}';
begin
  select * into v_i from installs where id = p_install for update;
  if v_i.id is null then raise exception 'install not found'; end if;

  if not exists (select 1 from install_photos where install_id = p_install) then
    v_missing := array_append(v_missing, 'photos');
  end if;
  if v_i.completion_report is null or not (v_i.completion_report ? 'checklist_complete') then
    v_missing := array_append(v_missing, 'checklist');
  end if;
  if v_i.completion_report is null or not (v_i.completion_report ? 'customer_signature') then
    v_missing := array_append(v_missing, 'customer_signature');
  end if;
  if not exists (select 1 from install_photos where install_id = p_install and lat is not null and lng is not null) then
    v_missing := array_append(v_missing, 'gps');
  end if;
  if not exists (select 1 from install_photos where install_id = p_install and taken_at is not null) then
    v_missing := array_append(v_missing, 'timestamp');
  end if;

  update installs set
    ai_verification_status = case when array_length(v_missing,1) is null then 'compliant' else 'review_required' end,
    ai_verification_at = now(),
    ai_verification_detail = jsonb_build_object('missing', to_jsonb(v_missing))
  where id = p_install;

  return jsonb_build_object('ok', true, 'status',
    case when array_length(v_missing,1) is null then 'compliant' else 'review_required' end,
    'missing', to_jsonb(v_missing));
end $$;

-- Subcontractor's Report-2 checkbox: confirms STC/CER submission is done on their
-- own compliance platform. Photo (submit_stc_photo, existing fn) stays OPTIONAL
-- supporting evidence — not required to proceed, per spec: "SolarSearch does NOT
-- replace compliance software, only requires confirmation."
create or replace function public.confirm_stc_submitted(p_install uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_i record; v_cfg record;
begin
  select * into v_i from installs where id = p_install for update;
  if v_i.id is null then raise exception 'install not found'; end if;
  if not (public.is_admin() or v_i.installer_id = public.current_installer_id()) then raise exception 'not your install'; end if;
  if v_i.ai_verification_status <> 'compliant' then raise exception 'install evidence not yet verified compliant'; end if;
  select * into v_cfg from pricing_config limit 1;

  update installs set
    stc_confirmed_at = now(),
    final_payment_requested_at = now(),
    final_payment_deadline_at = public.business_hours_offset(now(), v_cfg.final_payment_window_business_hours)
  where id = p_install;

  insert into events (site_id, lead_id, actor_type, actor_id, event_type, payload)
  select null, null, 'installer', v_i.installer_id::text, 'install.final_payment_requested',
         jsonb_build_object('install_id', p_install);

  return jsonb_build_object('ok', true, 'final_payment_deadline_at',
    public.business_hours_offset(now(), v_cfg.final_payment_window_business_hours));
end $$;

-- Retailer's evidence-backed dispute — blocks auto-approval of the final 50%.
create or replace function public.lodge_dispute(p_install uuid, p_reason text, p_detail text, p_evidence_path text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_i record;
begin
  if p_evidence_path is null or length(trim(p_evidence_path)) = 0 then
    raise exception 'a dispute requires supporting evidence';
  end if;
  select * into v_i from installs where id = p_install for update;
  if v_i.id is null then raise exception 'install not found'; end if;
  if not (public.is_admin() or v_i.retailer_id = public.current_retailer_id()) then raise exception 'not your job'; end if;
  if v_i.final_payment_requested_at is null then raise exception 'no final payment request to dispute'; end if;

  insert into install_disputes (install_id, raised_by_retailer_id, reason, detail, evidence_path)
  values (p_install, v_i.retailer_id, p_reason, p_detail, p_evidence_path);

  insert into events (site_id, lead_id, actor_type, actor_id, event_type, payload)
  select null, null, 'retailer', v_i.retailer_id::text, 'install.disputed',
         jsonb_build_object('install_id', p_install, 'reason', p_reason);

  return jsonb_build_object('ok', true);
end $$;

-- Sweep function (manually-triggerable now; cron/pg_cron wiring is a fast-follow,
-- same "build it callable first" precedent as the rest of this codebase's other
-- scheduled jobs). Two independent checks:
--   1. Pause installs where the 40% isn't funded and the deadline has passed.
--   2. Auto-approve + late fee where the final-payment window lapsed with no
--      retailer response and no open dispute.
create or replace function public.process_payment_timeouts()
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_paused int := 0; v_approved int := 0; r record;
begin
  for r in
    select i.id from installs i
    join payment_milestones pm on pm.install_id = i.id and pm.milestone = 'completion'
    where i.pipeline = 'subcontractor' and i.paused_at is null
      and i.milestone2_deadline_at is not null and i.milestone2_deadline_at < now()
      and pm.status not in ('paid','processing')
  loop
    update installs set paused_at = now(),
      pause_reason = 'Milestone 2 (40%) not funded 24 business hours before installation — do not attend site until funding is received.'
      where id = r.id;
    insert into events (site_id, lead_id, actor_type, event_type, payload)
    select null, null, 'system', 'install.paused', jsonb_build_object('install_id', r.id);
    v_paused := v_paused + 1;
  end loop;

  for r in
    select i.id, i.retailer_id from installs i
    where i.pipeline = 'subcontractor' and i.final_payment_requested_at is not null
      and i.final_payment_deadline_at < now()
      and not exists (select 1 from install_disputes d where d.install_id = i.id and d.status = 'open')
      and not exists (select 1 from payment_milestones pm where pm.install_id = i.id and pm.milestone = 'stc' and pm.status in ('paid','processing'))
  loop
    insert into late_fees (install_id, amount_cents, reason)
    select r.id, (select late_payment_fee_cents from pricing_config limit 1), 'final_payment_no_response'
    where not exists (select 1 from late_fees where install_id = r.id and reason = 'final_payment_no_response');

    insert into events (site_id, lead_id, actor_type, event_type, payload)
    select null, null, 'system', 'install.final_payment_auto_approved', jsonb_build_object('install_id', r.id);
    v_approved := v_approved + 1;
  end loop;

  return jsonb_build_object('paused', v_paused, 'auto_approved', v_approved);
end $$;

revoke all on function public.accept_job(uuid) from public;
revoke all on function public.accept_job_tender(uuid) from public;
revoke all on function public.schedule_install(uuid, timestamptz) from public;
revoke all on function public.confirm_schedule(uuid) from public;
revoke all on function public.verify_install_evidence(uuid) from public;
revoke all on function public.confirm_stc_submitted(uuid) from public;
revoke all on function public.lodge_dispute(uuid, text, text, text) from public;
grant execute on function public.accept_job(uuid) to authenticated;
grant execute on function public.accept_job_tender(uuid) to authenticated;
grant execute on function public.schedule_install(uuid, timestamptz) to authenticated;
grant execute on function public.confirm_schedule(uuid) to authenticated;
grant execute on function public.verify_install_evidence(uuid) to authenticated;
grant execute on function public.confirm_stc_submitted(uuid) to authenticated;
grant execute on function public.lodge_dispute(uuid, text, text, text) to authenticated;
grant execute on function public.process_payment_timeouts() to service_role;
