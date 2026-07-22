-- One Stop Warehouse (OSW) supplier + AE Solar 440W panel (the panel used on the
-- Marius Haymann job). Demonstrates multi-supplier pricing: this AE 440 at $99
-- (22.5 c/W) undercuts the Winaico/Tindo panels already in the book.
insert into public.suppliers (code, name, branch) values
  ('onestopwarehouse','One Stop Warehouse','Sydney')
on conflict (code) do nothing;

insert into public.supplier_materials (supplier, brand, category, part_no, description, unit_price, spec, in_use, active, captured_at)
values ('onestopwarehouse','AE Solar','panel','AES-AE440CMD-108BDE-AB/30/21',
        'AE Solar METEOR 440W N-Type Dual-glass Bifacial 108 Halfcell All Black 30mm MC4',
        99.0000,'{"watts":440,"ntype":true,"bifacial":true}', true, true, now())
on conflict (supplier, part_no) do update
  set unit_price = excluded.unit_price, description = excluded.description,
      spec = excluded.spec, in_use = true, active = true, captured_at = now();

-- More OSW panels (JA Solar + Jinko). "On Request" = made-to-order but priced,
-- so kept (unlike "Request a Quote"). Stock status stored in spec.in_stock.
insert into public.supplier_materials (supplier, brand, category, part_no, description, unit_price, spec, active, captured_at)
values
  ('onestopwarehouse','JA Solar','panel','JAS-JAM54D40-475/LR/30/21','JA Solar 475W N-Type Double Glass Monofacial High Efficiency 108-cell 30mm MC4 EVO2',116.3750,'{"watts":475,"ntype":true,"in_stock":true}',true,now()),
  ('onestopwarehouse','JA Solar','panel','JAS-JAM54D41-440/LB/30/21','JA Solar JAM54D41 440W N-Type Bifacial Double Glass 108 Halfcell All Black 30mm MC4',85.8000,'{"watts":440,"ntype":true,"bifacial":true,"in_stock":false}',true,now()),
  ('onestopwarehouse','JA Solar','panel','JAS-JAM72D40-590/MB/30/21','JA Solar 590W N-Type Bifacial Double Glass High Efficiency 144 Halfcell 30mm MC4 EVO2',112.1000,'{"watts":590,"ntype":true,"bifacial":true,"in_stock":false}',true,now()),
  ('onestopwarehouse','Jinko','panel','JNK-JKM510N-60HL4-V/30/21','Jinko Tiger Neo N-Type 510W TOPCon Mono 120 Halfcell Black Frame 30mm MC4 EVO2',107.1000,'{"watts":510,"ntype":true,"topcon":true,"in_stock":false}',true,now())
on conflict (supplier, part_no) do update
  set unit_price=excluded.unit_price, description=excluded.description, spec=excluded.spec, active=true, captured_at=now();

