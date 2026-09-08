-- Trace table for meta-inbound: one row per POST so webhook delivery and
-- signature verdicts are visible without platform log access. Proved out the
-- WhatsApp go-live (unpublished Meta apps silently drop production webhooks).
-- Service-role writes only; RLS on with no policies keeps clients out entirely.
create table if not exists public.meta_webhook_log (
  id bigserial primary key,
  at timestamptz not null default now(),
  sig_ok boolean,
  object text,
  note text
);
alter table public.meta_webhook_log enable row level security;
