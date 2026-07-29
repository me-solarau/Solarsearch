-- Supplier buy prices were readable by anon.
--
-- supplier_materials is correctly protected by RLS, but material_best_price and
-- cable_quote_price are SECURITY DEFINER views: they execute as their owner and
-- bypass that protection. Both carried a SELECT grant to anon, and the anon key
-- ships in the public website bundle — so anyone could read 425 rows of buy
-- prices along with best_supplier, i.e. the whole cost base and which merchant
-- gives the best price on each part.
--
-- Confirmed before the fix, running as anon:
--   material_best_price   425 rows visible
--   cable_quote_price      40 rows visible
--   supplier_materials     blocked by RLS (the table itself was fine)
--
-- Nothing client-side reads these views. The only consumer is quote_estimate(),
-- which is itself SECURITY DEFINER and therefore unaffected by the revoke.
-- Access is removed from anon AND authenticated: an installer or technician
-- with a login has no business seeing Solarsearch's buy prices either.

revoke all on public.material_best_price from anon, authenticated;
revoke all on public.cable_quote_price   from anon, authenticated;

comment on view public.material_best_price is
  'Supplier buy prices — COMMERCIALLY SENSITIVE. No direct grants to anon or authenticated; '
  'reach it only through a SECURITY DEFINER function that gates on is_admin().';
comment on view public.cable_quote_price is
  'Cable buy prices — COMMERCIALLY SENSITIVE. No direct grants to anon or authenticated.';
