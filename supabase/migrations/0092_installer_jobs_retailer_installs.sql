-- The capture app's job list (installer_jobs) inner-joined through leads, so a
-- retailer-posted install — which has no lead; its site, customer and system
-- detail live on the jobs row — never appeared in the app at all. First hit
-- live by the first external installer's first subcontract job. Left-join the
-- lead path and coalesce from jobs: panel_qty drives the per-item coverage
-- minimums, roof_type decides whether tile evidence is demanded, and the
-- customer reveal comes from the job when there is no lead.
create or replace function public.installer_jobs()
returns table(install_id uuid, lead_id uuid, status text, pipeline text, ss_ref text,
  address text, postcode text, suburb text, customer_name text, customer_mobile text,
  customer_email text, panel_qty integer, roof_material text, storeys smallint,
  system_kw numeric, battery_kwh numeric, scheduled_install_at timestamp with time zone,
  created_at timestamp with time zone)
language sql stable security definer set search_path to 'public'
as $function$
  select i.id, i.lead_id, i.status, i.pipeline,
         coalesce(s.ss_ref, 'JOB-' || upper(left(j.id::text, 8))) as ss_ref,
         coalesce(s.address, j.street_address) as address,
         coalesce(s.postcode, j.postcode) as postcode,
         coalesce(nullif(trim(split_part(s.address, ',', -1)), ''), j.suburb) as suburb,
         coalesce(c.full_name, j.customer_name),
         coalesce(c.mobile, j.customer_phone),
         coalesce(c.email, j.customer_email),
         coalesce((d.components->'panel'->>'qty')::int, j.panel_qty, 0) as panel_qty,
         coalesce(d.roof_material, s.roof_type, j.roof_type, 'tin') as roof_material,
         coalesce(s.storeys, j.storeys::smallint) as storeys,
         coalesce(d.system_kw, j.system_kw) as system_kw,
         coalesce(d.battery_kwh, j.battery_kwh) as battery_kwh,
         i.scheduled_install_at,
         i.created_at
  from installs i
  left join leads l on l.id = i.lead_id
  left join sites s on s.id = l.site_id
  left join customers c on c.id = l.customer_id
  left join jobs j on j.id = i.job_id
  left join lateral (
    select * from designs dd where dd.site_id = s.id order by dd.created_at desc limit 1
  ) d on true
  where public.is_admin() or i.installer_id = public.current_installer_id()
  order by i.created_at desc;
$function$;
