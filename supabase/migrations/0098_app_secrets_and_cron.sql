-- Private key/value store for operational tokens (e.g. the follow-up sweep
-- token pg_cron uses to authenticate to lead-agent). RLS on with NO policies:
-- unreachable by anon/authenticated; only the service role (edge functions)
-- and admin tooling can read it. The token value itself is seeded out-of-band,
-- never committed.
create table if not exists public.app_secrets (
  name text primary key,
  value text not null,
  created_at timestamptz not null default now()
);
alter table public.app_secrets enable row level security;

-- pg_cron drives Billy's scheduled follow-up sweep.
create extension if not exists pg_cron;

-- Provisioned out-of-band (token value and cron job are NOT in git):
--   insert into public.app_secrets(name, value)
--     values ('followup_token', encode(extensions.gen_random_bytes(24),'hex'));
--   select cron.schedule('billy-followup-sweep', '*/30 * * * *', $$
--     select net.http_post(
--       url := '<project>/functions/v1/lead-agent',
--       headers := jsonb_build_object('Content-Type','application/json'),
--       body := jsonb_build_object('followup_sweep', true,
--                 'token', (select value from public.app_secrets where name='followup_token')));
--   $$);
