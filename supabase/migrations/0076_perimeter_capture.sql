-- Capture the roof perimeter so edge protection is priced on the real measurement.
--
-- `designs.edge_perimeter_m` and the 6-argument `create_design(...)` already existed, but
-- nothing ever collected the number: every live quote fell back to the one-block $180 minimum
-- regardless of the actual roof. This adds the capture path and closes two holes around it.
--
-- Hole 1 — the ambiguous overload. Both the old 5-arg `create_design` and the newer 6-arg
-- version were live. PostgREST resolves by the argument names supplied, so a caller that
-- omitted p_edge_perimeter_m silently landed on the 5-arg version and the perimeter was
-- discarded with no error. Dropping the 5-arg form leaves exactly one path, and because the
-- new parameter defaults to null, every existing caller keeps working unchanged.
--
-- Hole 2 — no way to correct a measurement. A perimeter mis-typed at design time was frozen
-- into the design row with no supported way to fix it, which meant a wrong edge-protection
-- charge on the customer's agreement. `set_edge_perimeter()` allows the correction and writes
-- an event recording the before/after, so the change is visible in the audit trail rather than
-- being an unexplained price movement. It refuses once the customer has signed — at that point
-- the figure is contractual and a variation is the correct instrument, not an edit.

-- ---------------------------------------------------------------------------
-- 1. One create_design, not two.
-- ---------------------------------------------------------------------------
drop function if exists public.create_design(uuid, numeric, numeric, jsonb, uuid);

-- ---------------------------------------------------------------------------
-- 2. Correcting a perimeter after the design is saved.
-- ---------------------------------------------------------------------------
create or replace function public.set_edge_perimeter(
  p_lead_id uuid,
  p_perimeter_m numeric,
  p_staff_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_site_id uuid; v_design record; v_lead record; v_old numeric;
begin
  if not public.is_admin() then
    raise exception 'admin only';
  end if;
  if p_perimeter_m is not null and p_perimeter_m < 0 then
    raise exception 'perimeter cannot be negative';
  end if;

  select * into v_lead from leads where id = p_lead_id;
  if v_lead.id is null then raise exception 'lead not found'; end if;
  v_site_id := v_lead.site_id;

  -- Once signed, the edge-protection figure is part of an executed agreement.
  if v_lead.state in ('signed','connection_approved','installed','der_registered','audited','closed') then
    raise exception 'cannot change the perimeter after the customer has signed — raise a variation instead';
  end if;

  select * into v_design from designs where site_id = v_site_id order by created_at desc limit 1;
  if v_design.id is null then raise exception 'no design for this lead yet'; end if;

  v_old := v_design.edge_perimeter_m;
  update designs set edge_perimeter_m = p_perimeter_m where id = v_design.id;

  insert into events (site_id, lead_id, actor_type, actor_id, event_type, payload)
  values (v_site_id, p_lead_id, 'staff', p_staff_id::text, 'design.edge_perimeter_set',
    jsonb_build_object(
      'design_id', v_design.id,
      'from_m', v_old,
      'to_m', p_perimeter_m,
      'from_cents', public.edge_protection_cents(v_old),
      'to_cents', public.edge_protection_cents(p_perimeter_m)));

  return jsonb_build_object(
    'design_id', v_design.id,
    'edge_perimeter_m', p_perimeter_m,
    'edge_protection_cents', public.edge_protection_cents(p_perimeter_m));
end $function$;

comment on function public.set_edge_perimeter(uuid, numeric, uuid) is
  'Correct the measured roof perimeter on the latest design. Admin only, refused after signature, '
  'and always writes design.edge_perimeter_set to the append-only event log.';

revoke all on function public.set_edge_perimeter(uuid, numeric, uuid) from public, anon;
grant execute on function public.set_edge_perimeter(uuid, numeric, uuid) to authenticated;
