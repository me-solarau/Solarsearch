-- buy_seat was over-counting solar STCs by ~5x, gutting every board quote.
--
-- Three engines calculate the solar STC entitlement. Two of them use the real
-- method — capacity x zone rating x deeming years — and one did not:
--
--   instant_quote()   floor(kw * zone * deeming)      correct
--   quote_estimate()  floor(kw * zone * deeming)      correct
--   buy_seat()        floor(kw * 34)                  ~5x too many
--
-- buy_seat is the one that produces the quotes customers actually compare on
-- the board, so it was the worst possible place for it.
--
-- Verified against the field-validated Instant Quote tool: a 7.44 kW system
-- shows 51 solar STCs. zone x deeming gives exactly 51; the flat 34/kW gives
-- 252. On a 6.6 kW job the flat rate credited $8,288 of rebate against a real
-- entitlement near $1,665 — about $6,600 of phantom discount, which is what
-- made a full installation quote at roughly $1,100.
--
-- The 34 was not a typo in code. It came from the seeded incentive rule
-- `federal_solar_stc.rules.stc_per_kw_zone3 = 34`, which does not correspond to
-- any real deeming period. Rather than edit that row — quotes cite
-- `rules_version`, and rewriting a rule would change what past quotes claimed —
-- a new version supersedes it, per supersede-never-replace.

-- ---------------------------------------------------------------------------
-- 1. New rules version carrying the method rather than a baked-in total.
-- ---------------------------------------------------------------------------
insert into public.incentive_rules (version, scope, state, effective_from, effective_to, rules)
select 'v2026.07', 'federal_solar_stc', null, current_date, '2026-12-31',
       jsonb_build_object(
         'stc_price_cents', 3700,
         'zone_rating', 1.382,
         'deeming_end_year', 2031,
         'method', 'floor(system_kw * zone_rating * (deeming_end_year - current_year))',
         'supersedes', 'v2026.05 federal_solar_stc (stc_per_kw_zone3=34, not a real deeming basis)')
where not exists (
  select 1 from public.incentive_rules
  where version='v2026.07' and scope='federal_solar_stc');

-- ---------------------------------------------------------------------------
-- 2. Solar STC helper — one place, so the engines cannot drift again.
-- ---------------------------------------------------------------------------
create or replace function public.solar_stc_count(p_system_kw numeric)
returns integer
language sql
stable
set search_path to 'public'
as $$
  select floor(
    greatest(coalesce(p_system_kw,0), 0)
    * coalesce((select (rules->>'zone_rating')::numeric from incentive_rules
                where scope='federal_solar_stc' order by effective_from desc limit 1), 1.382)
    * greatest(0, coalesce((select (rules->>'deeming_end_year')::int from incentive_rules
                where scope='federal_solar_stc' order by effective_from desc limit 1), 2031)
               - extract(year from now())::int)
  )::integer;
$$;

comment on function public.solar_stc_count(numeric) is
  'Solar STC entitlement: capacity x zone rating x remaining deeming years, read from the '
  'current federal_solar_stc incentive rule. Matches instant_quote() and quote_estimate().';

grant execute on function public.solar_stc_count(numeric) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. buy_seat: swap the flat rate for the helper. Nothing else changes —
--    the battery tier maths was already correct and is left exactly as it was.
-- ---------------------------------------------------------------------------
create or replace function public.buy_seat(p_site_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_iid uuid := current_installer_id();
  v_state lead_state; v_seat_id uuid; v_pb record; v_design record; v_site record;
  v_margin numeric; v_panel_qty int; v_strings int; v_arrays int;
  v_kw numeric; v_kwh numeric; v_watts numeric; v_min_watts numeric;
  v_panel_cost numeric := 0; v_inv_cost numeric := 0; v_bat_cost numeric := 0;
  v_bom jsonb; v_bos numeric := 0;
  v_mat_cost numeric; v_mat_sell numeric;
  v_solar_rate numeric; v_solar_lab numeric; v_admin numeric := 530;
  v_bat_install numeric := 0; v_labour numeric;
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
  v_strings   := greatest(1, coalesce((v_design.components->>'strings')::int, 2));
  v_arrays    := greatest(1, coalesce((v_design.components->>'arrays')::int, 1));

  -- seat first (cap enforced by trigger)
  insert into seats (site_id, installer_id, path, price_cents)
  values (p_site_id, v_iid, 'path2_seat', 20000)
  returning id into v_seat_id;

  -- ---- materials: real supplier costs where resolvable, price book as fallback
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

  v_bom := public.bom_estimate(v_panel_qty, v_strings, v_arrays,
             coalesce(v_design.components->>'orientation','landscape'));
  v_bos := coalesce((v_bom->>'total')::numeric, 0);
  v_mat_cost := v_panel_cost + v_inv_cost + v_bat_cost + v_bos;

  -- If the catalog can't price the kit, fall back to the installer's flat rates
  -- so a seat purchase never fails outright.
  if v_panel_cost = 0 and v_inv_cost = 0 then
    v_mat_cost := coalesce((v_pb.base_rates->>'solar_fixed_cents')::numeric,160000)/100
                + coalesce((v_pb.base_rates->>'solar_per_kw_cents')::numeric,135000)/100 * v_kw
                + case when v_kwh > 0
                    then coalesce((v_pb.base_rates->>'battery_fixed_cents')::numeric,280000)/100
                       + coalesce((v_pb.base_rates->>'battery_per_kwh_cents')::numeric,82000)/100 * v_kwh
                    else 0 end;
    v_bos := 0;
  end if;

  -- ---- margin: installer's own, else platform default. Gross margin.
  v_margin := coalesce(v_pb.margin_pct,
                       (select material_margin_pct_default from pricing_config), 34) / 100.0;
  if v_margin >= 0.95 then v_margin := 0.95; end if;
  v_mat_sell := round(v_mat_cost / (1 - v_margin), 2);

  -- ---- labour, with the minimum billable system size (trade rule)
  v_min_watts := coalesce((select min_solar_watts from pricing_config), 6600);
  v_watts := greatest(v_kw * 1000, v_min_watts);
  v_solar_rate := case when coalesce(v_site.storeys,1) >= 2 then 0.34 else 0.32 end;
  v_solar_lab := round(v_watts * v_solar_rate, 2);
  v_bat_install := case when v_kwh > 0 then 2000 else 0 end;
  v_labour := v_solar_lab + v_bat_install + v_admin;

  v_before := round((v_mat_sell + v_labour) * 1.10 * 100);   -- cents, incl GST

  -- ---- STC rebate.
  -- Solar now uses the shared helper (capacity x zone x deeming) instead of a
  -- flat 34/kW, which credited roughly five times the real entitlement. STC
  -- follows ACTUAL installed capacity, never the 6.6kW minimum-billable size.
  -- Battery tiers are unchanged.
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
            'materials_cost', round(v_mat_cost,2),
            'materials_sell', v_mat_sell,
            'margin_pct', round(v_margin*100,1),
            'bom', v_bom,
            'solar_labour', v_solar_lab,
            'billable_watts', v_watts,
            'min_billable_applied', (v_kw*1000 < v_min_watts),
            'battery_install', v_bat_install,
            'admin', v_admin),
          'on_board')
  returning id into v_qid;

  return jsonb_build_object('seat_id', v_seat_id, 'quote_id', v_qid,
    'stc_count', v_stc, 'price_after_cents', v_after,
    'min_billable_applied', (v_kw*1000 < v_min_watts));
end $function$;
