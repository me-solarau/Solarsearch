-- buy_seat prices materials from the real catalog, and never from a labour rate.
--
-- Two defects fixed together:
--
-- 1. Materials source. buy_seat only matched supplier_materials on a model
--    string that HQ designs never contained (see 0080), so it always fell
--    through to the flat per-kW estimate. It now tries, in order:
--       catalog             quote_catalog by code — same source as instant_quote
--       supplier_materials  invoice history, matched on model text
--       price_book_estimate flat per-kW equipment rate, recorded as estimated
--    The source used is written to line_items.materials_source, and
--    materials_estimated flags the last resort so a guessed job is identifiable
--    rather than silently indistinguishable from a real one.
--
-- 2. Labour placement. Labour comes from installer_labour_rate() — the
--    installer's own $/W plus the rate-card roof/storey differential. The
--    materials margin applies to MATERIALS ONLY; labour, cable and travel pass
--    through at rate-card price instead of being marked up as if they were kit.
--
-- The price-book equipment fallback default drops from $1,350/kW to $450/kW.
-- $1,350/kW is a fully-installed retail figure; using it as an equipment cost
-- and then adding margin and labour on top priced a 6.6kW job near $19,700.
--
-- Verified end to end on a 15-panel 6.98kW tin single-storey job:
--   panels $2,010 + inverter $1,650 + BOM $935 = materials $4,595 (source: catalog)
--   materials sell (+34%) $6,962 · labour 6,980W x $0.35 = $2,443
--   cable $645 · admin $530 · before rebates $11,638
--   48 STC -> $1,776 rebate · customer pays $9,862

