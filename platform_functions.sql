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
create or replace function public.book_assessment(p_lead_id uuid, p_site_id uuid, p_slot text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into inspections (site_id, lead_id, mode, notes)
  values (p_site_id, p_lead_id, 'presale', jsonb_build_object('slot', p_slot, 'booked_via', 'funnel'));
  update leads set state='appointment_set' where id = p_lead_id and state <> 'appointment_set';
  insert into events (site_id, lead_id, actor_type, event_type, payload)
  values (p_site_id, p_lead_id, 'customer', 'assessment.booked', jsonb_build_object('slot', p_slot));
end $$;

revoke all on function public.capture_lead(jsonb) from public;
revoke all on function public.book_assessment(uuid,uuid,text) from public;
grant execute on function public.capture_lead(jsonb) to anon, authenticated;
grant execute on function public.book_assessment(uuid,uuid,text) to anon, authenticated;
