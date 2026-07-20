-- ============================================================================
-- 0002 — Re-key the blanket staff_all_* policies onto user_roles (Section 1/7)
-- Today every one of these policies checks "is there an active staff row for
-- this auth_uid" — functionally admin-only in practice (only staff exist).
-- This re-keys the SAME effective access (admin-only) onto user_roles.role,
-- so retailer/sales_rep/installer-scoped policies can be layered on in later
-- phases without touching this admin grant again. No access-level change for
-- any currently-real user (Johan's the only linked account, already 'admin').
-- ============================================================================

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from user_roles where user_id = auth.uid() and role = 'admin');
$$;

-- Tables from schema.sql's original staff_all_* set
drop policy if exists staff_all_leads on leads;
create policy admin_all_leads on leads for all using (is_admin()) with check (is_admin());

drop policy if exists staff_all_sites on sites;
create policy admin_all_sites on sites for all using (is_admin()) with check (is_admin());

drop policy if exists staff_all_quotes on quotes;
create policy admin_all_quotes on quotes for all using (is_admin()) with check (is_admin());

drop policy if exists staff_all_seats on seats;
create policy admin_all_seats on seats for all using (is_admin()) with check (is_admin());

drop policy if exists staff_all_books on price_books;
create policy admin_all_books on price_books for all using (is_admin()) with check (is_admin());

drop policy if exists staff_all_audits on audit_reports;
create policy admin_all_audits on audit_reports for all using (is_admin()) with check (is_admin());

drop policy if exists staff_read_events on events;
create policy admin_read_events on events for select using (is_admin());

-- Tables from rls_hardening.sql's do-block staff_all_<table> set
do $$
declare t text;
begin
  foreach t in array array[
    'customers','installers','installer_service_areas','inspections','photos',
    'designs','board_snapshots','proposals','deals','connection_applications',
    'findings','correspondence','campaigns']
  loop
    execute format('drop policy if exists %I on public.%I', 'staff_all_' || t, t);
    execute format($f$create policy %1$I on public.%2$I for all to authenticated
      using (is_admin()) with check (is_admin())$f$, 'admin_all_' || t, t);
  end loop;
end $$;

-- Reference tables (regions/dnsps/incentive_rules/etc.) already use
-- "for select to authenticated using (true)" — any signed-in role should see
-- these (rates, DNSP config), so they're intentionally left as-is.

-- The `anyone_insert_events` policy from schema.sql becomes redundant now
-- that both public-facing writers (capture_lead, book_assessment) are
-- SECURITY DEFINER and don't need it. Revoke direct anon inserts.
drop policy if exists anyone_insert_events on events;
