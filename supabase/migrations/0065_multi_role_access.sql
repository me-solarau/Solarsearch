-- Multi-role access: one login can legitimately hold several roles at once
-- (admin via user_roles; sales_rep / installer / retailer via their approved identity
-- records). The client guard previously keyed off a single user_roles.role, so a user
-- who was, say, both a sales tech and an installer could only ever enter one app.
--
-- my_access() returns every role the signed-in user actually holds, derived from the same
-- SECURITY DEFINER helpers RLS already trusts. requireRole() (client) uses it to admit a
-- page if the user holds ANY of that page's allowed roles — no schema/RLS change, purely a
-- truthful "what can this user open" lookup.
create or replace function public.my_access()
returns jsonb language sql stable security definer set search_path=public as $$
  select jsonb_build_object(
    'admin',     public.is_admin(),
    'sales_rep', public.current_sales_rep_id() is not null,
    'installer', public.current_installer_id() is not null,
    'retailer',  public.current_retailer_id()  is not null
  );
$$;

revoke all on function public.my_access() from public;
grant execute on function public.my_access() to authenticated;
