-- Fix: customer_board() raised "missing FROM-clause entry for table q" and so
-- the customer quote-comparison page (choose.html) failed for EVERY customer.
--
-- The aggregate ordered by `q.price_after_cents`, but `q` only exists inside the
-- derived table, which is exposed to the outer query as `t` (columns: row,
-- price_after_cents). Postgres only raises this at execution time, which is why
-- it survived until the funnel was first run end to end.
--
-- Only the ORDER BY reference changes (q. -> t.); the payload is untouched, so
-- cheapest-first ordering now works as intended.

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
