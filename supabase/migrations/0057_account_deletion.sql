-- In-app account deletion (Apple App Store Guideline 5.1.1(v) — required for any app with
-- account creation). The user can request deletion from within the app; this records the
-- request and immediately deactivates their access. Full data erasure is completed by an
-- admin/back-office process (an audited erase within a reasonable window).
create table if not exists public.account_deletions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  reason text,
  requested_at timestamptz not null default now(),
  erased_at timestamptz
);
alter table public.account_deletions enable row level security;
drop policy if exists account_del_own on public.account_deletions;
create policy account_del_own on public.account_deletions for select
  using (user_id = auth.uid() or public.is_admin());
drop policy if exists account_del_admin on public.account_deletions;
create policy account_del_admin on public.account_deletions for all
  using (public.is_admin()) with check (public.is_admin());

create or replace function public.request_account_deletion(p_reason text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'sign in first'; end if;
  insert into account_deletions (user_id, reason) values (v_uid, p_reason);
  -- immediate deactivation of any field-app access (best-effort; erasure follows)
  update sales_reps set status = 'rejected' where user_id = v_uid;
  update access_applications set status = 'denied' where user_id = v_uid;
  return jsonb_build_object('ok', true, 'requested', true);
end $$;
