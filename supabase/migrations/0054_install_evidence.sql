-- Install-evidence pipeline (the mandatory customer-protection gate from QUOTING_PROCESS):
-- a guided install photo set + completion report, for the installer AND any subcontractor,
-- with the SAME integrity chain as the sales-tech capture — geotagged, hashed, locked on
-- submission. The winning installer owns the record and remains accountable for a sub's work.

create table if not exists public.installs (
  id uuid primary key default gen_random_uuid(),
  lead_id uuid not null references public.leads(id) on delete cascade,
  installer_id uuid not null references public.installers(id) on delete restrict,
  pipeline text not null default 'installer' check (pipeline in ('installer','subcontractor')),
  subcontractor_name text,                     -- named sub when pipeline='subcontractor'
  status text not null default 'scheduled' check (status in ('scheduled','in_progress','installed','closed','cancelled')),
  started_at timestamptz, start_gps jsonb,
  submitted_at timestamptz, closed_at timestamptz,
  completion_report jsonb,
  created_at timestamptz not null default now()
);
create index if not exists installs_installer on public.installs(installer_id);
create index if not exists installs_lead on public.installs(lead_id);

create table if not exists public.install_photos (
  id uuid primary key default gen_random_uuid(),
  install_id uuid not null references public.installs(id) on delete cascade,
  step_key text not null,
  storage_path text, na_reason text, note text,
  lat double precision, lng double precision, taken_at timestamptz,
  sha256 text, bytes int,
  ai_verdict text, ai_reasons text[],
  created_at timestamptz not null default now()
);
create index if not exists install_photos_install on public.install_photos(install_id);

alter table public.installs enable row level security;
alter table public.install_photos enable row level security;
drop policy if exists installs_own on public.installs;
create policy installs_own on public.installs for all
  using (public.is_admin() or installer_id = public.current_installer_id())
  with check (public.is_admin() or installer_id = public.current_installer_id());
drop policy if exists install_photos_own on public.install_photos;
create policy install_photos_own on public.install_photos for all
  using (public.is_admin() or exists (select 1 from installs i where i.id = install_id
          and (i.installer_id = public.current_installer_id())))
  with check (public.is_admin() or exists (select 1 from installs i where i.id = install_id
          and (i.installer_id = public.current_installer_id())));

-- Immutability: install evidence is frozen once the install is submitted (mirrors 0050).
create or replace function public.lock_submitted_install_evidence()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_sub timestamptz;
begin
  select submitted_at into v_sub from installs where id = coalesce(NEW.install_id, OLD.install_id);
  if v_sub is not null and not public.is_admin() then
    raise exception 'install evidence is locked — this install was already submitted'
      using errcode = 'check_violation';
  end if;
  return case when TG_OP='DELETE' then OLD else NEW end;
end $$;
drop trigger if exists install_photos_lock on public.install_photos;
create trigger install_photos_lock before insert or update or delete on public.install_photos
  for each row execute function public.lock_submitted_install_evidence();

-- Start the install on site (logs GPS attendance).
create or replace function public.start_install(p_install uuid, p_lat double precision, p_lng double precision)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_i record;
begin
  select * into v_i from installs where id = p_install;
  if v_i.id is null then raise exception 'install not found'; end if;
  if not (public.is_admin() or v_i.installer_id = public.current_installer_id()) then raise exception 'not your install'; end if;
  if v_i.status <> 'scheduled' then raise exception 'cannot start from %', v_i.status; end if;
  update installs set status='in_progress', started_at=now(),
    start_gps=jsonb_build_object('lat',p_lat,'lng',p_lng) where id=p_install;
  return jsonb_build_object('ok',true);
end $$;

-- Mandatory gate: every required install step needs a photo (or an N/A reason), the completion
-- report must be present, and GPS attendance must be logged. Sets status='installed'.
create or replace function public.submit_install(p_install uuid, p_report jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_i record; v_req text[] := array['array','isolators','switchboard','inverter','labelling','earthing','final_tidy'];
  k text; v_have int;
begin
  select * into v_i from installs where id = p_install;
  if v_i.id is null then raise exception 'install not found'; end if;
  if not (public.is_admin() or v_i.installer_id = public.current_installer_id()) then raise exception 'not your install'; end if;
  if v_i.status <> 'in_progress' then raise exception 'start the install on site first'; end if;
  if v_i.start_gps is null or (v_i.start_gps->>'lat') is null then raise exception 'GPS attendance is required'; end if;
  if p_report is null or p_report = '{}'::jsonb then raise exception 'a completion report is required'; end if;
  foreach k in array v_req loop
    select count(*) into v_have from install_photos
      where install_id = p_install and step_key = k and (storage_path is not null or na_reason is not null);
    if v_have = 0 then raise exception 'missing install evidence for step: %', k; end if;
  end loop;
  update installs set status='installed', submitted_at=now(), completion_report=p_report where id=p_install;
  update leads set state='installed' where id = v_i.lead_id and state = 'signed';
  insert into events (site_id, lead_id, actor_type, actor_id, event_type, payload)
  select l.site_id, v_i.lead_id, 'installer', v_i.installer_id::text, 'install.submitted',
         jsonb_build_object('install_id', p_install, 'pipeline', v_i.pipeline)
  from leads l where l.id = v_i.lead_id;
  return jsonb_build_object('ok', true, 'status', 'installed');
end $$;
