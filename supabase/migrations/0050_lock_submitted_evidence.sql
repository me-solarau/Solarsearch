-- Lock in evidence: once an assessment is submitted, its photos are immutable — no insert,
-- update or delete of any assessment_photos row whose parent assessment has submitted_at set.
-- This makes the capture set, the no-access evidence, their GPS and timestamps a tamper-proof
-- audit trail (customer protection, no-access integrity, disputes). Admins retain an override
-- for corrections / legal holds. During capture (pre-submission) editing works as before.
create or replace function public.lock_submitted_evidence()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_aid uuid; v_submitted timestamptz;
begin
  v_aid := coalesce(NEW.assessment_id, OLD.assessment_id);
  select submitted_at into v_submitted from assessments where id = v_aid;
  if v_submitted is not null and not public.is_admin() then
    raise exception 'evidence is locked — assessment % was already submitted', v_aid
      using errcode = 'check_violation';
  end if;
  return case when TG_OP = 'DELETE' then OLD else NEW end;
end $$;

drop trigger if exists assessment_photos_lock on public.assessment_photos;
create trigger assessment_photos_lock
  before insert or update or delete on public.assessment_photos
  for each row execute function public.lock_submitted_evidence();
