-- Billy (the lead-agent edge function, running as service_role) prices leads
-- with the same engine HQ's Instant quote uses. Widen the auth check to admit
-- service_role; browsers still need admin/staff. Body otherwise identical to
-- the previous version of quote_estimate.
create or replace function public.quote_estimate(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_margin numeric := coalesce((p->>'margin_pct')::numeric,
                        (select material_margin_pct_default from pricing_config))/100;
  v_stcp numeric := coalesce((p->>'stc_price')::numeric, 37);
  v_zone numeric := coalesce((p->>'zone_rating')::numeric, 1.382);
  v_deem numeric := coalesce((p->>'deeming_years')::numeric, 5);
  v_min_watts numeric := coalesce((select min_solar_watts from pricing_config),6600);
  v_kw numeric := coalesce((p->>'solar_kw')::numeric,0);
  v_inv_kw numeric := coalesce((p->>'inverter_kw')::numeric, (p->>'solar_kw')::numeric, 0);
  v_panel_qty int := coalesce((p->>'panel_qty')::int,0);
  v_panel_price numeric := (select min(unit_price) from supplier_materials where part_no=p->>'panel_part' and unit_price is not null);
  v_inv_qty int := coalesce((p->>'inverter_qty')::int,1);
  v_inv_price numeric := (select min(unit_price) from supplier_materials where part_no=p->>'inverter_part' and unit_price is not null);
  v_bat_qty int := coalesce((p->>'battery_qty')::int,0);
  v_bat_price numeric := (select min(unit_price) from supplier_materials where part_no=p->>'battery_part' and unit_price is not null);
  v_bat_kwh numeric := coalesce((p->>'battery_kwh_usable')::numeric,0);
  v_bat_modules int := coalesce((p->>'battery_modules')::int, v_bat_qty);
  v_bat_stacks int := coalesce((p->>'battery_stacks')::int,1);
  v_bos numeric := coalesce((p->>'mounting_bos')::numeric,0);
  v_storey int := coalesce((p->>'storey')::int,1);
  v_phase int := coalesce((p->>'phase')::int,1);
  v_dc_m numeric := coalesce((p->>'dc_run_m')::numeric,0);
  v_ac_m numeric := coalesce((p->>'ac_run_m')::numeric,0);
  v_switchboard boolean := coalesce((p->>'switchboard_upgrade')::boolean,false);
  v_meter_upg boolean := coalesce((p->>'meter_upgrade')::boolean,false);
  v_l2 boolean := coalesce((p->>'service_fuse_l2')::boolean,false);
  v_mat_cost numeric; v_mat_sell numeric; v_watts numeric; v_solar_rate numeric;
  v_solar_lab numeric; v_dc numeric; v_ac numeric; v_bat_install numeric; v_backup numeric;
  v_switch numeric; v_meter numeric; v_svcfuse numeric; v_admin numeric := 530;
  v_labour numeric; v_ac_cable numeric;
  v_stc_solar int; v_stc_bat int; v_rebate numeric; v_has_battery boolean;
begin
  if not (public.is_admin() or public.is_active_staff() or auth.role() = 'service_role') then
    raise exception 'not authorised';
  end if;
  v_has_battery := (coalesce(v_bat_qty,0)>0 or coalesce(v_bat_modules,0)>0);
  v_mat_cost := coalesce(v_panel_qty*v_panel_price,0) + coalesce(v_inv_qty*v_inv_price,0)
              + coalesce(v_bat_qty*v_bat_price,0) + v_bos;
  v_mat_sell := round(v_mat_cost*(1+v_margin),2);
  v_watts := greatest(v_kw*1000, v_min_watts);
  v_solar_rate := case when v_storey>=2 then 0.34 else 0.32 end;
  v_solar_lab := round(v_watts*v_solar_rate,2);
  v_dc := 550 + greatest(0, v_dc_m-25)*14.16;
  if v_inv_kw <= 10 then
    v_ac := 95 + greatest(0, v_ac_m-5)*12.50;
  else
    v_ac_cable := (select quote_unit_price from cable_quote_price
                   where part_no = case when v_phase=3 then 'AC-16MM-4CE-ORANGE' else 'AC-16MM-2CE' end);
    v_ac := round(v_ac_m * coalesce(v_ac_cable,0) * 1.45, 2);
  end if;
  v_bat_install := case when v_has_battery
    then 2000 + greatest(0, v_bat_modules-4)*180 + greatest(0, v_bat_stacks-1)*450 else 0 end;
  v_backup := case when v_has_battery then (case when v_phase=3 then 350 else 280 end) else 0 end;
  v_switch := case when v_switchboard then coalesce((select baseline_rate from chargeables where code='switchboard_upgrade'),850) else 0 end;
  v_meter := case when v_meter_upg then coalesce((select baseline_rate from chargeables where code='meter_upgrade'),0) else 0 end;
  v_svcfuse := case when v_l2 then coalesce((select baseline_rate from chargeables where code='service_fuse_l2'),425) else 0 end;
  v_labour := v_solar_lab + v_dc + v_ac + v_bat_install + v_backup + v_switch + v_meter + v_svcfuse + v_admin;
  v_stc_solar := floor(v_kw * v_zone * v_deem);
  v_stc_bat := floor(6.8 * ( least(v_bat_kwh,14)*1.0
                           + greatest(0, least(v_bat_kwh,28)-14)*0.6
                           + greatest(0, least(v_bat_kwh,50)-28)*0.15 ));
  v_rebate := (v_stc_solar + v_stc_bat) * v_stcp;
  return jsonb_build_object(
    'materials_cost', round(v_mat_cost,2), 'materials_sell', v_mat_sell, 'margin_pct', round(v_margin*100,1),
    'solar_labour', v_solar_lab, 'dc_run', round(v_dc,2), 'ac_run', round(v_ac,2),
    'battery_install', v_bat_install, 'backup', v_backup, 'switchboard', v_switch,
    'meter_upgrade', v_meter, 'service_fuse_l2', v_svcfuse, 'admin', v_admin,
    'labour_total', round(v_labour,2),
    'subtotal_exgst', round(v_mat_sell + v_labour,2), 'gst', round((v_mat_sell+v_labour)*0.10,2),
    'stc_solar', v_stc_solar, 'stc_battery', v_stc_bat, 'stc_price', v_stcp, 'stc_rebate', round(v_rebate,2),
    'total_incl_gst', round((v_mat_sell+v_labour)*1.10 - v_rebate,2),
    'material_profit', round(v_mat_cost*v_margin,2));
end
$fn$;
