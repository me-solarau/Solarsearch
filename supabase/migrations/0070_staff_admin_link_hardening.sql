-- Staff ↔ auth link hardening.
--
-- The problem this fixes: `link_staff_on_signup` (rls_hardening.sql) matched a
-- single HARDCODED email and only ever set `staff.auth_uid`. It never created
-- the `user_roles` row that `is_admin()` actually reads. Consequences seen in
-- production:
--   * the hardcoded address matched no real account, so the link never fired;
--   * the owner's login sat in user_roles as 'sales_rep', so is_admin() was
--     false — which both bounced them out of hq.html (requireRole) and made the
--     admin RLS policies return zero rows. The leads dashboard looked empty
--     even though leads existed.
--
-- The fix: staff rows carry their own email, the trigger matches on it
-- (case-insensitively), and an ACTIVE admin staff row grants the admin
-- user_roles entry automatically. No hardcoded addresses, and the identity
-- link is derived from staff data instead of a literal in a migration.
--
-- Non-admin roles are unaffected: multi-role access derives sales_rep /
-- installer / retailer from their own identity tables (see 0065), so writing
-- 'admin' here never removes another capability.

-- 1. Staff carry their own email.
alter table public.staff add column if not exists email text;

create unique index if not exists staff_email_lower_idx
  on public.staff (lower(email)) where email is not null;

-- Backfill from the auth accounts already linked.
update public.staff s
set email = u.email
from auth.users u
where s.auth_uid = u.id and s.email is null;

-- 2. Keep user_roles in step for anyone already linked as active admin staff.
insert into user_roles (user_id, role)
select s.auth_uid, 'admin'
from public.staff s
where s.role = 'admin' and s.active and s.auth_uid is not null
on conflict (user_id) do update set role = 'admin';

-- 3. Reusable linker: match a new auth user to a staff row by email, adopt the
--    auth_uid, and grant admin when that staff row is an active admin.
create or replace function public.link_staff_account(p_user uuid, p_email text)
returns void language plpgsql security definer set search_path = public, auth as $$
declare v_staff public.staff;
begin
  if p_email is null then return; end if;

  select * into v_staff from public.staff
  where lower(email) = lower(p_email) and auth_uid is null
  limit 1;

  if v_staff.id is null then
    -- already linked (or not staff at all) — nothing to adopt
    select * into v_staff from public.staff where auth_uid = p_user limit 1;
    if v_staff.id is null then return; end if;
  else
    update public.staff set auth_uid = p_user where id = v_staff.id;
  end if;

  if v_staff.role = 'admin' and v_staff.active then
    insert into user_roles (user_id, role) values (p_user, 'admin')
    on conflict (user_id) do update set role = 'admin';
  end if;
end $$;

revoke execute on function public.link_staff_account(uuid, text) from anon, authenticated, public;

-- 4. Replace the signup trigger. Defensive by design: a failure here must never
--    block account creation, so any error is swallowed and the signup proceeds.
create or replace function public.link_staff_on_signup()
returns trigger language plpgsql security definer set search_path = public, auth as $$
begin
  begin
    perform public.link_staff_account(new.id, new.email);
  exception when others then
    null; -- never block a signup on the staff link
  end;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.link_staff_on_signup();

revoke execute on function public.link_staff_on_signup() from anon, authenticated, public;
