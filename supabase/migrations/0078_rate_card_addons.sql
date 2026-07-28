-- Rate-card add-ons: roof material, storey, travel, and cable runs.
--
-- `chargeables` already held the real rate card — solar labour per watt, DC/AC
-- cable runs with included metres and over-rates, travel per km. Two problems:
--
--   1. Roof material was missing. Only "tin, single storey" and "double storey"
--      existed, so a terracotta roof — the slowest and most breakable there is —
--      priced identically to tin.
--   2. buy_seat ignored the rate card entirely. It hard-coded 0.32 / 0.34 per
--      watt off storeys alone and never looked at roof material, travel distance
--      or cable runs, so none of these adders reached a customer quote.
--
-- Travel free radius moves 80km -> 75km per Johan.
--
-- The new roof rates are seeded as DERIVED, NOT CONFIRMED (baseline_confirmed
-- false) from the confirmed tin baseline. They are structure, not a claim about
-- what the work costs — the HQ rate card screen is where the real numbers go in.

-- ---------------------------------------------------------------------------
-- 1. Roof material labour rates ($/W, same unit as the existing tin baseline).
-- ---------------------------------------------------------------------------
insert into public.chargeables (code, name, unit, category, baseline_rate, baseline_confirmed, active, sort, meta)
values
  ('solar_labour_tile_concrete_1s',
   'Solar install labour — concrete tile, single storey',
   'watt','solar_labour', 0.3600, false, true, 11,
   '{"roof":"tile_concrete","storey":1,"min_watts":6600,"derived_from":"solar_labour_tin_1s","note":"placeholder — confirm real rate"}'::jsonb),
  ('solar_labour_tile_terracotta_1s',
   'Solar install labour — terracotta tile, single storey',
   'watt','solar_labour', 0.3800, false, true, 12,
   '{"roof":"tile_terracotta","storey":1,"min_watts":6600,"derived_from":"solar_labour_tin_1s","note":"placeholder — brittle, slowest roof; confirm real rate"}'::jsonb),
  ('solar_labour_tile_concrete_2s',
   'Solar install labour — concrete tile, double storey',
   'watt','solar_labour', 0.3800, false, true, 13,
   '{"roof":"tile_concrete","storey":2,"min_watts":6600,"derived_from":"solar_labour_2s","note":"placeholder — confirm real rate"}'::jsonb),
  ('solar_labour_tile_terracotta_2s',
   'Solar install labour — terracotta tile, double storey',
   'watt','solar_labour', 0.4000, false, true, 14,
   '{"roof":"tile_terracotta","storey":2,"min_watts":6600,"derived_from":"solar_labour_2s","note":"placeholder — confirm real rate"}'::jsonb)
on conflict (code) do nothing;

-- Make the two existing rows explicit about which roof/storey they cover, so the
-- lookup below has a complete matrix to match on.
update public.chargeables
   set meta = meta || '{"roof":"tin","storey":1}'::jsonb
 where code = 'solar_labour_tin_1s';
update public.chargeables
   set name = 'Solar install labour — tin roof, double storey',
       meta = meta || '{"roof":"tin","storey":2}'::jsonb
 where code = 'solar_labour_2s';

-- ---------------------------------------------------------------------------
-- 2. Travel: free inside 75km, ATO rate + markup beyond.
-- ---------------------------------------------------------------------------
update public.pricing_config set free_travel_radius_km = 75;

update public.chargeables
   set name = 'Travel — no charge within 75km radius',
       meta = meta || '{"free_radius_km":75}'::jsonb
 where code = 'travel_mobilisation';

update public.chargeables
   set name = 'Travel beyond 75km (ATO rate + 40% per km)',
       meta = meta || '{"free_radius_km":75}'::jsonb
 where code = 'travel_per_km';

-- ---------------------------------------------------------------------------
-- 3. Roof material on the design, so the quote can price the right rate.
--    Captured at design time alongside the edge perimeter.
-- ---------------------------------------------------------------------------
alter table public.designs add column if not exists roof_material text;
comment on column public.designs.roof_material is
  'tin | tile_concrete | tile_terracotta | flat | other. Drives the solar labour rate. '
  'Falls back to sites.roof_type when not set at design time.';

alter table public.designs add column if not exists travel_km numeric;
comment on column public.designs.travel_km is
  'One-way distance from depot, entered at design time. Only the excess beyond the '
  'free radius is charged.';

