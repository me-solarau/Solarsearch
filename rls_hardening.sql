-- ============================================================================
-- SOLARSEARCH — RLS hardening + staff auth link (run AFTER platform_functions.sql)
-- Completes the "RLS outline — tighten before production" note in schema.sql:
-- enables RLS on every remaining public table and adds staff-scoped policies.
-- ============================================================================

-- ---- Staff auth link: wire the admin staff row to the owner's auth account ----
grant select on public.staff to authenticated;  -- base grant; RLS self-read policy below scopes it

create or replace function public.link_staff_on_signup()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.email = 'neo.venom02@gmail.com' then         -- TODO: change to your admin email(s)
    update public.staff set auth_uid = new.id
    where full_name = 'Johan (Admin)' and auth_uid is null;
  end if;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.link_staff_on_signup();

revoke execute on function public.link_staff_on_signup() from anon, authenticated, public;

-- ---- Enable RLS on every remaining public table + staff-scoped policies ----
do $$
declare t text;
begin
  foreach t in array array[
    'regions','region_postcodes','dnsps','dnsp_postcodes','incentive_rules',
    'customers','installers','installer_service_areas','staff','inspections',
    'photos','designs','board_snapshots','proposals','deals',
    'connection_applications','findings','correspondence','campaigns']
  loop
    execute format('alter table public.%I enable row level security', t);
  end loop;

  foreach t in array array[
    'customers','installers','installer_service_areas','inspections','photos',
    'designs','board_snapshots','proposals','deals','connection_applications',
    'findings','correspondence','campaigns']
  loop
    execute format($f$create policy staff_all_%1$s on public.%1$I for all to authenticated
      using (exists (select 1 from staff s where s.auth_uid = auth.uid() and s.active))
      with check (exists (select 1 from staff s where s.auth_uid = auth.uid() and s.active))$f$, t);
  end loop;
end $$;

-- staff can read their own row (needed by the RLS staff-check subquery)
create policy staff_self_read on public.staff for select to authenticated using (auth_uid = auth.uid());

-- any active staff member can read the full staff directory (needed to list
-- consultants/inspectors for assignment in hq.html) — self-read alone can't
-- serve that, since it only ever returns the requester's own row.
create policy staff_directory_read on public.staff for select to authenticated
  using (exists (select 1 from staff s where s.auth_uid = auth.uid() and s.active));

-- private storage bucket for field.html's photo captures
insert into storage.buckets (id, name, public) values ('inspection-photos', 'inspection-photos', false)
  on conflict (id) do nothing;
create policy staff_inspection_photos_all on storage.objects for all to authenticated
  using (bucket_id = 'inspection-photos' and exists (select 1 from staff s where s.auth_uid = auth.uid() and s.active))
  with check (bucket_id = 'inspection-photos' and exists (select 1 from staff s where s.auth_uid = auth.uid() and s.active));

-- non-sensitive reference data: readable by signed-in staff/apps
create policy ref_read_regions          on public.regions          for select to authenticated using (true);
create policy ref_read_region_postcodes on public.region_postcodes for select to authenticated using (true);
create policy ref_read_dnsps            on public.dnsps            for select to authenticated using (true);
create policy ref_read_dnsp_postcodes   on public.dnsp_postcodes   for select to authenticated using (true);
create policy ref_read_incentive_rules  on public.incentive_rules  for select to authenticated using (true);

-- harden mutable search_path on schema.sql trigger functions
alter function public.forbid_mutation() set search_path = public;
alter function public.log_lead_state() set search_path = public;
alter function public.enforce_seat_cap() set search_path = public;
