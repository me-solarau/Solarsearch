-- ============================================================================
-- Supplier invoice ingestion = actual paid prices (ground truth) + auto "in_use".
-- An invoice (uploaded in HQ now, or emailed to an inbox webhook later) is
-- AI-read into {supplier, lines[]}; invoice_apply records the purchase, updates
-- that supplier's price to what was actually paid, flags the part in_use, and
-- stores prior price + delta per line so price drift is visible.
-- ============================================================================
create table if not exists public.supplier_invoices (
  id uuid primary key default gen_random_uuid(),
  supplier_code text references public.suppliers(code),
  invoice_no text,
  invoice_date date,
  source text not null default 'upload',   -- upload|email
  source_ref text,                         -- filename / email message id
  subtotal numeric(12,2),
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);

create table if not exists public.invoice_lines (
  id uuid primary key default gen_random_uuid(),
  invoice_id uuid references public.supplier_invoices(id) on delete cascade,
  part_no text,
  description text,
  qty numeric,
  unit_price numeric(12,4),
  matched boolean not null default false,     -- matched to a catalog part_no
  prev_price numeric(12,4),                   -- this supplier's price before the invoice
  price_delta numeric(12,4)                   -- unit_price - prev_price (null if new)
);

alter table public.supplier_invoices enable row level security;
alter table public.invoice_lines     enable row level security;
drop policy if exists supplier_invoices_all on public.supplier_invoices;
create policy supplier_invoices_all on public.supplier_invoices for all using (public.is_admin()) with check (public.is_admin());
drop policy if exists invoice_lines_all on public.invoice_lines;
create policy invoice_lines_all on public.invoice_lines for all using (public.is_admin()) with check (public.is_admin());

-- Apply an AI-read invoice. p_invoice = { invoice_no, invoice_date, source,
-- source_ref, subtotal, lines:[{part_no, description, qty, unit_price}] }.
create or replace function public.invoice_apply(p_supplier_code text, p_invoice jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_inv uuid; v_line jsonb; v_pn text; v_price numeric; v_qty numeric;
  v_canon record; v_prev numeric; v_matched int := 0; v_new int := 0;
  v_unmatched text[] := '{}'; v_drift jsonb := '[]'::jsonb; v_found boolean;
begin
  if not public.is_admin() then raise exception 'not authorised'; end if;
  if not exists (select 1 from suppliers where code = p_supplier_code) then
    raise exception 'unknown supplier %', p_supplier_code;
  end if;

  insert into supplier_invoices (supplier_code, invoice_no, invoice_date, source, source_ref, subtotal)
  values (p_supplier_code, nullif(p_invoice->>'invoice_no',''),
          nullif(p_invoice->>'invoice_date','')::date,
          coalesce(nullif(p_invoice->>'source',''),'upload'),
          nullif(p_invoice->>'source_ref',''),
          nullif(p_invoice->>'subtotal','')::numeric)
  returning id into v_inv;

  for v_line in select * from jsonb_array_elements(coalesce(p_invoice->'lines','[]'::jsonb)) loop
    v_pn := upper(trim(v_line->>'part_no'));
    v_price := nullif(v_line->>'unit_price','')::numeric;
    v_qty := nullif(v_line->>'qty','')::numeric;
    if v_pn is null or v_pn = '' then continue; end if;

    -- canonical catalog row (any supplier) to inherit category/spec/brand
    select brand, category, description, spec, url into v_canon
    from supplier_materials where upper(part_no) = v_pn
    order by (spec <> '{}'::jsonb) desc, captured_at desc limit 1;
    v_found := found;

    -- this supplier's current price, for drift
    select unit_price into v_prev from supplier_materials
    where supplier = p_supplier_code and upper(part_no) = v_pn;

    if not v_found then
      v_unmatched := array_append(v_unmatched, v_pn);
      insert into invoice_lines (invoice_id, part_no, description, qty, unit_price, matched)
      values (v_inv, v_pn, nullif(v_line->>'description',''), v_qty, v_price, false);
      continue;
    end if;

    if v_price is not null then
      insert into supplier_materials (supplier, brand, category, part_no, description, unit_price, spec, url, active, in_use, captured_at)
      values (p_supplier_code, coalesce(v_canon.brand,''), coalesce(v_canon.category,'accessory'), v_pn,
              coalesce(nullif(v_line->>'description',''), v_canon.description, v_pn),
              v_price, coalesce(v_canon.spec,'{}'::jsonb), v_canon.url, true, true, now())
      on conflict (supplier, part_no) do update
        set unit_price = excluded.unit_price, active = true, in_use = true, captured_at = now();
      -- mark the part in_use across all suppliers (it's an active component)
      update supplier_materials set in_use = true where upper(part_no) = v_pn;

      if v_prev is not null and v_prev <> v_price then
        v_drift := v_drift || jsonb_build_object('part_no', v_pn, 'old', v_prev, 'new', v_price,
                     'delta', round(v_price - v_prev, 2),
                     'pct', round((v_price - v_prev) / nullif(v_prev,0) * 100, 1));
      end if;
      if v_prev is null then v_new := v_new + 1; end if;
    end if;

    insert into invoice_lines (invoice_id, part_no, description, qty, unit_price, matched, prev_price, price_delta)
    values (v_inv, v_pn, nullif(v_line->>'description',''), v_qty, v_price, true, v_prev,
            case when v_prev is not null and v_price is not null then round(v_price - v_prev,2) else null end);
    v_matched := v_matched + 1;
  end loop;

  return jsonb_build_object('invoice_id', v_inv, 'matched', v_matched, 'new_for_supplier', v_new,
    'unmatched', v_unmatched, 'unmatched_count', coalesce(array_length(v_unmatched,1),0),
    'drift', v_drift);
end $$;

-- Convenience: current best (lowest) live price per part across suppliers.
create or replace view public.material_best_price as
select part_no, brand, category,
       min(unit_price) filter (where unit_price is not null) as best_price,
       (array_agg(supplier order by unit_price nulls last))[1] as best_supplier,
       count(*) filter (where unit_price is not null) as priced_suppliers
from public.supplier_materials
where active
group by part_no, brand, category;
