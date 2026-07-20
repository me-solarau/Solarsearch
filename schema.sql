-- ============================================================================
-- SOLARSEARCH PLATFORM — SUPABASE SCHEMA v1.0
-- PRD v2.0 reference. Run in Supabase SQL editor (or migrations).
-- Design principles:
--   * SS-xxxx site id is the spine; everything references sites.
--   * Region is data, not code (§17).
--   * Append-only event log on every state transition (§6, §10).
--   * All rule-like things (rebates, DNSPs) are versioned/effective-dated config.
-- ============================================================================

-- ---------- extensions ----------
create extension if not exists "uuid-ossp";

-- ============================================================================
-- 1. REGIONS & STATE RULES  (§17 — region is data, not code)
-- ============================================================================
create table regions (
  id            uuid primary key default uuid_generate_v4(),
  name          text not null,                    -- 'Newcastle & Greater Hunter'
  state         text not null check (state in ('NSW','QLD','VIC','SA','WA','TAS','ACT','NT')),
  status        text not null default 'pilot' check (status in ('waitlist','pilot','live','paused')),
  seat_price_cents      integer not null default 20000,   -- $200/seat (§2 R3)
  commission_per_stc_cents integer not null default 110,  -- $1.10/STC (§2 R3a)
  launched_at   date,
  created_at    timestamptz not null default now()
);

create table region_postcodes (
  region_id  uuid not null references regions(id) on delete cascade,
  postcode   text not null check (postcode ~ '^\d{4}$'),
  primary key (region_id, postcode)
);

-- DNSP config per postcode (§7.8 G-2, §17.2)
create table dnsps (
  id             uuid primary key default uuid_generate_v4(),
  name           text not null,                 -- 'Ausgrid', 'Essential Energy'
  state          text not null,
  application_channel text not null default 'portal' check (application_channel in ('portal','email','api')),
  portal_url     text,
  typical_turnaround_days integer default 10,
  approve_before_install boolean not null default true,  -- vs install-then-notify
  flexible_exports_required boolean not null default false,
  der_register_via text default 'dnsp_process',
  notes          text
);

create table dnsp_postcodes (
  dnsp_id   uuid not null references dnsps(id) on delete cascade,
  postcode  text not null check (postcode ~ '^\d{4}$'),
  primary key (dnsp_id, postcode)
);

-- Versioned incentive rules (§7.5 D-4, carried from v1.0)
create table incentive_rules (
  id              uuid primary key default uuid_generate_v4(),
  version         text not null,                 -- 'v2026.05'
  scope           text not null check (scope in ('federal_battery','federal_solar_stc','state_scheme')),
  state           text,                          -- null = national
  effective_from  date not null,
  effective_to    date,
  rules           jsonb not null,                -- e.g. {"stc_factor":6.8,"stc_price_cents":3700,"tiers":[[14,1.0],[28,0.6],[50,0.15]]}
  created_at      timestamptz not null default now()
);
create index on incentive_rules (scope, effective_from);

-- ============================================================================
-- 2. PEOPLE & ORGS
-- ============================================================================
create table customers (
  id          uuid primary key default uuid_generate_v4(),
  full_name   text not null,
  email       text,
  mobile      text,                              -- E.164 or AU format
  mobile_verified_at timestamptz,
  created_at  timestamptz not null default now()
);
create index on customers (mobile);

create table installers (
  id            uuid primary key default uuid_generate_v4(),
  company_name  text not null,
  abn           text,
  status        text not null default 'pending' check (status in ('pending','approved','suspended','offboarded')),
  saa_accreditation text,
  saa_expiry    date,
  licence_numbers jsonb default '{}',            -- {"NSW":"12345C"}
  insurance_expiry date,
  contact_name  text,
  contact_email text,
  contact_mobile text,
  brand_kit     jsonb default '{}',              -- logo url, colours, warranty text (Option C proposals)
  pylon_account_ref text,
  agency_agreement_signed_at timestamptz,        -- P-1 agent model authority
  created_at    timestamptz not null default now()
);

create table installer_service_areas (
  installer_id uuid not null references installers(id) on delete cascade,
  region_id    uuid not null references regions(id),
  postcode     text not null,
  tiers        text[] not null default '{seats}',  -- any of: raw_leads, appointments, seats
  weekly_capacity integer default 5,
  paused       boolean not null default false,
  primary key (installer_id, postcode)
);

