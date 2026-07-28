-- Applied to vbpzigwgfmchdpvxetge as four migrations:
--   instant_quote_catalog_and_public_rpc
--   instant_quote_fix_labour_double_count
--   edge_perimeter_at_design
--   edge_booking_inherits_design_perimeter
--
-- 1. PUBLIC INSTANT QUOTE (instant_quote(jsonb), anon-callable)
--    Brings the field-validated Me-Solar model online: per-panel BOM ratios x
--    catalog costs + cable runs, gross margin covering labour AND profit
--    (cost/(1-margin) — the artifact's form), STC rebate, mandatory edge
--    protection. Default margin 40%.
--    SECURITY: returns customer-facing figures only. Never materials cost,
--    never margin, never BOM lines — otherwise supplier pricing is readable
--    off the network tab.
--    A first cut applied the gross margin AND explicit labour lines, which
--    double-counted labour; the fix migration removed the labour lines.
--
-- 2. 6.6kW MINIMUM as a PRICE FLOOR, not phantom panels. A sub-6.6kW job is
--    priced at the 6.6kW-equivalent and flagged min_job_charge_applied. STC
--    always follows ACTUAL installed capacity — claiming STCs on the floored
--    size would be a CER problem.
--
-- 3. EDGE PROTECTION — deliberate change to a locked spec decision.
--    Spec said "provider-billed, not a customer quote line". Johan's call
--    2026-07-28: it is compulsory Safe Work Australia height safety on every
--    install, so omitting an unavoidable cost makes a customer quote wrong.
--    Money flow: customer pays the installer as a visible line; the installer
--    passes it to the booked edge-protection crew. Pass-through, not margin.
--    Solarsearch still bills the trade party per billing_party (installer on
--    the main pipeline, RETAILER on subcontract — never the subbie).
--    Priced $180 incl per 20 linear metres, rounded UP to whole blocks, one
--    block minimum. Measured at DESIGN, so the online quote shows the minimum.

create table if not exists public.quote_catalog (
  code text primary key,
  kind text not null check (kind in ('panel','inverter','battery')),
  label text not null, cost numeric not null,
  watts numeric, kw numeric, phase int, usable_kwh numeric,
  width_mm numeric, length_mm numeric,
  active boolean not null default true, sort int not null default 0
);
alter table public.quote_catalog enable row level security;
drop policy if exists quote_catalog_read on public.quote_catalog;
create policy quote_catalog_read on public.quote_catalog for select to authenticated using (true);
drop policy if exists quote_catalog_admin on public.quote_catalog;
create policy quote_catalog_admin on public.quote_catalog for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

insert into public.quote_catalog (code,kind,label,cost,watts,kw,phase,usable_kwh,width_mm,length_mm,sort) values
  ('AIKO-A465','panel','AIKO Neostar 2S A465 · 465W',134.0,465,null,null,null,1136,1760,10),
  ('TRINA-440','panel','Trina Vertex S+ · 440W',118.0,440,null,null,null,1134,1762,20),
  ('JINKO-440','panel','Jinko Tiger Neo · 440W',112.0,440,null,null,null,1134,1762,30),
  ('GW5K-1P','inverter','GoodWe 5kW 1-phase',1180.0,null,5,1,null,null,null,10),
  ('GW8K-ESA-1P','inverter','GoodWe ESA 8kW 1-phase',1650.0,null,8,1,null,null,null,20),
  ('GW10K-ESA-1P','inverter','GoodWe ESA 10kW 1-phase',1980.0,null,10,1,null,null,null,30),
  ('GW15K-ESA-3P','inverter','GoodWe ESA 15kW 3-phase',2991.0,null,15,3,null,null,null,40),
  ('GW8.3-BAT-D','battery','GoodWe GW8.3-BAT-D · 8kWh usable',2150.0,null,null,null,8,null,null,10)
on conflict (code) do nothing;

create or replace function public.edge_protection_price(p_perimeter_m numeric)
returns numeric language sql immutable set search_path = public as $$
  select greatest(1, ceil(coalesce(nullif(p_perimeter_m,0),1) / 20.0))
       * coalesce((select edge_protect_per_20m_incl from pricing_config), 180);
$$;
grant execute on function public.edge_protection_price(numeric) to anon, authenticated;

-- Perimeter is measured at design; null means not yet measured (price at the
-- 1-block minimum online).
alter table public.designs add column if not exists edge_perimeter_m numeric;
comment on column public.designs.edge_perimeter_m is
  'Roof edge/perimeter in linear metres, measured at design. Drives edge-protection pricing in whole 20m blocks.';

-- Function bodies live in the database (see the applied migrations above):
--   instant_quote(jsonb)            public, cost-safe customer quote
--   create_design(...,p_edge_perimeter_m)  accepts the measured perimeter
--   request_edge_protection(...)    linear_m now DEFAULTS to the design
--                                   perimeter so the crew works to the quoted
--                                   distance. An explicit value is an override
--                                   and is logged as edge.perimeter_override
--                                   with both figures and both prices.
