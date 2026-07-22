-- ============================================================================
-- Cable materials (Resource Electrical) + rate-card additions captured while
-- building out the Marius quote. AC cable runs >10kW are priced as
-- (cable $/m x 1.45) -- the 45% covers labour + profit on material. Cable slots
-- also exist under goelectrical (null price) so the same part can be re-quoted
-- from multiple suppliers (best_price wins).
-- ============================================================================
insert into public.suppliers (code, name) values ('resourceelectrical','Resource Electrical')
on conflict (code) do nothing;

-- Cable catalog: Resource Electrical priced rows + goelectrical null slots
insert into public.supplier_materials (supplier, brand, category, part_no, description, unit_price, spec, active, captured_at)
values
  ('resourceelectrical','Generic','cable','DC-4MM-TWIN-1500V','4mm DC Solar Twin 1500V cable (per m)',3.2100,'{"mm2":4,"twin":true,"volt":1500,"dc":true,"unit":"m"}',true,now()),
  ('resourceelectrical','Generic','cable','AC-4MM-2CE-ORANGE','4mm 2 Core + Earth Orange cable (per m)',4.4800,'{"mm2":4,"cores":2,"earth":true,"orange":true,"unit":"m"}',true,now()),
  ('resourceelectrical','Generic','cable','AC-6MM-2CE-ORANGE','6mm 2 Core + Earth Orange cable (per m)',7.3900,'{"mm2":6,"cores":2,"earth":true,"orange":true,"unit":"m"}',true,now()),
  ('resourceelectrical','Generic','cable','AC-6MM-3CE-ORANGE','6mm 3 Core + Earth Orange cable (per m)',9.4400,'{"mm2":6,"cores":3,"earth":true,"orange":true,"unit":"m"}',true,now()),
  ('resourceelectrical','Generic','cable','AC-6MM-4CE-ORANGE','6mm 4 Core + Earth Orange cable (per m)',12.4300,'{"mm2":6,"cores":4,"earth":true,"orange":true,"unit":"m"}',true,now()),
  ('resourceelectrical','Generic','cable','AC-10MM-2CE-ORANGE','10mm 2 Core + Earth Orange Circular cable (per m)',12.2200,'{"mm2":10,"cores":2,"earth":true,"orange":true,"unit":"m"}',true,now()),
  ('resourceelectrical','Generic','cable','AC-10MM-4CE-ORANGE','10mm 4 Core + Earth Orange Circular cable (per m)',19.6800,'{"mm2":10,"cores":4,"earth":true,"orange":true,"unit":"m"}',true,now()),
  ('resourceelectrical','Generic','cable','AC-16MM-2CE','16mm 2 Core + Earth Orange Circular cable (per m)',17.2400,'{"mm2":16,"cores":2,"earth":true,"orange":true,"unit":"m"}',true,now()),
  ('resourceelectrical','Generic','cable','AC-16MM-4CE-ORANGE','16mm 4 Core + Earth Orange Circular cable (per m)',30.3100,'{"mm2":16,"cores":4,"earth":true,"orange":true,"unit":"m"}',true,now()),
  ('goelectrical','Generic','cable','AC-16MM-2CE','16mm 2 Core + Earth cable (AC, single-phase >10kW)',null,'{"mm2":16,"cores":2,"earth":true,"price_review":true,"review_reason":"need supplier $/m"}',true,now()),
  ('goelectrical','Generic','cable','AC-16MM-4CE-ORANGE','16mm 4 Core + Earth Orange Circular cable (AC, three-phase >10kW)',null,'{"mm2":16,"cores":4,"earth":true,"orange":true,"price_review":true,"review_reason":"need supplier $/m"}',true,now())
on conflict (supplier, part_no) do update set
  unit_price=excluded.unit_price, description=excluded.description, spec=excluded.spec, active=true, captured_at=now();

-- Rate-card additions / updates (confirmed me-solar baselines)
insert into public.chargeables (code, name, unit, category, baseline_rate, baseline_confirmed, included_qty, over_rate, over_unit, meta, sort) values
  ('battery_install','Battery install & commission (base = 16kWh or 4 modules, whichever first)','job','labour',2000.00,true,4,180.0000,'module','{"included_kwh":16,"included_modules":4,"included_rule":"whichever_fewer"}',30),
  ('battery_extra_stack','Battery — each additional stack/tower (modules still per-module)','stack','labour',450.00,true,null,null,null,'{"per_additional_stack":true}',31),
  ('backup_wiring_1p','Backup wiring — single phase (incl. smart meter install)','job','electrical',280.00,true,null,null,null,'{"phase":1,"includes_smart_meter":true}',82),
  ('backup_wiring_3p','Backup wiring — three phase (incl. smart meter install)','job','electrical',350.00,true,null,null,null,'{"phase":3,"includes_smart_meter":true}',83),
  ('ac_cable_run_16mm_1p','AC cable run >10kW single phase (16mm 2C+E, material +45%)','m','electrical',null,false,null,null,null,'{"kw_min":10,"cable_mm2":16,"cores":2,"material_based":true,"markup_pct":45,"cable_ref":"AC-16MM-2CE"}',97),
  ('ac_cable_run_16mm_3p','AC cable run >10kW three phase (16mm 4C+E orange, material +45%)','m','electrical',null,false,null,null,null,'{"kw_min":10,"cable_mm2":16,"cores":4,"material_based":true,"markup_pct":45,"cable_ref":"AC-16MM-4CE-ORANGE"}',98)
on conflict (code) do update set
  name=excluded.name, unit=excluded.unit, category=excluded.category, baseline_rate=excluded.baseline_rate,
  baseline_confirmed=excluded.baseline_confirmed, included_qty=excluded.included_qty, over_rate=excluded.over_rate,
  over_unit=excluded.over_unit, meta=excluded.meta, sort=excluded.sort;
