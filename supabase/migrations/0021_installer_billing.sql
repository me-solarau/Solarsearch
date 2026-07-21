-- ============================================================================
-- Installer billing feed: the seats they bought ($200 each) and the winner
-- commissions they owe on won jobs ($1.10/STC), for the installer's own
-- account. SECURITY DEFINER + scoped to current_installer_id, so seats/deals
-- base-table RLS stays staff-only.
-- ============================================================================
create or replace function public.installer_billing()
returns jsonb
language sql stable security definer set search_path = public as $$
  with me as (select current_installer_id() as iid)
  select coalesce(jsonb_agg(row order by row->>'date' desc), '[]'::jsonb)
  from (
    select jsonb_build_object(
      'date', se.purchased_at, 'kind', 'seat',
      'ref', (select ss_ref from sites where id = se.site_id),
      'description', 'Seat — Site Quoted board',
      'amount_cents', se.price_cents, 'status', 'paid'
    ) as row
    from seats se where se.installer_id = (select iid from me)
    union all
    select jsonb_build_object(
      'date', d.signed_at, 'kind', 'commission',
      'ref', (select ss_ref from sites where id = d.site_id),
      'description', 'Winner commission ($1.10/STC)',
      'amount_cents', d.commission_cents, 'status', d.invoice_status
    ) as row
    from deals d where d.installer_id = (select iid from me)
  ) t;
$$;
revoke all on function public.installer_billing() from public;
grant execute on function public.installer_billing() to authenticated;
