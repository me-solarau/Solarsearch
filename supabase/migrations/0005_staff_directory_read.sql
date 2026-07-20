-- Any active staff member can read the staff directory (needed to list
-- consultants for assignment, and generally to display "assigned to" names
-- anywhere in hq.html). Matches the staff_all_* self-referential pattern
-- already used for every other internal table. staff previously only had
-- staff_self_read (auth_uid = auth.uid()), so any query for OTHER staff
-- rows silently returned empty under RLS.
create policy staff_directory_read on public.staff for select to authenticated
  using (exists (select 1 from staff s where s.auth_uid = auth.uid() and s.active));
