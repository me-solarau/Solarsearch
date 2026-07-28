-- $0.35/W is ME-SOLAR's retail SUBCONTRACTOR LABOUR rate (Johan).
--
-- It was sitting in base_rates.solar_per_kw_cents, which buy_seat consumes as
-- MATERIALS COST. So the labour rate was marked up by the materials margin, and
-- then a second, separate labour line was added at the platform rate. Labour was
-- counted twice, and margin was being taken on labour.
--
-- Fix: price books carry their own labour rate, used as the base install rate.
-- The roof/storey add-ons still apply, as a DIFFERENTIAL over the rate-card tin
-- single-storey baseline, so an installer's own rate is respected while a
-- terracotta double-storey job still costs more than tin:
--
--   ME-SOLAR tin 1 storey        = 0.35
--   ME-SOLAR tin 2 storey        = 0.35 + (0.34 - 0.32) = 0.37
--   ME-SOLAR concrete 2 storey   = 0.35 + (0.38 - 0.32) = 0.41
--   ME-SOLAR terracotta 2 storey = 0.35 + (0.40 - 0.32) = 0.43
--
-- Installers with no labour rate of their own keep using the rate card directly.

create or replace function public.installer_labour_rate(
  p_price_book_id uuid, p_roof text, p_storeys int)
returns numeric
language sql
stable
set search_path to 'public'
as $$
  select case
    when own.rate is null then public.solar_labour_rate(p_roof, p_storeys)
    else round(own.rate
               + (public.solar_labour_rate(p_roof, p_storeys)
                  - public.solar_labour_rate('tin', 1)), 4)
  end
  from (
    select nullif((base_rates->>'solar_labour_per_watt_cents')::numeric, 0)/100.0 as rate
    from price_books where id = p_price_book_id
  ) own;
$$;

comment on function public.installer_labour_rate(uuid,text,int) is
  'Install labour $/W for a price book. Uses the installer''s own rate when set, plus the '
  'rate-card roof/storey differential over the tin single-storey baseline. Falls back to the '
  'rate card outright when the installer has not set a rate.';

grant execute on function public.installer_labour_rate(uuid,text,int) to authenticated;

-- ME-SOLAR: $0.35/W is labour. Remove it from the materials slot so the
-- materials fallback stops using a labour rate as a per-kW equipment cost.
update public.price_books p
   set base_rates = (p.base_rates - 'solar_per_kw_cents')
                    || jsonb_build_object('solar_labour_per_watt_cents', 35)
  from installers i
 where i.id = p.installer_id and i.company_name ilike '%ME-SOLAR%';

-- The DC base already covered exactly the run Johan specified. State the
-- included bill of materials on the base rate, not only on the over-length
-- rate, so the rate card says what the base price buys.
update public.chargeables
   set name = 'DC cable run — base 25m (2x 4mm2 DC, 1x 4mm2 earth, 25mm corrugated), then per m',
       meta = meta || jsonb_build_object(
         'base_bom', jsonb_build_array(
           '4mm2 DC cable x2', '4mm2 earth cable x1', '25mm corrugated solar conduit'),
         'base_included_m', 25)
 where code = 'dc_cable_run';
