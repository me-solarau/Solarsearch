-- ============================================================================
-- 0001 — user_roles: the RLS-facing role for every portal (Section 1)
-- Additive only. Does not touch staff/existing policies (that's Phase 2).
-- Reconciliation: staff.role stays as-is for internal display; every linked
-- staff member gets user_roles.role = 'admin' regardless of their staff.role
-- sub-type (hq_ops/inspector/designer/compliance_reviewer all -> admin here).
-- ============================================================================

create table user_roles (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  role       text not null check (role in ('admin','retailer','sales_rep','installer')),
  created_at timestamptz not null default now()
);

alter table user_roles enable row level security;

-- Every signed-in user may read their own role (needed by the client-side
-- auth guard to decide where to route them / what to render).
create policy self_read_role on user_roles for select to authenticated
  using (user_id = auth.uid());

-- Backfill: any staff already linked to a real auth account (i.e. Johan, if
-- he's already signed in to hq.html in production via magic link) gets
-- user_roles.role = 'admin'.
insert into user_roles (user_id, role)
select auth_uid, 'admin' from staff where auth_uid is not null
on conflict (user_id) do nothing;