-- OSW inverters. NOTE: OSW SKUs differ from goelectrical for the same model
-- (GW-GW20K-ETA-G20 vs GDWGW20K-ETA-G20), so cross-supplier best-price matching
-- needs a canonical product map (future work). Captured as-is for now.
insert into public.supplier_materials (supplier, brand, category, part_no, description, unit_price, spec, active, captured_at)
values
  ('onestopwarehouse','Goodwe','inverter','GW-GW20K-ETA-G20','Goodwe All-in-One 20kW Three Phase ETA Inverter 200% Oversizing 4MPPT',2070.0000,'{"kw":20,"phase":3,"in_stock":false}',true,now()),
  ('onestopwarehouse','Goodwe','inverter','GW-GW15K-ETA-G20','Goodwe All-in-One 15kW Three Phase ETA Inverter 200% Oversizing 4MPPT',1876.0000,'{"kw":15,"phase":3,"in_stock":true}',true,now()),
  ('onestopwarehouse','Goodwe','inverter','GW-GW9.99K-ETA-G20','Goodwe All-in-One 9.99kW Three Phase ETA Inverter 200% Oversizing 4MPPT',1876.0000,'{"kw":9.99,"phase":3,"in_stock":true}',true,now()),
  ('onestopwarehouse','Goodwe','inverter','GW-GW8K-ETA-G20','Goodwe All-in-One 8kW Three Phase ETA Inverter 200% Oversizing 3MPPT (pre-order)',1810.0000,'{"kw":8,"phase":3,"in_stock":false}',true,now()),
  ('onestopwarehouse','Goodwe','inverter','GW-GW6K-ETA-G20','Goodwe All-in-One 6kW Three Phase ETA Inverter 200% Oversizing 3MPPT (pre-order)',1763.0000,'{"kw":6,"phase":3,"in_stock":false}',true,now()),
  ('onestopwarehouse','Goodwe','inverter','GW-GW5K-ETA-G20','Goodwe All-in-One 5kW Three Phase ETA Inverter 200% Oversizing 3MPPT (pre-order)',1729.0000,'{"kw":5,"phase":3,"in_stock":false}',true,now()),
  ('onestopwarehouse','Goodwe','inverter','GW-GW110K-GT','Goodwe C&I String 110kW Three Phase 10MPPT 2 Strings/MPPT w/WiFi w/Meter',4705.0000,'{"kw":110,"phase":3,"in_stock":false}',true,now()),
  ('onestopwarehouse','Goodwe','inverter','GW-GW100K-GT','Goodwe C&I String 100kW Three Phase 8MPPT 2 Strings/MPPT w/WiFi w/Meter',4519.0000,'{"kw":100,"phase":3,"in_stock":true}',true,now()),
  ('onestopwarehouse','Sungrow','inverter','SGR-SH5.0RS-ADA','Sungrow Hybrid HV 5.0kW 1 Phase 2MPPT w/Wi-Fi w/DC iso w/In-built Backup',1750.0000,'{"kw":5,"phase":1,"hybrid":true,"in_stock":false}',true,now()),
  ('onestopwarehouse','Sungrow','inverter','SGR-SH6.0RS-ADA','Sungrow Hybrid HV 6.0kW 1 Phase 2MPPT w/wifi w/DCI w/inbuilt Backup',1950.0000,'{"kw":6,"phase":1,"hybrid":true,"in_stock":false}',true,now()),
  ('onestopwarehouse','Goodwe','inverter','GW-GW6000N-EH','Goodwe N-EH Battery Ready Hybrid HV 6.0kW 1 Phase 2MPPT (Activated)',1699.0000,'{"kw":6,"phase":1,"hybrid":true,"in_stock":false}',true,now()),
  ('onestopwarehouse','Sungrow','inverter','SGR-SH8.0RS','Sungrow Hybrid HV 8kW 1 Phase 4MPPT w/wifi w/DCI w/inbuilt Backup',2400.0000,'{"kw":8,"phase":1,"hybrid":true,"in_stock":false}',true,now()),
  ('onestopwarehouse','Sungrow','inverter','SGR-SH10RT-ADA','Sungrow Hybrid HV 10.0kW 3 Phase 2MPPT/3 Strings w/Wi-Fi w/DCI',3400.0000,'{"kw":10,"phase":3,"hybrid":true,"in_stock":false}',true,now()),
  ('onestopwarehouse','Goodwe','inverter','GW-GW5KL-ET','Goodwe ET Hybrid HV 5.0kW 3 Phase 2MPPT/2 Strings w/wifi w/GM3000 (no DCI)',2070.0000,'{"kw":5,"phase":3,"hybrid":true,"in_stock":false}',true,now()),
  ('onestopwarehouse','Goodwe','inverter','GW-GW8000-ET-20','Goodwe ET G2 Hybrid HV 8kW 3 Phase 2MPPT w/wifi w/DCI w/inbuilt meter w/3xCTs',2285.0000,'{"kw":8,"phase":3,"hybrid":true,"in_stock":true}',true,now()),
  ('onestopwarehouse','Sungrow','inverter','SGR-SH15T','Sungrow Hybrid HV 15kW 3 Phase 3MPPT/5 Strings w/Wi-Fi w/DCI w/In-built Backup',3995.0000,'{"kw":15,"phase":3,"hybrid":true,"in_stock":false}',true,now())
on conflict (supplier, part_no) do update
  set unit_price=excluded.unit_price, description=excluded.description, spec=excluded.spec, active=true, captured_at=now();

