-- Fix: the completed-job photo gate counts any non-passing photo as blocking. No-access
-- evidence photos (step_key='no_access_evidence', ai_verdict null) are not part of the
-- capture checklist, so exclude them — otherwise a tech who grabbed no-access evidence and
-- then got access couldn't submit 'completed'.
create or replace function public.submit_assessment(p_assessment_id uuid, p_outcome text, p_site_data jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare
  v_rep uuid := current_sales_rep_id(); v_a record; v_fee int; v_status text; v_bad int;
  v_asg_id uuid; v_jobs_done int; v_jobs_target int; v_new_status text := null;
  v_reason text := nullif(trim(p_site_data->>'access_reason'), '');
  v_glat double precision; v_glng double precision; v_slat double precision; v_slng double precision;
  v_dist double precision; v_ev int;
begin
  if p_outcome not in ('completed','no_access','partial') then raise exception 'invalid outcome'; end if;
  select * into v_a from assessments where id = p_assessment_id;
  if v_a.id is null then raise exception 'assessment not found'; end if;
  if v_a.sales_rep_id <> v_rep then raise exception 'not your job'; end if;
  if v_a.status not in ('in_progress','scheduled') then raise exception 'cannot submit from status %', v_a.status; end if;

  if p_outcome = 'completed' then
    select count(*) into v_bad from assessment_photos
      where assessment_id = p_assessment_id and step_key <> 'no_access_evidence'
        and (ai_verdict is distinct from 'pass') and na_reason is null;
    if v_bad > 0 then raise exception '% photo step(s) still need a passing shot or an N/A reason', v_bad; end if;
  end if;

  if p_outcome = 'no_access' then
    if v_reason is null then raise exception 'a reason is required for a no-access visit'; end if;
    if v_a.scheduled_at is null then raise exception 'no confirmed booking on file — cannot claim no access'; end if;
    v_glat := (v_a.start_gps->>'lat')::double precision;
    v_glng := (v_a.start_gps->>'lng')::double precision;
    if v_glat is null or v_glng is null then
      raise exception 'start the visit on site first — GPS attendance is required to log no access';
    end if;
    select s.lat, s.lng into v_slat, v_slng
      from leads l join sites s on s.id = l.site_id where l.id = v_a.lead_id;
    if v_slat is not null and v_slng is not null then
      v_dist := geo_distance_m(v_glat, v_glng, v_slat, v_slng);
      if v_dist > 300 then
        raise exception 'your GPS is % m from the site — must be on site to log no access', round(v_dist);
      end if;
    end if;
    select count(*) into v_ev from assessment_photos
      where assessment_id = p_assessment_id and step_key = 'no_access_evidence'
        and lat is not null and lng is not null;
    if v_ev < 1 then
      raise exception 'add at least one geotagged evidence photo (locked gate / no-one home / call log) to log no access';
    end if;
  end if;

  v_status := p_outcome;

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
    v_fee := 0;
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
  select l.site_id, v_a.lead_id, 'sales_rep', v_rep::text,
         case when p_outcome = 'no_access' then 'assessment.no_access' else 'assessment.submitted' end,
         jsonb_build_object('assessment_id', p_assessment_id, 'outcome', p_outcome, 'fee_cents', v_fee,
                            'access_reason', v_reason, 'gps_dist_m', round(v_dist),
                            'drone_jobs_done', v_jobs_done, 'drone_jobs_target', v_jobs_target,
                            'drone_earned', (v_new_status = 'owned'))
  from leads l where l.id = v_a.lead_id;

  return jsonb_build_object('ok', true, 'outcome', p_outcome, 'fee_cents', v_fee,
                            'access_reason', v_reason,
                            'drone_jobs_done', v_jobs_done, 'drone_jobs_target', v_jobs_target,
                            'drone_earned', (v_new_status = 'owned'));
end $function$;
