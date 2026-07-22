-- Structured site facts flow: sales-tech capture -> sites -> quote engine.
-- submit_assessment now maps the tech's site_data (phase/roof/storeys) onto the
-- sites columns so the quote engine reads real facts, not assumptions. quote_prefill
-- returns a lead's captured facts (phase, roof->tin/tile, storey, AC run from the
-- walked board-to-inverter distance, existing/wants) to pre-fill the instant quote.
create or replace function public.submit_assessment(p_assessment_id uuid, p_outcome text, p_site_data jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
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
         jsonb_build_object('assessment_id', p_assessment_id, 'outcome', p_outcome, 'fee_cents', v_fee)
  from leads l where l.id = v_a.lead_id;

  return jsonb_build_object('ok', true, 'outcome', p_outcome, 'fee_cents', v_fee);
end $function$;

create or replace function public.quote_prefill(p_lead_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v record; v_sd jsonb;
begin
  if not (public.is_admin() or public.is_active_staff()) then raise exception 'not authorised'; end if;
  select l.existing, l.wants, l.existing_system, s.ss_ref, s.address, s.postcode,
         s.phases, s.roof_type, s.storeys
    into v from leads l join sites s on s.id = l.site_id where l.id = p_lead_id;
  if not found then raise exception 'lead not found'; end if;
  select site_data into v_sd from assessments
    where lead_id = p_lead_id and status = 'completed' order by submitted_at desc limit 1;
  return jsonb_build_object(
    'ss_ref', v.ss_ref, 'address', v.address, 'postcode', v.postcode,
    'phase', coalesce(v.phases, case v_sd->>'phase' when 'three' then 3 when 'single' then 1 else null end),
    'storey', coalesce(v.storeys, case v_sd->>'storeys' when 'double' then 2 when 'multi' then 3 else 1 end),
    'roof_type', v.roof_type,
    'roof', case when coalesce(v.roof_type,'') ~* 'tile' then 'tile'
                 when coalesce(v.roof_type,'') ~* 'metal|tin|corrugated|flat' then 'tin' else 'other' end,
    'ac_run_m', nullif(v_sd->>'board_to_inverter_m','')::numeric,
    'switchboard', v_sd->>'switchboard_condition', 'meter', v_sd->>'meter_type',
    'existing', v.existing, 'wants', v.wants, 'existing_system', v.existing_system);
end $$;
