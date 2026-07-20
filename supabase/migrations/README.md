# Migrations convention

`schema.sql`, `platform_functions.sql`, and `rls_hardening.sql` (repo root)
are the historical baseline — run once, in that order, to get a fresh
Supabase project to the current production schema. They are not retroactively
split into this folder.

**Every schema change from now on is a new file here**, named
`NNNN_description.sql` (four-digit sequence, e.g. `0001_user_roles.sql`),
applied in order after the baseline. Each file should be self-contained and
re-runnable-safe where practical (`create table if not exists`, `create or
replace function`, etc.) even though these are applied once in sequence, not
via a diffing tool.

**Before merging any migration to the production project
(`vbpzigwgfmchdpvxetge`):** apply it to a fresh Supabase branch first
(`create_branch` off `vbpzigwgfmchdpvxetge`, `with_data: false` gives a clean
schema-only clone), confirm it applies without error on top of the current
baseline + all prior numbered migrations, then `delete_branch` once confirmed
— branches cost ~$0.0134/hr, don't leave them running.
