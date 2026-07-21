-- Design step: turn an inspected lead into a completed design and advance it
-- to 'designed'. One design row per call (variant defaults to 'primary').
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

  update leads set state = 'designed'
  where id = p_lead_id and state = 'inspected';

  insert into events (site_id, lead_id, actor_type, actor_id, event_type, payload)
  values (v_site_id, p_lead_id, 'staff', p_staff_id::text, 'design.completed',
    jsonb_build_object('design_id', v_design_id, 'system_kw', p_system_kw, 'battery_kwh', p_battery_kwh));

  return jsonb_build_object('design_id', v_design_id);
end $$;

-- Open the installer board: a designed job becomes available for installers to
-- buy seats and quote. Advances 'designed' -> 'quoted'.
create or replace function public.open_board(p_lead_id uuid, p_staff_id uuid default null)
returns void
language plpgsql
set search_path = public
as $$
declare v_site_id uuid;
begin
  select site_id into v_site_id from leads where id = p_lead_id;
  if v_site_id is null then raise exception 'lead not found'; end if;

  update leads set state = 'quoted'
  where id = p_lead_id and state = 'designed';

  insert into events (site_id, lead_id, actor_type, actor_id, event_type, payload)
  values (v_site_id, p_lead_id, 'staff', p_staff_id::text, 'board.opened', '{}'::jsonb);
end $$;

revoke all on function public.create_design(uuid,numeric,numeric,jsonb,uuid) from public;
revoke all on function public.open_board(uuid,uuid) from public;
grant execute on function public.create_design(uuid,numeric,numeric,jsonb,uuid) to authenticated;
grant execute on function public.open_board(uuid,uuid) to authenticated;
