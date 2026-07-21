-- ============================================================================
-- SOLARSEARCH — public capture RPCs (run AFTER schema.sql + seed.sql)
-- These let the anonymous public funnel write into the staff-only schema
-- safely: SECURITY DEFINER creates customer + site + lead + events under RLS.
-- ============================================================================

-- Public lead capture: customer + site + lead(captured) + events.
create or replace function public.capture_lead(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_region uuid;
  v_site_id uuid; v_ss text; v_customer_id uuid; v_lead_id uuid;
  v_postcode text := nullif(payload->>'postcode','');
  v_goal text := coalesce(payload->>'goal','');
  v_lead_type text; v_timeline text; v_owner text;
  v_roof text := nullif(payload->>'roof','');
  v_storeys smallint;
  v_extras text[];
  v_bill numeric := nullif(payload->>'bill','')::numeric;
  v_consents jsonb;
  v_marketing boolean := coalesce((payload->>'consent_marketing')::boolean,false);
  v_privacy boolean := coalesce((payload->>'consent_privacy')::boolean,false);
begin
  v_lead_type := case v_goal
    when 'solar' then 'solar' when 'both' then 'solar_battery'
    when 'battery' then 'battery_retrofit' when 'commercial' then 'commercial'
    when 'solarsafe' then 'solarsafe_audit'
    else 'solar_battery' end;
  v_timeline := case nullif(payload->>'timeline','')
    when 'asap' then 'asap' when 'soon' then '1_3_months'
    when 'later' then '3_6_months' when 'research' then 'researching' else null end;
  v_owner := case nullif(payload->>'own','')
    when 'own' then 'owner_occupier' when 'landlord' then 'landlord'
    when 'rent' then 'renter_with_authority' else null end;
  if v_roof is not null and v_roof not in ('tile','tin','flat') then v_roof := 'other'; end if;
  v_storeys := case nullif(payload->>'storeys','') when '1' then 1 when '2' then 2 else null end;

  select coalesce(array_agg(case when e='hw' then 'electric_hw' else e end), '{}')
    into v_extras
  from jsonb_array_elements_text(coalesce(payload->'extras','[]'::jsonb)) as t(e);

  select region_id into v_region from region_postcodes where postcode = v_postcode limit 1;

  insert into customers (full_name, email, mobile)
  values (coalesce(nullif(payload->>'name',''),'(no name)'), nullif(payload->>'email',''), nullif(payload->>'mobile',''))
  returning id into v_customer_id;

  insert into sites (region_id, address, postcode, state, roof_type, storeys)
  values (v_region, coalesce(nullif(payload->>'address',''),'(not provided)'), coalesce(v_postcode,'0000'), 'NSW', v_roof, v_storeys)
  returning id, ss_ref into v_site_id, v_ss;

  v_consents := case when v_privacy then jsonb_build_array(jsonb_build_object(
      'purpose','lead_sharing',
      'text_version', coalesce(payload->>'consent_version','collection-notice-2026-07'),
      'granted_at', now(),
      'marketing_opt_in', v_marketing
    )) else '[]'::jsonb end;

  insert into leads (site_id, customer_id, state, lead_type, bill_quarterly_cents, timeline, owner_status, extras, existing_system, source_platform, utm, consents)
  values (v_site_id, v_customer_id, 'captured', v_lead_type,
    case when v_bill is not null then (v_bill*100)::int else null end,
    v_timeline, v_owner, coalesce(v_extras,'{}'),
    case when v_goal='battery' then jsonb_build_object('size', payload->>'sysSize', 'backup', payload->>'backup') else null end,
    coalesce(nullif(payload->>'source_platform',''),'organic'),
    coalesce(payload->'utm','{}'::jsonb),
    v_consents)
  returning id into v_lead_id;

  insert into events (site_id, lead_id, actor_type, event_type, payload)
  values (v_site_id, v_lead_id, 'customer', 'lead.captured',
    jsonb_build_object('ss_ref', v_ss, 'goal', v_goal, 'lead_type', v_lead_type,
      'org_name', payload->>'org_name', 'org_spend', payload->>'org_spend',
      'utm', coalesce(payload->'utm','{}'::jsonb), 'referrer', payload->>'referrer'));

  if v_consents <> '[]'::jsonb then
    insert into events (site_id, lead_id, actor_type, event_type, payload)
    values (v_site_id, v_lead_id, 'customer', 'consent.granted', v_consents->0);
  end if;

  return jsonb_build_object('ss_ref', v_ss, 'lead_id', v_lead_id, 'site_id', v_site_id);
end $$;

-- Booking: inspection + advance lead state (auto-logs via trigger) + event.
-- p_mode/p_reason let callers create either a 'presale' (index.html) or
-- 'solarsafe' (solarsafe.html) inspection; p_reason records why the
-- customer booked (feeds field.html's protocol-mode selection).
create or replace function public.book_assessment(p_lead_id uuid, p_site_id uuid, p_slot text, p_mode text default 'presale', p_reason text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_mode not in ('presale','solarsafe') then
    raise exception 'invalid inspection mode: %', p_mode;
  end if;
  insert into inspections (site_id, lead_id, mode, notes)
  values (p_site_id, p_lead_id, p_mode,
    jsonb_strip_nulls(jsonb_build_object('slot', p_slot, 'booked_via', 'funnel', 'reason', p_reason)));
  update leads set state='appointment_set' where id = p_lead_id and state <> 'appointment_set';
  insert into events (site_id, lead_id, actor_type, event_type, payload)
  values (p_site_id, p_lead_id, 'customer', 'assessment.booked', jsonb_build_object('slot', p_slot, 'mode', p_mode));
end $$;

-- field.html's "Create quote lead from this inspection" button (Solarsafe
-- jobs only): clones the existing site/customer into a new sales lead
-- rather than re-running capture_lead (which would duplicate rows that
-- already exist from the original Solarsafe booking).
create or replace function public.convert_solarsafe_lead(p_inspection_id uuid, p_staff_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_site_id uuid; v_orig_lead_id uuid; v_customer_id uuid; v_new_lead_id uuid; v_ss text; v_consents jsonb;
begin
  select i.site_id, i.lead_id into v_site_id, v_orig_lead_id from inspections i where i.id = p_inspection_id;
  if v_site_id is null then raise exception 'inspection not found'; end if;
  select customer_id, consents into v_customer_id, v_consents from leads where id = v_orig_lead_id;
  select ss_ref into v_ss from sites where id = v_site_id;

  insert into leads (site_id, customer_id, state, lead_type, source_platform, consents)
  values (v_site_id, v_customer_id, 'captured', 'solar_battery', 'solarsafe_conversion', coalesce(v_consents,'[]'::jsonb))
  returning id into v_new_lead_id;

  insert into events (site_id, lead_id, actor_type, actor_id, event_type, payload)
  values (v_site_id, v_new_lead_id, 'staff', p_staff_id::text, 'lead.captured',
    jsonb_build_object('ss_ref', v_ss, 'source_platform', 'solarsafe_conversion', 'from_inspection', p_inspection_id));

  return jsonb_build_object('ss_ref', v_ss, 'lead_id', v_new_lead_id);
end $$;

-- Complete an inspection from field.html. Atomically: set completed_at, log
-- the outcome, and (presale only) advance the lead to 'inspected' so HQ's
-- pipeline moves it to the design queue. Solarsafe audits complete without
-- advancing (they're not sales-pipeline leads).
create or replace function public.complete_inspection(p_inspection_id uuid, p_counts jsonb default '{}', p_staff_id uuid default null)
returns void
language plpgsql
set search_path = public
as $$
declare
  v_mode text; v_site_id uuid; v_lead_id uuid;
begin
  select mode, site_id, lead_id into v_mode, v_site_id, v_lead_id
  from inspections where id = p_inspection_id;
  if v_site_id is null then raise exception 'inspection not found'; end if;

  update inspections set completed_at = now() where id = p_inspection_id and completed_at is null;

  insert into events (site_id, lead_id, actor_type, actor_id, event_type, payload)
  values (v_site_id, v_lead_id, 'staff', p_staff_id::text, 'inspection.completed', coalesce(p_counts,'{}'::jsonb));

  if v_mode = 'presale' and v_lead_id is not null then
    update leads set state = 'inspected'
    where id = v_lead_id and state not in ('inspected','designed','quoted','customer_chose','signed','connection_approved','installed','der_registered','audited','closed');
  end if;
end $$;

revoke all on function public.capture_lead(jsonb) from public;
-- Design step: inspected lead -> completed design row -> 'designed'.
create or replace function public.create_design(
  p_lead_id uuid, p_system_kw numeric default null, p_battery_kwh numeric default null,
  p_components jsonb default '{}', p_staff_id uuid default null)
returns jsonb
language plpgsql
set search_path = public
as $$
declare v_site_id uuid; v_design_id uuid;
begin
  select site_id into v_site_id from leads where id = p_lead_id;
  if v_site_id is null then raise exception 'lead not found'; end if;
  insert into designs (site_id, variant, system_kw, battery_kwh, components, status, designed_by, completed_at)
  values (v_site_id, 'primary', p_system_kw, p_battery_kwh, coalesce(p_components,'{}'::jsonb), 'complete', p_staff_id, now())
  returning id into v_design_id;
  update leads set state = 'designed' where id = p_lead_id and state = 'inspected';
  insert into events (site_id, lead_id, actor_type, actor_id, event_type, payload)
  values (v_site_id, p_lead_id, 'staff', p_staff_id::text, 'design.completed',
    jsonb_build_object('design_id', v_design_id, 'system_kw', p_system_kw, 'battery_kwh', p_battery_kwh));
  return jsonb_build_object('design_id', v_design_id);
end $$;

-- Open the installer board: designed job becomes seat-buyable. 'designed' -> 'quoted'.
create or replace function public.open_board(p_lead_id uuid, p_staff_id uuid default null)
returns void
language plpgsql
set search_path = public
as $$
declare v_site_id uuid;
begin
  select site_id into v_site_id from leads where id = p_lead_id;
  if v_site_id is null then raise exception 'lead not found'; end if;
  update leads set state = 'quoted' where id = p_lead_id and state = 'designed';
  insert into events (site_id, lead_id, actor_type, actor_id, event_type, payload)
  values (v_site_id, p_lead_id, 'staff', p_staff_id::text, 'board.opened', '{}'::jsonb);
end $$;

revoke all on function public.book_assessment(uuid,uuid,text,text,text) from public;
revoke all on function public.convert_solarsafe_lead(uuid,uuid) from public;
revoke all on function public.complete_inspection(uuid,jsonb,uuid) from public;
revoke all on function public.create_design(uuid,numeric,numeric,jsonb,uuid) from public;
revoke all on function public.open_board(uuid,uuid) from public;
grant execute on function public.capture_lead(jsonb) to anon, authenticated;
grant execute on function public.book_assessment(uuid,uuid,text,text,text) to anon, authenticated;
grant execute on function public.convert_solarsafe_lead(uuid,uuid) to authenticated;
grant execute on function public.complete_inspection(uuid,jsonb,uuid) to authenticated;
grant execute on function public.create_design(uuid,numeric,numeric,jsonb,uuid) to authenticated;
grant execute on function public.open_board(uuid,uuid) to authenticated;

-- ============================================================================
-- Installer portal: identity link + firewalled board + seat/quote (§2, §8).
-- Installer-facing access goes only through these SECURITY DEFINER RPCs, which
-- whitelist columns and scope to the caller's own installer via auth_uid — the
-- installers/seats/quotes tables stay staff-only under RLS. Full definitions
-- live in supabase/migrations/0011_installer_identity_board_and_seats.sql;
-- see also 0012 (installer self-read policy for the header company name).
-- ============================================================================
-- current_installer_id(), v_design_id_safe(uuid), installer_board(),
-- buy_seat(uuid), link_installer_on_signup() + on_auth_user_created_installer
-- are defined in migration 0011 — kept there as the single source of truth for
-- this larger block rather than duplicated here.
