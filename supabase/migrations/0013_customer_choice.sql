-- ============================================================================
-- Customer choice (choose.html magic link). The customer is unauthenticated —
-- access is gated by an unguessable per-lead token carried in the link. Both
-- RPCs are SECURITY DEFINER and validate the token, so the anon role never
-- touches base tables and one customer's token only ever reaches their own
-- site's quotes.
-- ============================================================================

-- Per-lead magic-link token (the "link to your saved comparison").
alter table public.leads add column if not exists choice_token uuid unique default uuid_generate_v4();
update public.leads set choice_token = uuid_generate_v4() where choice_token is null;

-- What the customer sees: the on-board quotes for their site. Installer company
-- name + equipment + price only — no competitor customer data, no internal ids
-- beyond the quote id needed to choose.
create or replace function public.customer_board(p_token uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_site_id uuid; v_lead record; v_design record; v_quotes jsonb;
begin
  select * into v_lead from leads where choice_token = p_token;
  if v_lead.id is null then return jsonb_build_object('error','invalid link'); end if;
  v_site_id := v_lead.site_id;
  select * into v_design from designs where site_id = v_site_id order by created_at desc limit 1;

  select coalesce(jsonb_agg(row order by (q.price_after_cents)), '[]'::jsonb) into v_quotes
  from (
    select jsonb_build_object(
      'quote_id', q.id,
      'company', i.company_name,
      'warranty_years', coalesce((i.brand_kit->>'warranty_years')::int, 10),
      'panel', coalesce(pb.preferred_equipment->>'panel_sku', d.components->>'panel'),
      'inverter', coalesce(pb.preferred_equipment->>'inverter_sku', d.components->>'inverter'),
      'battery', coalesce(pb.preferred_equipment->>'battery_sku', d.components->>'battery'),
      'price_before_cents', q.price_before_rebates_cents,
      'price_after_cents', q.price_after_cents,
      'rebate_cents', q.rebate_cents,
      'stc_count', q.stc_count
    ) as row, q.price_after_cents
    from quotes q
    join installers i on i.id = q.installer_id
    left join price_books pb on pb.id = q.price_book_id
    left join designs d on d.id = q.design_id
    where q.site_id = v_site_id and q.status = 'on_board'
  ) t;

  return jsonb_build_object(
    'ss_ref', (select ss_ref from sites where id = v_site_id),
    'suburb', nullif(trim(split_part((select address from sites where id = v_site_id), ',', -1)), ''),
    'postcode', (select postcode from sites where id = v_site_id),
    'customer_first', split_part(coalesce((select full_name from customers where id = v_lead.customer_id),''),' ',1),
    'system_kw', v_design.system_kw, 'battery_kwh', v_design.battery_kwh,
    'already_chosen', (v_lead.state in ('customer_chose','signed','connection_approved','installed','der_registered','audited','closed')),
    'quotes', v_quotes
  );
end $$;
revoke all on function public.customer_board(uuid) from public;
grant execute on function public.customer_board(uuid) to anon, authenticated;

-- Record the choice: consent-gated. Snapshots the board verbatim (immutable),
-- marks the chosen quote and declines the rest, creates the deal, advances the
-- lead, and logs the event.
create or replace function public.customer_choose(p_token uuid, p_quote_id uuid, p_consent boolean)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_lead record; v_site_id uuid; v_quote record; v_snap_id uuid; v_deal_commission int; v_ver text;
begin
  if not coalesce(p_consent,false) then raise exception 'consent required'; end if;
  select * into v_lead from leads where choice_token = p_token;
  if v_lead.id is null then raise exception 'invalid link'; end if;
  v_site_id := v_lead.site_id;
  if v_lead.state in ('customer_chose','signed','connection_approved','installed','der_registered','audited','closed') then
    raise exception 'a choice has already been made for this job';
  end if;

  select * into v_quote from quotes where id = p_quote_id and site_id = v_site_id and status = 'on_board';
  if v_quote.id is null then raise exception 'quote not available'; end if;

  -- immutable snapshot of exactly what was on the board at choice time
  insert into board_snapshots (site_id, payload)
  values (v_site_id, (select jsonb_agg(to_jsonb(q)) from quotes q where q.site_id = v_site_id and q.status = 'on_board'))
  returning id into v_snap_id;

  update quotes set status = 'chosen', board_snapshot_id = v_snap_id where id = p_quote_id;
  update quotes set status = 'declined', board_snapshot_id = v_snap_id
    where site_id = v_site_id and status = 'on_board' and id <> p_quote_id;

  select round(coalesce(v_quote.stc_count,0) * coalesce((select commission_per_stc_cents from regions r
     join sites s on s.region_id = r.id where s.id = v_site_id), 110)) into v_deal_commission;

  insert into deals (site_id, quote_id, installer_id, commission_cents)
  values (v_site_id, p_quote_id, v_quote.installer_id, v_deal_commission)
  on conflict (quote_id) do nothing;

  update leads set state = 'customer_chose' where id = v_lead.id;

  insert into events (site_id, lead_id, actor_type, event_type, payload)
  values (v_site_id, v_lead.id, 'customer', 'customer.chose',
    jsonb_build_object('quote_id', p_quote_id, 'installer_id', v_quote.installer_id, 'snapshot_id', v_snap_id, 'consent_version', 'v3.2'));

  return jsonb_build_object('company', (select company_name from installers where id = v_quote.installer_id));
end $$;
revoke all on function public.customer_choose(uuid, uuid, boolean) from public;
grant execute on function public.customer_choose(uuid, uuid, boolean) to anon, authenticated;
