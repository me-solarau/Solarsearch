-- Edge protection becomes a visible line on what the customer compares and signs.
--
-- Spec (Johan): edge protection is a mandatory Safe Work Australia height-safety service on
-- EVERY installation. $180 incl per 20 linear metres, minimum charge, rounded up to whole 20m
-- blocks. The customer sees it, the customer pays the installer, the installer passes it to the
-- booked edge-protection crew. Solarsearch is not in the middle of that money leg.
--
-- Until now `instant_quote()` showed the line but `customer_board()` and `customer_proposal()`
-- did not — so the charge appeared on the instant estimate and then vanished from the comparison
-- board and the signed agreement. That is the reverse of the intent, since the whole point of
-- making it visible is that there is no post-signature variation.
--
-- Design notes:
--   * `price_after_cents` (the installer's own quoted price) is NOT modified. Edge protection is
--     carried as its own field and added into a separate `total_payable_cents`. Everything
--     downstream that reads the installer price — commission, deals, milestone payments — keeps
--     reading the same number it always did.
--   * Edge protection is identical for every installer on a board (same roof, same perimeter),
--     so adding it shifts all quotes by the same amount and the comparison stays fair.
--   * When the perimeter has not been measured yet, the price falls back to the one-block $180
--     minimum and `edge_perimeter_measured` is false, so the UI can say so honestly rather than
--     presenting a floor as if it were a final figure.

-- ---------------------------------------------------------------------------
-- 1. Cents helper. edge_protection_price() returns dollars; quotes are in cents.
-- ---------------------------------------------------------------------------
create or replace function public.edge_protection_cents(p_perimeter_m numeric)
returns integer
language sql
stable
set search_path to 'public'
as $$
  select round(public.edge_protection_price(p_perimeter_m) * 100)::integer;
$$;

comment on function public.edge_protection_cents(numeric) is
  'Mandatory height-safety edge protection, in cents. $180 incl per started 20 linear metres; '
  'falls back to the one-block minimum when the perimeter has not been measured yet.';

grant execute on function public.edge_protection_cents(numeric) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Comparison board — every quote carries the line and a true total payable.
-- ---------------------------------------------------------------------------
create or replace function public.customer_board(p_token uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_site_id uuid; v_lead record; v_design record; v_quotes jsonb;
  v_edge_cents integer; v_perimeter numeric;
begin
  select * into v_lead from leads where choice_token = p_token;
  if v_lead.id is null then return jsonb_build_object('error','invalid link'); end if;
  v_site_id := v_lead.site_id;
  select * into v_design from designs where site_id = v_site_id order by created_at desc limit 1;

  v_perimeter  := v_design.edge_perimeter_m;
  v_edge_cents := public.edge_protection_cents(v_perimeter);

  select coalesce(jsonb_agg(row order by t.total_payable_cents), '[]'::jsonb) into v_quotes
  from (
    select jsonb_build_object(
      'quote_id', q.id,
      'company', i.company_name,
      'warranty_years', coalesce((pb.preferred_equipment->>'warranty_years')::int, (i.brand_kit->>'warranty_years')::int, 10),
      'panel', coalesce(pb.preferred_equipment->>'panel_sku', public.equipment_label(d.components->'panel')),
      'inverter', coalesce(pb.preferred_equipment->>'inverter_sku', public.equipment_label(d.components->'inverter')),
      'battery', coalesce(pb.preferred_equipment->>'battery_sku', public.equipment_label(d.components->'battery')),
      'price_before_cents', q.price_before_rebates_cents,
      'price_after_cents', q.price_after_cents,
      'rebate_cents', q.rebate_cents,
      'stc_count', q.stc_count,
      'edge_protection_cents', v_edge_cents,
      'total_payable_cents', q.price_after_cents + v_edge_cents
    ) as row,
    q.price_after_cents + v_edge_cents as total_payable_cents
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
    'edge_protection_cents', v_edge_cents,
    'edge_perimeter_m', v_perimeter,
    'edge_perimeter_measured', (v_perimeter is not null and v_perimeter > 0),
    'already_chosen', (v_lead.state in ('customer_chose','signed','connection_approved','installed','der_registered','audited','closed')),
    'quotes', v_quotes
  );
end $function$;

-- ---------------------------------------------------------------------------
-- 3. The signed agreement — the line the customer actually commits to.
-- ---------------------------------------------------------------------------
create or replace function public.customer_proposal(p_token uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_lead record; v_q record; v_prop record;
  v_edge_cents integer; v_perimeter numeric;
begin
  select * into v_lead from leads where choice_token = p_token;
  if v_lead.id is null then return jsonb_build_object('error','invalid link'); end if;

  select q.*, i.company_name,
         coalesce((pb.preferred_equipment->>'warranty_years')::int,(i.brand_kit->>'warranty_years')::int,10) as warranty_years,
         pb.preferred_equipment, d.components, d.system_kw, d.battery_kwh, d.edge_perimeter_m
  into v_q
  from quotes q
  join installers i on i.id = q.installer_id
  left join price_books pb on pb.id = q.price_book_id
  left join designs d on d.id = q.design_id
  where q.site_id = v_lead.site_id and q.status = 'chosen'
  order by q.created_at desc limit 1;
  if v_q.id is null then return jsonb_build_object('error','no chosen quote yet'); end if;

  select * into v_prop from proposals where quote_id = v_q.id order by created_at desc limit 1;

  v_perimeter  := v_q.edge_perimeter_m;
  v_edge_cents := public.edge_protection_cents(v_perimeter);

  return jsonb_build_object(
    'customer_first', split_part(coalesce((select full_name from customers where id = v_lead.customer_id),''),' ',1),
    'company', v_q.company_name,
    'warranty_years', v_q.warranty_years,
    'panel', coalesce(v_q.preferred_equipment->>'panel_sku', public.equipment_label(v_q.components->'panel')),
    'inverter', coalesce(v_q.preferred_equipment->>'inverter_sku', public.equipment_label(v_q.components->'inverter')),
    'battery', coalesce(v_q.preferred_equipment->>'battery_sku', public.equipment_label(v_q.components->'battery')),
    'system_kw', v_q.system_kw, 'battery_kwh', v_q.battery_kwh,
    'price_before_cents', v_q.price_before_rebates_cents,
    'price_after_cents', v_q.price_after_cents, 'rebate_cents', v_q.rebate_cents,
    'edge_protection_cents', v_edge_cents,
    'edge_perimeter_m', v_perimeter,
    'edge_perimeter_measured', (v_perimeter is not null and v_perimeter > 0),
    'total_payable_cents', v_q.price_after_cents + v_edge_cents,
    'ss_ref', (select ss_ref from sites where id = v_lead.site_id),
    'address', (select address from sites where id = v_lead.site_id),
    'signed', (v_prop.signed_at is not null),
    'signed_at', v_prop.signed_at
  );
end $function$;

-- ---------------------------------------------------------------------------
-- 4. Record the signed total in the append-only event log.
--
-- The `proposal.signed` event previously captured who signed but not what they
-- signed for. With edge protection now part of the payable amount, the exact
-- breakdown the customer agreed to has to be preserved at signature time — a
-- later perimeter re-measure or price-book change must not be able to rewrite
-- history. Events are append-only, so this snapshot is permanent.
-- ---------------------------------------------------------------------------
create or replace function public.customer_sign(p_token uuid, p_full_name text, p_user_agent text, p_consent boolean)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_lead record; v_q record; v_prop record; v_ip text;
  v_edge_cents integer; v_perimeter numeric;
begin
  if not coalesce(p_consent,false) then raise exception 'consent required'; end if;
  if length(coalesce(trim(p_full_name),'')) < 2 then raise exception 'full name required'; end if;
  select * into v_lead from leads where choice_token = p_token;
  if v_lead.id is null then raise exception 'invalid link'; end if;

  select q.*, d.edge_perimeter_m into v_q
    from quotes q
    left join designs d on d.id = q.design_id
    where q.site_id = v_lead.site_id and q.status = 'chosen' order by q.created_at desc limit 1;
  if v_q.id is null then raise exception 'no chosen quote to sign'; end if;

  select * into v_prop from proposals where quote_id = v_q.id order by created_at desc limit 1;
  if v_prop.id is null then raise exception 'no proposal issued'; end if;
  if v_prop.signed_at is not null then
    return jsonb_build_object('company', (select company_name from installers where id = v_q.installer_id), 'already', true);
  end if;

  v_perimeter  := v_q.edge_perimeter_m;
  v_edge_cents := public.edge_protection_cents(v_perimeter);

  begin v_ip := split_part(coalesce(current_setting('request.headers', true)::json->>'x-forwarded-for',''), ',', 1);
  exception when others then v_ip := null; end;

  update proposals set signed_at = now(),
    signature = jsonb_build_object('name', trim(p_full_name), 'ip', nullif(v_ip,''), 'user_agent', p_user_agent, 'ts', now())
  where id = v_prop.id;

  update leads set state = 'signed' where id = v_lead.id and state = 'customer_chose';

  insert into events (site_id, lead_id, actor_type, event_type, payload)
  values (v_lead.site_id, v_lead.id, 'customer', 'proposal.signed',
    jsonb_build_object(
      'proposal_id', v_prop.id, 'quote_id', v_q.id, 'installer_id', v_q.installer_id,
      'name', trim(p_full_name),
      'price_after_cents', v_q.price_after_cents,
      'rebate_cents', v_q.rebate_cents,
      'edge_protection_cents', v_edge_cents,
      'edge_perimeter_m', v_perimeter,
      'total_payable_cents', v_q.price_after_cents + v_edge_cents));

  return jsonb_build_object('company', (select company_name from installers where id = v_q.installer_id));
end $function$;
