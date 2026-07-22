-- ============================================================================
-- Installer rate cards = the labour/margin layer that completes a quote.
--   quote = materials x (1 + installer material_margin_pct)
--         + SUM(chargeable qty x installer rate, else me-solar baseline)
--         - rebates
--
-- Solar install labour is PER WATT and varies by roof x storey (real me-solar
-- baseline: $0.32/W tin single, $0.34/W double). Some chargeables use a base +
-- included allowance + per-unit overage (cable runs). `meta` drives automatic
-- variant selection (roof/storey for solar labour, kW band / cable size for AC
-- cable). Rates with baseline_confirmed=false are PLACEHOLDERS pending real
-- me-solar numbers; confirmed=true are supplied by the business.
-- ============================================================================
create table if not exists public.chargeables (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,
  name text not null,
  unit text not null,                       -- watt|panel|inverter|battery|kw|kwh|job|hour|km|m
  category text not null,                   -- solar_labour|labour|access|electrical|logistics|admin
  baseline_rate numeric(12,4),              -- me-solar baseline, ex-GST
  baseline_confirmed boolean not null default false,
  included_qty numeric,                     -- units covered by baseline_rate (e.g. 25m)
  over_rate numeric(12,4),                  -- price per unit beyond included_qty
  over_unit text,                           -- unit for overage (e.g. 'm')
  meta jsonb not null default '{}'::jsonb,  -- variant selectors: {roof,storey,kw_max,cable_mm2,...}
  active boolean not null default true,
  sort int not null default 100,
  created_at timestamptz not null default now()
);

create table if not exists public.installer_rate_cards (
  installer_id uuid primary key references public.installers(id) on delete cascade,
  material_margin_pct numeric(6,2) not null default 0,   -- % markup on materials
  note text,
  active boolean not null default true,
  updated_at timestamptz not null default now()
);

create table if not exists public.installer_chargeable_rates (
  installer_id uuid not null references public.installers(id) on delete cascade,
  chargeable_code text not null references public.chargeables(code) on delete cascade,
  rate numeric(12,4) not null,
  updated_at timestamptz not null default now(),
  primary key (installer_id, chargeable_code)
);

alter table public.chargeables                enable row level security;
alter table public.installer_rate_cards       enable row level security;
alter table public.installer_chargeable_rates enable row level security;

drop policy if exists chargeables_read on public.chargeables;
create policy chargeables_read on public.chargeables for select
  using (public.is_admin() or public.is_active_staff() or public.current_installer_id() is not null);
drop policy if exists chargeables_write on public.chargeables;
create policy chargeables_write on public.chargeables for all
  using (public.is_admin()) with check (public.is_admin());

drop policy if exists rate_cards_admin on public.installer_rate_cards;
create policy rate_cards_admin on public.installer_rate_cards for all
  using (public.is_admin()) with check (public.is_admin());
drop policy if exists rate_cards_self on public.installer_rate_cards;
create policy rate_cards_self on public.installer_rate_cards for select
  using (installer_id = public.current_installer_id());

drop policy if exists charge_rates_admin on public.installer_chargeable_rates;
create policy charge_rates_admin on public.installer_chargeable_rates for all
  using (public.is_admin()) with check (public.is_admin());
drop policy if exists charge_rates_self on public.installer_chargeable_rates;
create policy charge_rates_self on public.installer_chargeable_rates for select
  using (installer_id = public.current_installer_id());

insert into public.chargeables
  (code, name, unit, category, baseline_rate, baseline_confirmed, included_qty, over_rate, over_unit, meta, sort) values
  -- CONFIRMED me-solar baselines
  ('solar_labour_tin_1s','Solar install labour — tin roof, single storey','watt','solar_labour',0.3200,true,null,null,null,'{"roof":"tin","storey":1}',10),
  ('solar_labour_2s','Solar install labour — double storey','watt','solar_labour',0.3400,true,null,null,null,'{"storey":2}',11),
  ('dc_cable_run','DC cable run (2 strings)','job','electrical',550.00,true,25,5.5000,'m','{"strings":2}',95),
  ('ac_cable_run','AC cable run (up to 10kW)','job','electrical',95.00,true,5,12.5000,'m','{"kw_max":10,"cable_mm2":10}',96),
  -- PLACEHOLDER baselines (confirm real me-solar values)
  ('battery_install','Battery install & commission','battery','labour',600.00,false,null,null,null,'{}',30),
  ('ground_mount','Ground-mount structure & install','job','labour',1500.00,false,null,null,null,'{}',40),
  ('ev_charger_install','EV charger install','job','labour',350.00,false,null,null,null,'{}',50),
  ('hw_diverter_install','Hot water diverter install','job','labour',300.00,false,null,null,null,'{}',60),
  ('switchboard_upgrade','Switchboard upgrade','job','electrical',850.00,false,null,null,null,'{}',70),
  ('meter_reconfig','Metering reconfiguration / smart meter coord','job','electrical',300.00,false,null,null,null,'{}',80),
  ('three_phase_supply','Three-phase supply works','job','electrical',1200.00,false,null,null,null,'{}',90),
  ('cable_trenching','Trenching / underground cable','m','electrical',35.00,false,null,null,null,'{}',100),
  ('scaffold_access','Scaffolding / height access','job','access',600.00,false,null,null,null,'{}',110),
  ('travel_mobilisation','Travel / mobilisation','job','logistics',150.00,false,null,null,null,'{}',150),
  ('travel_per_km','Travel beyond zone','km','logistics',1.50,false,null,null,null,'{}',160),
  ('stc_admin','STC / CER paperwork & assignment','job','admin',150.00,false,null,null,null,'{}',170),
  ('saa_signoff','SAA design & sign-off','job','admin',200.00,false,null,null,null,'{}',180),
  ('electrical_ces','Electrical CES / compliance certificate','job','admin',180.00,false,null,null,null,'{}',190)
on conflict (code) do update set
  name=excluded.name, unit=excluded.unit, category=excluded.category,
  baseline_rate=excluded.baseline_rate, baseline_confirmed=excluded.baseline_confirmed,
  included_qty=excluded.included_qty, over_rate=excluded.over_rate, over_unit=excluded.over_unit,
  meta=excluded.meta, sort=excluded.sort;
