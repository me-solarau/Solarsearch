-- Access is confirmed up front (confirmation-based booking), so a 'no access' visit is a
-- CONFIRMATION EXCEPTION, not a normal payable outcome. Change:
--   * no_access fee -> $0 (was $25). No payout for a visit that shouldn't happen; also
--     closes the integrity hole where no_access needed no photos (=> $25 for zero evidence).
--   * no_access now REQUIRES a reason (p_site_data.access_reason) so it's a logged, flagged
--     exception ops can act on (reschedule / chase the confirmation), never a silent claim.
create or replace function public.submit_assessment(p_assessment_id uuid, p_outcome text, p_site_data jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare
  v_rep uuid := current_sales_rep_id(); v_a record; v_fee int; v_status text; v_bad int;
  v_asg_id uuid; v_jobs_done int; v_jobs_target int; v_new_status text := null;
  v_reason text := nullif(trim(p_site_data->>'access_reason'), '');
begin
  if p_outcome not in ('completed','no_access','partial') then raise exception 'invalid outcome'; end if;
  if p_outcome = 'no_access' and v_reason is null then
    raise exception 'a reason is required for a no-access visit';
  end if;
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

  -- completed-job rate follows the drone rate differential (see 0045); no_access is a $0
  -- logged exception; partial keeps its prior fee.
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
                            'access_reason', v_reason,
                            'drone_jobs_done', v_jobs_done, 'drone_jobs_target', v_jobs_target,
                            'drone_earned', (v_new_status = 'owned'))
  from leads l where l.id = v_a.lead_id;

  return jsonb_build_object('ok', true, 'outcome', p_outcome, 'fee_cents', v_fee,
                            'access_reason', v_reason,
                            'drone_jobs_done', v_jobs_done, 'drone_jobs_target', v_jobs_target,
                            'drone_earned', (v_new_status = 'owned'));
end $function$;
