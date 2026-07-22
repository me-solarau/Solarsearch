-- Enforce the integrity clause of the tech T&Cs: dishonesty, tampering or fraud => immediate
-- suspension and/or ban. Enforcement is automatic: current_sales_rep_id() only resolves a rep
-- whose status is approved/active/conditionally_active, so flipping status to 'suspended' or
-- 'banned' instantly cuts off grab_job, start_visit, submit_assessment and the job pool.
--   * suspended = reversible hold.  * banned = permanent, terminal.

alter table public.sales_reps drop constraint if exists sales_reps_status_check;
alter table public.sales_reps add constraint sales_reps_status_check
  check (status = any (array['registered','docs_submitted','under_review','approved',
                            'conditionally_active','active','suspended','banned','rejected']));

-- Audit trail for every status change (defensible record for a dispute over a ban).
create table if not exists public.tech_status_log (
  id uuid primary key default gen_random_uuid(),
  rep_id uuid not null references public.sales_reps(id) on delete cascade,
  from_status text,
  to_status text not null,
  reason text,
  changed_by uuid,
  created_at timestamptz not null default now()
);
alter table public.tech_status_log enable row level security;
drop policy if exists tech_status_log_admin on public.tech_status_log;
create policy tech_status_log_admin on public.tech_status_log for all
  using (public.is_admin()) with check (public.is_admin());

-- Admin: suspend / ban / reinstate a technician, with a logged reason.
create or replace function public.set_tech_status(p_rep uuid, p_status text, p_reason text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_old text;
begin
  if not public.is_admin() then raise exception 'not authorised'; end if;
  if p_status not in ('suspended','banned','approved','active','conditionally_active') then
    raise exception 'invalid status %', p_status;
  end if;
  select status into v_old from sales_reps where id = p_rep;
  if v_old is null then raise exception 'technician not found'; end if;
  update sales_reps set status = p_status where id = p_rep;
  insert into tech_status_log (rep_id, from_status, to_status, reason, changed_by)
    values (p_rep, v_old, p_status, nullif(trim(coalesce(p_reason,'')), ''), auth.uid());
  return jsonb_build_object('ok', true, 'from', v_old, 'to', p_status);
end $$;
