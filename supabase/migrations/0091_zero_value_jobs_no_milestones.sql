-- Zero-value jobs are legitimate: onboarding/test runs and goodwill work where
-- no money should move. The milestone engine previously raised on them, which
-- made accept_job explode on a $0 job. A job with no value now simply builds
-- no payment milestones — every other part of the flow (schedule, evidence,
-- verification, completion) runs unchanged.
create or replace function public.build_payment_milestones(p_install uuid)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare v_i record; v_cfg record; v_comm_pct numeric(5,2); v_jv int;
begin
  select * into v_i from installs where id = p_install;
  if v_i.id is null then raise exception 'install not found'; end if;
  if not (public.is_admin()
          or v_i.installer_id = public.current_installer_id()
          or v_i.retailer_id  = public.current_retailer_id()) then
    raise exception 'not your install';
  end if;
  if coalesce(v_i.job_value_cents,0) <= 0 then
    return jsonb_build_object('ok', true, 'install_id', p_install,
      'milestones', 'skipped — zero-value job, no charges apply');
  end if;
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
end $function$;
