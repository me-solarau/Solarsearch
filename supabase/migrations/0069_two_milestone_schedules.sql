-- Two payment-milestone schedules, by pipeline. The main-pipeline installer fronts the full
-- system materials (big cash outlay); a subcontractor does not (minor material only), so they
-- differ:
--   Installer (main):     10% acceptance · 40% materials ordered/scheduled · 50% completion
--   Subcontractor (sub):  10% acceptance · 60% completion · 30% STC (retailer release)
-- DER registration is NOT a payment gate (final compliance step, within 21 days of completion).

-- Installer-pipeline percentages (subcontract keeps milestone_deposit/completion/stc = 10/60/30).
alter table public.pricing_config add column if not exists milestone_installer_deposit_pct    numeric(5,2) not null default 10;
alter table public.pricing_config add column if not exists milestone_installer_materials_pct   numeric(5,2) not null default 40;
alter table public.pricing_config add column if not exists milestone_installer_completion_pct  numeric(5,2) not null default 50;

-- Allow the new 'materials' milestone.
alter table public.payment_milestones drop constraint if exists payment_milestones_milestone_check;
alter table public.payment_milestones add constraint payment_milestones_milestone_check
  check (milestone in ('deposit','materials','completion','stc'));

-- Rebuild milestones per pipeline. Clears only 'pending' rows (never touches processing/paid);
-- application_fee (subcontract commission) rides only on the subcontractor schedule.
create or replace function public.build_payment_milestones(p_install uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_i record; v_cfg record; v_comm_pct numeric(5,2); v_jv int;
begin
  select * into v_i from installs where id = p_install;
  if v_i.id is null then raise exception 'install not found'; end if;
  if not (public.is_admin()
          or v_i.installer_id = public.current_installer_id()
          or v_i.retailer_id  = public.current_retailer_id()) then
    raise exception 'not your install';
  end if;
  if coalesce(v_i.job_value_cents,0) <= 0 then raise exception 'job_value_cents not set'; end if;
  v_jv := v_i.job_value_cents;
  select * into v_cfg from pricing_config limit 1;

  delete from payment_milestones where install_id = p_install and status = 'pending';

  if v_i.pipeline = 'subcontractor' then
    v_comm_pct := coalesce(v_cfg.subcontract_commission_pct, 10);
    insert into payment_milestones (install_id, milestone, pct, amount_cents, application_fee_cents)
    values
      (p_install,'deposit',    v_cfg.milestone_deposit_pct,
         round(v_jv * v_cfg.milestone_deposit_pct/100.0),
         round(v_jv * v_cfg.milestone_deposit_pct/100.0 * v_comm_pct/100.0)),
      (p_install,'completion', v_cfg.milestone_completion_pct,
         round(v_jv * v_cfg.milestone_completion_pct/100.0),
         round(v_jv * v_cfg.milestone_completion_pct/100.0 * v_comm_pct/100.0)),
      (p_install,'stc',        v_cfg.milestone_stc_pct,
         round(v_jv * v_cfg.milestone_stc_pct/100.0),
         round(v_jv * v_cfg.milestone_stc_pct/100.0 * v_comm_pct/100.0))
    on conflict (install_id, milestone) do nothing;
  else
    -- main installer pipeline: 10 / 40 / 50, no per-milestone commission
    insert into payment_milestones (install_id, milestone, pct, amount_cents, application_fee_cents)
    values
      (p_install,'deposit',    v_cfg.milestone_installer_deposit_pct,
         round(v_jv * v_cfg.milestone_installer_deposit_pct/100.0), 0),
      (p_install,'materials',  v_cfg.milestone_installer_materials_pct,
         round(v_jv * v_cfg.milestone_installer_materials_pct/100.0), 0),
      (p_install,'completion', v_cfg.milestone_installer_completion_pct,
         round(v_jv * v_cfg.milestone_installer_completion_pct/100.0), 0)
    on conflict (install_id, milestone) do nothing;
  end if;

  return jsonb_build_object('ok', true, 'install_id', p_install, 'pipeline', v_i.pipeline);
end $$;
