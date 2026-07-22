-- Catalog rows added while testing the Jason Dawe quote against Pylon/SimPro.
--  * AIKO 465 panel at the confirmed $134 ex buy price.
--  * Goodwe GW8.3-BAT-D at the real me-solar buy price ($2,150 ex) -- the $2,550
--    goelectrical row is retail; $2,150 is what closes the quote onto SimPro's
--    materials cost (the remaining gap vs SimPro is margin 40% vs 34% + labour
--    itemisation, not battery cost).
insert into public.supplier_materials (supplier, brand, category, part_no, description, unit_price, spec, in_use, active, captured_at)
values
  ('onestopwarehouse','AIKO','panel','AIKO-A465-MAH54Mb','AIKO Solar Neostar 2S 465W N-Type ABC',134.0000,'{"watts":465,"ntype":true,"supplier_tbc":true}',true,true,now()),
  ('onestopwarehouse','Goodwe','battery','GDWGW8.3-BAT-D-G20','Goodwe GW8.3-BAT-D 8.32kWh (8kWh usable) HV battery',2150.0000,'{"kwh":8.32,"usable_kwh":8,"buy_price":true}',true,true,now())
on conflict (supplier, part_no) do update set unit_price=excluded.unit_price, description=excluded.description, spec=excluded.spec, active=true, captured_at=now();
