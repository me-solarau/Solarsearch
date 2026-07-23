-- Post-win contact reveal for the assigned installer.
--
-- leads/sites/customers are admin-only under RLS, so the installer app's embedded
-- `installs -> leads(sites(...))` read returns null for a real (non-admin) installer —
-- meaning the winning installer can't even see the site address to attend. This RPC is
-- the scoped reveal: a SECURITY DEFINER function that returns the customer's contact and
-- the site address for the installer's OWN installs only (installs.installer_id =
-- current_installer_id()), or all of them for an admin. Because an installs row only
-- exists once the job has been assigned to that installer (post customer selection), the
-- existence of the row is itself the "they won it" gate — no rival ever sees this.
create or replace function public.installer_jobs()
returns table (
  install_id      uuid,
  lead_id         uuid,
  status          text,
  pipeline        text,
  ss_ref          text,
  address         text,
  postcode        text,
  suburb          text,
  customer_name   text,
  customer_mobile text,
  customer_email  text,
  created_at      timestamptz
)
language sql stable security definer set search_path = public as $$
  select i.id, i.lead_id, i.status, i.pipeline,
         s.ss_ref, s.address, s.postcode,
         nullif(trim(split_part(s.address, ',', -1)), '') as suburb,
         c.full_name, c.mobile, c.email, i.created_at
  from installs i
  join leads l on l.id = i.lead_id
  join sites s on s.id = l.site_id
  left join customers c on c.id = l.customer_id
  where public.is_admin() or i.installer_id = public.current_installer_id()
  order by i.created_at desc;
$$;

revoke all on function public.installer_jobs() from public;
grant execute on function public.installer_jobs() to authenticated;
