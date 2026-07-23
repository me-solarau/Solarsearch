-- Final link in the money trail: STC verification (the 30% milestone). Until now the
-- pipeline was timestamped + evented through install.submitted (60%), but there was no
-- record for "STCs confirmed/created" — so the last 30% had no auditable trigger. This adds
-- the missing event + timestamp, mirroring accept_install / submit_install.
--
-- STC verification is an HQ/staff action (the certificates are confirmed against the CER /
-- clearing house), so this is admin-only. It requires the install to have been submitted
-- (status 'installed'), stamps the STC details, and emits `stc.verified` — the documented,
-- timestamped basis to release the final 30%. It does NOT close the job or advance the lead:
-- DER registration and audit still follow, and closing is a later, separate step.

alter table public.installs add column if not exists stc_verified_at timestamptz;
alter table public.installs add column if not exists stc_count       int;
alter table public.installs add column if not exists stc_reference    text;

create or replace function public.verify_stc(p_install uuid, p_stc_count int default null, p_reference text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_i record;
begin
  if not public.is_admin() then raise exception 'not authorised'; end if;
  select * into v_i from installs where id = p_install;
  if v_i.id is null then raise exception 'install not found'; end if;
  if v_i.stc_verified_at is not null then
    return jsonb_build_object('ok', true, 'already', true, 'stc_verified_at', v_i.stc_verified_at);
  end if;
  -- Can't verify STCs for a job that hasn't been installed (evidence submitted) yet.
  if v_i.status not in ('installed','closed') then
    raise exception 'install must be submitted before STC verification (status is %)', v_i.status;
  end if;

  update installs
     set stc_verified_at = now(),
         stc_count       = coalesce(p_stc_count, stc_count),
         stc_reference   = coalesce(p_reference, stc_reference)
   where id = p_install;

  -- Records the STC milestone only. DER registration, audit and closing are separate,
  -- later steps — this does not touch install.status or the lead state.
  insert into events (site_id, lead_id, actor_type, actor_id, event_type, payload)
  select l.site_id, v_i.lead_id, 'admin', auth.uid()::text, 'stc.verified',
         jsonb_build_object('install_id', p_install, 'stc_count', p_stc_count, 'reference', p_reference)
  from leads l where l.id = v_i.lead_id;

  return jsonb_build_object('ok', true, 'stc_verified_at', now());
end $$;

revoke all on function public.verify_stc(uuid, int, text) from public;
grant execute on function public.verify_stc(uuid, int, text) to authenticated;
