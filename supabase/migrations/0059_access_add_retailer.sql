-- Allow retailer partner applications through the same access-application gate. Retailer
-- grants are recorded (no auto-provision here — retailers are provisioned via the existing
-- retailer conversion tooling in HQ), so decide_access needs no change.
alter table public.access_applications drop constraint if exists access_applications_app_check;
alter table public.access_applications add constraint access_applications_app_check
  check (app in ('sales_tech','installer','inspector','retailer'));

create or replace function public.apply_for_access(p_app text, p_full_name text, p_email text,
                                                    p_phone text default null, p_terms_ref text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_uid uuid := auth.uid(); v_status text;
begin
  if v_uid is null then raise exception 'sign in first'; end if;
  if p_app not in ('sales_tech','installer','inspector','retailer') then raise exception 'unknown app %', p_app; end if;
  insert into access_applications (user_id, app, full_name, email, phone, terms_ref, terms_accepted_at, status)
  values (v_uid, p_app, p_full_name, p_email, p_phone, p_terms_ref, now(), 'pending')
  on conflict (user_id, app) do update set
    full_name = excluded.full_name, email = excluded.email, phone = excluded.phone,
    terms_ref = excluded.terms_ref, terms_accepted_at = now(),
    status = case when access_applications.status = 'denied' then 'pending' else access_applications.status end
  returning status into v_status;
  return jsonb_build_object('ok', true, 'status', v_status);
end $$;
