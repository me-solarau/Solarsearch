-- Billy goes multi-channel: Facebook Messenger and WhatsApp arrive through the
-- meta-inbound webhook and share the same agent_threads memory as SMS.
--
-- Thread key semantics (agent_threads.phone):
--   sms / whatsapp  →  bare digits (last 9). WhatsApp's wa_id IS the phone
--                      number, so a WhatsApp chat continues the same thread —
--                      same memory, same caps — as SMS with that customer.
--   messenger       →  'fb:<psid>' — Messenger PSIDs are page-scoped and not
--                      phone numbers, so those threads live under a prefixed
--                      key and Billy asks for a mobile once qualified.
alter table public.agent_threads
  add column if not exists channel text not null default 'sms'
  check (channel in ('sms','messenger','whatsapp'));
