-- Billy — the Solarsearch AI lead-follow-up agent. One row per SMS
-- conversation Billy runs with a lead. Billy (service role, via the
-- lead-agent edge function) writes; HQ admins read the state and can take
-- over (status -> 'human'), which is what makes Billy go quiet on a lead.
create table if not exists public.agent_threads (
  id uuid primary key default gen_random_uuid(),
  lead_id uuid not null references public.leads(id),
  phone text not null, -- normalised last-9-digits, matches sms loop-guard normaliser
  status text not null default 'active'
    check (status in ('active','qualified','not_interested','human','opted_out','expired')),
  extracted jsonb not null default '{}'::jsonb, -- what Billy has learned so far
  summary text,          -- Billy's informed briefing for the owner
  msg_count integer not null default 0, -- Billy outbound count (hard cap enforced in code)
  last_inbound_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- one live conversation per phone number at a time
create unique index if not exists agent_threads_active_phone
  on public.agent_threads (phone) where status = 'active';
create index if not exists agent_threads_lead on public.agent_threads (lead_id);

alter table public.agent_threads enable row level security;

create policy admin_all_agent_threads on public.agent_threads
  for all to authenticated
  using (public.is_admin())
  with check (public.is_admin());
