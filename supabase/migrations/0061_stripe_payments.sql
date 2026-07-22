-- Stripe Connect wiring: connected-account IDs, per-milestone payment ledger, and
-- webhook idempotency. Money movement lives in the edge functions (stripe-onboard,
-- create-milestone-payment, stripe-webhook); this migration is the DB side of record.
--
-- Milestones map 1:1 to install events that already exist:
--   deposit    10%  <- install.accepted  (accept_install)
--   completion 60%  <- install.submitted (submit_install)  [job complete = app submitted]
--   stc        30%  <- STC verification
-- Commission on the retailer-subcontract pipeline is the Stripe application_fee on each
-- slice (10% total = 5% retailer + 5% subcontractor, per pricing_config / 0060).

-- Connected-account IDs for everyone who receives money.
alter table public.installers add column if not exists stripe_account_id text;
alter table public.retailers  add column if not exists stripe_account_id text;

-- A retailer identity helper mirroring current_installer_id(), so RLS can scope rows
-- to the signed-in retailer.
create or replace function public.current_retailer_id() returns uuid
language sql stable security definer set search_path=public as $$
  select id from public.retailers where user_id = auth.uid()
   and status in ('approved','conditionally_active','active') limit 1
$$;

-- Milestone percentages live in pricing_config so they're tunable without a deploy.
alter table public.pricing_config add column if not exists milestone_deposit_pct    numeric(5,2) not null default 10;
alter table public.pricing_config add column if not exists milestone_completion_pct numeric(5,2) not null default 60;
alter table public.pricing_config add column if not exists milestone_stc_pct        numeric(5,2) not null default 30;

-- One row per milestone per install. amount_cents is the customer/retailer charge for the
-- slice; application_fee_cents is Solarsearch's cut on that slice (subcontract pipeline only).
create table if not exists public.payment_milestones (
  id                       uuid primary key default gen_random_uuid(),
  install_id               uuid not null references public.installs(id) on delete cascade,
  milestone                text not null check (milestone in ('deposit','completion','stc')),
  pct                      numeric(5,2) not null,
  amount_cents             int not null,
  application_fee_cents    int not null default 0,
  status                   text not null default 'pending'
                             check (status in ('pending','processing','paid','failed','refunded','canceled')),
  stripe_payment_intent_id text,
  paid_at                  timestamptz,
  created_at               timestamptz not null default now(),
  unique (install_id, milestone)
);
create index if not exists payment_milestones_install on public.payment_milestones(install_id);
create index if not exists payment_milestones_status  on public.payment_milestones(status);

alter table public.payment_milestones enable row level security;

-- Admin sees all; the install's installer and its retailer see their own milestones.
drop policy if exists pm_read on public.payment_milestones;
create policy pm_read on public.payment_milestones for select
  using (
    public.is_admin()
    or exists (select 1 from public.installs i where i.id = install_id
                 and (i.installer_id = public.current_installer_id()
                      or i.retailer_id = public.current_retailer_id())));

-- Only server-side (service role / SECURITY DEFINER) writes milestones; no client writes.
drop policy if exists pm_no_client_write on public.payment_milestones;
create policy pm_no_client_write on public.payment_milestones for all
  using (public.is_admin()) with check (public.is_admin());

-- Build (or refresh) the three milestone rows for an install from its job_value_cents.
-- application_fee_cents is charged only on the subcontractor pipeline (retailer's commission
-- share rides on the retailer-paid slices; kept simple here as the full 10% commission split
-- pro-rated across milestones). Idempotent: recomputes pending rows, never touches paid ones.
create or replace function public.build_payment_milestones(p_install uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_i   record;
  v_cfg record;
  v_comm_pct numeric(5,2);
begin
  select * into v_i from installs where id = p_install;
  if v_i.id is null then raise exception 'install not found'; end if;
  if not (public.is_admin()
          or v_i.installer_id = public.current_installer_id()
          or v_i.retailer_id  = public.current_retailer_id()) then
    raise exception 'not your install';
  end if;
  if coalesce(v_i.job_value_cents,0) <= 0 then raise exception 'job_value_cents not set'; end if;

  select * into v_cfg from pricing_config limit 1;
  -- Full commission percentage only applies to the subcontractor pipeline.
  v_comm_pct := case when v_i.pipeline = 'subcontractor'
                     then coalesce(v_cfg.subcontract_commission_pct,10) else 0 end;

  insert into payment_milestones (install_id, milestone, pct, amount_cents, application_fee_cents)
  values
    (p_install,'deposit',    v_cfg.milestone_deposit_pct,
       round(v_i.job_value_cents * v_cfg.milestone_deposit_pct/100.0),
       round(v_i.job_value_cents * v_cfg.milestone_deposit_pct/100.0 * v_comm_pct/100.0)),
    (p_install,'completion', v_cfg.milestone_completion_pct,
       round(v_i.job_value_cents * v_cfg.milestone_completion_pct/100.0),
       round(v_i.job_value_cents * v_cfg.milestone_completion_pct/100.0 * v_comm_pct/100.0)),
    (p_install,'stc',        v_cfg.milestone_stc_pct,
       round(v_i.job_value_cents * v_cfg.milestone_stc_pct/100.0),
       round(v_i.job_value_cents * v_cfg.milestone_stc_pct/100.0 * v_comm_pct/100.0))
  on conflict (install_id, milestone) do update
    set pct = excluded.pct,
        amount_cents = excluded.amount_cents,
        application_fee_cents = excluded.application_fee_cents
    where payment_milestones.status = 'pending';

  return jsonb_build_object('ok', true, 'install_id', p_install);
end $$;

-- Webhook idempotency: record each Stripe event id once so retried deliveries are no-ops.
create table if not exists public.stripe_events (
  id         text primary key,        -- Stripe event id (evt_...)
  type       text,
  created_at timestamptz not null default now()
);
alter table public.stripe_events enable row level security;
-- Server-only table; no client policies (service role bypasses RLS).
