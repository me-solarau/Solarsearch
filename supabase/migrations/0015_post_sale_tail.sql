-- ============================================================================
-- Post-sale tail: signed -> connection_approved -> installed -> der_registered
-- -> closed, plus deal invoicing. Also fixes a gap that affected every
-- invoker-mode workflow RPC: events had no INSERT policy, so a staff-driven
-- create_design / open_board / complete_inspection / (these) would fail when
-- logging their event. Add an admin INSERT policy on events to match the
-- admin_all_* model already used on leads/deals/connection_applications.
-- ============================================================================

create policy admin_insert_events on public.events for insert to authenticated
  with check (is_admin());

-- Ordered post-sale state machine. Each call advances exactly one step and
-- performs that step's side effect. Invoker-mode, so RLS keeps it admin-only
-- (a non-admin caller fails the leads/events/connection_applications checks).
create or replace function public.post_sale_advance(
  p_lead_id uuid, p_to_state text, p_ref text default null,
  p_export_limit numeric default null, p_staff_id uuid default null)
returns jsonb
language plpgsql set search_path = public as $$
declare v_lead record; v_site uuid; v_from lead_state; v_next text; v_dnsp uuid; v_conn record;
begin
  select * into v_lead from leads where id = p_lead_id;
  if not found then raise exception 'lead not found'; end if;
  v_site := v_lead.site_id; v_from := v_lead.state;

  v_next := case v_from
    when 'signed' then 'connection_approved'
    when 'connection_approved' then 'installed'
    when 'installed' then 'der_registered'
    when 'der_registered' then 'closed'
    else null end;
  if v_next is null or v_next <> p_to_state then
    raise exception 'cannot advance from % to %', v_from, p_to_state;
  end if;

  if p_to_state = 'connection_approved' then
    select * into v_conn from connection_applications where site_id = v_site order by created_at desc limit 1;
    if not found then
      select coalesce(s.dnsp_id, (select dp.dnsp_id from dnsp_postcodes dp where dp.postcode = s.postcode limit 1))
        into v_dnsp from sites s where s.id = v_site;
      if v_dnsp is null then raise exception 'no DNSP resolved for this site — set one before approving'; end if;
      insert into connection_applications (site_id, deal_id, dnsp_id, lodged_by, status, reference, export_limit_kw, lodged_at, decided_at)
      values (v_site, (select id from deals where site_id = v_site order by signed_at desc limit 1),
              v_dnsp, 'solarsearch', 'approved', p_ref, p_export_limit, now(), now());
    else
      update connection_applications set status = 'approved',
        reference = coalesce(p_ref, reference), export_limit_kw = coalesce(p_export_limit, export_limit_kw),
        decided_at = now()
      where id = v_conn.id;
    end if;
  elsif p_to_state = 'der_registered' then
    update connection_applications set der_registered_at = now()
    where site_id = v_site and der_registered_at is null;
  elsif p_to_state = 'closed' then
    if not exists (select 1 from connection_applications where site_id = v_site and der_registered_at is not null) then
      raise exception 'DERR must be registered before closing (G-7)';
    end if;
  end if;

  update leads set state = p_to_state::lead_state where id = p_lead_id;

  insert into events (site_id, lead_id, actor_type, actor_id, event_type, payload)
  values (v_site, p_lead_id, 'staff', p_staff_id::text, 'post_sale.advanced',
    jsonb_build_object('from', v_from, 'to', p_to_state, 'reference', p_ref));

  return jsonb_build_object('state', p_to_state);
end $$;
revoke all on function public.post_sale_advance(uuid,text,text,numeric,uuid) from public;
grant execute on function public.post_sale_advance(uuid,text,text,numeric,uuid) to authenticated;

-- Deal invoicing status (pending -> invoiced -> paid, or credited).
create or replace function public.set_invoice_status(p_deal_id uuid, p_status text, p_ref text default null, p_staff_id uuid default null)
returns void
language plpgsql set search_path = public as $$
declare v_site uuid;
begin
  if p_status not in ('pending','invoiced','paid','credited') then raise exception 'invalid invoice status: %', p_status; end if;
  update deals set invoice_status = p_status, invoice_ref = coalesce(p_ref, invoice_ref)
  where id = p_deal_id returning site_id into v_site;
  if v_site is null then raise exception 'deal not found'; end if;
  insert into events (site_id, actor_type, actor_id, event_type, payload)
  values (v_site, 'staff', p_staff_id::text, 'deal.invoice_status', jsonb_build_object('deal_id', p_deal_id, 'status', p_status, 'ref', p_ref));
end $$;
revoke all on function public.set_invoice_status(uuid,text,text,uuid) from public;
grant execute on function public.set_invoice_status(uuid,text,text,uuid) to authenticated;
