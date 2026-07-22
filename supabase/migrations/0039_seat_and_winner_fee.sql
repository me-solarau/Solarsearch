-- me-solar revenue model: $80 seat per quoting installer + 7% winner fee on the
-- deal value (ex-GST subtotal), charged to the installer the customer selects.
-- (The installer's own 34% material margin + labour rate card is separate.)
alter table public.pricing_config add column if not exists seat_fee numeric(10,2) not null default 80;
alter table public.pricing_config add column if not exists winner_fee_pct numeric(6,2) not null default 7;
alter table public.pricing_config add column if not exists winner_fee_base text not null default 'ex_gst_subtotal';
update public.pricing_config set seat_fee=80, winner_fee_pct=7, winner_fee_base='ex_gst_subtotal', updated_at=now() where id;
