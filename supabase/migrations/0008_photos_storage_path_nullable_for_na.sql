-- A step assessed N/A legitimately has no photo (field.html only requires
-- one for pass/minor/major). storage_path must allow null so that
-- assessment can still be recorded as a row.
alter table public.photos alter column storage_path drop not null;
