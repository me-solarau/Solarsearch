-- Calibrate the me-solar baseline material margin 40% -> 34% to match the real
-- SimPro/Pylon quotes (validated on Jason Dawe). At 34% the instant estimate runs
-- slightly conservative vs the sent quotes -- the residual is our itemised battery
-- install / backup / admin labour, which SimPro bundled. Installers still override
-- via installer_rate_cards.material_margin_pct.
update public.pricing_config set material_margin_pct_default = 34, updated_at = now() where id;
