-- Commercial solar marketplace (SRES 1 MW expansion, Oct 2026).
--
-- Retailers post commercial jobs (100 kW – 1 MW) and choose HOW installers are
-- sourced, per job:
--   'grab'   — open to all opted-in installers, first grab wins (existing model)
--   'tender' — open to all, offers only; the retailer compares and accepts one
--   'invite' — only named installers see the job; offers only
--
-- Everything downstream is unchanged on purpose: acceptance still creates the
-- install, the Solarsafe app still captures the evidence, AI verification and
-- STC confirmation still gate the 10/40/50 milestones. Commercial changes who
-- can see a job and how it is won — never the compliance record behind it.

-- ============================================================================
-- 1. jobs: commercial fields + sourcing mode
-- ============================================================================
alter table public.jobs add column if not exists is_commercial boolean not null default false;
alter table public.jobs add column if not exists sourcing_mode text not null default 'grab'
  check (sourcing_mode in ('grab','tender','invite'));
alter table public.jobs add column if not exists invited_installer_ids uuid[] not null default '{}';
-- The DNSP connection approval is the schedule driver on commercial work.
alter table public.jobs add column if not exists dnsp_status text not null default 'not_submitted'
  check (dnsp_status in ('not_submitted','submitted','approved'));
-- STCs for 100 kW – 1 MW only exist for systems completed on/after 1 Oct 2026 —
-- the retailer states the target so installers can price the timing constraint.
alter table public.jobs add column if not exists target_completion_date date;

-- ============================================================================
-- 2. list_available_jobs: hide invite-only jobs from non-invitees and expose
--    the commercial fields (still PII-redacted — no customer detail pre-award)
-- ============================================================================
create or replace function public.list_available_jobs()
returns setof jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare v_iid uuid := current_installer_id();
begin
  if v_iid is null then raise exception 'not an approved installer'; end if;
  return query
  select jsonb_build_object(
    'id', j.id,
    'title', j.title,
    'suburb', j.suburb,
    'postcode', j.postcode,
    'system_kw', j.system_kw,
    'battery_kwh', j.battery_kwh,
    'storeys', j.storeys,
    'roof_type', j.roof_type,
    'job_type', j.job_type,
    'scheduled_window', j.scheduled_window,
    'general_instructions', j.general_instructions,
    'edge_perimeter_m', j.edge_perimeter_m,
    'edge_protection_provided_separately', j.edge_protection_provided_separately,
    'created_at', j.created_at,
    'is_commercial', j.is_commercial,
    'sourcing_mode', j.sourcing_mode,
    'dnsp_status', j.dnsp_status,
    'target_completion_date', j.target_completion_date,
    'panel_qty', j.panel_qty,
    'invited', (v_iid = any(j.invited_installer_ids)),
    'is_preapproved', public.is_preapproved_installer(j.retailer_id, v_iid, j.job_type),
    'pre_quote_cents', (
      select rate_cents from retailer_installer_rates
      where retailer_id = j.retailer_id and installer_id = v_iid and job_type = j.job_type
        and approved_at is not null limit 1
    ),
    'forfeited_by_me', (j.forfeited_by_installer_id = v_iid and coalesce(j.reclaimable_after,'-infinity'::timestamptz) > now())
  )
  from jobs j
  where j.status = 'open'
    and (j.sourcing_mode <> 'invite' or v_iid = any(j.invited_installer_ids));
end $function$;

-- ============================================================================
-- 3. accept_job: grab only wins grab-mode jobs
-- ============================================================================
create or replace function public.accept_job(p_job uuid)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare v_job record; v_installer_id uuid; v_install_id uuid;
begin
  v_installer_id := public.current_installer_id();
  if v_installer_id is null then raise exception 'not an approved installer'; end if;
  select * into v_job from jobs where id = p_job for update;
  if v_job.id is null then raise exception 'job not found'; end if;
  if v_job.status <> 'open' then raise exception 'job is not available'; end if;
  if v_job.sourcing_mode <> 'grab' then
    raise exception 'this job takes offers — submit an offer and the retailer will choose';
  end if;
  if v_job.forfeited_by_installer_id = v_installer_id and v_job.reclaimable_after > now() then
    raise exception 'you forfeited this job by not scheduling it in time -- you can re-grab it after %', v_job.reclaimable_after;
  end if;
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
  perform public.accept_install(v_install_id);
  perform public.build_payment_milestones(v_install_id);
  return jsonb_build_object('ok', true, 'install_id', v_install_id);
end $function$;

-- ============================================================================
-- 4. submit_job_tender: invite-only jobs take offers from invitees only
-- ============================================================================
create or replace function public.submit_job_tender(p_job uuid, p_offer_cents integer, p_message text default null::text)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare v_iid uuid := public.current_installer_id(); v_job record; v_tid uuid;
begin
  if v_iid is null then raise exception 'not an approved installer'; end if;
  if not exists (select 1 from installers where id = v_iid and subcontractor_opted_in_at is not null) then
    raise exception 'opt in to subcontract work before tendering on jobs';
  end if;
  select * into v_job from jobs where id = p_job;
  if v_job.id is null then raise exception 'job not found'; end if;
  if v_job.status <> 'open' then raise exception 'job is not available'; end if;
  if v_job.sourcing_mode = 'invite' and not (v_iid = any(v_job.invited_installer_ids)) then
    raise exception 'this job is invite-only';
  end if;
  if p_offer_cents is null or p_offer_cents < 0 then raise exception 'invalid offer amount'; end if;

  insert into job_tenders (job_id, installer_id, offer_cents, message, status)
  values (p_job, v_iid, p_offer_cents, p_message, 'pending')
  on conflict (job_id, installer_id) do update
    set offer_cents = excluded.offer_cents, message = excluded.message,
        status = 'pending', decided_at = null, created_at = now()
  returning id into v_tid;

  insert into events (site_id, lead_id, actor_type, actor_id, event_type, payload)
  select null, null, 'installer', v_iid::text, 'job.tender_submitted',
    jsonb_build_object('job_id', p_job, 'tender_id', v_tid, 'offer_cents', p_offer_cents);

  return jsonb_build_object('ok', true, 'tender_id', v_tid);
end $function$;

-- ============================================================================
-- 5. list_invitable_installers: retailer-scoped directory for the invite picker
--    and for naming bidders on the compare screen. Company identity only —
--    never contact details; conversations stay inside the platform.
-- ============================================================================
create or replace function public.list_invitable_installers()
returns setof jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
declare v_rid uuid := public.current_retailer_id();
begin
  if v_rid is null then raise exception 'not a retailer'; end if;
  return query
  select jsonb_build_object(
    'id', i.id,
    'company_name', i.company_name,
    'preapproved', exists (
      select 1 from retailer_installer_rates r
      where r.retailer_id = v_rid and r.installer_id = i.id and r.approved_at is not null
    )
  )
  from installers i
  where i.status = 'approved' and i.subcontractor_opted_in_at is not null
  order by i.company_name;
end $function$;

revoke all on function public.list_invitable_installers() from public;
grant execute on function public.list_invitable_installers() to authenticated;
