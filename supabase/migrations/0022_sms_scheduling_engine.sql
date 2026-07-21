-- ============================================================================
-- Twilio SMS scheduling engine (SMS_PUSH_PLAN Part A). Turns the technician
-- dispatch loop conversational: the system proposes route-efficient windows by
-- SMS, the customer replies "1/2/3" (or RESCHEDULE/CANCEL/STOP), and an inbound
-- webhook confirms the visit — no phone tag. All sends/receives are logged for
-- dispute protection (§6). The Edge Functions run service-role, so the
-- state-transition RPCs here are granted to service_role ONLY (revoked from
-- authenticated/anon): the browser can never confirm/release a visit it doesn't
-- own — that stays gated by schedule_visit's current_sales_rep_id() check.
-- Additive; nothing downstream changes.
-- ============================================================================

-- ---- message log (both directions) ----
create table if not exists public.sms_messages (
  id            uuid primary key default uuid_generate_v4(),
  lead_id       uuid references public.leads(id) on delete set null,
  assessment_id uuid references public.assessments(id) on delete set null,
  direction     text not null check (direction in ('out','in')),
  to_number     text,
  from_number   text,
  body          text,
  twilio_sid    text,
  status        text,                         -- queued|sent|scheduled|delivered|received|failed|undelivered
  kind          text,                         -- offer|confirm|reminder|eta|reschedule|cancel|optout|fallback|inbound
  created_at    timestamptz not null default now()
);
create index if not exists sms_messages_assessment_idx on public.sms_messages (assessment_id);
create index if not exists sms_messages_lead_idx on public.sms_messages (lead_id);
create index if not exists sms_messages_sid_idx on public.sms_messages (twilio_sid);

-- ---- assessment scheduling state ----
alter table public.assessments add column if not exists offered_windows   jsonb;         -- [{iso,label,cluster}]
alter table public.assessments add column if not exists schedule_state    text
  check (schedule_state in ('offered','confirmed','reschedule','cancelled'));
alter table public.assessments add column if not exists reminder_sent_at  timestamptz;   -- scheduled or sent
alter table public.assessments add column if not exists eta_sent_at       timestamptz;
alter table public.assessments add column if not exists sms_consent_version text;

-- ---- opt-out (STOP) honoured per customer (§ compliance) ----
alter table public.customers add column if not exists sms_opt_out boolean not null default false;

-- ---- trust-badge fields for the intro-SMS link (customer confidence at door) ----
alter table public.sales_reps add column if not exists photo_url     text;
alter table public.sales_reps add column if not exists accreditation text;

-- ============================================================================
-- RLS: admin sees all; technician reads the SMS thread for their own jobs.
-- ============================================================================
alter table public.sms_messages enable row level security;
create policy admin_all_sms on public.sms_messages for all to authenticated
  using (is_admin()) with check (is_admin());
create policy rep_read_own_sms on public.sms_messages for select to authenticated
  using (exists (
    select 1 from assessments a
    where a.id = sms_messages.assessment_id and a.sales_rep_id = current_sales_rep_id()
  ));
-- Inserts are done by the service-role Edge Functions (RLS bypassed).

