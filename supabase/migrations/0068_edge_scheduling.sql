-- Edge-protection scheduling. Flow:
--   1. Installer nominates an install date for a won job — MIN 7 days notice — to the edge team.
--   2. The edge protection team receives the request and approves (or declines) it.
--   3. On approval it's a contractual obligation for Solarsearch to provide the service.
-- Billing party follows the pipeline (installer on main jobs, retailer on subcontracted jobs);
-- captured here, charged in the edge-protection billing build.

-- Edge protection team = a granted edge_protection application (or admin).
create or replace function public.is_edge_protection() returns boolean
language sql stable security definer set search_path=public as $$
  select public.is_admin() or exists (
    select 1 from access_applications
    where user_id = auth.uid() and app = 'edge_protection' and status = 'granted');
$$;

-- my_access() += edge_protection, cleaner, so the client guards admit these roles.
create or replace function public.my_access()
returns jsonb language sql stable security definer set search_path=public as $$
  select jsonb_build_object(
    'admin',           public.is_admin(),
    'sales_rep',       public.current_sales_rep_id() is not null,
    'installer',       public.current_installer_id() is not null,
    'retailer',        public.current_retailer_id()  is not null,
    'edge_protection', public.is_edge_protection(),
    'cleaner',         exists (select 1 from access_applications
                               where user_id = auth.uid() and app = 'cleaner' and status = 'granted')
  );
$$;

