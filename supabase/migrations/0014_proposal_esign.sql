-- ============================================================================
-- Native proposal + e-signature (sign.html magic link). After the customer
-- chooses, a proposal is issued in the winning installer's name; the customer
-- signs it on a token-gated page and the lead advances to 'signed'. ETA-style
-- capture: name + IP (x-forwarded-for) + user agent + timestamp. Docusign
-- remains a possible future channel ('pylon'/external); this is the 'native' one.
-- ============================================================================

-- customer_choose now also issues the native proposal for the chosen quote, so
-- the customer flows choose -> sign in one session. (Redefines the function from
-- 0013 with the proposal insert appended.)
create or replace function public.customer_choose(p_token uuid, p_quote_id uuid, p_consent boolean)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_lead record; v_site_id uuid; v_quote record; v_snap_id uuid; v_deal_commission int;
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

  -- issue the native proposal for e-signature (agent model: in the installer's name)
  insert into proposals (quote_id, channel, template_version, brand_kit_version, issued_at)
  values (p_quote_id, 'native', 'native-v1',
          (select brand_kit->>'version' from installers where id = v_quote.installer_id), now());

  update leads set state = 'customer_chose' where id = v_lead.id;

  insert into events (site_id, lead_id, actor_type, event_type, payload)
  values (v_site_id, v_lead.id, 'customer', 'customer.chose',
    jsonb_build_object('quote_id', p_quote_id, 'installer_id', v_quote.installer_id, 'snapshot_id', v_snap_id, 'consent_version', 'v3.2'));

  return jsonb_build_object('company', (select company_name from installers where id = v_quote.installer_id));
end $$;
revoke all on function public.customer_choose(uuid, uuid, boolean) from public;
grant execute on function public.customer_choose(uuid, uuid, boolean) to anon, authenticated;

-- What the customer sees on the sign page: their chosen quote + installer +
-- the proposal's signed state. Token-scoped, no other customer's data.
create or replace function public.customer_proposal(p_token uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_lead record; v_q record; v_prop record;
begin
  select * into v_lead from leads where choice_token = p_token;
  if v_lead.id is null then return jsonb_build_object('error','invalid link'); end if;

  select q.*, i.company_name, coalesce((i.brand_kit->>'warranty_years')::int,10) as warranty_years,
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
    'panel', coalesce(v_q.preferred_equipment->>'panel_sku', v_q.components->>'panel'),
    'inverter', coalesce(v_q.preferred_equipment->>'inverter_sku', v_q.components->>'inverter'),
    'battery', coalesce(v_q.preferred_equipment->>'battery_sku', v_q.components->>'battery'),
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

-- Sign the proposal: consent + typed full name. Captures name/IP/UA/timestamp,
-- marks the proposal signed, and advances the lead customer_chose -> signed.
create or replace function public.customer_sign(p_token uuid, p_full_name text, p_user_agent text, p_consent boolean)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_lead record; v_q record; v_prop record; v_ip text;
begin
  if not coalesce(p_consent,false) then raise exception 'consent required'; end if;
  if length(coalesce(trim(p_full_name),'')) < 2 then raise exception 'full name required'; end if;
  select * into v_lead from leads where choice_token = p_token;
  if v_lead.id is null then raise exception 'invalid link'; end if;

  select q.* into v_q from quotes q
    where q.site_id = v_lead.site_id and q.status = 'chosen' order by q.created_at desc limit 1;
  if v_q.id is null then raise exception 'no chosen quote to sign'; end if;

  select * into v_prop from proposals where quote_id = v_q.id order by created_at desc limit 1;
  if v_prop.id is null then raise exception 'no proposal issued'; end if;
  if v_prop.signed_at is not null then
    return jsonb_build_object('company', (select company_name from installers where id = v_q.installer_id), 'already', true);
  end if;

  begin v_ip := split_part(coalesce(current_setting('request.headers', true)::json->>'x-forwarded-for',''), ',', 1);
  exception when others then v_ip := null; end;

  update proposals set signed_at = now(),
    signature = jsonb_build_object('name', trim(p_full_name), 'ip', nullif(v_ip,''), 'user_agent', p_user_agent, 'ts', now())
  where id = v_prop.id;

  update leads set state = 'signed' where id = v_lead.id and state = 'customer_chose';

  insert into events (site_id, lead_id, actor_type, event_type, payload)
  values (v_lead.site_id, v_lead.id, 'customer', 'proposal.signed',
    jsonb_build_object('proposal_id', v_prop.id, 'quote_id', v_q.id, 'installer_id', v_q.installer_id, 'name', trim(p_full_name)));

  return jsonb_build_object('company', (select company_name from installers where id = v_q.installer_id));
end $$;
revoke all on function public.customer_sign(uuid, text, text, boolean) from public;
grant execute on function public.customer_sign(uuid, text, text, boolean) to anon, authenticated;
