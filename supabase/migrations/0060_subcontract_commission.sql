-- Solarsearch commission on retailer-subcontracted installs: 10% of job value, split 5%
-- (retailer) + 5% (subcontractor). Requires a clear acceptance -> submission audit path so
-- Solarsearch can audit and invoice both parties against the evidenced job.
alter table public.pricing_config add column if not exists subcontract_commission_pct numeric(5,2) not null default 10;
alter table public.pricing_config add column if not exists subcontract_retailer_pct   numeric(5,2) not null default 5;
alter table public.pricing_config add column if not exists subcontract_subbie_pct      numeric(5,2) not null default 5;

-- Audit path fields on the install.
alter table public.installs add column if not exists retailer_id uuid references public.retailers(id);
alter table public.installs add column if not exists accepted_at timestamptz;
alter table public.installs add column if not exists job_value_cents int;

-- Acceptance step (subcontractor accepts the job) — starts the audit window + the 10% deposit.
create or replace function public.accept_install(p_install uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_i record;
begin
  select * into v_i from installs where id = p_install;
  if v_i.id is null then raise exception 'install not found'; end if;
  if not (public.is_admin() or v_i.installer_id = public.current_installer_id()) then raise exception 'not your install'; end if;
  if v_i.accepted_at is not null then return jsonb_build_object('ok', true, 'already', true); end if;
  update installs set accepted_at = now() where id = p_install;
  insert into events (site_id, lead_id, actor_type, actor_id, event_type, payload)
  select l.site_id, v_i.lead_id, 'installer', v_i.installer_id::text, 'install.accepted',
         jsonb_build_object('install_id', p_install, 'pipeline', v_i.pipeline)
  from leads l where l.id = v_i.lead_id;
  return jsonb_build_object('ok', true);
end $$;

-- Commission audit/invoice basis: submitted subcontracted installs with the 10% / 5% / 5%
-- amounts and the acceptance->submission window. security_invoker so RLS (installer/admin) applies.
create or replace view public.subcontract_commission
with (security_invoker = on) as
select i.id as install_id, i.retailer_id, i.installer_id as subcontractor_id,
       i.job_value_cents, i.accepted_at, i.submitted_at,
       round(coalesce(i.job_value_cents,0) * (select subcontract_commission_pct from pricing_config)/100.0) as commission_cents,
       round(coalesce(i.job_value_cents,0) * (select subcontract_retailer_pct   from pricing_config)/100.0) as retailer_cents,
       round(coalesce(i.job_value_cents,0) * (select subcontract_subbie_pct      from pricing_config)/100.0) as subcontractor_cents
from installs i
where i.pipeline = 'subcontractor' and i.submitted_at is not null;
