-- Remove the Solarsafe platform surface from Solarsearch.
--
-- Solarsafe is a separate business on a separate platform: its own repo
-- (me-solarau/solarsafe, Next.js + Prisma), its own database (the "Solarsafe
-- app" Supabase project), its own auth. What lived here was a parallel second
-- implementation — booking funnel, inspection mode, audit reports — competing
-- with the real one.
--
-- Solarsearch keeps referring customers to Solarsafe as a named partner; that
-- is marketing copy and links, and needs nothing in this database.
--
-- SAFETY: every object dropped below was verified empty on production
-- (project vbpzigwgfmchdpvxetge) before this migration was written:
--
--   audit_reports          0 rows
--   findings               0 rows
--   correspondence         0 rows
--   inspections mode='solarsafe'   0 rows   (7 rows exist, all 'presale')
--   leads lead_type='solarsafe_audit'  0 rows   (18 leads, none solarsafe)
--   staff role='inspector' 0 rows
--
-- Re-run those counts before applying if any time has passed. The migration
-- deliberately does NOT touch presale inspections, which are Solarsearch's own
-- consultant visits and carry live data.

begin;

-- Refuse to run if Solarsafe data appeared after this was written. Better to
-- fail loudly than to drop a customer's compliance report.
do $$
declare n integer;
begin
  select
    (select count(*) from audit_reports)
  + (select count(*) from findings)
  + (select count(*) from correspondence)
  + (select count(*) from inspections where mode = 'solarsafe')
  + (select count(*) from leads where lead_type = 'solarsafe_audit')
  into n;

  if n > 0 then
    raise exception
      'Aborting: % Solarsafe row(s) found. This migration only removes an empty, unused surface — migrate the data to the Solarsafe platform first.', n;
  end if;
end $$;

-- --- 1. the Solarsafe→Solarsearch lead bridge ------------------------------
-- field.html's "Create quote lead from this inspection" button. Turning a
-- compliance inspection into a sales lead is exactly the coupling that makes
-- Solarsafe's independence claim ("no installer commissions on inspections")
-- untrue, so it goes with the rest of the surface.
drop function if exists public.convert_solarsafe_lead(uuid, uuid);

-- --- 2. Solarsafe reporting tables -----------------------------------------
-- findings references audit_reports; correspondence references both it and
-- sites. Dropped child-first so no cascade is needed.
drop table if exists findings;
drop table if exists correspondence;
drop table if exists audit_reports;

-- --- 3. inspections: presale is the only mode Solarsearch books ------------
alter table inspections drop constraint if exists inspections_mode_check;
alter table inspections add constraint inspections_mode_check
  check (mode in ('presale'));

-- book_assessment: presale is the only mode it will now accept.
--
-- Signature and return type are kept byte-identical to the live function
-- (5 args, returns void) — `create or replace` cannot change a return type, and
-- index.html calls it with three arguments relying on the defaults. Body is the
-- live definition with only the mode check and the inserted mode changed.
create or replace function public.book_assessment(
  p_lead_id uuid,
  p_site_id uuid,
  p_slot text,
  p_mode text default 'presale',
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if p_mode <> 'presale' then
    raise exception 'invalid inspection mode: % (Solarsearch books presale visits only; compliance inspections are booked on Solarsafe)', p_mode;
  end if;

  insert into inspections (site_id, lead_id, mode, notes)
  values (p_site_id, p_lead_id, 'presale',
    jsonb_strip_nulls(jsonb_build_object('slot', p_slot, 'booked_via', 'funnel', 'reason', p_reason)));

  update leads set state = 'appointment_set'
   where id = p_lead_id and state <> 'appointment_set';

  insert into events (site_id, lead_id, actor_type, event_type, payload)
  values (p_site_id, p_lead_id, 'customer', 'assessment.booked',
    jsonb_build_object('slot', p_slot, 'mode', 'presale'));
end $function$;

-- --- 4. leads: drop the Solarsafe lead type and conversion source ----------
alter table leads drop constraint if exists leads_lead_type_check;
alter table leads add constraint leads_lead_type_check
  check (lead_type in ('solar', 'solar_battery', 'battery_retrofit', 'commercial'));

-- capture_lead maps a funnel goal to a lead_type. 'solarsafe' was solarsafe.html's
-- goal; that page is gone, so the mapping goes with it — otherwise a stale or
-- hand-crafted call with goal:'solarsafe' would still mint a 'solarsafe_audit'
-- lead and now fail the constraint above, breaking a public funnel endpoint.
--
-- Re-declared in full below, verbatim from 0026 apart from that one deleted
-- branch. Unknown goals already fall through to the 'solar_battery' default,
-- so removing the branch needs no other change.
update leads set source_platform = null where source_platform = 'solarsafe_conversion';

create or replace function public.capture_lead(payload jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
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
  v_existing jsonb := payload->'existing';
  v_wants jsonb := payload->'wants';
begin
  -- legacy goal -> lead_type (unchanged, keeps reporting stable)
  v_lead_type := case v_goal
    when 'solar' then 'solar' when 'both' then 'solar_battery'
    when 'battery' then 'battery_retrofit' when 'commercial' then 'commercial'
    else 'solar_battery' end;

  -- two-fact scope: use what the funnel sent, else derive from the legacy goal
  if v_existing is null then
    v_existing := case v_goal
      when 'battery' then jsonb_build_object('solar',true,'battery',false)
      else jsonb_build_object('solar',false,'battery',false) end;
  end if;
  if v_wants is null then
    v_wants := case v_goal
      when 'solar' then jsonb_build_object('solar',true,'battery',false)
      when 'both' then jsonb_build_object('solar',true,'battery',true)
      when 'battery' then jsonb_build_object('solar',false,'battery',true)
      else jsonb_build_object('solar',false,'battery',false) end;
  end if;

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

  insert into leads (site_id, customer_id, state, lead_type, bill_quarterly_cents, timeline, owner_status,
                     extras, existing_system, existing, wants, source_platform, utm, consents)
  values (v_site_id, v_customer_id, 'captured', v_lead_type,
    case when v_bill is not null then (v_bill*100)::int else null end,
    v_timeline, v_owner, coalesce(v_extras,'{}'),
    case when coalesce((v_existing->>'solar')::boolean,false)
         then jsonb_build_object('size', payload->>'sysSize', 'backup', payload->>'backup')
         else null end,
    v_existing, v_wants,
    coalesce(nullif(payload->>'source_platform',''),'organic'),
    coalesce(payload->'utm','{}'::jsonb),
    v_consents)
  returning id into v_lead_id;

  insert into events (site_id, lead_id, actor_type, event_type, payload)
  values (v_site_id, v_lead_id, 'customer', 'lead.captured',
    jsonb_build_object('ss_ref', v_ss, 'goal', v_goal, 'lead_type', v_lead_type,
      'existing', v_existing, 'wants', v_wants,
      'org_name', payload->>'org_name', 'org_spend', payload->>'org_spend',
      'utm', coalesce(payload->'utm','{}'::jsonb), 'referrer', payload->>'referrer'));

  if v_consents <> '[]'::jsonb then
    insert into events (site_id, lead_id, actor_type, event_type, payload)
    values (v_site_id, v_lead_id, 'customer', 'consent.granted', v_consents->0);
  end if;

  return jsonb_build_object('ss_ref', v_ss, 'lead_id', v_lead_id, 'site_id', v_site_id);
end $$;

-- --- 5. staff: inspector was the Solarsafe-only role -----------------------
alter table staff drop constraint if exists staff_role_check;
alter table staff add constraint staff_role_check
  check (role in ('admin', 'hq_ops', 'consultant', 'designer', 'compliance_reviewer'));

commit;
