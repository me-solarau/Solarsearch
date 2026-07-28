-- Human-readable equipment names on the customer comparison page and the signed
-- agreement.
--
-- Both customer_board() and customer_proposal() fall back to
-- `components->>'panel'` when an installer hasn't set a preferred_equipment SKU.
-- `designs.components` stores objects, e.g.
--   {"panel": {"brand":"Jinko","model":"JKM440","qty":15}}
-- so `->>'panel'` returns the object serialised as text and the customer saw
--   {"qty": 15, "brand": "Jinko", "model": "JKM440"}
-- on choose.html — and, worse, on the agreement they sign.
--
-- equipment_label() renders "Brand Model" from an object, passes plain strings
-- through untouched, and returns null when there's nothing to show (so the
-- pages' existing `|| '—'` fallback still applies).

create or replace function public.equipment_label(p jsonb)
returns text language sql immutable set search_path = public as $$
  select case
    when p is null or jsonb_typeof(p) = 'null' then null
    when jsonb_typeof(p) = 'object'
      then nullif(btrim(concat_ws(' ', p->>'brand', p->>'model')), '')
    when jsonb_typeof(p) = 'string' then nullif(p #>> '{}', '')
    else nullif(p::text, '')
  end;
$$;

grant execute on function public.equipment_label(jsonb) to anon, authenticated;

-- ---- customer_board: readable equipment (keeps the 0071 ORDER BY fix) ----
create or replace function public.customer_board(p_token uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_site_id uuid; v_lead record; v_design record; v_quotes jsonb;
begin
  select * into v_lead from leads where choice_token = p_token;
  if v_lead.id is null then return jsonb_build_object('error','invalid link'); end if;
  v_site_id := v_lead.site_id;
  select * into v_design from designs where site_id = v_site_id order by created_at desc limit 1;

  select coalesce(jsonb_agg(row order by t.price_after_cents), '[]'::jsonb) into v_quotes
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

-- ---- customer_proposal: same treatment for the signed agreement ----
create or replace function public.customer_proposal(p_token uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_lead record; v_q record; v_prop record;
begin
  select * into v_lead from leads where choice_token = p_token;
  if v_lead.id is null then return jsonb_build_object('error','invalid link'); end if;

  select q.*, i.company_name,
         coalesce((pb.preferred_equipment->>'warranty_years')::int,(i.brand_kit->>'warranty_years')::int,10) as warranty_years,
         pb.preferred_equipment, d.components, d.system_kw, d.battery_kwh
  into v_q
  from quotes q
  join installers i on i.id = q.installer_id
  left join price_books pb on pb.id = q.price_book_id
  left join designs d on d.id = q.design_id
  where q.site_id = v_lead.site_id and q.status = 'chosen'
  order by q.created_at desc limit 1;
  if v_q.id is null then return jsonb_build_object('error','no chosen quote yet'); end if;

  select * into v_prop from proposals where quote_id = v_q.id order by created_at desc limit 1;

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
    'ss_ref', (select ss_ref from sites where id = v_lead.site_id),
    'address', (select address from sites where id = v_lead.site_id),
    'signed', (v_prop.signed_at is not null),
    'signed_at', v_prop.signed_at
  );
end $$;

revoke all on function public.customer_proposal(uuid) from public;
grant execute on function public.customer_proposal(uuid) to anon, authenticated;
