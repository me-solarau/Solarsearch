-- Private storage bucket for field.html's photo captures — none existed
-- before, so photo uploads had nowhere to go. Staff-wide access, same
-- model as every other internal table (see rls_hardening.sql).
insert into storage.buckets (id, name, public)
values ('inspection-photos', 'inspection-photos', false)
on conflict (id) do nothing;

create policy staff_inspection_photos_all on storage.objects for all to authenticated
  using (bucket_id = 'inspection-photos' and exists (select 1 from staff s where s.auth_uid = auth.uid() and s.active))
  with check (bucket_id = 'inspection-photos' and exists (select 1 from staff s where s.auth_uid = auth.uid() and s.active));
