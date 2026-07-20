-- ============================================================================
-- 0003 — Phase 3 data model additions (spec Section 2). Purely additive:
-- new columns get defaults, new tables are new, nothing existing is dropped
-- or renamed. capture_lead/book_assessment need no changes (they don't
-- reference any of these new columns and the new ones all default cleanly).
--
-- Two consolidations vs. the spec's literal wording, flagged rather than
-- silently applied:
--
-- 1. Spec asks for `lead_events` and `job_events` tables mirroring each
--    other. This codebase already has ONE append-only `events` table
--    (site_id/lead_id, actor_type, event_type, payload, forbid_mutation
--    trigger) serving exactly this purpose for leads. Rather than fork the
--    audit trail across three near-identical tables, this migration widens
--    `events` instead: adds a nullable `job_id` column and extends
--    `actor_type` to include 'retailer'/'sales_rep'. One event log stays
--    the single source of truth, matching the append-only-log principle
--    used everywhere else in this project family.
-- 2. `leads.status` (the spec's new admin-facing bucket: new/contacted/
--    visit_requested/.../won/lost) is added ALONGSIDE the existing
--    `leads.state` (the detailed internal lifecycle enum already in
--    schema.sql: captured/validated/scored/.../closed). They are not yet
--    reconciled into one field — that's a deliberate deferral, not an
--    oversight; both are additive today so nothing breaks either way.
-- ============================================================================

-- ---- leads: new admin-facing status bucket + marketplace fields ----
alter table leads add column status text not null default 'new'
  check (status in ('new','contacted','visit_requested','visit_confirmed','assessed','designs_sent','quoted','won','lost'));
alter table leads add column assigned_installer_ids uuid[] not null default '{}'
  check (array_length(assigned_installer_ids,1) is null or array_length(assigned_installer_ids,1) <= 3);
alter table leads add column claimed_at timestamptz;
alter table leads add column admin_notes text;
alter table leads add column is_demo boolean not null default false;
alter table leads add column status_updated_at timestamptz not null default now();

create or replace function log_lead_status() returns trigger language plpgsql as $$
begin
  if tg_op = 'UPDATE' and new.status is distinct from old.status then
    new.status_updated_at := now();
    insert into events (site_id, lead_id, actor_type, event_type, payload)
    values (new.site_id, new.id, 'system', 'lead.status_changed',
            jsonb_build_object('from', old.status, 'to', new.status));
  end if;
  return new;
end $$;
create trigger leads_status_log before update on leads
  for each row execute function log_lead_status();

-- ---- retailers (Section 2/3) ----
create table retailers (
  id            uuid primary key default uuid_generate_v4(),
  company_name  text not null,
  abn           text,
  contact_name  text,
  contact_email text,
  contact_phone text,
  netcc_number  text,
  electrical_licence_no text,
  electrical_licence_state text,
  regions       uuid[] not null default '{}',
  status        text not null default 'registered'
    check (status in ('registered','docs_submitted','under_review','approved','conditionally_active','active','suspended','rejected')),
  user_id       uuid references auth.users(id),
  created_at    timestamptz not null default now()
);

-- Public request-access submissions, pre-account (Section 4.1) — anon
-- insert-only, same pattern as the existing lead-capture funnel.
create table retailer_applications (
  id            uuid primary key default uuid_generate_v4(),
  company_name  text not null,
  abn           text,
  contact_name  text,
  contact_email text,
  contact_phone text,
  regions       text[] not null default '{}', -- free-text region/suburb names; anon applicants can't resolve regions.id
  message       text,
  status        text not null default 'pending' check (status in ('pending','converted','rejected')),
  created_at    timestamptz not null default now()
);

-- ---- sales reps (Section 2/3) ----
create table sales_reps (
  id                  uuid primary key default uuid_generate_v4(),
  full_name           text not null,
  email               text,
  phone               text,
  regions             uuid[] not null default '{}',
  status              text not null default 'registered'
    check (status in ('registered','docs_submitted','under_review','approved','conditionally_active','active','suspended','rejected')),
  police_check_ref    text,
  police_check_expiry date,
  user_id             uuid references auth.users(id),
  created_at          timestamptz not null default now()
);

