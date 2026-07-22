-- ============================================================================
-- (1) Fix the DC cable run over-rate: $5.50/m was BELOW material cost (~$9.77/m
--     for 25mm conduit + 4mm earth + 2x 4mm DC twin). Move to material x 1.45 =
--     $14.16/m beyond the 25m base (base $550 unchanged).
-- (2) eBay price point for 10mm 4C+E orange ($18.77) — multi-supplier.
-- (3) cable_quote_price view: orange circular cables quote on the AVERAGE of the
--     highest & lowest supplier price (per business rule); other cables use the
--     cheapest. The quote engine reads quote_unit_price from here.
-- ============================================================================
update public.chargeables set
  over_rate = 14.1600,
  name = 'DC cable run (2 strings) — base 25m, then material +45%/m',
  meta = '{"strings":2,"base_included_m":25,"over_material_based":true,"markup_pct":45,"over_bom":["25mm flexible solar conduit x1","4mm earth wire x1","4mm DC twin x2"],"over_material_per_m":9.77}'
where code='dc_cable_run';

insert into public.suppliers (code, name) values ('ebay','eBay AU (marketplace)')
on conflict (code) do nothing;

insert into public.supplier_materials (supplier, brand, category, part_no, description, unit_price, spec, active, captured_at)
values ('ebay','Generic','cable','AC-10MM-4CE-ORANGE','10mm 4 Core + Earth Orange Circular cable (per m)',18.7700,'{"mm2":10,"cores":4,"earth":true,"orange":true,"unit":"m","marketplace":true}',true,now())
on conflict (supplier, part_no) do update set unit_price=excluded.unit_price, spec=excluded.spec, active=true, captured_at=now();

create or replace view public.cable_quote_price as
select part_no,
       bool_or(coalesce((spec->>'orange')::boolean,false)) as orange,
       count(*) as suppliers,
       min(unit_price) as low,
       max(unit_price) as high,
       case when bool_or(coalesce((spec->>'orange')::boolean,false))
            then round((min(unit_price)+max(unit_price))/2, 4)   -- orange circ: avg of high & low
            else min(unit_price) end as quote_unit_price          -- others: cheapest
from public.supplier_materials
where category='cable' and unit_price is not null
group by part_no;
