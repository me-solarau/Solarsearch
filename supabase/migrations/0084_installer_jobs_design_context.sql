-- The capture app needs the design to know what evidence to ask for.
--
-- Johan: the roof-array shot proves the panels are there, but the evidence that
-- matters is underneath — mounting feet, tile seating, earth clamps with
-- galvanic protection, rails and straps, penetrations. Several of those are
-- quantity-driven: 18 panels means 36 feet, and he wants at least a 50% spot
-- check. The app cannot compute that without the panel count, and it cannot
-- decide whether tile-seating shots apply without the roof material.
--
-- Return type changes, so the function is dropped and recreated.
drop function if exists public.installer_jobs();

create function public.installer_jobs()
returns table(install_id uuid, lead_id uuid, status text, pipeline text,
              ss_ref text, address text, postcode text, suburb text,
              customer_name text, customer_mobile text, customer_email text,
              panel_qty int, roof_material text, storeys smallint,
              system_kw numeric, battery_kwh numeric,
              created_at timestamp with time zone)
language sql
stable security definer
set search_path to 'public'
as $function$
  select i.id, i.lead_id, i.status, i.pipeline,
         s.ss_ref, s.address, s.postcode,
         nullif(trim(split_part(s.address, ',', -1)), '') as suburb,
         c.full_name, c.mobile, c.email,
         coalesce((d.components->'panel'->>'qty')::int, 0) as panel_qty,
         coalesce(d.roof_material, s.roof_type, 'tin')    as roof_material,
         s.storeys,
         d.system_kw, d.battery_kwh,
         i.created_at
  from installs i
  join leads l on l.id = i.lead_id
  join sites s on s.id = l.site_id
  left join customers c on c.id = l.customer_id
  left join lateral (
    select * from designs dd where dd.site_id = s.id order by dd.created_at desc limit 1
  ) d on true
  where public.is_admin() or i.installer_id = public.current_installer_id()
  order by i.created_at desc;
$function$;

grant execute on function public.installer_jobs() to authenticated;
