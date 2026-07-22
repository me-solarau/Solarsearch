-- Reframe the drone financing to match the legal footing (see docs/TECH_TOOLKIT.md):
--   * Having a drone is a CONDITION of engagement — the tech's own obligation. They may
--     supply their own drone; tech_kit_ready() checks the kit, never the loan.
--   * Solarsearch's financial assistance is an OPTIONAL PRIVILEGE the tech opts into.
-- To satisfy Fair Work s324 (written, voluntary authorisation) and revocability, a
-- deduction only runs when the loan carries a recorded authorisation that hasn't been
-- revoked. Revoking stops deductions immediately; the residual balance is then a normal
-- debt settled off-ledger, not a forced ongoing deduction.

alter table public.drone_loans add column if not exists deduction_authorised boolean not null default false;
alter table public.drone_loans add column if not exists authorised_at timestamptz;
alter table public.drone_loans add column if not exists authorisation_ref text;   -- link/id of the signed, voluntary agreement

-- Accrue only against an active loan that has a live, recorded authorisation.
create or replace function public.drone_loan_accrue(p_rep uuid, p_job_cents int)
returns int language plpgsql security definer set search_path=public as $$
declare v_loan record; v_amt int;
begin
  select * into v_loan from drone_loans
    where rep_id = p_rep and status = 'active'
      and deduction_authorised = true and authorised_at is not null
    for update;
  if not found then return 0; end if;   -- no loan, or authorisation not given / revoked -> no deduction
  v_amt := least(v_loan.per_job_cents, v_loan.principal_cents - v_loan.paid_cents, greatest(coalesce(p_job_cents,0),0));
  if v_amt <= 0 then return 0; end if;
  update drone_loans set
    paid_cents = paid_cents + v_amt,
    status     = case when paid_cents + v_amt >= principal_cents then 'paid' else 'active' end,
    paid_at    = case when paid_cents + v_amt >= principal_cents then now() else paid_at end
  where id = v_loan.id;
  return v_amt;
end $$;

-- Admin records or revokes the tech's voluntary authorisation. Recording sets the
-- signed-agreement ref + timestamp; revoking stops future deductions on the spot.
create or replace function public.drone_loan_set_authorisation(p_loan uuid, p_authorised boolean, p_ref text default null)
returns void language plpgsql security definer set search_path=public as $$
begin
  if not public.is_admin() then raise exception 'not authorised'; end if;
  update drone_loans set
    deduction_authorised = p_authorised,
    authorised_at        = case when p_authorised then coalesce(authorised_at, now()) else authorised_at end,
    authorisation_ref    = coalesce(p_ref, authorisation_ref)
  where id = p_loan;
end $$;