-- ============================================================================
-- technician_windows: server-side route-efficient window generator (the SMS
-- engine, not the browser, now proposes windows). Mirrors the tech.html logic:
-- next 10 days from the rep's availability, clusters near an already-scheduled
-- job that day (65-min gap), avoids double-booking (<45 min), returns up to 3.
-- All times computed in Australia/Sydney. Returns [{iso,label,cluster}].
-- ============================================================================
create or replace function public.technician_windows(p_assessment_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_tz       text := 'Australia/Sydney';
  v_rep      uuid;
  v_windows  jsonb;
  v_blackout date[];
  v_out      jsonb := '[]'::jsonb;
  v_now      timestamp := timezone(v_tz, now());   -- wall-clock in Sydney
  d          int;
  v_day      date;
  v_daykey   text;
  v_win      jsonb;
  v_s_txt    text;
  v_e_txt    text;
  v_ws       timestamptz;
  v_we       timestamptz;
  v_last     timestamptz;
  v_cluster  boolean;
  v_cands    timestamptz[];
  v_cand     timestamptz;
  v_conflict int;
  v_count    int := 0;
begin
  select sales_rep_id into v_rep from assessments where id = p_assessment_id;
  if v_rep is null then return v_out; end if;
  select windows, blackout_dates into v_windows, v_blackout
    from technician_availability where sales_rep_id = v_rep;
  if v_windows is null then return v_out; end if;

  for d in 1..10 loop
    exit when v_count >= 3;
    v_day    := v_now::date + d;
    v_daykey := (array['sun','mon','tue','wed','thu','fri','sat'])[extract(dow from v_day)::int + 1];
    if v_blackout is not null and v_day = any(v_blackout) then continue; end if;

    v_win := v_windows -> v_daykey -> 0;               -- first window of that weekday
    if v_win is null then continue; end if;
    v_s_txt := v_win ->> 0; v_e_txt := v_win ->> 1;
    if v_s_txt is null or v_e_txt is null then continue; end if;

    v_ws := timezone(v_tz, (v_day::text || ' ' || v_s_txt)::timestamp);
    v_we := timezone(v_tz, (v_day::text || ' ' || v_e_txt)::timestamp);

    -- last scheduled job for this rep that day -> cluster right after it
    select max(scheduled_at) into v_last
      from assessments
      where sales_rep_id = v_rep and status = 'scheduled' and scheduled_at is not null
        and (timezone(v_tz, scheduled_at))::date = v_day;
    v_cluster := v_last is not null;

    v_cands := array[]::timestamptz[];
    if v_cluster and (v_last + interval '65 minutes') between v_ws and v_we then
      v_cands := array[v_last + interval '65 minutes'];
    end if;
    if array_length(v_cands, 1) is null then
      v_cands := array[v_ws];
      if v_ws + interval '3 hours' <= v_we then
        v_cands := v_cands || (v_ws + interval '3 hours');
      end if;
    end if;

    foreach v_cand in array v_cands loop
      exit when v_count >= 3;
      if v_cand <= now() then continue; end if;
      select count(*) into v_conflict
        from assessments
        where sales_rep_id = v_rep and status = 'scheduled' and scheduled_at is not null
          and abs(extract(epoch from (scheduled_at - v_cand))) < 45 * 60;
      if v_conflict > 0 then continue; end if;
      v_out := v_out || jsonb_build_object(
        'iso', to_char(v_cand at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        'label', trim(to_char(v_cand at time zone v_tz, 'Dy DD Mon FMHH12:MIam')),
        'cluster', v_cluster
      );
      v_count := v_count + 1;
    end loop;
  end loop;

  return v_out;
end $$;
revoke all on function public.technician_windows(uuid) from public, anon;
grant execute on function public.technician_windows(uuid) to authenticated;

-- ============================================================================
-- Service-role state transitions for the inbound webhook. Granted to
-- service_role only: an ordinary authenticated user can NOT call these (they
-- would bypass the sales_rep ownership check), so the firewall holds.
-- ============================================================================

-- Confirm the visit from an SMS reply: sets the time, reveals the address to
-- the tech (status='scheduled'), marks the thread confirmed, logs the event.
create or replace function public.sms_confirm_visit(p_assessment_id uuid, p_scheduled_at timestamptz)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_a record;
begin
  select * into v_a from assessments where id = p_assessment_id;
  if v_a.id is null then raise exception 'assessment not found'; end if;
  if v_a.status not in ('claimed','scheduled') then
    raise exception 'cannot confirm from status %', v_a.status;
  end if;
  update assessments
    set scheduled_at = p_scheduled_at, status = 'scheduled', schedule_state = 'confirmed'
    where id = p_assessment_id;
  insert into events (site_id, lead_id, actor_type, actor_id, event_type, payload)
  select l.site_id, v_a.lead_id, 'system', 'sms', 'assessment.scheduled',
         jsonb_build_object('scheduled_at', p_scheduled_at, 'via', 'sms')
  from leads l where l.id = v_a.lead_id;
  return jsonb_build_object('ok', true, 'lead_id', v_a.lead_id);
end $$;
revoke all on function public.sms_confirm_visit(uuid, timestamptz) from public, anon, authenticated;
grant execute on function public.sms_confirm_visit(uuid, timestamptz) to service_role;

-- Release a claim (CANCEL / no-show intent): cancels the assessment so the lead
-- returns to the pool for another technician; the lead stays 'appointment_set'.
create or replace function public.sms_release_assessment(p_assessment_id uuid, p_reason text default 'customer_cancel')
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_a record;
begin
  select * into v_a from assessments where id = p_assessment_id;
  if v_a.id is null then raise exception 'assessment not found'; end if;
  update assessments set status = 'cancelled', schedule_state = 'cancelled' where id = p_assessment_id;
  insert into events (site_id, lead_id, actor_type, actor_id, event_type, payload)
  select l.site_id, v_a.lead_id, 'system', 'sms', 'assessment.cancelled',
         jsonb_build_object('reason', p_reason, 'via', 'sms')
  from leads l where l.id = v_a.lead_id;
  return jsonb_build_object('ok', true, 'lead_id', v_a.lead_id);
end $$;
revoke all on function public.sms_release_assessment(uuid, text) from public, anon, authenticated;
grant execute on function public.sms_release_assessment(uuid, text) to service_role;

-- Mark a thread as awaiting fresh windows (RESCHEDULE): the Edge Function then
-- re-runs sms-offer-windows.
create or replace function public.sms_mark_reschedule(p_assessment_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  update assessments set schedule_state = 'reschedule',
    scheduled_at = case when status = 'scheduled' then null else scheduled_at end,
    status = case when status = 'scheduled' then 'claimed' else status end
    where id = p_assessment_id;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.sms_mark_reschedule(uuid) from public, anon, authenticated;
grant execute on function public.sms_mark_reschedule(uuid) to service_role;

-- ============================================================================
-- Public trust badge (intro-SMS link target): the technician's name, first
-- name, photo, accreditation, and region — NO customer data. Anyone with the
-- link can read it (the customer needs to before they're logged in anywhere).
-- ============================================================================
create or replace function public.tech_badge(p_rep uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'full_name', r.full_name,
    'first_name', split_part(r.full_name, ' ', 1),
    'photo_url', r.photo_url,
    'accreditation', r.accreditation,
    'verified', r.status in ('approved','active','conditionally_active'),
    'police_checked', r.police_check_ref is not null
  )
  from sales_reps r
  where r.id = p_rep and r.status in ('approved','active','conditionally_active');
$$;
revoke all on function public.tech_badge(uuid) from public;
grant execute on function public.tech_badge(uuid) to anon, authenticated;
