-- Designs were never priced against the real catalog.
--
-- The HQ design form stores components as flat strings —
--   {"panel":"Jinko Tiger Neo 440W","inverter":"Sungrow SH-RS"}
-- but buy_seat reads components->'panel'->>'model'. Indexing a JSON *string* by
-- key returns null, so v_panel_cost and v_inv_cost were always 0, the catalog
-- match never fired, and every quote fell through to the flat per-kW materials
-- fallback. Panel qty was null too, so the BOM came out near zero.
--
-- Fix: designs carry structured components keyed to quote_catalog — the same
-- priced catalog the field-validated Instant Quote uses — and create_design
-- builds that object itself so the shape cannot drift from what buy_seat reads.

create or replace function public.design_catalog()
returns table(kind text, code text, label text, watts numeric, kw numeric,
              usable_kwh numeric, cost numeric)
language sql
stable security definer
set search_path to 'public'
as $$
  select c.kind, c.code, c.label, c.watts, c.kw, c.usable_kwh, c.cost
  from quote_catalog c
  where c.active and public.is_admin()
  order by c.kind, c.sort, c.label;
$$;

grant execute on function public.design_catalog() to authenticated;

create or replace function public.create_design(
  p_lead_id uuid,
  p_system_kw numeric default null,
  p_battery_kwh numeric default null,
  p_components jsonb default '{}'::jsonb,
  p_staff_id uuid default null,
  p_edge_perimeter_m numeric default null,
  p_panel_code text default null,
  p_panel_qty int default null,
  p_inverter_code text default null,
  p_battery_code text default null,
  p_battery_qty int default null,
  p_strings int default null,
  p_arrays int default null
)
returns jsonb
language plpgsql
set search_path to 'public'
as $function$
declare
  v_site_id uuid; v_design_id uuid;
  v_panel record; v_inv record; v_bat record;
  v_components jsonb := coalesce(p_components,'{}'::jsonb);
  v_kw numeric := p_system_kw; v_kwh numeric := p_battery_kwh;
begin
  select site_id into v_site_id from leads where id = p_lead_id;
  if v_site_id is null then raise exception 'lead not found'; end if;

  select * into v_panel from quote_catalog where kind='panel'    and code = p_panel_code    and active;
  select * into v_inv   from quote_catalog where kind='inverter' and code = p_inverter_code and active;
  select * into v_bat   from quote_catalog where kind='battery'  and code = p_battery_code  and active;

  -- Structured components keyed to the catalog. Only overwrite what was chosen,
  -- so a free-text design still saves exactly as before.
  if v_panel.code is not null then
    v_components := v_components || jsonb_build_object('panel', jsonb_build_object(
      'code', v_panel.code, 'model', v_panel.label, 'brand', split_part(v_panel.label,' ',1),
      'watts', v_panel.watts, 'qty', greatest(coalesce(p_panel_qty,0),0),
      'unit_cost', v_panel.cost));
    if p_panel_qty is not null and p_panel_qty > 0 then
      v_kw := round(p_panel_qty * v_panel.watts / 1000.0, 2);
    end if;
  end if;
  if v_inv.code is not null then
    v_components := v_components || jsonb_build_object('inverter', jsonb_build_object(
      'code', v_inv.code, 'model', v_inv.label, 'kw', v_inv.kw, 'unit_cost', v_inv.cost));
  end if;
  if v_bat.code is not null and coalesce(p_battery_qty,0) > 0 then
    v_components := v_components || jsonb_build_object('battery', jsonb_build_object(
      'code', v_bat.code, 'model', v_bat.label, 'qty', p_battery_qty,
      'usable_kwh', v_bat.usable_kwh, 'unit_cost', v_bat.cost));
    v_kwh := round(p_battery_qty * coalesce(v_bat.usable_kwh,0), 2);
  end if;
  if p_strings is not null then v_components := v_components || jsonb_build_object('strings', p_strings); end if;
  if p_arrays  is not null then v_components := v_components || jsonb_build_object('arrays',  p_arrays);  end if;

  insert into designs (site_id, variant, system_kw, battery_kwh, components, status,
                       designed_by, completed_at, edge_perimeter_m)
  values (v_site_id, 'primary', v_kw, v_kwh, v_components,
          'complete', p_staff_id, now(), p_edge_perimeter_m)
  returning id into v_design_id;

  update leads set state = 'designed'
  where id = p_lead_id and state = 'inspected';

  insert into events (site_id, lead_id, actor_type, actor_id, event_type, payload)
  values (v_site_id, p_lead_id, 'staff', p_staff_id::text, 'design.completed',
    jsonb_build_object('design_id', v_design_id, 'system_kw', v_kw,
                       'battery_kwh', v_kwh, 'edge_perimeter_m', p_edge_perimeter_m,
                       'components', v_components));

  return jsonb_build_object('design_id', v_design_id, 'system_kw', v_kw, 'battery_kwh', v_kwh);
end $function$;

-- Drop the older 6-arg form so PostgREST cannot resolve to a version that
-- silently ignores the catalog arguments (the same overload trap as before).
drop function if exists public.create_design(uuid, numeric, numeric, jsonb, uuid, numeric);