-- decide_access(): edge_protection / cleaner grants get a user_roles row (only if none exists,
-- so we never demote), so login routes them to their app.
create or replace function public.decide_access(p_id uuid, p_granted boolean, p_note text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_app record; v_prov text := 'none';
begin
  if not public.is_admin() then raise exception 'not authorised'; end if;
  select * into v_app from access_applications where id = p_id;
  if v_app.id is null then raise exception 'application not found'; end if;

  if not p_granted then
    update access_applications set status='denied', decided_by=auth.uid(), decided_at=now(),
      note=coalesce(p_note, note) where id = p_id;
    return jsonb_build_object('ok', true, 'status', 'denied');
  end if;

  if v_app.terms_accepted_at is null then
    raise exception 'applicant must accept the Terms & Conditions before access can be granted';
  end if;

  update access_applications set status='granted', decided_by=auth.uid(), decided_at=now(),
    note=coalesce(p_note, note) where id = p_id;

  begin
    if v_app.app = 'sales_tech' then
      if exists (select 1 from sales_reps where user_id = v_app.user_id) then
        update sales_reps set status='approved',
          full_name=coalesce(full_name, v_app.full_name), email=coalesce(email, v_app.email),
          phone=coalesce(phone, v_app.phone),
          contractor_terms_at=coalesce(contractor_terms_at, v_app.terms_accepted_at),
          contractor_terms_ref=coalesce(contractor_terms_ref, v_app.terms_ref)
        where user_id = v_app.user_id;
      else
        insert into sales_reps (full_name, email, phone, user_id, status, contractor_terms_at, contractor_terms_ref)
        values (coalesce(v_app.full_name,'Technician'), v_app.email, v_app.phone, v_app.user_id,
                'approved', v_app.terms_accepted_at, v_app.terms_ref);
      end if;
      v_prov := 'sales_rep';
    elsif v_app.app = 'installer' then
      if exists (select 1 from installers where auth_uid = v_app.user_id) then
        update installers set status='approved' where auth_uid = v_app.user_id;
      else
        insert into installers (company_name, contact_email, auth_uid, status)
        values (coalesce(v_app.full_name, v_app.email, 'Installer'), v_app.email, v_app.user_id, 'approved');
      end if;
      v_prov := 'installer';
    elsif v_app.app in ('edge_protection','cleaner') then
      -- dedicated service contractors: no separate identity table; ensure a user_roles row so
      -- login routes them (only if they don't already have one, so we never demote an admin/installer).
      insert into user_roles (user_id, role)
      select v_app.user_id, v_app.app
      where not exists (select 1 from user_roles where user_id = v_app.user_id);
      v_prov := v_app.app;
    end if;
  exception when others then
    update access_applications
      set note = coalesce(note,'') || ' [auto-provision failed: ' || sqlerrm || ' — onboard manually]'
      where id = p_id;
    v_prov := 'failed';
  end;

  return jsonb_build_object('ok', true, 'status', 'granted', 'provisioned', v_prov);
end $$;

-- Bookings: one edge-protection booking per install.
create table if not exists public.edge_protection_bookings (
  id             uuid primary key default gen_random_uuid(),
  install_id     uuid not null references public.installs(id) on delete cascade,
  installer_id   uuid not null references public.installers(id),
  retailer_id    uuid references public.retailers(id),
  billing_party  text not null check (billing_party in ('installer','retailer')),
  scheduled_date date not null,
  linear_m       numeric,
  status         text not null default 'requested'
                   check (status in ('requested','approved','declined','cancelled','completed')),
  notes          text,
  requested_by   uuid,
  requested_at   timestamptz not null default now(),
  decided_by     uuid,
  decided_at     timestamptz,
  decide_note    text,
  unique (install_id)
);
create index if not exists epb_status on public.edge_protection_bookings(status);
create index if not exists epb_installer on public.edge_protection_bookings(installer_id);

alter table public.edge_protection_bookings enable row level security;
drop policy if exists epb_read on public.edge_protection_bookings;
create policy epb_read on public.edge_protection_bookings for select using (
  public.is_admin() or public.is_edge_protection()
  or installer_id = public.current_installer_id()
  or retailer_id  = public.current_retailer_id());
drop policy if exists epb_admin_write on public.edge_protection_bookings;
create policy epb_admin_write on public.edge_protection_bookings for all
  using (public.is_admin()) with check (public.is_admin());

-- Installer nominates an install date (>= 7 days notice) for a won job.
create or replace function public.request_edge_protection(p_install uuid, p_scheduled_date date,
                                                          p_linear_m numeric default null, p_notes text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_i record; v_bp text;
begin
  select * into v_i from installs where id = p_install;
  if v_i.id is null then raise exception 'install not found'; end if;
  if not (public.is_admin() or v_i.installer_id = public.current_installer_id()) then raise exception 'not your install'; end if;
  if v_i.status in ('closed','cancelled') then raise exception 'install is %', v_i.status; end if;
  if p_scheduled_date is null then raise exception 'nominate an installation date'; end if;
  if p_scheduled_date < (current_date + 7) then raise exception 'edge protection needs at least 7 days notice'; end if;

  v_bp := case when v_i.pipeline = 'subcontractor' then 'retailer' else 'installer' end;

  insert into edge_protection_bookings (install_id, installer_id, retailer_id, billing_party,
                                        scheduled_date, linear_m, notes, requested_by, status)
  values (p_install, v_i.installer_id, v_i.retailer_id, v_bp, p_scheduled_date, p_linear_m, p_notes, auth.uid(), 'requested')
  on conflict (install_id) do update set
    scheduled_date = excluded.scheduled_date, linear_m = excluded.linear_m, notes = excluded.notes,
    billing_party = excluded.billing_party, requested_by = excluded.requested_by, requested_at = now(),
    status = case when edge_protection_bookings.status in ('declined','cancelled') then 'requested'
                  else edge_protection_bookings.status end;

  insert into events (site_id, lead_id, actor_type, actor_id, event_type, payload)
  select l.site_id, v_i.lead_id, 'installer', v_i.installer_id::text, 'edge.requested',
         jsonb_build_object('install_id', p_install, 'scheduled_date', p_scheduled_date, 'billing_party', v_bp)
  from leads l where l.id = v_i.lead_id;
  return jsonb_build_object('ok', true, 'billing_party', v_bp);
end $$;

-- Edge team approves (contractual) or declines a request.
create or replace function public.decide_edge_protection(p_booking uuid, p_approve boolean, p_note text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_b record; v_i record;
begin
  if not public.is_edge_protection() then raise exception 'edge protection team only'; end if;
  select * into v_b from edge_protection_bookings where id = p_booking;
  if v_b.id is null then raise exception 'booking not found'; end if;
  if v_b.status <> 'requested' then raise exception 'already %', v_b.status; end if;

  update edge_protection_bookings
     set status = case when p_approve then 'approved' else 'declined' end,
         decided_by = auth.uid(), decided_at = now(), decide_note = p_note
   where id = p_booking;

  select * into v_i from installs where id = v_b.install_id;
  insert into events (site_id, lead_id, actor_type, actor_id, event_type, payload)
  select l.site_id, v_i.lead_id, 'edge_protection', auth.uid()::text,
         case when p_approve then 'edge.approved' else 'edge.declined' end,
         jsonb_build_object('booking_id', p_booking, 'install_id', v_b.install_id, 'scheduled_date', v_b.scheduled_date)
  from leads l where l.id = v_i.lead_id;
  return jsonb_build_object('ok', true, 'status', case when p_approve then 'approved' else 'declined' end, 'contractual', p_approve);
end $$;

-- The edge team's work queue — bookings with the job details they need (address, date, size).
create or replace function public.edge_protection_queue()
returns table (booking_id uuid, install_id uuid, status text, billing_party text, scheduled_date date,
               linear_m numeric, address text, suburb text, postcode text, installer text, requested_at timestamptz)
language sql stable security definer set search_path=public as $$
  select b.id, b.install_id, b.status, b.billing_party, b.scheduled_date, b.linear_m,
         s.address, nullif(trim(split_part(s.address, ',', -1)), '') as suburb, s.postcode,
         i.company_name, b.requested_at
  from edge_protection_bookings b
  join installs ins on ins.id = b.install_id
  join leads l on l.id = ins.lead_id
  join sites s on s.id = l.site_id
  join installers i on i.id = b.installer_id
  where public.is_edge_protection()
  order by (b.status = 'requested') desc, b.scheduled_date asc;
$$;

revoke all on function public.request_edge_protection(uuid, date, numeric, text) from public;
revoke all on function public.decide_edge_protection(uuid, boolean, text) from public;
revoke all on function public.edge_protection_queue() from public;
grant execute on function public.request_edge_protection(uuid, date, numeric, text) to authenticated;
grant execute on function public.decide_edge_protection(uuid, boolean, text) to authenticated;
grant execute on function public.edge_protection_queue() to authenticated;
grant execute on function public.is_edge_protection() to authenticated;