-- OSW batteries + battery control modules
insert into public.supplier_materials (supplier, brand, category, part_no, description, unit_price, spec, active, captured_at)
values
  ('onestopwarehouse','Sungrow','battery','ES-SGR-SBR Battery Module-3.2kWh','Sungrow Battery Module 3.2kWh for SBR Battery Kit',980.0000,'{"kwh":3.2,"in_stock":false}',true,now()),
  ('onestopwarehouse','Goodwe','accessory','ES-GW-LX-F-G2 Power Control Unit','GW Lynx Home F HV G2 Battery Power Control Unit (PCU-F52)',670.0000,'{"in_stock":false}',true,now()),
  ('onestopwarehouse','Sungrow','accessory','ES-SGR-SBR Control Module','Sungrow Battery System Parts (Control Module) for SBR Battery Kit',1060.0000,'{"in_stock":true}',true,now()),
  ('onestopwarehouse','SAJ','accessory','ES-SAJ-B2 Control Module v2','SAJ Battery Control Module for B2 Battery Kit (BC2-HV1) w/ battery cables',325.0000,'{"in_stock":true}',true,now()),
  ('onestopwarehouse','Alpha ESS','battery','ES-Alpha-SMILE-BAT-8.2PH-Secondary','Alpha Secondary Battery Smile 8.2kWh HV for T10 & S6 (Outdoor) SMILE-BAT-8.2PH',4750.0000,'{"kwh":8.2,"in_stock":false}',true,now()),
  ('onestopwarehouse','SolarEdge','mounting','ES-SEG-Floor stand','SolarEdge Battery Energy Bank Floor Stand (10yr warranty)',550.0000,'{"in_stock":true}',true,now()),
  ('onestopwarehouse','SolarEdge','accessory','ES-SEG-Backup Interface','SolarEdge Energy Hub Backup Interface for Energy Bank battery (12yr)',500.0000,'{"in_stock":true}',true,now()),
  ('onestopwarehouse','SolarEdge','accessory','ES-SEG-Combiner Box','SolarEdge Battery DC Combiner Box for 5/6kW Homehub (w/3rd party)',480.0000,'{"in_stock":false}',true,now()),
  ('onestopwarehouse','Alpha ESS','accessory','ES-Alpha-Smile-M5-13.9P-Extension Box','Alpha ESS Smile M5 13.99kWh Secondary Battery Extension Box w/top cover w/connecting plates',321.0000,'{"in_stock":true}',true,now()),
  ('onestopwarehouse','Alpha ESS','battery','ES-Alpha-Smile-M5-BAT-13.9P','AlphaESS SMILE-M-BAT-13.9P 13.99kWh usable LV Battery 100% DOD IP65',2800.0000,'{"kwh":13.99,"in_stock":true}',true,now()),
  ('onestopwarehouse','FOXESS','accessory','ES-FOX-Master Battery Cable Cover','FOXESS Master Battery Cable Cover',null,'{"in_stock":false,"price_review":true,"review_reason":"listed $0.00 - placeholder, confirm price"}',true,now()),
  ('onestopwarehouse','Solis','accessory','SOL-Solis-Dyness-Combiner box','Solis Dyness Combiner Box DCB-5-125-LV (5 in 2 out) for Powerbox Pro Parallel',630.0000,'{"in_stock":true}',true,now()),
  ('onestopwarehouse','Goodwe','battery','ES-GW-LX-F-G2 Battery Module-3.2kWh -V2','GW Lynx 3.2kWh Home F HV G2 Battery Module V2 (mixable with V1)',710.0000,'{"kwh":3.2,"in_stock":false}',true,now()),
  ('onestopwarehouse','SAJ','battery','ES-SAJ-B2 Battery Module-5kWh-HV5 plus','SAJ Battery Module 5kWh HV5 Plus for B2 Battery Kit (B2-5.0-HV5-PLUS)',1150.0000,'{"kwh":5,"in_stock":false}',true,now()),
  ('onestopwarehouse','Goodwe','battery','ES-GW92.1-BAT-AC-G10','Goodwe HV Storage 92.1kWh Cabinet w/Air Con w/Aerosol (ET inverter required)',27869.0000,'{"kwh":92.1,"commercial":true,"in_stock":true}',true,now()),
  ('onestopwarehouse','Goodwe','battery','ES-GW102.4-BAT-AC-G10','Goodwe HV Storage 102.4kWh Cabinet w/Air Con w/Aerosol (ET inverter required)',29996.0000,'{"kwh":102.4,"commercial":true,"in_stock":false}',true,now()),
  ('onestopwarehouse','Sungrow','battery','ES-SGR-SBH-5KWH','Sungrow SBH Battery Module 5kWh (min 4x5kWh in tower) for 15/20/25T models',2405.0000,'{"kwh":5,"in_stock":false}',true,now()),
  ('onestopwarehouse','Goodwe','battery','ES-GW61.4-BAT-AC-G10','Goodwe HV Storage 61.4kWh Cabinet w/Air Con w/Aerosol (ET inverter required)',21452.0000,'{"kwh":61.4,"commercial":true,"in_stock":false}',true,now()),
  ('onestopwarehouse','Sungrow','battery','ES-SGR-SBR Battery Module-6.4kWh','Sungrow SBR Battery Kit 6.4kWh [2 x 3.2kWh + control module SBR064]',4000.0000,'{"kwh":6.4,"kit":true,"in_stock":false}',true,now()),
  ('onestopwarehouse','Sungrow','accessory','ES-SGR-SBR Combiner Box','Sungrow Battery Combiner Box (for 3/4 battery towers)',690.0000,'{"in_stock":false}',true,now())
on conflict (supplier, part_no) do update
  set unit_price=excluded.unit_price, description=excluded.description, spec=excluded.spec, active=true, captured_at=now();
