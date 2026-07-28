-- STC verification = the retailer's release of the final 30% on the SUBCONTRACT pipeline.
-- (STC confirmation is only relevant where a retailer has subcontracted the install: the
-- retailer is paying the subcontractor and wants to see proof before the last payment.)
--
-- Flow:
--   1. Subcontractor uploads a formal STC photo/certificate  -> submit_stc_photo()
--   2. Retailer reviews it and is happy -> clicks approve    -> verify_stc()
--      which stamps + emits `stc.verified` — the documented, timestamped basis that
--      authorises the final 30% milestone charge (the Stripe charge stays a separate,
--      controlled step: create-milestone-payment for the 'stc' milestone).
--
-- Money is NOT moved here — this is the approval + audit record only. UI wiring (the
-- subcontractor's upload control in the install app, and the retailer's approve button)
-- lands when the retailer portal exists; this is the enforceable spine underneath it.

alter table public.installs add column if not exists stc_photo_path  text;
alter table public.installs add column if not exists stc_photo_at    timestamptz;
alter table public.installs add column if not exists stc_verified_at timestamptz;
alter table public.installs add column if not exists stc_count       int;
alter table public.installs add column if not exists stc_reference   text;

-- Step 1 — the subcontractor (the install's installer) attaches the formal STC photo.
-- Stored as a single path (install/<id>/stc...), separate from the locked install-evidence
-- set, so it can be added after submission without touching the immutable record.
create or replace function public.submit_stc_photo(p_install uuid, p_path text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_i record;
begin
  if p_path is null or length(trim(p_path)) = 0 then raise exception 'stc photo path required'; end if;
  select * into v_i from installs where id = p_install;
  if v_i.id is null then raise exception 'install not found'; end if;
  if not (public.is_admin() or v_i.installer_id = public.current_installer_id()) then
    raise exception 'not your install';
  end if;
  if v_i.pipeline <> 'subcontractor' then raise exception 'STC evidence applies to subcontracted installs only'; end if;
  if v_i.status not in ('installed','closed') then raise exception 'submit the install before adding STC evidence'; end if;
  if v_i.stc_verified_at is not null then raise exception 'STC already verified; evidence is locked'; end if;

  update installs set stc_photo_path = p_path, stc_photo_at = now() where id = p_install;

  insert into events (site_id, lead_id, actor_type, actor_id, event_type, payload)
  select l.site_id, v_i.lead_id, 'installer', v_i.installer_id::text, 'stc.photo_uploaded',
         jsonb_build_object('install_id', p_install)
  from leads l where l.id = v_i.lead_id;
  return jsonb_build_object('ok', true);
end $$;

-- Step 2 — the RETAILER (who owns the subcontracted job) approves the STC evidence. This
-- is the "happy, release final payment" action. Requires a photo to review. Stamps the
-- verification and emits `stc.verified` — the audit trigger for the final 30%.
create or replace function public.verify_stc(p_install uuid, p_stc_count int default null, p_reference text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_i record;
begin
  select * into v_i from installs where id = p_install;
  if v_i.id is null then raise exception 'install not found'; end if;
  if v_i.pipeline <> 'subcontractor' then raise exception 'STC verification applies to subcontracted installs only'; end if;
  -- The retailer who owns this job (or an admin) approves — not the subcontractor.
  if not (public.is_admin() or v_i.retailer_id = public.current_retailer_id()) then
    raise exception 'only the retailer for this job can verify STCs';
  end if;
  if v_i.stc_verified_at is not null then
    return jsonb_build_object('ok', true, 'already', true, 'stc_verified_at', v_i.stc_verified_at);
  end if;
  if v_i.stc_photo_path is null then raise exception 'no formal STC photo to review yet'; end if;

  update installs
     set stc_verified_at = now(),
         stc_count       = coalesce(p_stc_count, stc_count),
         stc_reference   = coalesce(p_reference, stc_reference)
   where id = p_install;

  -- Authorises the final 30%. The charge itself (create-milestone-payment for 'stc') is a
  -- separate, controlled step keyed off this event.
  insert into events (site_id, lead_id, actor_type, actor_id, event_type, payload)
  select l.site_id, v_i.lead_id, 'retailer', v_i.retailer_id::text, 'stc.verified',
         jsonb_build_object('install_id', p_install, 'stc_count', p_stc_count, 'reference', p_reference)
  from leads l where l.id = v_i.lead_id;

  return jsonb_build_object('ok', true, 'stc_verified_at', now());
end $$;

revoke all on function public.submit_stc_photo(uuid, text) from public;
revoke all on function public.verify_stc(uuid, int, text) from public;
grant execute on function public.submit_stc_photo(uuid, text) to authenticated;
grant execute on function public.verify_stc(uuid, int, text) to authenticated;
