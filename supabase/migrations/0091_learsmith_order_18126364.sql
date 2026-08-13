-- ============================================================================
-- Lear & Smith (Lambton) confirmation order 18126364, 14-Aug-2026 — switchboard
-- and consumable gear bought for the Fletcher / 34 Kingfisher Dr job (our ref
-- Jason Gowan). Prices are ex-GST NETT per EA, i.e. what we actually paid, so
-- they are ground truth for the material side of a quote (same standing as an
-- invoice_apply run, just recorded at migration time).
--
-- Two things happen here:
--   1. the seven lines land in supplier_materials under supplier='learsmith',
--      flagged in_use because they were genuinely installed, not browsed;
--   2. the order itself is recorded as a supplier_invoice + invoice_lines so the
--      next Lear & Smith invoice for the same parts shows price drift instead of
--      silently overwriting.
--
-- Item codes were read off a photographed hard copy whose left edge was cropped,
-- so the leading characters of five codes are inferred from the supplier's
-- 3-letter brand-prefix convention (MTL=Matelec, HAG=Hager, LIF=Lifesaver,
-- ZZZ=non-stock). MTLCLIP-M4X2/SS matches the existing goelectrical row exactly
-- and is certain; the rest carry spec.part_no_unverified so they can be
-- reconciled against the next Lear & Smith paperwork before they are trusted for
-- RFQ round-trips.
-- ============================================================================

insert into public.supplier_materials
  (supplier, brand, category, part_no, description, unit_price, spec, in_use, active, captured_at)
values
  -- Cable clip: same Matelec part already in the book at goelectrical $0.2550 —
  -- Lear & Smith is cheaper at $0.23, which is the point of multi-supplier pricing.
  ('learsmith','Matelec','mounting','MTLCLIP-M4X2/SS',
   'Solar Cable Clip Stainless Steel 2 x 4.0mm',
   0.2300,'{"source_order":"18126364"}',true,true,now()),

  -- Switchboard links
  ('learsmith','Generic','accessory','NSTESL5R',
   'Active Link 5 Hole 100A Red',
   4.1100,'{"amps":100,"holes":5,"part_no_unverified":true,"source_order":"18126364"}',true,true,now()),
  ('learsmith','Generic','accessory','NSTESL12',
   'Neutral Link 12 Hole 100A Black',
   7.2200,'{"amps":100,"holes":12,"part_no_unverified":true,"source_order":"18126364"}',true,true,now()),

  -- Hager MCBs — the three-phase AC protection used on >10kW single/three phase jobs
  ('learsmith','Hager','accessory','HAGMSN350',
   'Miniature Circuit Breaker (MCB) 3P 6kA C Curve 50A 3 Module',
   39.4000,'{"poles":3,"amps":50,"curve":"C","ka":6,"part_no_unverified":true,"source_order":"18126364"}',true,true,now()),
  ('learsmith','Hager','accessory','HAGMSN340',
   'Miniature Circuit Breaker (MCB) 3P 6kA C Curve 40A 3 Module',
   39.4000,'{"poles":3,"amps":40,"curve":"C","ka":6,"part_no_unverified":true,"source_order":"18126364"}',true,true,now()),

  -- Site consumables
  ('learsmith','Lifesaver','accessory','LIFLIFPE9M',
   'Smoke Alarm 9V DC Photoelectric with Mute',
   16.0000,'{"part_no_unverified":true,"source_order":"18126364"}',true,true,now()),
  ('learsmith','Generic','accessory','ZZZ104728',
   '90mm Surface Mounted White Bollard with Fixing Kit',
   85.0000,'{"mm":90,"part_no_unverified":true,"source_order":"18126364"}',true,true,now())
on conflict (supplier, part_no) do update
  set unit_price  = excluded.unit_price,
      brand       = excluded.brand,
      category    = excluded.category,
      description = excluded.description,
      spec        = excluded.spec,
      in_use      = true,
      active      = true,
      captured_at = now();

-- Mark these parts in_use across every supplier that stocks them (the cable clip
-- already exists under goelectrical), matching invoice_apply's behaviour.
update public.supplier_materials
   set in_use = true
 where upper(part_no) in ('MTLCLIP-M4X2/SS','NSTESL5R','NSTESL12','HAGMSN350','HAGMSN340','LIFLIFPE9M','ZZZ104728');

-- ---------------------------------------------------------------------------
-- Record the order itself (guarded so re-running does not duplicate lines).
-- TOTAL 301.15 ex GST + 30.11 GST = 331.26 inc; subtotal stored ex-GST to match
-- the ex-GST unit prices above.
-- ---------------------------------------------------------------------------
do $$
declare v_inv uuid;
begin
  if exists (select 1 from public.supplier_invoices
              where supplier_code = 'learsmith' and invoice_no = '18126364') then
    return;
  end if;

  insert into public.supplier_invoices
    (supplier_code, invoice_no, invoice_date, source, source_ref, subtotal)
  values ('learsmith','18126364','2026-08-14','upload','confirmation order 18126364 (photo)',301.15)
  returning id into v_inv;

  insert into public.invoice_lines (invoice_id, part_no, description, qty, unit_price, matched, prev_price, price_delta)
  values
    (v_inv,'MTLCLIP-M4X2/SS','Solar Cable Clip S/S 2 x 4.0mm',100,0.2300,true,null,null),
    (v_inv,'NSTESL5R','Active Link 5 Hole 100A Red',3,4.1100,true,null,null),
    (v_inv,'NSTESL12','Neutral Link 12 Hole 100A Black',1,7.2200,true,null,null),
    (v_inv,'HAGMSN350','Miniature Circuit Breaker (MCB) 3P 6kA C 50A 3M',2,39.4000,true,null,null),
    (v_inv,'HAGMSN340','Miniature Circuit Breaker (MCB) 3P 6kA C 40A 3M',2,39.4000,true,null,null),
    (v_inv,'LIFLIFPE9M','Smoke Alarm Lifesaver 9V DC Photoelectric with Mute',1,16.0000,true,null,null),
    (v_inv,'ZZZ104728','90mm Surface Mounted White Bollard with Fixing Kit',1,85.0000,true,null,null);
end $$;
