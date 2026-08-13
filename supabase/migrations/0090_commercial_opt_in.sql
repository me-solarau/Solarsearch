-- Commercial solar is opt-in for installers — not everybody's cup of tea.
--
-- A 100 kW – 1 MW job carries a different risk profile (SWMS, cranes, weeks on
-- one roof) and a residential crew should never have commercial work pushed at
-- them unasked. Mirrors the existing subcontractor opt-in: a timestamp column,
-- a self-serve toggle RPC, and enforcement in every commercial path — the
-- board, the grab, the tender, and the retailer's invite directory.

alter table public.installers add column if not exists commercial_opted_in_at timestamptz;

-- Self-serve toggle. Installers cannot update their own row (RLS is read-only
-- by design), so the flag moves through this narrow, audited gate instead.
create or replace function public.set_commercial_opt_in(p_in boolean)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare v_iid uuid := public.current_installer_id();
begin
  if v_iid is null then raise exception 'not an approved installer'; end if;
  update installers
    set commercial_opted_in_at = case when p_in then coalesce(commercial_opted_in_at, now()) else null end
    where id = v_iid;
  insert into events (site_id, lead_id, actor_type, actor_id, event_type, payload)
  select null, null, 'installer', v_iid::text,
    case when p_in then 'installer.commercial_opt_in' else 'installer.commercial_opt_out' end,
    jsonb_build_object('installer_id', v_iid);
  return jsonb_build_object('ok', true, 'commercial_opted_in', p_in);
end $function$;

revoke all on function public.set_commercial_opt_in(boolean) from public;
grant execute on function public.set_commercial_opt_in(boolean) to authenticated;

-- Board: commercial jobs only reach opted-in installers. Invitations do not
-- override the opt-in — an installer who has not raised their hand for
-- commercial sees none of it, even by name.
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
    and (j.sourcing_mode <> 'invite' or v_iid = any(j.invited_installer_ids))
    and (not j.is_commercial or exists (
      select 1 from installers i where i.id = v_iid and i.commercial_opted_in_at is not null));
end $function$;

-- Grab: a commercial job cannot be accepted without the commercial opt-in.
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
  if v_job.is_commercial and not exists (
    select 1 from installers where id = v_installer_id and commercial_opted_in_at is not null) then
    raise exception 'opt in to commercial solar before taking commercial jobs';
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

-- Tender: same rule for offers.
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
  if v_job.is_commercial and not exists (
    select 1 from installers where id = v_iid and commercial_opted_in_at is not null) then
    raise exception 'opt in to commercial solar before offering on commercial jobs';
  end if;
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

-- Invite directory: only commercial-opted installers are offerable — a retailer
-- cannot invite someone onto work they have not raised their hand for.
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
  where i.status = 'approved'
    and i.subcontractor_opted_in_at is not null
    and i.commercial_opted_in_at is not null
  order by i.company_name;
end $function$;
