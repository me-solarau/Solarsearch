-- ============================================================================
-- Installer portal foundation: identity link + firewalled board + seat/quote
-- All installer-facing reads/writes go through SECURITY DEFINER RPCs that
-- whitelist columns and scope to the caller's own installer row via auth_uid,
-- so base-table RLS stays staff-only and the cross-installer + customer-PII
-- firewall can't be bypassed by a crafted PostgREST query.
-- ============================================================================

-- 1. Identity: link an installer login to its installers row.
alter table public.installers add column if not exists auth_uid uuid unique;

-- Auto-link an installer auth user to its row by matching contact_email, and
-- give it the 'installer' portal role. Runs alongside the existing staff link.
create or replace function public.link_installer_on_signup()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_installer_id uuid;
begin
  select id into v_installer_id from installers
    where lower(contact_email) = lower(new.email) and auth_uid is null limit 1;
  if v_installer_id is not null then
    update installers set auth_uid = new.id where id = v_installer_id;
    insert into user_roles (user_id, role) values (new.id, 'installer')
      on conflict (user_id) do nothing;
  end if;
  return new;
end $$;
revoke execute on function public.link_installer_on_signup() from anon, authenticated, public;

drop trigger if exists on_auth_user_created_installer on auth.users;
create trigger on_auth_user_created_installer
  after insert on auth.users
  for each row execute function public.link_installer_on_signup();

-- Helper: resolve the calling installer's id (and require it be approved).
create or replace function public.current_installer_id()
returns uuid language sql stable security definer set search_path = public as $$
  select id from installers where auth_uid = auth.uid() and status = 'approved' limit 1;
$$;
grant execute on function public.current_installer_id() to authenticated;

-- Helper so buy_seat can reference the site's latest design id inline.
create or replace function public.v_design_id_safe(p_site_id uuid)
returns uuid language sql stable security definer set search_path = public as $$
  select id from designs where site_id = p_site_id order by created_at desc limit 1;
$$;

-- 2. Firewalled board: on-board sites in the caller's service-area postcodes.
-- Returns design + general location only; customer name/email never, and the
-- full street address only for sites where the caller already holds a seat.
create or replace function public.installer_board()
returns table (
  site_id uuid, ss_ref text, suburb text, postcode text, roof_type text, storeys smallint,
  system_kw numeric, battery_kwh numeric, seats_taken int, has_my_seat boolean,
  my_price_after_cents int, address text
)
language sql stable security definer set search_path = public as $$
  with me as (select current_installer_id() as iid)
  select s.id, s.ss_ref,
         nullif(trim(split_part(s.address, ',', -1)), '') as suburb,
         s.postcode, s.roof_type, s.storeys,
         d.system_kw, d.battery_kwh,
         (select count(*)::int from seats se where se.site_id = s.id) as seats_taken,
         exists(select 1 from seats se where se.site_id = s.id and se.installer_id = (select iid from me)) as has_my_seat,
         (select q.price_after_cents from quotes q
            where q.site_id = s.id and q.installer_id = (select iid from me)
            order by q.created_at desc limit 1) as my_price_after_cents,
         case when exists(select 1 from seats se where se.site_id = s.id and se.installer_id = (select iid from me))
              then s.address else null end as address
  from leads l
  join sites s on s.id = l.site_id
  join installer_service_areas isa on isa.installer_id = (select iid from me) and isa.postcode = s.postcode and not isa.paused
  left join lateral (select * from designs dd where dd.site_id = s.id order by created_at desc limit 1) d on true
  where (select iid from me) is not null
    and l.state in ('quoted','customer_chose')
  order by s.created_at desc;
$$;
grant execute on function public.installer_board() to authenticated;

