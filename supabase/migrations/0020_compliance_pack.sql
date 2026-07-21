-- ============================================================================
-- Compliance / close-out pack (pack.html). Token-gated (the lead's choice_token,
-- so the customer can open their own copy; HQ opens it with the same token).
-- Assembles the whole verified job record — identity, design, chosen installer
-- + equipment + price, the e-signature with its capture metadata, DNSP/DERR
-- lodgement, a photo-evidence summary (step + verdict + note + timestamp/GPS —
-- raw images stay in the locked private record), and the milestone timeline.
-- Internal figures (commission) are intentionally excluded — this is the
-- customer-facing verification summary.
-- ============================================================================
create or replace function public.compliance_pack(p_token uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_lead record; v_site record; v_design record; v_q record; v_prop record; v_conn record;
        v_evidence jsonb; v_timeline jsonb;
begin
  select * into v_lead from leads where choice_token = p_token;
  if v_lead.id is null then return jsonb_build_object('error','invalid link'); end if;
  select * into v_site from sites where id = v_lead.site_id;
  select * into v_design from designs where site_id = v_lead.site_id order by created_at desc limit 1;

  select q.*, i.company_name,
         coalesce((pb.preferred_equipment->>'warranty_years')::int,(i.brand_kit->>'warranty_years')::int,10) as warranty_years,
         pb.preferred_equipment, d.components
  into v_q
  from quotes q
  join installers i on i.id = q.installer_id
  left join price_books pb on pb.id = q.price_book_id
  left join designs d on d.id = q.design_id
  where q.site_id = v_lead.site_id and q.status = 'chosen'
  order by q.created_at desc limit 1;

  select * into v_prop from proposals p where p.quote_id = v_q.id order by p.created_at desc limit 1;
  select * into v_conn from connection_applications where site_id = v_lead.site_id order by created_at desc limit 1;

  -- photo evidence: technician assessment photos + consultant inspection photos
  v_evidence :=
    coalesce((select jsonb_agg(jsonb_build_object(
        'source','site assessment','step',ap.step_key,'verdict',ap.ai_verdict,
        'note',ap.note,'na',ap.na_reason,'taken_at',ap.taken_at,
        'gps', case when ap.lat is not null then jsonb_build_object('lat',ap.lat,'lng',ap.lng) else null end
      ) order by ap.created_at)
      from assessment_photos ap join assessments a on a.id = ap.assessment_id where a.lead_id = v_lead.id),'[]'::jsonb)
    ||
    coalesce((select jsonb_agg(jsonb_build_object(
        'source','inspection','step',p.step_key,'verdict',p.assessment,
        'note',p.note,'taken_at',p.taken_at,
        'gps', case when p.lat is not null then jsonb_build_object('lat',p.lat,'lng',p.lng) else null end
      ) order by p.created_at)
      from photos p join inspections i on i.id = p.inspection_id where i.site_id = v_lead.site_id),'[]'::jsonb);

  v_timeline := coalesce((select jsonb_agg(jsonb_build_object('event',e.event_type,'at',e.created_at,'payload',e.payload) order by e.created_at)
    from events e where e.lead_id = v_lead.id
      and e.event_type in ('assessment.booked','assessment.submitted','inspection.completed','design.completed',
                           'board.opened','customer.chose','proposal.signed','post_sale.advanced')),'[]'::jsonb);

  return jsonb_build_object(
    'ss_ref', v_site.ss_ref,
    'address', v_site.address,
    'postcode', v_site.postcode,
    'customer_name', (select full_name from customers where id = v_lead.customer_id),
    'state', v_lead.state,
    'system_kw', v_design.system_kw, 'battery_kwh', v_design.battery_kwh,
    'rules_version', v_q.rules_version,
    'installer', jsonb_build_object(
      'company', v_q.company_name, 'warranty_years', v_q.warranty_years,
      'panel', coalesce(v_q.preferred_equipment->>'panel_sku', v_q.components->>'panel'),
      'inverter', coalesce(v_q.preferred_equipment->>'inverter_sku', v_q.components->>'inverter'),
      'battery', coalesce(v_q.preferred_equipment->>'battery_sku', v_q.components->>'battery'),
      'price_before_cents', v_q.price_before_rebates_cents, 'rebate_cents', v_q.rebate_cents,
      'price_after_cents', v_q.price_after_cents, 'stc_count', v_q.stc_count),
    'agreement', jsonb_build_object(
      'signed', (v_prop.signed_at is not null), 'signed_at', v_prop.signed_at,
      'signed_name', v_prop.signature->>'name', 'signed_ip', v_prop.signature->>'ip'),
    'lodgement', jsonb_build_object(
      'connection_status', v_conn.status, 'connection_reference', v_conn.reference,
      'export_limit_kw', v_conn.export_limit_kw, 'der_registered_at', v_conn.der_registered_at),
    'evidence', v_evidence,
    'timeline', v_timeline,
    'generated_at', now()
  );
end $$;
revoke all on function public.compliance_pack(uuid) from public;
grant execute on function public.compliance_pack(uuid) to anon, authenticated;
