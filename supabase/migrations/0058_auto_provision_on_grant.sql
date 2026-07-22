-- Auto-provision the role when an access application is granted, so approval is one step:
-- granting a sales_tech / installer application now creates (or re-activates) the role row as
-- 'approved', which is what current_sales_rep_id()/current_installer_id() resolve — the person
-- can use the app immediately. Grant is still blocked unless the T&Cs were accepted.
-- Inspector lives outside this repo, so it is granted (recorded) but not provisioned here.
-- Provisioning is wrapped: if it fails (e.g. an unexpected NOT NULL), the grant still lands and
-- a note is attached so an admin can finish via the existing Onboard flow.
create or replace function public.decide_access(p_id uuid, p_granted boolean, p_note text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_app record; v_prov text := 'none';
begin
  if not public.is_admin() then raise exception 'not authorised'; end if;
  select * into v_app from access_applications where id = p_id;
  if v_app.id is null then raise exception 'application not found'; end if;

  if not p_granted then
    update access_applications set status='denied', decided_by=auth.uid(), decided_at=now(),
      note=coalesce(p_note, note) where id = p_id;
    return jsonb_build_object('ok', true, 'status', 'denied');
  end if;

  if v_app.terms_accepted_at is null then
    raise exception 'applicant must accept the Terms & Conditions before access can be granted';
  end if;

  update access_applications set status='granted', decided_by=auth.uid(), decided_at=now(),
    note=coalesce(p_note, note) where id = p_id;

  begin
    if v_app.app = 'sales_tech' then
      if exists (select 1 from sales_reps where user_id = v_app.user_id) then
        update sales_reps set status='approved',
          full_name=coalesce(full_name, v_app.full_name), email=coalesce(email, v_app.email),
          phone=coalesce(phone, v_app.phone),
          contractor_terms_at=coalesce(contractor_terms_at, v_app.terms_accepted_at),
          contractor_terms_ref=coalesce(contractor_terms_ref, v_app.terms_ref)
        where user_id = v_app.user_id;
      else
        insert into sales_reps (full_name, email, phone, user_id, status, contractor_terms_at, contractor_terms_ref)
        values (coalesce(v_app.full_name,'Technician'), v_app.email, v_app.phone, v_app.user_id,
                'approved', v_app.terms_accepted_at, v_app.terms_ref);
      end if;
      v_prov := 'sales_rep';
    elsif v_app.app = 'installer' then
      if exists (select 1 from installers where user_id = v_app.user_id) then
        update installers set status='approved' where user_id = v_app.user_id;
      else
        insert into installers (company_name, contact_email, user_id, status)
        values (coalesce(v_app.full_name, v_app.email, 'Installer'), v_app.email, v_app.user_id, 'approved');
      end if;
      v_prov := 'installer';
    end if;
  exception when others then
    update access_applications
      set note = coalesce(note,'') || ' [auto-provision failed: ' || sqlerrm || ' — onboard manually]'
      where id = p_id;
    v_prov := 'failed';
  end;

  return jsonb_build_object('ok', true, 'status', 'granted', 'provisioned', v_prov);
end $$;