-- Path-1 price books (§7.3 I-3)
create table price_books (
  id            uuid primary key default uuid_generate_v4(),
  installer_id  uuid not null references installers(id) on delete cascade,
  name          text not null default 'Default',
  verified_at   timestamptz,                     -- stale if > 60 days (blocked from auto-quote)
  base_rates    jsonb not null,                  -- {"solar_per_kw_cents":135000,"solar_fixed_cents":160000,"battery_per_kwh_cents":82000,"battery_fixed_cents":280000}
  adders        jsonb not null default '{}',     -- {"two_storey_cents":45000,"tile_roof_cents":35000,"switchboard_upgrade_cents":180000,"three_phase_cents":60000}
  preferred_equipment jsonb not null default '{}', -- {"panel_sku":"...","inverter_sku":"...","battery_sku":"..."} (Pylon SKUs)
  active        boolean not null default true,
  created_at    timestamptz not null default now()
);

create table staff (
  id        uuid primary key default uuid_generate_v4(),
  auth_uid  uuid unique,                          -- supabase auth.users id
  full_name text not null,
  role      text not null check (role in ('admin','hq_ops','consultant','inspector','designer','compliance_reviewer')), -- consultant = presale/sales visits, inspector = Solarsafe compliance inspections
  regions   uuid[] default '{}',                  -- RBAC region scoping (§17.5)
  active    boolean not null default true
);

-- ============================================================================
-- 3. THE SPINE — SITES & LEADS  (§6, §10)
-- ============================================================================
create sequence ss_site_seq start 1000;

create table sites (
  id          uuid primary key default uuid_generate_v4(),
  ss_ref      text unique not null default ('SS-' || nextval('ss_site_seq')),  -- SS-1000, SS-1001...
  region_id   uuid references regions(id),
  address     text not null,
  postcode    text not null,
  state       text not null default 'NSW',
  nmi         text,                               -- G-1, validated app-side
  dnsp_id     uuid references dnsps(id),
  phases      smallint check (phases in (1,2,3)),
  roof_type   text check (roof_type in ('tile','tin','flat','other')),
  storeys     smallint,
  lat         double precision,
  lng         double precision,
  created_at  timestamptz not null default now()
);
create index on sites (postcode);

-- Lead lifecycle states (§6)
create type lead_state as enum (
  'captured','validated','scored','contacted','qualified','appointment_set',
  'inspected','designed','quoted','customer_chose','signed',
  'connection_approved','installed','der_registered','audited','closed',
  'nurture','sold_raw','appointment_sold','dead'
);

