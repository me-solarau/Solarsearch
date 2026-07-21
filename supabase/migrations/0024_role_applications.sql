-- ============================================================================
-- Public role applications (native-app onboarding). Apple rejects a pure login
-- wall (Guideline 5.1.1 / 4.3): the field + installer apps must let a brand-new
-- person do something — apply to work with Solarsearch — before any account
-- exists. Mirrors the existing retailer_applications firewall pattern: anon can
-- INSERT (submit an application), only admin can read/manage. Nothing sensitive
-- is exposed; HQ Vetting turns an application into an onboarded account via the
-- existing onboard-technician / onboard-installer functions.
-- ============================================================================
create table if not exists public.role_applications (
  id           uuid primary key default uuid_generate_v4(),
  role         text not null check (role in ('technician','consultant','installer')),
  full_name    text not null,
  email        text,
  phone        text,
  company_name text,                              -- installers
  abn          text,                              -- installers
  postcodes    text[] not null default '{}',      -- free-text service postcodes
  message      text,
  status       text not null default 'pending' check (status in ('pending','contacted','converted','rejected')),
  created_at   timestamptz not null default now()
);

alter table public.role_applications enable row level security;
create policy admin_all_role_applications on public.role_applications
  for all to authenticated using (is_admin()) with check (is_admin());
create policy anon_insert_role_applications on public.role_applications
  for insert to anon with check (true);
-- authenticated (e.g. a logged-in but not-yet-approved user) may also apply
create policy auth_insert_role_applications on public.role_applications
  for insert to authenticated with check (true);
