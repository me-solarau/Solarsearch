-- Cable was being double-counted. Johan's rule, verbatim:
--
--   "the first 25m dc and 5m ac is included in the labour cost as a default,
--    but additional dc rates per meter after 25m apply and ac rates based on
--    inverter size applies per meter after 5m. hybrid inverters have a back up
--    cable = ac meters x 2"
--
-- The previous cable_charge() billed the dc_cable_run base ($550) and the
-- ac_cable_run base ($95) on EVERY quote — $645 of cable that the $0.35/W
-- labour rate already covers. Bases are no longer charged. Only excess metres.
--
-- AC is sized off the INVERTER kW rating, not the array:
--    <=10kW         10mm, flat per-metre over-rate from the rate card ($12.50)
--    >10kW 1-phase  16mm 2C+E   $17.24/m x 1.45 markup = $25.00/m
--    >10kW 3-phase  16mm 4C+E   $30.31/m x 1.45 markup = $43.95/m
--
-- Verified against the subcontract stream at $0.35/W:
--   standard 25m/5m, 5kW          cable $0.00      total incl GST  $2,541
--   45m DC (20m over)             cable $283.20    total           $2,852.52
--   25m AC (20m over), 5kW        cable $250.00    total           $2,816
--   25m AC, 15kW 1-phase          cable $499.96    total           $6,324.96
--   25m AC, 15kW 3-phase          cable $878.99    total           $6,741.89
--   same but hybrid (50m billed)  cable $1,977.73  total           $7,950.50

create or replace function public.ac_rate_per_m(
  p_inverter_kw numeric default null, p_phases int default 1)
returns numeric
language plpgsql
stable
set search_path to 'public'
as $function$
declare v_row record; v_mat numeric;
begin
  if coalesce(p_inverter_kw,0) <= 10 then
    select over_rate into v_mat from chargeables where code='ac_cable_run' and active;
    return coalesce(v_mat, 0);
  end if;

  select * into v_row from chargeables
   where code = case when coalesce(p_phases,1) >= 3 then 'ac_cable_run_16mm_3p'
                     else 'ac_cable_run_16mm_1p' end
     and active;
  if v_row.code is null then return 0; end if;

  select min(unit_price) into v_mat from supplier_materials
   where active and unit_price is not null and part_no = v_row.meta->>'cable_ref';
  if v_mat is null then
    -- No material price on file: fall back to the 10mm over-rate rather than
    -- silently charging nothing for a heavier, more expensive cable.
    select over_rate into v_mat from chargeables where code='ac_cable_run' and active;
    return coalesce(v_mat, 0);
  end if;

  return round(v_mat * (1 + coalesce((v_row.meta->>'markup_pct')::numeric,45)/100.0), 4);
end $function$;

comment on function public.ac_rate_per_m(numeric,int) is
  'AC cable $/m beyond the included 5m, sized off the inverter kW rating and phase count.';

create or replace function public.cable_charge(
  p_dc_m numeric,
  p_ac_m numeric,
  p_inverter_kw numeric default null,
  p_phases int default 1,
  p_hybrid boolean default false
)
returns numeric
language sql
stable
set search_path to 'public'
as $$
  select round(
      greatest(0, coalesce(p_dc_m,0)
        - coalesce((select included_qty from chargeables where code='dc_cable_run' and active), 25))
      * coalesce((select over_rate from chargeables where code='dc_cable_run' and active), 0)
    + greatest(0, coalesce(p_ac_m,0) * (case when p_hybrid then 2 else 1 end)
        - coalesce((select included_qty from chargeables where code='ac_cable_run' and active), 5))
      * public.ac_rate_per_m(p_inverter_kw, p_phases)
  , 2);
$$;

comment on function public.cable_charge(numeric,numeric,numeric,int,boolean) is
  'Cable charged on EXCESS LENGTH ONLY — the first 25m DC and 5m AC are included in the labour '
  'rate. AC priced per the inverter rating; a hybrid inverter doubles the billable AC length for '
  'its backup cable.';

drop function if exists public.cable_charge(numeric, numeric);
drop function if exists public.cable_charge(numeric, numeric, numeric, int);
drop function if exists public.ac_cable_charge(numeric, numeric, int);

grant execute on function public.ac_rate_per_m(numeric,int) to authenticated;
grant execute on function public.cable_charge(numeric,numeric,numeric,int,boolean) to authenticated;

alter table public.designs add column if not exists inverter_hybrid boolean not null default false;
alter table public.designs add column if not exists inverter_kw numeric;
alter table public.designs add column if not exists phases smallint;
comment on column public.designs.inverter_hybrid is
  'Hybrid inverters carry a backup cable, so the billable AC run is doubled.';