-- 3. Buy a seat + generate a Path-1 auto-quote from the caller's price book,
-- the site design, and current incentive rules. Cap of 3 enforced by the
-- existing seats trigger. Mirrors the funnel's rebate maths (solar 34 STC/kW,
-- battery tiers 6.8x, $37/STC) so the customer sees consistent numbers.
create or replace function public.buy_seat(p_site_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_iid uuid := current_installer_id();
  v_state lead_state; v_seat_id uuid; v_pb record; v_design record;
  v_solar_fixed int; v_solar_per_kw int; v_bat_fixed int; v_bat_per_kwh int;
  v_before int; v_adders int := 0;
  v_kw numeric; v_kwh numeric;
  v_solar_stc int; v_bat_stc numeric := 0; v_prev numeric := 0; v_cap numeric; v_rate numeric;
  v_stc int; v_rebate int; v_after int; v_qid uuid; v_ver text;
  v_tiers numeric[][] := array[[14,1.0],[28,0.6],[50,0.15]];
  i int;
begin
  if v_iid is null then raise exception 'not an approved installer'; end if;
  select state into v_state from leads where site_id = p_site_id order by created_at desc limit 1;
  if v_state is null or v_state not in ('quoted','customer_chose') then raise exception 'site is not open for quoting'; end if;
  if not exists (select 1 from installer_service_areas where installer_id = v_iid and postcode = (select postcode from sites where id = p_site_id) and not paused) then
    raise exception 'site is outside your service areas';
  end if;

  select * into v_pb from price_books where installer_id = v_iid and active
    and (verified_at is null or verified_at > now() - interval '60 days')
    order by created_at desc limit 1;
  if v_pb.id is null then raise exception 'no active (non-stale) price book — verify your rates first'; end if;

  select * into v_design from designs where site_id = p_site_id order by created_at desc limit 1;
  v_kw := coalesce(v_design.system_kw, 0);
  v_kwh := coalesce(v_design.battery_kwh, 0);

  -- seat (cap enforced by trigger)
  insert into seats (site_id, installer_id, path, price_cents)
  values (p_site_id, v_iid, 'path2_seat', 20000)
  returning id into v_seat_id;

  -- pricing from the installer's price book
  v_solar_fixed  := coalesce((v_pb.base_rates->>'solar_fixed_cents')::int, 160000);
  v_solar_per_kw := coalesce((v_pb.base_rates->>'solar_per_kw_cents')::int, 135000);
  v_bat_fixed    := coalesce((v_pb.base_rates->>'battery_fixed_cents')::int, 280000);
  v_bat_per_kwh  := coalesce((v_pb.base_rates->>'battery_per_kwh_cents')::int, 82000);
  v_before := v_solar_fixed + round(v_solar_per_kw * v_kw)
              + case when v_kwh > 0 then v_bat_fixed + round(v_bat_per_kwh * v_kwh) else 0 end;
  select storeys, roof_type into v_design from sites where id = p_site_id;
  if coalesce(v_design.storeys,1) >= 2 then v_adders := v_adders + coalesce((v_pb.adders->>'two_storey_cents')::int,0); end if;
  if v_design.roof_type = 'tile' then v_adders := v_adders + coalesce((v_pb.adders->>'tile_roof_cents')::int,0); end if;
  v_before := v_before + v_adders;

  -- rebate (mirrors funnel RULES v2026.05): solar 34 STC/kW, battery tiers, $37/STC
  v_solar_stc := floor(v_kw * 34);
  for i in 1..array_length(v_tiers,1) loop
    v_cap := v_tiers[i][1]; v_rate := v_tiers[i][2];
    v_bat_stc := v_bat_stc + greatest(0, least(v_kwh, v_cap) - v_prev) * 6.8 * v_rate;
    v_prev := v_cap;
    exit when v_kwh <= v_cap;
  end loop;
  v_stc := v_solar_stc + floor(v_bat_stc);
  v_rebate := v_stc * 3700;
  v_after := greatest(0, v_before - v_rebate);

  select version into v_ver from incentive_rules order by effective_from desc limit 1;

  insert into quotes (site_id, design_id, installer_id, seat_id, path, price_book_id, rules_version,
                      price_before_rebates_cents, rebate_cents, price_after_cents, stc_count, status)
  values (p_site_id, v_design_id_safe(p_site_id), v_iid, v_seat_id, 'path1_auto', v_pb.id, coalesce(v_ver,'v2026.05'),
          v_before, v_rebate, v_after, v_stc, 'on_board')
  returning id into v_qid;

  insert into events (site_id, actor_type, actor_id, event_type, payload)
  values (p_site_id, 'installer', v_iid::text, 'seat.purchased',
          jsonb_build_object('seat_id', v_seat_id, 'quote_id', v_qid, 'price_after_cents', v_after));

  return jsonb_build_object('seat_id', v_seat_id, 'quote_id', v_qid,
    'price_after_cents', v_after, 'stc_count', v_stc);
end $$;

revoke all on function public.buy_seat(uuid) from public;
grant execute on function public.buy_seat(uuid) to authenticated;
