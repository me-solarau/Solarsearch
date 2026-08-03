-- A STOP from anyone must stick, not just from people we already know.
--
-- Investigation of the Kudosity inbox (2026-08-03): 22+ distinct numbers texted
-- STOP to our sender number over the previous week — and the platform never
-- sent an SMS to ANY of them (verified per-number against sms_messages). The
-- sends they are opting out of originate outside the platform: either bulk
-- sends made directly from the Kudosity account, another tool wired to the
-- same account/number, or the number's previous life. Only the Kudosity-side
-- sent report can settle which.
--
-- What is ours to fix regardless: the existing opt-out flow only set
-- customers.sms_opt_out, and none of these senders matched a customer row, so
-- every one of those opt-outs was silently dropped. If such a person later
-- becomes a lead, the platform would text someone who had already said stop.
-- That is a Spam Act problem, not a UX problem.
--
-- sms_suppressions is a standalone do-not-text list keyed on the normalised
-- number. It is fed by a trigger on sms_messages rather than by the edge
-- function, so every logged inbound STOP lands here regardless of which code
-- path logged it. sms-send checks this list before any send (verified: 403,
-- no provider call).

create table if not exists public.sms_suppressions (
  number     text primary key,          -- digits only, e.g. 61417817546
  first_seen timestamptz not null default now(),
  last_seen  timestamptz not null default now(),
  source     text not null default 'sms_stop'
);

alter table public.sms_suppressions enable row level security;
drop policy if exists sms_suppressions_admin_read on public.sms_suppressions;
create policy sms_suppressions_admin_read on public.sms_suppressions
  for select to authenticated using (public.is_admin());

create or replace function public.record_sms_stop()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_digits text;
begin
  if new.direction = 'in'
     and upper(trim(coalesce(new.body,''))) ~ '^(STOP|STOPALL|UNSUBSCRIBE|CANCEL ALL|END|QUIT)$' then
    v_digits := regexp_replace(coalesce(new.from_number,''), '\D', '', 'g');
    if length(v_digits) >= 9 then
      insert into public.sms_suppressions(number) values (v_digits)
      on conflict (number) do update set last_seen = now();
    end if;
  end if;
  return new;
end $$;

drop trigger if exists sms_messages_record_stop on public.sms_messages;
create trigger sms_messages_record_stop
  after insert on public.sms_messages
  for each row execute function public.record_sms_stop();

-- Backfill every STOP already in the log (36 numbers at time of writing).
insert into public.sms_suppressions(number, first_seen, last_seen)
select regexp_replace(from_number,'\D','','g'), min(created_at), max(created_at)
from public.sms_messages
where direction='in'
  and upper(trim(coalesce(body,''))) ~ '^(STOP|STOPALL|UNSUBSCRIBE|CANCEL ALL|END|QUIT)$'
  and length(regexp_replace(coalesce(from_number,''),'\D','','g')) >= 9
group by 1
on conflict (number) do nothing;