-- ---- installers: marketplace linkage (SAA/licence already exist as
-- saa_accreditation/licence_numbers — not duplicated here) ----
alter table installers add column linked_retailer_ids uuid[] not null default '{}';

-- ---- vetting documents (Section 3) — polymorphic owner, no FK (owner_type
-- picks which table owner_id belongs to; a real FK would need per-type
-- columns or an exclusion trigger, deferred as unnecessary complexity here) ----
create table vetting_documents (
  id           uuid primary key default uuid_generate_v4(),
  owner_type   text not null check (owner_type in ('retailer','installer','sales_rep')),
  owner_id     uuid not null,
  doc_type     text not null check (doc_type in ('abn','netcc','saa','electrical_licence','public_liability','workers_comp','police_check','id')),
  storage_path text,
  expiry_date  date,
  verified_by  uuid references staff(id),
  verified_at  timestamptz,
  status       text not null default 'pending' check (status in ('pending','verified','rejected','expired')),
  created_at   timestamptz not null default now()
);
create index on vetting_documents (owner_type, owner_id);

-- ---- jobs (retailer marketplace — Section 2/6) ----
create table jobs (
  id                      uuid primary key default uuid_generate_v4(),
  retailer_id             uuid not null references retailers(id),
  title                   text not null,
  suburb                  text,
  postcode                text,
  system_kw               numeric(6,2),
  battery_kwh             numeric(6,2),
  storeys                 smallint,
  roof_type               text check (roof_type in ('tile','tin','flat','other')),
  scheduled_window        text,
  rate_text               text,
  status                  text not null default 'open' check (status in ('open','claimed','in_progress','completed','cancelled')),
  claimed_by_installer_id uuid references installers(id),
  claimed_at              timestamptz,
  created_at              timestamptz not null default now()
);

-- Widen the existing event log instead of forking it into lead_events/
-- job_events (see header note) — job_id only makes sense once jobs exists.
alter table events add column job_id uuid references jobs(id);

alter table events drop constraint if exists events_actor_type_check;
alter table events add constraint events_actor_type_check
  check (actor_type in ('system','ai_agent','staff','customer','installer','retailer','sales_rep'));

-- ---- assessments (sales-rep site visits — Section 2/6) ----
create table assessments (
  id            uuid primary key default uuid_generate_v4(),
  lead_id       uuid not null references leads(id),
  sales_rep_id  uuid references sales_reps(id),
  scheduled_at  timestamptz,
  status        text not null default 'scheduled' check (status in ('scheduled','completed','no_access','cancelled')),
  findings      jsonb not null default '{}',
  photo_refs    text[] not null default '{}',
  completed_at  timestamptz,
  created_at    timestamptz not null default now()
);

-- ---- app-wide admin config (Section 5.6) ----
create table app_settings (
  key        text primary key,
  value      jsonb not null,
  updated_at timestamptz not null default now(),
  updated_by uuid references staff(id)
);

-- ---- RLS: admin-only on everything new except retailer_applications
-- (anon insert-only, per Section 1.3) ----
alter table retailers enable row level security;
alter table retailer_applications enable row level security;
alter table sales_reps enable row level security;
alter table vetting_documents enable row level security;
alter table jobs enable row level security;
alter table assessments enable row level security;
alter table app_settings enable row level security;

create policy admin_all_retailers on retailers for all using (is_admin()) with check (is_admin());
create policy admin_all_sales_reps on sales_reps for all using (is_admin()) with check (is_admin());
create policy admin_all_vetting_documents on vetting_documents for all using (is_admin()) with check (is_admin());
create policy admin_all_jobs on jobs for all using (is_admin()) with check (is_admin());
create policy admin_all_assessments on assessments for all using (is_admin()) with check (is_admin());
create policy admin_all_app_settings on app_settings for all using (is_admin()) with check (is_admin());

create policy admin_all_retailer_applications on retailer_applications for all using (is_admin()) with check (is_admin());
create policy anon_insert_retailer_applications on retailer_applications for insert to anon with check (true);
