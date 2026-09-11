-- Out-of-area zone activation. Admin-gated (HQ firewall): only an authenticated
-- HQ admin may add a postcode to coverage. SECURITY DEFINER so it can write the
-- coverage tables under that check; execute granted to authenticated only.
create or replace function public.hq_activate_zone(p_postcode text, p_installer_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_region uuid;
  v_reengaged int := 0;
begin
  if not public.is_admin() then
    raise exception 'admin only';
  end if;
  if p_postcode !~ '^\d{4}$' or p_postcode = '0000' then
    raise exception 'invalid postcode';
  end if;
  if not exists (select 1 from installers where id = p_installer_id) then
    raise exception 'installer not found';
  end if;

  -- Attach the new postcode to the dominant coverage region (single region
  -- today); fall back to any region if none is mapped yet.
  select region_id into v_region
  from installer_service_areas
  group by region_id
  order by count(*) desc
  limit 1;
  if v_region is null then
    select id into v_region from regions limit 1;
  end if;
  if v_region is null then
    raise exception 'no region configured';
  end if;

  if not exists (select 1 from region_postcodes where region_id = v_region and postcode = p_postcode) then
    insert into region_postcodes(region_id, postcode) values (v_region, p_postcode);
  end if;

  if not exists (select 1 from installer_service_areas where installer_id = p_installer_id and postcode = p_postcode) then
    insert into installer_service_areas(installer_id, region_id, postcode, paused)
    values (p_installer_id, v_region, p_postcode, false);
  end if;

  -- Reopen the captured out-of-area conversations for this postcode so Billy can
  -- re-engage them, and flag them for the good-news nudge. At most one active
  -- thread per phone (unique constraint), newest first, and never if one is
  -- already active.
  with at_pc as (
    select t.id, t.phone,
           row_number() over (partition by t.phone order by t.updated_at desc) as rn
    from agent_threads t
    join leads l on l.id = t.lead_id
    join sites s on s.id = l.site_id
    where s.postcode = p_postcode
      and t.status = 'not_interested'
      and (t.extracted->>'out_of_area') = 'true'
  )
  update agent_threads t
     set status = 'active',
         extracted = (t.extracted - 'out_of_area') || jsonb_build_object('reengage_pending', true),
         updated_at = now()
  from at_pc
  where t.id = at_pc.id
    and at_pc.rn = 1
    and not exists (select 1 from agent_threads a where a.phone = t.phone and a.status = 'active');
  get diagnostics v_reengaged = row_count;

  return jsonb_build_object('ok', true, 'postcode', p_postcode, 'region_id', v_region, 'reengaged', v_reengaged);
end;
$$;

revoke all on function public.hq_activate_zone(text, uuid) from public;
grant execute on function public.hq_activate_zone(text, uuid) to authenticated;
