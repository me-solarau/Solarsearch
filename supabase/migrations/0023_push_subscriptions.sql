-- ============================================================================
-- Web Push subscriptions (SMS_PUSH_PLAN Part B1). "Ping — new job near you."
-- Keyed by auth user so it works for any role (technician now; consultant /
-- installer later reuse the same table). notify-pool (service-role Edge
-- Function) reads the crypto material through a SECURITY DEFINER RPC granted to
-- service_role only, so a browser can never read another device's push keys.
-- Native (iOS/Android) tokens land in the same table with platform='ios'|'android'
-- so Part B2 reuses this untouched.
-- ============================================================================
create table if not exists public.push_subscriptions (
  id           uuid primary key default uuid_generate_v4(),
  user_id      uuid not null references auth.users(id) on delete cascade,
  endpoint     text not null unique,          -- web push URL, or a native token URI
  p256dh       text,                           -- web push only
  auth         text,                           -- web push only
  platform     text not null default 'web' check (platform in ('web','ios','android')),
  user_agent   text,
  created_at   timestamptz not null default now(),
  last_seen_at timestamptz not null default now()
);
create index if not exists push_subscriptions_user_idx on public.push_subscriptions (user_id);

alter table public.push_subscriptions enable row level security;
-- A device manages only its own subscriptions.
create policy push_self_all on public.push_subscriptions for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
-- Admin can see the fleet (counts/debug); never needs the keys client-side.
create policy push_admin_read on public.push_subscriptions for select to authenticated
  using (is_admin());

-- ============================================================================
-- Eligible push targets for a pool-bound postcode: every approved technician
-- whose regions cover it, with a live subscription. Returns the crypto material
-- notify-pool needs to encrypt each push. Deliberately does NOT hard-filter on
-- availability during the pilot (better to over-notify than miss a job); the
-- Edge Function can tighten later. service_role only.
-- ============================================================================
create or replace function public.push_targets_for_postcode(p_postcode text)
returns table (endpoint text, p256dh text, auth text, platform text, sales_rep_id uuid)
language sql stable security definer set search_path = public as $$
  select ps.endpoint, ps.p256dh, ps.auth, ps.platform, r.id
  from sales_reps r
  join push_subscriptions ps on ps.user_id = r.user_id
  where r.status in ('approved','active','conditionally_active')
    and p_postcode in (
      select rp.postcode from region_postcodes rp
      where rp.region_id in (select unnest(r.regions))
    );
$$;
revoke all on function public.push_targets_for_postcode(text) from public, anon, authenticated;
grant execute on function public.push_targets_for_postcode(text) to service_role;

-- Drop a dead subscription (410/404 from the push service). service_role only.
create or replace function public.prune_push_endpoint(p_endpoint text)
returns void language sql security definer set search_path = public as $$
  delete from push_subscriptions where endpoint = p_endpoint;
$$;
revoke all on function public.prune_push_endpoint(text) from public, anon, authenticated;
grant execute on function public.prune_push_endpoint(text) to service_role;
