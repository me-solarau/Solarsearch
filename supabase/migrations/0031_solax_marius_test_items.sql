-- SolaX items added while pricing the Marius Haymann test job (30x AE 440 +
-- SolaX X3 Ultra 20kW + 28.8kWh SolaX T-BAT). Supplier attribution is TBC
-- (spec.supplier_tbc) and some prices are test/derived — flagged so they don't
-- silently feed a real customer quote:
--   * HS28.8 complete stack is the real all-in battery price ($14,472).
--   * BMU + base are DERIVED (stack - 8 modules), split nominally.
--   * X3 ZDNY-TL20000 is an eBay best-offer test price AND is the grid-tie X3,
--     not the X3 Ultra hybrid the battery actually needs (price_review).
insert into public.supplier_materials (supplier, brand, category, part_no, description, unit_price, spec, in_use, active, captured_at)
values
  ('onestopwarehouse','SolaX','battery','SOLAX-TBAT-HV-S3.6','SolaX T-BAT HV-S3.6 Battery Module 3.6kWh',1555.0000,'{"kwh":3.6,"supplier_tbc":true}',true,true,now()),
  ('onestopwarehouse','SolaX','battery','SOLAX-TBAT-HS28.8','SolaX T-BAT HS28.8 complete 28.8kWh HV battery system (TP-HS BMU + 8x HV-S3.6 modules + base)',14472.0000,'{"kwh":28.8,"complete_stack":true,"includes":"BMU + 8 modules + base","supplier_tbc":true}',true,true,now()),
  ('onestopwarehouse','SolaX','accessory','SOLAX-TBAT-HV-BMS','SolaX TP-HS BMU (Triple Power Battery Management Unit, top of stack)',1732.0000,'{"derived":true,"derived_note":"HS28.8 stack ($14472) minus 8x HV-S3.6 modules ($12440), less $300 base","supplier_tbc":true}',true,true,now()),
  ('onestopwarehouse','SolaX','accessory','SOLAX-TBAT-HV-BASE','SolaX T-BAT HV Triple Power Base with feet (bottom unit)',300.0000,'{"derived":true,"derived_note":"nominal base within the $2032 BMU+base derived from the HS28.8 stack","supplier_tbc":true}',true,true,now()),
  ('onestopwarehouse','SolaX','inverter','SOLAX-X3-ZDNY-TL20000','SolaX 20kW X3 Three Phase Solar Inverter ZDNY-TL20000 (grid-tie, non-hybrid)',3279.0000,'{"kw":20,"phase":3,"supplier_tbc":true,"price_review":true,"review_reason":"eBay best-offer test price; grid-tie X3 not the X3 Ultra hybrid a battery needs"}',true,true,now())
on conflict (supplier, part_no) do update
  set unit_price=excluded.unit_price, description=excluded.description, spec=excluded.spec, active=true, captured_at=now();