-- ---------------------------------------------------------------------------
-- 4. Rate lookups. One place, so the engines cannot each invent their own.
-- ---------------------------------------------------------------------------
create or replace function public.solar_labour_rate(p_roof text, p_storeys int)
returns numeric
language sql
stable
set search_path to 'public'
as $$
  with want as (
    select case
             when lower(coalesce(p_roof,'')) in ('tile_terracotta','terracotta') then 'tile_terracotta'
             when lower(coalesce(p_roof,'')) in ('tile_concrete','concrete','tile') then 'tile_concrete'
             when lower(coalesce(p_roof,'')) in ('tin','klip_lok','klip-lok','metal') then 'tin'
             else 'tin'
           end as roof,
           case when coalesce(p_storeys,1) >= 2 then 2 else 1 end as storey
  )
  select coalesce(
    -- exact roof + storey
    (select c.baseline_rate from chargeables c, want w
      where c.active and c.category='solar_labour'
        and c.meta->>'roof' = w.roof and (c.meta->>'storey')::int = w.storey limit 1),
    -- same storey, any roof (keeps a quote working if a roof rate is missing)
    (select c.baseline_rate from chargeables c, want w
      where c.active and c.category='solar_labour'
        and (c.meta->>'storey')::int = w.storey order by c.sort limit 1),
    case when (select storey from want) >= 2 then 0.34 else 0.32 end
  );
$$;

comment on function public.solar_labour_rate(text,int) is
  'Solar install labour $/W for a roof material and storey count, read from the chargeables '
  'rate card. Unknown roof materials fall back to tin.';

create or replace function public.travel_charge(p_km numeric)
returns numeric
language sql
stable
set search_path to 'public'
as $$
  select round(greatest(0, coalesce(p_km,0)
           - coalesce((select free_travel_radius_km from pricing_config), 75))
         * coalesce((select baseline_rate from chargeables
                      where code='travel_per_km' and active), 1.232), 2);
$$;

comment on function public.travel_charge(numeric) is
  'Travel charge for a one-way distance. Free inside the configured radius; beyond it, '
  'ATO cents-per-km plus markup, per the travel_per_km rate-card row.';

create or replace function public.cable_charge(p_dc_m numeric, p_ac_m numeric)
returns numeric
language sql
stable
set search_path to 'public'
as $$
  with dc as (select * from chargeables where code='dc_cable_run' and active),
       ac as (select * from chargeables where code='ac_cable_run' and active)
  select round(
      coalesce((select d.baseline_rate
                + greatest(0, coalesce(p_dc_m,0) - coalesce(d.included_qty,0)) * coalesce(d.over_rate,0)
                from dc d), 0)
    + coalesce((select a.baseline_rate
                + greatest(0, coalesce(p_ac_m,0) - coalesce(a.included_qty,0)) * coalesce(a.over_rate,0)
                from ac a), 0)
  , 2);
$$;

comment on function public.cable_charge(numeric,numeric) is
  'DC + AC cable run charge: each has a base price covering an included run length, then a '
  'per-metre over-rate. Reads dc_cable_run / ac_cable_run from the rate card.';

grant execute on function public.solar_labour_rate(text,int) to authenticated;
grant execute on function public.travel_charge(numeric)      to authenticated;
grant execute on function public.cable_charge(numeric,numeric) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Admin editing of the rate card. Rates are money — changes are logged.
-- ---------------------------------------------------------------------------
create or replace function public.set_chargeable_rate(
  p_code text, p_rate numeric, p_included_qty numeric default null,
  p_over_rate numeric default null, p_confirm boolean default true)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_old record;
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  if p_rate is not null and p_rate < 0 then raise exception 'rate cannot be negative'; end if;

  select * into v_old from chargeables where code = p_code;
  if v_old.code is null then raise exception 'no such rate-card item: %', p_code; end if;

  update chargeables
     set baseline_rate      = coalesce(p_rate, baseline_rate),
         included_qty       = coalesce(p_included_qty, included_qty),
         over_rate          = coalesce(p_over_rate, over_rate),
         baseline_confirmed = coalesce(p_confirm, baseline_confirmed)
   where code = p_code;

  insert into events (actor_type, actor_id, event_type, payload)
  values ('staff', auth.uid()::text, 'ratecard.updated',
    jsonb_build_object('code', p_code,
      'from_rate', v_old.baseline_rate, 'to_rate', coalesce(p_rate, v_old.baseline_rate),
      'from_included', v_old.included_qty, 'to_included', coalesce(p_included_qty, v_old.included_qty),
      'from_over_rate', v_old.over_rate, 'to_over_rate', coalesce(p_over_rate, v_old.over_rate),
      'confirmed', coalesce(p_confirm, v_old.baseline_confirmed)));

  return jsonb_build_object('ok', true, 'code', p_code,
    'rate', coalesce(p_rate, v_old.baseline_rate));
end $function$;

revoke all on function public.set_chargeable_rate(text,numeric,numeric,numeric,boolean) from public, anon;
grant execute on function public.set_chargeable_rate(text,numeric,numeric,numeric,boolean) to authenticated;

-- Read the whole card for the HQ screen, newest-relevant first.
create or replace function public.rate_card()
returns table(code text, name text, unit text, category text,
              baseline_rate numeric, included_qty numeric, over_rate numeric,
              over_unit text, confirmed boolean, meta jsonb)
language sql
stable security definer
set search_path to 'public'
as $$
  select c.code, c.name, c.unit, c.category, c.baseline_rate, c.included_qty,
         c.over_rate, c.over_unit, c.baseline_confirmed, c.meta
  from chargeables c
  where c.active and public.is_admin()
  order by c.category, c.sort, c.code;
$$;

grant execute on function public.rate_card() to authenticated;