create table leads (
  id            uuid primary key default uuid_generate_v4(),
  site_id       uuid not null references sites(id),
  customer_id   uuid not null references customers(id),
  state         lead_state not null default 'captured',
  lead_type     text not null default 'solar_battery' check (lead_type in ('solar','solar_battery','battery_retrofit','commercial','solarsafe_audit')),
  score         smallint check (score between 0 and 100),
  bill_quarterly_cents integer,
  timeline      text check (timeline in ('asap','1_3_months','3_6_months','researching')),
  owner_status  text check (owner_status in ('owner_occupier','landlord','renter_with_authority')),
  extras        text[] default '{}',              -- pool, ev, electric_hw
  existing_system jsonb,                          -- battery_retrofit: {"kw":6.6,"inverter":"...","age_years":8}
  -- attribution (§7.1 A-4)
  source_platform text,                           -- meta, google, tiktok, organic, solarsafe_conversion, referral
  campaign_id   uuid,
  creative_ref  text,
  utm           jsonb default '{}',
  click_id      text,                             -- gclid/fbclid for offline conversion upload
  -- consent (immutable-by-policy; see events for history)
  consents      jsonb not null default '[]',      -- [{purpose, text_version, granted_at, ip}]
  dead_reason   text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index on leads (state);
create index on leads (site_id);

-- ============================================================================
-- 4. APPEND-ONLY EVENT LOG  (§6, §10 — training data + audit trail)
-- ============================================================================
create table events (
  id          bigserial primary key,
  site_id     uuid references sites(id),
  lead_id     uuid references leads(id),
  actor_type  text not null check (actor_type in ('system','ai_agent','staff','customer','installer')),
  actor_id    text,
  event_type  text not null,                      -- 'lead.state_changed','quote.generated','consent.granted',...
  payload     jsonb not null default '{}',
  created_at  timestamptz not null default now()
);
create index on events (lead_id, created_at);
create index on events (event_type);

-- No updates/deletes on events (append-only invariant)
create or replace function forbid_mutation() returns trigger language plpgsql as $$
begin raise exception 'events is append-only'; end $$;
create trigger events_no_update before update or delete on events
  for each row execute function forbid_mutation();

-- Auto-log lead state transitions
create or replace function log_lead_state() returns trigger language plpgsql as $$
begin
  if tg_op = 'UPDATE' and new.state is distinct from old.state then
    insert into events (site_id, lead_id, actor_type, event_type, payload)
    values (new.site_id, new.id, 'system', 'lead.state_changed',
            jsonb_build_object('from', old.state, 'to', new.state));
  end if;
  new.updated_at := now();
  return new;
end $$;
create trigger leads_state_log before update on leads
  for each row execute function log_lead_state();

-- ============================================================================
-- 5. FIELD OPERATIONS  (§7.4)
-- ============================================================================
create table inspections (
  id           uuid primary key default uuid_generate_v4(),
  site_id      uuid not null references sites(id),
  lead_id      uuid references leads(id),
  mode         text not null check (mode in ('presale','solarsafe')),
  inspector_id uuid references staff(id),
  scheduled_at timestamptz,
  started_at   timestamptz,
  completed_at timestamptz,                       -- only set when completion gate passes (F-7)
  notes        jsonb default '{}',
  created_at   timestamptz not null default now()
);

create table photos (
  id            uuid primary key default uuid_generate_v4(),
  inspection_id uuid not null references inspections(id) on delete cascade,
  step_key      text not null,                    -- 'roof_north','switchboard_exterior','battery_location',...
  storage_path  text,                             -- supabase storage object; null for an N/A-assessed step (no photo)
  lat           double precision,
  lng           double precision,
  taken_at      timestamptz not null,
  quality_flags text[] default '{}',
  assessment    text check (assessment in ('pass','minor','major','na')),
  note          text,                              -- observation note (required by field.html for minor/major)
  created_at    timestamptz not null default now()
);

-- ============================================================================
-- 6. DESIGN, SEATS, QUOTES, DEALS  (§7.5, §7.6, Option C)
-- ============================================================================
create table designs (
  id           uuid primary key default uuid_generate_v4(),
  site_id      uuid not null references sites(id),
  variant      text not null default 'primary',   -- 'primary','solar_only','solar_battery'
  pylon_project_ref text,                          -- SS ref embedded in Pylon project name
  system_kw    numeric(6,2),
  battery_kwh  numeric(6,2),
  components   jsonb default '{}',                 -- SKUs: panel/inverter/battery
  status       text not null default 'queued' check (status in ('queued','in_progress','complete')),
  designed_by  uuid references staff(id),
  completed_at timestamptz,
  created_at   timestamptz not null default now()
);

create table seats (
  id            uuid primary key default uuid_generate_v4(),
  site_id       uuid not null references sites(id),
  installer_id  uuid not null references installers(id),
  path          text not null check (path in ('path1_auto','path2_seat')),
  price_cents   integer not null,
  purchased_at  timestamptz not null default now(),
  unique (site_id, installer_id)
);
-- max 3 seats per site (§2 rule 1)
create or replace function enforce_seat_cap() returns trigger language plpgsql as $$
begin
  if (select count(*) from seats where site_id = new.site_id) >= 3 then
    raise exception 'seat cap reached: max 3 installers per site';
  end if;
  return new;
end $$;
create trigger seats_cap before insert on seats
  for each row execute function enforce_seat_cap();

create table quotes (
  id            uuid primary key default uuid_generate_v4(),
  site_id       uuid not null references sites(id),
  design_id     uuid not null references designs(id),
  installer_id  uuid not null references installers(id),
  seat_id       uuid references seats(id),
  path          text not null check (path in ('path1_auto','path2_manual')),
  price_book_id uuid references price_books(id),
  rules_version text not null,                    -- incentive_rules.version stamped (D-4)
  price_before_rebates_cents integer not null,
  rebate_cents  integer not null,
  price_after_cents integer not null,
  stc_count     integer,                          -- drives $1.10/STC commission
  line_items    jsonb default '[]',
  status        text not null default 'on_board' check (status in ('draft','on_board','chosen','declined','withdrawn','expired')),
  board_snapshot_id uuid,                          -- immutability: what the customer saw
  created_at    timestamptz not null default now()
);

-- immutable board snapshots (§10 invariant)
create table board_snapshots (
  id         uuid primary key default uuid_generate_v4(),
  site_id    uuid not null references sites(id),
  shown_at   timestamptz not null default now(),
  payload    jsonb not null                        -- verbatim quotes as displayed
);

create table proposals (                            -- Option C native, or Pylon-issued
  id           uuid primary key default uuid_generate_v4(),
  quote_id     uuid not null references quotes(id),
  channel      text not null check (channel in ('native','pylon')),
  template_version text,                            -- P-1 version stamping
  brand_kit_version text,
  pdf_path     text,
  issued_at    timestamptz,
  signed_at    timestamptz,
  signature    jsonb,                               -- {name, ip, user_agent, ts} — ETA-compliant capture
  signed_pdf_path text,
  created_at   timestamptz not null default now()
);

create table deals (
  id             uuid primary key default uuid_generate_v4(),
  site_id        uuid not null references sites(id),
  quote_id       uuid not null references quotes(id) unique,
  installer_id   uuid not null references installers(id),
  commission_cents integer not null,               -- stc_count * region.commission_per_stc
  invoice_status text not null default 'pending' check (invoice_status in ('pending','invoiced','paid','credited')),
  invoice_ref    text,
  signed_at      timestamptz not null default now()
);

-- ============================================================================
-- 7. CONNECTIONS & DER  (§7.8)
-- ============================================================================
create table connection_applications (
  id           uuid primary key default uuid_generate_v4(),
  site_id      uuid not null references sites(id),
  deal_id      uuid references deals(id),
  dnsp_id      uuid not null references dnsps(id),
  lodged_by    text not null default 'solarsearch' check (lodged_by in ('solarsearch','installer')),
  status       text not null default 'draft' check (status in ('draft','lodged','info_requested','approved','rejected')),
  reference    text,
  export_limit_kw numeric(5,1),
  documents    jsonb default '[]',
  lodged_at    timestamptz,
  decided_at   timestamptz,
  der_registered_at timestamptz,                  -- G-7: blocks 'closed' until set
  created_at   timestamptz not null default now()
);

-- ============================================================================
-- 8. SOLARSAFE  (§9)
-- ============================================================================
create table audit_reports (
  id            uuid primary key default uuid_generate_v4(),
  site_id       uuid not null references sites(id),
  inspection_id uuid not null references inspections(id),
  status        text not null default 'ai_draft' check (status in ('ai_draft','in_review','released','withdrawn')),
  reviewer_id   uuid references staff(id),         -- §9.1: human counter-signature required
  released_at   timestamptz,
  pdf_path      text,
  independence_disclosed boolean not null default true,
  created_at    timestamptz not null default now(),
  constraint release_requires_reviewer check (status <> 'released' or reviewer_id is not null)
);

create table findings (
  id          uuid primary key default uuid_generate_v4(),
  report_id   uuid not null references audit_reports(id) on delete cascade,
  clause_ref  text not null,                       -- 'AS/NZS 5033:2021 cl 4.x'
  severity    text not null check (severity in ('info','minor','major','safety')),
  description text not null,
  photo_ids   uuid[] default '{}',
  created_at  timestamptz not null default now()
);

create table correspondence (
  id          uuid primary key default uuid_generate_v4(),
  site_id     uuid not null references sites(id),
  report_id   uuid references audit_reports(id),
  party       text not null check (party in ('customer','installer','cer','fair_trading','other')),
  direction   text not null check (direction in ('outbound','inbound')),
  channel     text not null default 'email',
  subject     text,
  body_path   text,                                -- stored document
  customer_authority_ref text,                     -- §9.3
  response_due date,                               -- 14-day clock (I-6)
  created_at  timestamptz not null default now()
);

-- ============================================================================
-- 9. CAMPAIGNS  (§7.1)
-- ============================================================================
create table campaigns (
  id          uuid primary key default uuid_generate_v4(),
  region_id   uuid references regions(id),
  platform    text not null check (platform in ('meta','google','tiktok')),
  name        text not null,
  objective   text,
  status      text not null default 'draft' check (status in ('draft','active','paused','ended')),
  daily_budget_cents integer,
  external_ref text,
  created_at  timestamptz not null default now()
);

-- ============================================================================
-- 10. ROW LEVEL SECURITY (outline — tighten before production)
-- ============================================================================
alter table leads enable row level security;
alter table sites enable row level security;
alter table quotes enable row level security;
alter table seats enable row level security;
alter table price_books enable row level security;
alter table audit_reports enable row level security;
alter table events enable row level security;

-- HQ staff: full read via role claim (configure supabase auth JWT custom claims)
create policy staff_all_leads on leads for all
  using (exists (select 1 from staff s where s.auth_uid = auth.uid() and s.active));

-- Installers: only their own seats/quotes/price books (installer portal uses
-- a mapped auth uid on installers table — add installer_users join table when
-- building the portal; placeholder policies below)
create policy staff_all_sites  on sites  for all using (exists (select 1 from staff s where s.auth_uid = auth.uid() and s.active));
create policy staff_all_quotes on quotes for all using (exists (select 1 from staff s where s.auth_uid = auth.uid() and s.active));
create policy staff_all_seats  on seats  for all using (exists (select 1 from staff s where s.auth_uid = auth.uid() and s.active));
create policy staff_all_books  on price_books for all using (exists (select 1 from staff s where s.auth_uid = auth.uid() and s.active));
create policy staff_all_audits on audit_reports for all using (exists (select 1 from staff s where s.auth_uid = auth.uid() and s.active));
create policy staff_read_events on events for select using (exists (select 1 from staff s where s.auth_uid = auth.uid() and s.active));
create policy anyone_insert_events on events for insert with check (true);
