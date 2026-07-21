-- ============================================================================
-- Sales Technician field-capture foundation (scope v1.2 §6). Additive only —
-- does not touch the existing consultant/inspections presale flow. Stands up
-- the technician track on the existing sales_reps + assessments tables:
-- claim/schedule/visit/submit lifecycle, per-photo AI capture, availability,
-- payouts, runs, travel cache, and the technician-scoped RLS the doc calls a
-- hard launch blocker. The technician Submit will rejoin the existing pipeline
-- at the 'inspected' lead state (the doc's "assessed"), so everything
-- downstream (design -> board -> choose -> sign -> post-sale) is unaffected.
-- ============================================================================

-- ---- assessments: claim/visit/submit lifecycle (§6) ----
alter table public.assessments add column if not exists claimed_at      timestamptz;
alter table public.assessments add column if not exists claim_expires_at timestamptz;
alter table public.assessments add column if not exists started_at      timestamptz;
alter table public.assessments add column if not exists start_gps       jsonb;          -- {lat,lng}
alter table public.assessments add column if not exists submitted_at    timestamptz;
alter table public.assessments add column if not exists outcome         text check (outcome in ('completed','no_access','partial'));
alter table public.assessments add column if not exists fee_cents       integer;
alter table public.assessments add column if not exists payout_id       uuid;
alter table public.assessments add column if not exists site_data       jsonb not null default '{}';  -- §4.1 structured fields
alter table public.assessments add column if not exists run_id          uuid;

-- widen the status lifecycle: claimed -> scheduled -> in_progress -> completed/no_access/partial (or cancelled)
alter table public.assessments drop constraint if exists assessments_status_check;
alter table public.assessments add constraint assessments_status_check
  check (status in ('claimed','scheduled','in_progress','completed','no_access','partial','cancelled'));

-- ---- per-photo capture with AI verdict (§4.2) ----
create table if not exists public.assessment_photos (
  id            uuid primary key default uuid_generate_v4(),
  assessment_id uuid not null references public.assessments(id) on delete cascade,
  step_key      text not null,
  storage_path  text,                                   -- null when the step is N/A
  na_reason     text,
  lat           double precision,
  lng           double precision,
  taken_at      timestamptz,
  ai_verdict    text check (ai_verdict in ('pending','pass','fail')),
  ai_reasons    text[] default '{}',
  retake_count  integer not null default 0,
  note          text,
  created_at    timestamptz not null default now()
);
create index if not exists assessment_photos_assessment_idx on public.assessment_photos (assessment_id);

-- ---- technician availability (§5.1 window offering source) ----
create table if not exists public.technician_availability (
  sales_rep_id   uuid primary key references public.sales_reps(id) on delete cascade,
  base_postcode  text,
  windows        jsonb not null default '{}',           -- {mon:[["08:00","12:00"]], ...}
  blackout_dates date[] not null default '{}',
  updated_at     timestamptz not null default now()
);

-- ---- payouts (§6) — Stripe Connect batch + per-job line items ----
create table if not exists public.payouts (
  id                 uuid primary key default uuid_generate_v4(),
  sales_rep_id       uuid not null references public.sales_reps(id),
  period_start       date,
  period_end         date,
  status             text not null default 'pending' check (status in ('pending','processing','paid','failed')),
  stripe_transfer_ref text,
  total_cents        integer not null default 0,
  created_at         timestamptz not null default now(),
  paid_at            timestamptz
);
create table if not exists public.payout_items (
  id            uuid primary key default uuid_generate_v4(),
  payout_id     uuid not null references public.payouts(id) on delete cascade,
  assessment_id uuid references public.assessments(id),
  description   text,
  amount_cents  integer not null,
  created_at    timestamptz not null default now()
);

-- ---- runs (§5.2 technician-day container) ----
create table if not exists public.runs (
  id           uuid primary key default uuid_generate_v4(),
  sales_rep_id uuid not null references public.sales_reps(id),
  run_date     date not null,
  sequence     jsonb not null default '[]',             -- ordered assessment ids
  economics    jsonb not null default '{}',             -- {total_km, hours, effective_rate_cents}
  created_at   timestamptz not null default now(),
  unique (sales_rep_id, run_date)
);

-- ---- travel-time cache (§5.4 Distance Matrix cost control) ----
create table if not exists public.travel_cache (
  from_key         text not null,                       -- postcode or "lat,lng"
  to_key           text not null,
  duration_seconds integer,
  distance_meters  integer,
  fetched_at       timestamptz not null default now(),
  primary key (from_key, to_key)
);

-- ============================================================================
-- Identity + helpers
-- ============================================================================
-- Link a sales-rep login to its row by email, grant the 'sales_rep' role.
create or replace function public.link_sales_rep_on_signup()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_rep uuid;
begin
  select id into v_rep from sales_reps where lower(email) = lower(new.email) and user_id is null limit 1;
  if v_rep is not null then
    update sales_reps set user_id = new.id where id = v_rep;
    insert into user_roles (user_id, role) values (new.id, 'sales_rep') on conflict (user_id) do nothing;
  end if;
  return new;
end $$;
revoke execute on function public.link_sales_rep_on_signup() from anon, authenticated, public;
drop trigger if exists on_auth_user_created_sales_rep on auth.users;
create trigger on_auth_user_created_sales_rep
  after insert on auth.users for each row execute function public.link_sales_rep_on_signup();

-- Resolve the calling technician's rep id (must be an active/approved rep).
create or replace function public.current_sales_rep_id()
returns uuid language sql stable security definer set search_path = public as $$
  select id from sales_reps
  where user_id = auth.uid() and status in ('approved','active','conditionally_active') limit 1;
$$;
grant execute on function public.current_sales_rep_id() to authenticated;

-- ============================================================================
-- Technician-scoped RLS (§6 launch blocker). Job-pool reads of other people's
-- leads happen only through a SECURITY DEFINER RPC (built next), so base tables
-- stay locked down: a technician sees only their own rep row + own assessments.
-- ============================================================================
alter table public.assessment_photos enable row level security;
alter table public.technician_availability enable row level security;
alter table public.payouts enable row level security;
alter table public.payout_items enable row level security;
alter table public.runs enable row level security;
alter table public.travel_cache enable row level security;

-- sales_reps: technician reads/updates only their own row (admin already has all)
create policy rep_self_read   on public.sales_reps for select to authenticated using (user_id = auth.uid());
create policy rep_self_update on public.sales_reps for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- assessments: technician sees + works only their own claims (admin already has all)
create policy rep_own_assessments on public.assessments for all to authenticated
  using (sales_rep_id = current_sales_rep_id())
  with check (sales_rep_id = current_sales_rep_id());

-- assessment_photos: technician CRUD for their own assessments; admin all
create policy admin_all_assessment_photos on public.assessment_photos for all to authenticated
  using (is_admin()) with check (is_admin());
create policy rep_own_assessment_photos on public.assessment_photos for all to authenticated
  using (exists (select 1 from assessments a where a.id = assessment_id and a.sales_rep_id = current_sales_rep_id()))
  with check (exists (select 1 from assessments a where a.id = assessment_id and a.sales_rep_id = current_sales_rep_id()));

-- availability / runs: self + admin
create policy admin_all_availability on public.technician_availability for all to authenticated using (is_admin()) with check (is_admin());
create policy rep_own_availability   on public.technician_availability for all to authenticated
  using (sales_rep_id = current_sales_rep_id()) with check (sales_rep_id = current_sales_rep_id());
create policy admin_all_runs on public.runs for all to authenticated using (is_admin()) with check (is_admin());
create policy rep_own_runs   on public.runs for all to authenticated
  using (sales_rep_id = current_sales_rep_id()) with check (sales_rep_id = current_sales_rep_id());

-- payouts: technician reads own; admin all; writes via service-role batch job
create policy admin_all_payouts on public.payouts for all to authenticated using (is_admin()) with check (is_admin());
create policy rep_read_payouts   on public.payouts for select to authenticated using (sales_rep_id = current_sales_rep_id());
create policy admin_all_payout_items on public.payout_items for all to authenticated using (is_admin()) with check (is_admin());
create policy rep_read_payout_items  on public.payout_items for select to authenticated
  using (exists (select 1 from payouts p where p.id = payout_id and p.sales_rep_id = current_sales_rep_id()));

-- travel_cache: admin-managed; readable by signed-in staff/apps
create policy admin_all_travel_cache on public.travel_cache for all to authenticated using (is_admin()) with check (is_admin());

-- ---- private storage bucket for assessment photos ----
insert into storage.buckets (id, name, public) values ('assessment-photos','assessment-photos',false)
  on conflict (id) do nothing;
create policy admin_assessment_photos_storage on storage.objects for all to authenticated
  using (bucket_id='assessment-photos' and is_admin())
  with check (bucket_id='assessment-photos' and is_admin());
create policy rep_assessment_photos_storage on storage.objects for all to authenticated
  using (bucket_id='assessment-photos' and current_sales_rep_id() is not null)
  with check (bucket_id='assessment-photos' and current_sales_rep_id() is not null);
