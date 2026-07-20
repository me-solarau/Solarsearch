-- Close the loop from field.html back into the sales pipeline. Atomically:
-- set completed_at, log the outcome event, and (presale only) advance the
-- lead to 'inspected' so it flows to the design queue. A Solarsafe audit
-- is not a sales-pipeline lead, so it completes without advancing state —
-- the separate convert_solarsafe_lead RPC is how a Solarsafe customer
-- enters the sales pipeline. Runs under the caller's staff RLS (invoker).
create or replace function public.complete_inspection(p_inspection_id uuid, p_counts jsonb default '{}', p_staff_id uuid default null)
returns void
language plpgsql
set search_path = public
as $$
declare
  v_mode text; v_site_id uuid; v_lead_id uuid;
begin
  select mode, site_id, lead_id into v_mode, v_site_id, v_lead_id
  from inspections where id = p_inspection_id;
  if v_site_id is null then raise exception 'inspection not found'; end if;

  update inspections set completed_at = now() where id = p_inspection_id and completed_at is null;

  insert into events (site_id, lead_id, actor_type, actor_id, event_type, payload)
  values (v_site_id, v_lead_id, 'staff', p_staff_id::text, 'inspection.completed', coalesce(p_counts,'{}'::jsonb));

  if v_mode = 'presale' and v_lead_id is not null then
    update leads set state = 'inspected'
    where id = v_lead_id and state not in ('inspected','designed','quoted','customer_chose','signed','connection_approved','installed','der_registered','audited','closed');
  end if;
end $$;

revoke all on function public.complete_inspection(uuid, jsonb, uuid) from public;
grant execute on function public.complete_inspection(uuid, jsonb, uuid) to authenticated;
