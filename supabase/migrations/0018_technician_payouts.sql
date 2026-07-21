-- ============================================================================
-- Technician payout ledger (scope §6, §8 Phase 2). Batches unbilled completed/
-- no-access assessments into a payout per technician for a period, then marks
-- paid. The actual Stripe Connect transfer is stubbed (mark_payout_paid records
-- the reference) — payouts run outside Apple IAP (§3.6). Admin-only in effect:
-- both functions write payouts/payout_items whose RLS is admin_all.
-- ============================================================================

create or replace function public.create_payout_batches(p_period_start date, p_period_end date, p_staff_id uuid default null)
returns jsonb
language plpgsql set search_path = public as $$
declare v_rep record; v_pid uuid; v_total int; v_batches int := 0; v_paid int := 0;
begin
  for v_rep in (
    select distinct sales_rep_id from assessments
    where payout_id is null and fee_cents is not null and sales_rep_id is not null
      and submitted_at::date between p_period_start and p_period_end
  ) loop
    select coalesce(sum(fee_cents),0) into v_total from assessments
      where sales_rep_id = v_rep.sales_rep_id and payout_id is null and fee_cents is not null
        and submitted_at::date between p_period_start and p_period_end;
    if v_total <= 0 then continue; end if;

    insert into payouts (sales_rep_id, period_start, period_end, status, total_cents)
    values (v_rep.sales_rep_id, p_period_start, p_period_end, 'pending', v_total)
    returning id into v_pid;

    insert into payout_items (payout_id, assessment_id, description, amount_cents)
    select v_pid, a.id,
           coalesce(a.outcome,'assessment') || ' — ' ||
             coalesce((select s.ss_ref from sites s join leads l on l.site_id = s.id where l.id = a.lead_id), ''),
           a.fee_cents
    from assessments a
    where a.sales_rep_id = v_rep.sales_rep_id and a.payout_id is null and a.fee_cents is not null
      and a.submitted_at::date between p_period_start and p_period_end;

    update assessments set payout_id = v_pid
    where sales_rep_id = v_rep.sales_rep_id and payout_id is null and fee_cents is not null
      and submitted_at::date between p_period_start and p_period_end;

    v_batches := v_batches + 1; v_paid := v_paid + v_total;
  end loop;
  return jsonb_build_object('batches', v_batches, 'total_cents', v_paid);
end $$;
revoke all on function public.create_payout_batches(date,date,uuid) from public;
grant execute on function public.create_payout_batches(date,date,uuid) to authenticated;

-- Mark a payout paid. Real Stripe Connect transfer is stubbed — this records
-- the reference and stamps paid_at.
create or replace function public.mark_payout_paid(p_payout_id uuid, p_ref text default null)
returns void
language plpgsql set search_path = public as $$
begin
  update payouts set status = 'paid', paid_at = now(),
    stripe_transfer_ref = coalesce(p_ref, stripe_transfer_ref)
  where id = p_payout_id;
  if not found then raise exception 'payout not found'; end if;
end $$;
revoke all on function public.mark_payout_paid(uuid,text) from public;
grant execute on function public.mark_payout_paid(uuid,text) to authenticated;
