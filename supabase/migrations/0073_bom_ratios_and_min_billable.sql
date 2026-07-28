-- Applied to vbpzigwgfmchdpvxetge as two migrations:
--   bom_ratios_and_min_billable · buy_seat_bom_pricing_min_billable
--
-- Per-panel BOM prebuild + minimum billable system size, ported from the
-- field-validated Me-Solar Instant Quote model: cost the actual bill of
-- materials from per-panel ratios, apply a gross margin that covers labour and
-- profit, and sanity-check gross profit against the STC value.
--
-- Two problems this fixes:
--   1. `price_books.solar_per_kw_cents` is a flat $/kW field that invited a unit
--      error — a $/W subbie rate ($0.35) typed into a $/kW field. At $350/kW the
--      STC rebate exceeded the price and the engine floored the customer quote
--      at $0. Costing a real BOM removes the whole class of mistake.
--   2. No minimum billable size. Trade rule: a sub-6.6kW job is not worth doing
--      at its own size but IS worth doing at the 6.6kW minimum fee. The floor
--      applies to billable size only — the job is never refused.
--
-- Verified live: a 3kW job now prices at $3,548.87 (billable_watts 6600,
-- min_billable_applied true) where the old model produced $0.

create table if not exists public.bom_ratios (
  code text primary key, label text not null,
  per text not null check (per in ('panel','string','array','job')),
  mult numeric not null, unit_cost numeric not null,
  active boolean not null default true, sort int not null default 0,
  updated_at timestamptz not null default now()
);
alter table public.bom_ratios enable row level security;
drop policy if exists bom_ratios_read on public.bom_ratios;
create policy bom_ratios_read on public.bom_ratios for select to authenticated using (true);
drop policy if exists bom_ratios_admin on public.bom_ratios;
create policy bom_ratios_admin on public.bom_ratios for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- Ratios + unit costs as used by Me-Solar. Clamps = mid (2.5) + end (0.75).
insert into public.bom_ratios (code,label,per,mult,unit_cost,sort) values
  ('feet','Feet','panel',2.50,2.95,10),
  ('clamps','Universal clamps','panel',3.25,2.50,20),
  ('weeb','WEEB / earthing','panel',1.50,1.12,30),
  ('joiners','Joiners','panel',0.50,2.70,40),
  ('ground_lug','Grounding lug','string',2.00,3.93,50),
  ('disconnect_pt','Disconnection point','string',1.00,22.67,60),
  ('flashing','Flashing','array',2.00,12.75,70),
  ('pole_housing','Pole housing','job',1.00,30.00,80),
  ('breaker','Circuit breaker','job',2.00,47.99,90),
  ('label_kit','Label kit','job',1.00,20.47,100)
on conflict (code) do nothing;

-- Per-installer gross margin (the artifact's 28-40% slider).
-- Null falls back to pricing_config.material_margin_pct_default.
alter table public.price_books add column if not exists margin_pct numeric;
comment on column public.price_books.margin_pct is
  'Installer gross margin %, applied as cost/(1-margin). Null = platform default.';

-- bom_estimate() and buy_seat() bodies are held in the database; see the
-- applied migrations above. bom_estimate computes mounting/BOS from the ratios
-- plus geometric rail count (panel dim x 2 rails x qty / 4700mm stock),
-- returning {total, lines[]}. buy_seat prices materials from supplier_materials
-- where the catalog can resolve the kit, falls back to the installer's flat
-- rates otherwise, applies the installer margin, and bills solar labour at
-- greatest(system_watts, pricing_config.min_solar_watts).
