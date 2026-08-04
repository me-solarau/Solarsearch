-- NSW PDRS battery incentive (PRCs) — the rebate our battery quotes are missing.
--
-- GreenDeal partner mail (Aug 2026): from 1 Sep the PDRS extends to apartment,
-- commercial and large C&I batteries (BESS3-5). More immediately: RESIDENTIAL
-- battery PRCs exist TODAY — since 1 Jul 2026 batteries to 50kWh are eligible
-- with the incentive soft-capped at 28kWh, and solar is no longer required.
-- Every NSW battery quote we produce omits this, so we look roughly $70/kWh
-- dearer than any competitor who includes it.
--
-- Verified from public sources: PRCs = peak demand reduction capacity x network
-- loss factor x 10 (floored); NLF 1.04 Ausgrid / 1.05 Endeavour & Essential;
-- usable = 90% of nameplate; PRC price ~$3.50 (Jun 2026); 28kWh soft cap.
-- NOT confirmed: the per-kWh pass-through Me-Solar would actually receive from
-- its ACP. The estimate is anchored to GreenDeal's own calculator example
-- (9.8kWh GoodWe: $3,105.60 total, less 66 national STC at $2,442 leaves
-- ~$663.60 PRC => ~$70 per usable kWh) and is marked unconfirmed. Binding board
-- quotes do NOT use it until Johan confirms the ACP rate — money decisions are
-- raised, never silently implemented.

-- The scope check predates state schemes having their own identity; widen it.
alter table public.incentive_rules drop constraint if exists incentive_rules_scope_check;
alter table public.incentive_rules add constraint incentive_rules_scope_check
  check (scope = any (array['federal_battery','federal_solar_stc','state_scheme','nsw_pdrs_bess2','nsw_pdrs_bess_commercial']));

insert into public.incentive_rules (version, scope, state, effective_from, effective_to, rules)
select 'v2026.08', 'nsw_pdrs_bess2', 'NSW', current_date, null,
       jsonb_build_object(
         'rebate_per_usable_kwh_cents', 7000,
         'kwh_cap', 28,
         'prc_price_cents_reference', 350,
         'network_loss_factor', jsonb_build_object('ausgrid',1.04,'endeavour',1.05,'essential',1.05),
         'confirmed', false,
         'anchor', 'GreenDeal partner calculator Aug 2026: 9.8kWh GoodWe -> $663.60 PRC component',
         'note', 'ESTIMATE ONLY. Confirm the actual per-PRC / per-kWh pass-through with the ACP (GreenDeal) and battery VPP eligibility before applying to binding quotes.')
where not exists (
  select 1 from public.incentive_rules where version='v2026.08' and scope='nsw_pdrs_bess2');

create or replace function public.nsw_battery_prc_estimate(p_usable_kwh numeric)
returns numeric
language sql
stable
set search_path to 'public'
as $$
  select coalesce((
    select round(least(greatest(p_usable_kwh,0), coalesce((r.rules->>'kwh_cap')::numeric,28))
                 * coalesce((r.rules->>'rebate_per_usable_kwh_cents')::numeric,0) / 100.0, 2)
    from incentive_rules r
    where r.scope='nsw_pdrs_bess2'
      and r.effective_from <= current_date
      and (r.effective_to is null or r.effective_to >= current_date)
    order by r.effective_from desc limit 1
  ), 0);
$$;

comment on function public.nsw_battery_prc_estimate(numeric) is
  'Estimated NSW PDRS battery (PRC) rebate in dollars for a usable-kWh capacity, from the '
  'current nsw_pdrs_bess2 incentive rule. UNCONFIRMED pass-through — estimate tool only.';

grant execute on function public.nsw_battery_prc_estimate(numeric) to anon, authenticated;
