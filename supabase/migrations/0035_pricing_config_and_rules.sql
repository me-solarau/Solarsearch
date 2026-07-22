-- ============================================================================
-- Global pricing config + two edge-case rules.
--   material_margin_pct_default : me-solar baseline markup on hardware (40%);
--     installer_rate_cards.material_margin_pct overrides per installer.
--   min_solar_watts : solar labour bills max(actual, 6600W) x $/W so small jobs
--     still cover fuel/travel/labour (6.6kW equivalent minimum).
--   Travel : free within free_travel_radius_km (80km); beyond = ATO km rate x
--     (1 + travel_markup_pct/100). ATO rate stored here so it's updatable each FY.
-- (Cable runs carry their own 45% and are NOT subject to material_margin.)
-- ============================================================================
create table if not exists public.pricing_config (
  id boolean primary key default true,
  material_margin_pct_default numeric(6,2) not null default 40,
  ato_rate_per_km numeric(6,3) not null default 0.88,     -- FY2025-26 ATO cents/km method
  free_travel_radius_km numeric not null default 80,
  travel_markup_pct numeric(6,2) not null default 40,
  min_solar_watts numeric not null default 6600,          -- 6.6kW equivalent minimum
  updated_at timestamptz not null default now(),
  constraint pricing_config_singleton check (id)
);
insert into public.pricing_config
  (id, material_margin_pct_default, ato_rate_per_km, free_travel_radius_km, travel_markup_pct, min_solar_watts)
values (true, 40, 0.88, 80, 40, 6600)
on conflict (id) do update set
  material_margin_pct_default = excluded.material_margin_pct_default,
  ato_rate_per_km = excluded.ato_rate_per_km,
  free_travel_radius_km = excluded.free_travel_radius_km,
  travel_markup_pct = excluded.travel_markup_pct,
  min_solar_watts = excluded.min_solar_watts,
  updated_at = now();

alter table public.pricing_config enable row level security;
drop policy if exists pricing_config_read on public.pricing_config;
create policy pricing_config_read on public.pricing_config for select
  using (public.is_admin() or public.is_active_staff() or public.current_installer_id() is not null);
drop policy if exists pricing_config_write on public.pricing_config;
create policy pricing_config_write on public.pricing_config for all
  using (public.is_admin()) with check (public.is_admin());

-- Minimum 6.6kW solar labour
update public.chargeables set meta = meta || '{"min_watts":6600}'::jsonb where category='solar_labour';

-- Travel rules
update public.chargeables set baseline_rate=0, baseline_confirmed=true,
  name='Travel — no charge within 80km radius',
  meta='{"free_radius_km":80,"no_charge_within_radius":true}'
  where code='travel_mobilisation';
update public.chargeables set baseline_rate=1.2320, baseline_confirmed=true, over_unit='km',
  name='Travel beyond 80km (ATO rate + 40% per km)',
  meta='{"free_radius_km":80,"ato_rate":0.88,"markup_pct":40,"per_km_beyond_free":true}'
  where code='travel_per_km';
