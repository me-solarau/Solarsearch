-- Access-application + T&C acknowledgment gate for the field apps (sales_tech, installer,
-- inspector). A user applies for access to an app and MUST acknowledge the Terms & Conditions;
-- acceptance (approval) can only be granted by an admin, and only after the T&Cs were accepted.
create table if not exists public.access_applications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  app text not null check (app in ('sales_tech','installer','inspector')),
  full_name text, email text, phone text,
  terms_ref text, terms_accepted_at timestamptz,
  status text not null default 'pending' check (status in ('pending','granted','denied')),
  note text, decided_by uuid, decided_at timestamptz,
  created_at timestamptz not null default now(),
  unique (user_id, app)
);
alter table public.access_applications enable row level security;
drop policy if exists access_app_own on public.access_applications;
create policy access_app_own on public.access_applications for select
  using (user_id = auth.uid() or public.is_admin());
drop policy if exists access_app_admin on public.access_applications;
create policy access_app_admin on public.access_applications for all
  using (public.is_admin()) with check (public.is_admin());

-- Applicant submits / re-submits an application. Calling this records T&C acceptance (the app
-- only calls it after the applicant ticks "I have read and accept the Terms & Conditions").
create or replace function public.apply_for_access(p_app text, p_full_name text, p_email text,
                                                    p_phone text default null, p_terms_ref text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_uid uuid := auth.uid(); v_status text;
begin
  if v_uid is null then raise exception 'sign in first'; end if;
  if p_app not in ('sales_tech','installer','inspector') then raise exception 'unknown app %', p_app; end if;
  insert into access_applications (user_id, app, full_name, email, phone, terms_ref, terms_accepted_at, status)
  values (v_uid, p_app, p_full_name, p_email, p_phone, p_terms_ref, now(), 'pending')
  on conflict (user_id, app) do update set
    full_name = excluded.full_name, email = excluded.email, phone = excluded.phone,
    terms_ref = excluded.terms_ref, terms_accepted_at = now(),
    status = case when access_applications.status = 'denied' then 'pending' else access_applications.status end
  returning status into v_status;
  return jsonb_build_object('ok', true, 'status', v_status);
end $$;

-- Admin decision. Acceptance can ONLY be granted if the applicant acknowledged the T&Cs.
-- Actual role provisioning stays with the existing onboarding flows (onboard-technician /
-- onboard-installer); this records the gated decision.
create or replace function public.decide_access(p_id uuid, p_granted boolean, p_note text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_app record;
begin
  if not public.is_admin() then raise exception 'not authorised'; end if;
  select * into v_app from access_applications where id = p_id;
  if v_app.id is null then raise exception 'application not found'; end if;
  if p_granted and v_app.terms_accepted_at is null then
    raise exception 'applicant must accept the Terms & Conditions before access can be granted';
  end if;
  update access_applications set status = case when p_granted then 'granted' else 'denied' end,
    decided_by = auth.uid(), decided_at = now(), note = coalesce(p_note, note)
  where id = p_id;
  return jsonb_build_object('ok', true, 'status', case when p_granted then 'granted' else 'denied' end);
end $$;
