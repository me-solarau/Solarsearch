-- Fix infinite recursion (42P17) on public.staff. The staff_directory_read
-- policy checked staff membership by selecting FROM staff inside its own USING
-- clause, so evaluating it re-triggered itself. This blocked ANY query that
-- touches staff RLS — including Storage uploads, whose inspection-photos policy
-- probes the staff table (which is why technician photo uploads failed with a
-- generic "database schema is invalid or incompatible" error from storage-api).
--
-- Move the membership test into a SECURITY DEFINER helper owned by a BYPASSRLS
-- role (same pattern as is_admin() / current_sales_rep_id()), so the check no
-- longer re-enters staff RLS.
--
-- Applied live to the Solarsearch project.
create or replace function public.is_active_staff()
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.staff s where s.auth_uid = auth.uid() and s.active);
$$;
revoke all on function public.is_active_staff() from public, anon;
grant execute on function public.is_active_staff() to authenticated;

drop policy if exists staff_directory_read on public.staff;
create policy staff_directory_read on public.staff for select to authenticated
  using (public.is_active_staff());

-- Also point the Storage inspection-photos policy at the helper so it never
-- inlines a staff subquery during unrelated (assessment-photos) uploads.
drop policy if exists staff_inspection_photos_all on storage.objects;
create policy staff_inspection_photos_all on storage.objects for all to authenticated
  using (bucket_id = 'inspection-photos' and public.is_active_staff())
  with check (bucket_id = 'inspection-photos' and public.is_active_staff());
