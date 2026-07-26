-- Two new service streams for the 1 Aug go-live, each with a role vacancy:
--   * Edge protection — MANDATORY height-safety for every solar roof install.
--       $180 incl / 20m linear + $30/day after 3 included days.
--   * Solar cleaning — standalone service, priced by system size.
-- Both roles are engaged as independent contractors on a 12-month term, renewable on
-- performance (T&Cs live in apply.html). This migration adds the applyable roles + the
-- pricing storage; the quote/booking application logic lands once the billing rules are set.

-- 1) Role vacancies through the same access-application + T&C gate.
alter table public.access_applications drop constraint if exists access_applications_app_check;
alter table public.access_applications add constraint access_applications_app_check
  check (app in ('sales_tech','installer','inspector','retailer','edge_protection','cleaner'));

create or replace function public.apply_for_access(p_app text, p_full_name text, p_email text,
                                                    p_phone text default null, p_terms_ref text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_uid uuid := auth.uid(); v_status text;
begin
  if v_uid is null then raise exception 'sign in first'; end if;
  if p_app not in ('sales_tech','installer','inspector','retailer','edge_protection','cleaner') then
    raise exception 'unknown app %', p_app;
  end if;
  insert into access_applications (user_id, app, full_name, email, phone, terms_ref, terms_accepted_at, status)
  values (v_uid, p_app, p_full_name, p_email, p_phone, p_terms_ref, now(), 'pending')
  on conflict (user_id, app) do update set
    full_name = excluded.full_name, email = excluded.email, phone = excluded.phone,
    terms_ref = excluded.terms_ref, terms_accepted_at = now(),
    status = case when access_applications.status = 'denied' then 'pending' else access_applications.status end
  returning status into v_status;
  return jsonb_build_object('ok', true, 'status', v_status);
end $$;

-- 2) Pricing storage (tunable without a deploy). GST-inclusive where noted.
-- Edge protection (mandatory on installs):
alter table public.pricing_config add column if not exists edge_protect_per_20m_incl  numeric(10,2) not null default 180;  -- $ incl per 20m linear
alter table public.pricing_config add column if not exists edge_protect_extra_day_incl numeric(10,2) not null default 30;   -- $ incl per day after the included days
alter table public.pricing_config add column if not exists edge_protect_free_days      int          not null default 3;     -- days included before extra-day charge

-- Solar cleaning tiers by system kW (upper bound of each band; >30kW is custom-quoted):
alter table public.pricing_config add column if not exists clean_price_le_6_6   numeric(10,2) not null default 250;  -- <= 6.6 kW
alter table public.pricing_config add column if not exists clean_price_le_13_2  numeric(10,2) not null default 299;  -- 6.61 - 13.2 kW
alter table public.pricing_config add column if not exists clean_price_le_20    numeric(10,2) not null default 375;  -- 13.21 - 20 kW
alter table public.pricing_config add column if not exists clean_price_le_30    numeric(10,2) not null default 499;  -- 20.01 - 30 kW
-- > 30 kW: quote (no fixed price)

-- Helper: cleaning price for a system size (null => custom quote for >30kW).
create or replace function public.cleaning_price(p_kw numeric)
returns numeric language sql stable set search_path=public as $$
  select case
    when p_kw is null then null
    when p_kw <= 6.6  then (select clean_price_le_6_6  from pricing_config limit 1)
    when p_kw <= 13.2 then (select clean_price_le_13_2 from pricing_config limit 1)
    when p_kw <= 20   then (select clean_price_le_20   from pricing_config limit 1)
    when p_kw <= 30   then (select clean_price_le_30   from pricing_config limit 1)
    else null  -- >30kW: custom quote
  end;
$$;
grant execute on function public.cleaning_price(numeric) to authenticated;