create or replace function public.buy_seat(p_site_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_iid uuid := current_installer_id();
  v_state lead_state; v_seat_id uuid; v_pb record; v_design record; v_site record;
  v_margin numeric; v_panel_qty int; v_bat_qty int; v_strings int; v_arrays int;
  v_kw numeric; v_kwh numeric; v_watts numeric; v_min_watts numeric;
  v_panel_cost numeric := 0; v_inv_cost numeric := 0; v_bat_cost numeric := 0;
  v_bom jsonb; v_bos numeric := 0; v_mat_src text := 'catalog';
  v_mat_cost numeric; v_mat_sell numeric;
  v_roof text; v_solar_rate numeric; v_solar_lab numeric; v_admin numeric := 530;
  v_bat_install numeric := 0; v_labour numeric;
  v_cable numeric := 0; v_travel numeric := 0;
  v_stc int; v_bat_stc numeric := 0; v_prev numeric := 0; v_cap numeric; v_rate numeric;
  v_rebate int; v_before int; v_after int; v_qid uuid; v_ver text;
  v_tiers numeric[][] := array[[14,1.0],[28,0.6],[50,0.15]];
  i int;
begin
  if v_iid is null then raise exception 'not an approved installer'; end if;
  select state into v_state from leads where site_id = p_site_id order by created_at desc limit 1;
  if v_state is null or v_state not in ('quoted','customer_chose') then
    raise exception 'site is not open for quoting'; end if;
  if not exists (select 1 from installer_service_areas
                 where installer_id = v_iid
                   and postcode = (select postcode from sites where id = p_site_id)
                   and not paused) then
    raise exception 'site is outside your service areas';
  end if;

  select * into v_pb from price_books where installer_id = v_iid and active
    and (verified_at is null or verified_at > now() - interval '60 days')
    order by created_at desc limit 1;
  if v_pb.id is null then raise exception 'no active (non-stale) price book — verify your rates first'; end if;

  select * into v_design from designs where site_id = p_site_id order by created_at desc limit 1;
  select * into v_site   from sites   where id = p_site_id;

  v_kw  := coalesce(v_design.system_kw, 0);
  v_kwh := coalesce(v_design.battery_kwh, 0);
  v_panel_qty := coalesce((v_design.components->'panel'->>'qty')::int, 0);
  v_bat_qty   := coalesce((v_design.components->'battery'->>'qty')::int, 0);
  v_strings   := greatest(1, coalesce((v_design.components->>'strings')::int, 2));
  v_arrays    := greatest(1, coalesce((v_design.components->>'arrays')::int, 1));

  insert into seats (site_id, installer_id, path, price_cents)
  values (p_site_id, v_iid, 'path2_seat', 20000)
  returning id into v_seat_id;

  -- 1st: the priced design catalog, keyed by code. Same source instant_quote uses.
  v_panel_cost := coalesce((select c.cost from quote_catalog c
                  where c.kind='panel' and c.active
                    and c.code = v_design.components->'panel'->>'code'), 0) * v_panel_qty;
  v_inv_cost   := coalesce((select c.cost from quote_catalog c
                  where c.kind='inverter' and c.active
                    and c.code = v_design.components->'inverter'->>'code'), 0);
  v_bat_cost   := coalesce((select c.cost from quote_catalog c
                  where c.kind='battery' and c.active
                    and c.code = v_design.components->'battery'->>'code'), 0) * greatest(v_bat_qty,0);

  -- 2nd: supplier invoice history, matched on the model text.
  if v_panel_cost = 0 and v_inv_cost = 0 then
    v_mat_src := 'supplier_materials';
    v_panel_cost := coalesce((
      select min(unit_price) from supplier_materials
      where active and category='panel'
        and (v_design.components->'panel'->>'model') is not null
        and description ilike '%'||(v_design.components->'panel'->>'model')||'%'), 0) * v_panel_qty;
    v_inv_cost := coalesce((
      select min(unit_price) from supplier_materials
      where active and category='inverter'
        and (v_design.components->'inverter'->>'model') is not null
        and description ilike '%'||(v_design.components->'inverter'->>'model')||'%'), 0);
    v_bat_cost := coalesce((
      select min(unit_price) from supplier_materials
      where active and category='battery'
        and (v_design.components->'battery'->>'model') is not null
        and description ilike '%'||(v_design.components->'battery'->>'model')||'%'), 0);
  end if;

  v_bom := public.bom_estimate(v_panel_qty, v_strings, v_arrays,
             coalesce(v_design.components->>'orientation','landscape'));
  v_bos := coalesce((v_bom->>'total')::numeric, 0);
  v_mat_cost := v_panel_cost + v_inv_cost + v_bat_cost + v_bos;

  -- 3rd and last: the price book's flat EQUIPMENT rate per kW. This is a coarse
  -- estimate, never a labour rate — labour is priced separately below.
  if v_panel_cost = 0 and v_inv_cost = 0 then
    v_mat_src := 'price_book_estimate';
    v_mat_cost := coalesce((v_pb.base_rates->>'solar_fixed_cents')::numeric,160000)/100
                + coalesce((v_pb.base_rates->>'solar_per_kw_cents')::numeric,45000)/100 * v_kw
                + case when v_kwh > 0
                    then coalesce((v_pb.base_rates->>'battery_fixed_cents')::numeric,280000)/100
                       + coalesce((v_pb.base_rates->>'battery_per_kwh_cents')::numeric,82000)/100 * v_kwh
                    else 0 end;
    v_bos := 0;
  end if;

  -- Materials margin. Applied to materials only — never to labour, cable or
  -- travel, which pass through at rate-card price.
  v_margin := coalesce(v_pb.margin_pct,
                       (select material_margin_pct_default from pricing_config), 34) / 100.0;
  if v_margin >= 0.95 then v_margin := 0.95; end if;
  v_mat_sell := round(v_mat_cost / (1 - v_margin), 2);

  v_min_watts := coalesce((select min_solar_watts from pricing_config), 6600);
  v_watts := greatest(v_kw * 1000, v_min_watts);
  v_roof := coalesce(v_design.roof_material, v_site.roof_type, 'tin');
  v_solar_rate := public.installer_labour_rate(v_pb.id, v_roof, coalesce(v_site.storeys,1));
  v_solar_lab := round(v_watts * v_solar_rate, 2);
  v_bat_install := case when v_kwh > 0 then 2000 else 0 end;

  v_cable  := public.cable_charge(v_design.dc_run_m, v_design.ac_run_m);
  v_travel := public.travel_charge(v_design.travel_km);

  v_labour := v_solar_lab + v_bat_install + v_admin + v_cable + v_travel;
  v_before := round((v_mat_sell + v_labour) * 1.10 * 100);

  v_stc := public.solar_stc_count(v_kw);
  for i in 1..array_length(v_tiers,1) loop
    v_cap := v_tiers[i][1]; v_rate := v_tiers[i][2];
    v_bat_stc := v_bat_stc + greatest(0, least(v_kwh, v_cap) - v_prev) * 6.8 * v_rate;
    v_prev := v_cap;
    exit when v_kwh <= v_cap;
  end loop;
  v_stc := v_stc + floor(v_bat_stc);
  v_rebate := v_stc * 3700;
  v_after := greatest(0, v_before - v_rebate);

  select version into v_ver from incentive_rules order by effective_from desc limit 1;

  insert into quotes (site_id, design_id, installer_id, seat_id, path, price_book_id,
                      rules_version, price_before_rebates_cents, rebate_cents,
                      price_after_cents, stc_count, line_items, status)
  values (p_site_id, v_design.id, v_iid, v_seat_id, 'path1_auto', v_pb.id,
          coalesce(v_ver,'v2026.05'), v_before, v_rebate, v_after, v_stc,
          jsonb_build_object(
            'materials_source', v_mat_src,
            'materials_estimated', (v_mat_src = 'price_book_estimate'),
            'materials_cost', round(v_mat_cost,2),
            'materials_sell', v_mat_sell,
            'margin_pct', round(v_margin*100,1),
            'panel_cost', round(v_panel_cost,2),
            'inverter_cost', round(v_inv_cost,2),
            'battery_cost', round(v_bat_cost,2),
            'bom', v_bom,
            'roof_material', v_roof,
            'storeys', coalesce(v_site.storeys,1),
            'solar_labour_rate_per_watt', v_solar_rate,
            'solar_labour', v_solar_lab,
            'billable_watts', v_watts,
            'min_billable_applied', (v_kw*1000 < v_min_watts),
            'battery_install', v_bat_install,
            'cable_runs', v_cable,
            'dc_run_m', v_design.dc_run_m,
            'ac_run_m', v_design.ac_run_m,
            'travel', v_travel,
            'travel_km', v_design.travel_km,
            'admin', v_admin),
          'on_board')
  returning id into v_qid;

  return jsonb_build_object('seat_id', v_seat_id, 'quote_id', v_qid,
    'stc_count', v_stc, 'price_after_cents', v_after,
    'materials_source', v_mat_src,
    'min_billable_applied', (v_kw*1000 < v_min_watts));
end $function$;
