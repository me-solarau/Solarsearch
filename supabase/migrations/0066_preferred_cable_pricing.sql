-- Preferred/verified supplier pricing for cable. A real branch quote beats a marketplace
-- average: Lear & Smith (Lambton) quoted 10mm 4C+E orange at $13.30/m and the user buys there
-- ~99% of the time, so that price should drive the quote — not the (min+max)/2 average that let
-- a $19.68 eBay outlier inflate every 10mm run.
--
-- Mechanism: mark a supplier price spec.preferred=true. cable_quote_price then uses the
-- preferred price when one exists, else falls back to the previous logic (orange: avg of
-- high/low; others: cheapest). General — any cable can be pinned to a verified supplier.

insert into public.supplier_materials (supplier, brand, category, part_no, description, unit_price, spec, active, captured_at)
values ('learsmith','Generic','cable','AC-10MM-4CE-ORANGE',
        '10mm 4 Core + Earth Orange Circular cable (per m) — Lear & Smith Lambton branch quote',
        13.3000,
        '{"mm2":10,"cores":4,"earth":true,"orange":true,"unit":"m","preferred":true,"verified":true,"supplier_name":"Lear & Smith","branch":"Lambton"}',
        true, now())
on conflict (supplier, part_no) do update
  set unit_price = excluded.unit_price, spec = excluded.spec, active = true, captured_at = now();

-- Column order preserved (CREATE OR REPLACE can only append); has_preferred added last.
create or replace view public.cable_quote_price as
select part_no,
       bool_or(coalesce((spec->>'orange')::boolean,false)) as orange,
       count(*) as suppliers,
       min(unit_price) as low,
       max(unit_price) as high,
       coalesce(
         -- a verified/preferred supplier price wins outright
         min(unit_price) filter (where coalesce((spec->>'preferred')::boolean,false)),
         case when bool_or(coalesce((spec->>'orange')::boolean,false))
              then round((min(unit_price)+max(unit_price))/2, 4)   -- orange circ: avg of high & low
              else min(unit_price) end                              -- others: cheapest
       ) as quote_unit_price,
       bool_or(coalesce((spec->>'preferred')::boolean,false)) as has_preferred
from public.supplier_materials
where category='cable' and unit_price is not null
group by part_no;
