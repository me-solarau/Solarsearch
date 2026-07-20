-- photos had no column to record the PASS/MINOR/MAJOR/N/A call or the
-- observation note field.html collects per step — without this the actual
-- compliance evidence was captured in the UI and then discarded.
alter table public.photos add column if not exists assessment text check (assessment in ('pass','minor','major','na'));
alter table public.photos add column if not exists note text;

-- field.html's "Create quote lead from this inspection" button (Solarsafe
-- jobs only): clones the existing site/customer into a new sales lead
-- rather than re-running capture_lead (which would duplicate the customer
-- and site rows that already exist from the original Solarsafe booking).
create or replace function public.convert_solarsafe_lead(p_inspection_id uuid, p_staff_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_site_id uuid; v_orig_lead_id uuid; v_customer_id uuid; v_new_lead_id uuid; v_ss text; v_consents jsonb;
begin
  select i.site_id, i.lead_id into v_site_id, v_orig_lead_id from inspections i where i.id = p_inspection_id;
  if v_site_id is null then raise exception 'inspection not found'; end if;
  select customer_id, consents into v_customer_id, v_consents from leads where id = v_orig_lead_id;
  select ss_ref into v_ss from sites where id = v_site_id;

  insert into leads (site_id, customer_id, state, lead_type, source_platform, consents)
  values (v_site_id, v_customer_id, 'captured', 'solar_battery', 'solarsafe_conversion', coalesce(v_consents,'[]'::jsonb))
  returning id into v_new_lead_id;

  insert into events (site_id, lead_id, actor_type, actor_id, event_type, payload)
  values (v_site_id, v_new_lead_id, 'staff', p_staff_id::text, 'lead.captured',
    jsonb_build_object('ss_ref', v_ss, 'source_platform', 'solarsafe_conversion', 'from_inspection', p_inspection_id));

  return jsonb_build_object('ss_ref', v_ss, 'lead_id', v_new_lead_id);
end $$;

revoke all on function public.convert_solarsafe_lead(uuid, uuid) from public;
grant execute on function public.convert_solarsafe_lead(uuid, uuid) to authenticated;
