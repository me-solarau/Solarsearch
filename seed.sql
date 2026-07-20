-- ============================================================================
-- SOLARSEARCH SEED DATA — Hunter pilot
-- ============================================================================

-- Region: Newcastle & Greater Hunter
insert into regions (id, name, state, status, seat_price_cents, commission_per_stc_cents, launched_at)
values ('11111111-1111-1111-1111-111111111111','Newcastle & Greater Hunter','NSW','pilot',20000,110,current_date);

insert into region_postcodes (region_id, postcode)
select '11111111-1111-1111-1111-111111111111', p from unnest(array[
 '2280','2281','2282','2283','2284','2285','2286','2287','2289','2290','2291','2292','2293','2294','2295','2296','2297','2298','2299',
 '2300','2302','2303','2304','2305','2306','2307','2308',
 '2315','2316','2317','2318','2319','2320','2321','2322','2323','2324','2325','2326','2327','2330','2333','2334','2335'
]) as p;

-- DNSPs
insert into dnsps (id, name, state, application_channel, portal_url, typical_turnaround_days, approve_before_install)
values
 ('22222222-2222-2222-2222-222222222221','Ausgrid','NSW','portal','https://www.ausgrid.com.au',10,true),
 ('22222222-2222-2222-2222-222222222222','Essential Energy','NSW','portal','https://www.essentialenergy.com.au',15,true);

insert into dnsp_postcodes (dnsp_id, postcode)
select '22222222-2222-2222-2222-222222222221', p from unnest(array['2280','2281','2282','2283','2284','2285','2286','2287','2289','2290','2291','2292','2293','2294','2295','2296','2297','2298','2299','2300','2302','2303','2304','2305','2306','2307','2308','2315','2316','2317','2318','2319','2320','2321','2322','2323','2324']) as p;
insert into dnsp_postcodes (dnsp_id, postcode)
select '22222222-2222-2222-2222-222222222222', p from unnest(array['2325','2326','2327','2330','2333','2334','2335']) as p;

-- Incentive rules (Jul–Dec 2026 window)
insert into incentive_rules (version, scope, effective_from, effective_to, rules) values
 ('v2026.05','federal_battery','2026-05-01','2026-12-31',
  '{"stc_factor":6.8,"stc_price_cents":3700,"tiers":[[14,1.0],[28,0.6],[50,0.15]],"next_stepdown":"2027-01-01"}'),
 ('v2026.05','federal_solar_stc','2026-01-01','2026-12-31',
  '{"stc_per_kw_zone3":34,"stc_price_cents":3700}');

-- Pilot installer (placeholder details — replace with the real partner)
insert into installers (id, company_name, abn, status, saa_accreditation, saa_expiry, contact_name, contact_email, agency_agreement_signed_at)
values ('33333333-3333-3333-3333-333333333333','Pilot Installer Pty Ltd','00 000 000 000','approved','A1234567','2027-06-30','TBC','tbc@example.com', now());

insert into installer_service_areas (installer_id, region_id, postcode, tiers, weekly_capacity)
select '33333333-3333-3333-3333-333333333333','11111111-1111-1111-1111-111111111111', postcode, '{seats,raw_leads,appointments}', 6
from region_postcodes where region_id = '11111111-1111-1111-1111-111111111111';

insert into price_books (installer_id, name, verified_at, base_rates, adders, preferred_equipment)
values ('33333333-3333-3333-3333-333333333333','Hunter 2026', now(),
 '{"solar_per_kw_cents":135000,"solar_fixed_cents":160000,"battery_per_kwh_cents":82000,"battery_fixed_cents":280000}',
 '{"two_storey_cents":45000,"tile_roof_cents":35000,"switchboard_upgrade_cents":180000,"three_phase_cents":60000}',
 '{"panel":"Jinko Tiger Neo 440W","inverter":"Sungrow SH-RS hybrid","battery":"Sungrow SBR"}');

-- HQ admin (link auth_uid after first login)
insert into staff (full_name, role, regions) values
 ('Johan (Admin)','admin', array['11111111-1111-1111-1111-111111111111']::uuid[]),
 ('Consultant One','consultant', array['11111111-1111-1111-1111-111111111111']::uuid[]);
