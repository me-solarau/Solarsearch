-- ============================================================================
-- Supplier RFQ + AI price-import loop.
-- suppliers: the RFQ recipients (multi-supplier pricing already works via
-- supplier_materials.supplier). in_use flags the SKUs we actually install so the
-- RFQ stays short. rfqs/rfq_lines record every request (our "what we quote"
-- history). price_imports logs each AI-read supplier return. price_import_apply
-- upserts a supplier's prices, inheriting category/spec/brand from the canonical
-- catalog row so a Green Tech quote line becomes a fully-formed priced row.
-- ============================================================================
create table if not exists public.suppliers (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,          -- matches supplier_materials.supplier
  name text not null,
  branch text,
  email text,
  phone text,
  contact_name text,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

insert into public.suppliers (code, name, branch) values
  ('goelectrical','Go Electrical','Tuggerah'),
  ('greentech','Green Tech','Newcastle'),
  ('learsmith','Lear & Smith','Lambton')
on conflict (code) do nothing;

alter table public.supplier_materials add column if not exists in_use boolean not null default false;

create table if not exists public.rfqs (
  id uuid primary key default gen_random_uuid(),
  supplier_code text references public.suppliers(code),
  status text not null default 'draft',   -- draft|sent|quoted|closed
  note text,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  sent_at timestamptz
);

create table if not exists public.rfq_lines (
  id uuid primary key default gen_random_uuid(),
  rfq_id uuid references public.rfqs(id) on delete cascade,
  part_no text not null,
  brand text,
  description text,
  qty int not null default 1,
  last_price numeric(12,4)                 -- our most recent known price, for reference
);

create table if not exists public.price_imports (
  id uuid primary key default gen_random_uuid(),
  supplier_code text references public.suppliers(code),
  source text not null default 'ai_quote',
  status text not null default 'applied',  -- proposed|applied
  summary jsonb,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);

alter table public.suppliers      enable row level security;
alter table public.rfqs           enable row level security;
alter table public.rfq_lines      enable row level security;
alter table public.price_imports  enable row level security;

drop policy if exists suppliers_read on public.suppliers;
create policy suppliers_read on public.suppliers for select using (public.is_active_staff() or public.is_admin());
drop policy if exists suppliers_write on public.suppliers;
create policy suppliers_write on public.suppliers for all using (public.is_admin()) with check (public.is_admin());

drop policy if exists rfqs_all on public.rfqs;
create policy rfqs_all on public.rfqs for all using (public.is_admin()) with check (public.is_admin());
drop policy if exists rfq_lines_all on public.rfq_lines;
create policy rfq_lines_all on public.rfq_lines for all using (public.is_admin()) with check (public.is_admin());
drop policy if exists price_imports_all on public.price_imports;
create policy price_imports_all on public.price_imports for all using (public.is_admin()) with check (public.is_admin());

-- Build an RFQ for a supplier from the flagged in-use catalog (canonical rows).
create or replace function public.rfq_build(p_supplier_code text, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_rfq uuid; v_count int;
begin
  if not public.is_admin() then raise exception 'not authorised'; end if;
  insert into rfqs (supplier_code, note, status) values (p_supplier_code, p_note, 'draft') returning id into v_rfq;
  insert into rfq_lines (rfq_id, part_no, brand, description, last_price)
  select v_rfq, m.part_no, m.brand, m.description,
         (select min(x.unit_price) from supplier_materials x where x.part_no = m.part_no and x.unit_price is not null)
  from supplier_materials m
  where m.in_use and m.active
  group by m.part_no, m.brand, m.description;
  get diagnostics v_count = row_count;
  return jsonb_build_object('rfq_id', v_rfq, 'lines', v_count);
end $$;

-- Apply an AI-extracted supplier quote: upsert per-supplier prices, inheriting
-- category/spec/brand from the canonical catalog row. Returns a match summary.
create or replace function public.price_import_apply(p_supplier_code text, p_lines jsonb, p_source text default 'ai_quote')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_line jsonb; v_pn text; v_price numeric; v_canon record;
  v_updated int := 0; v_unmatched text[] := '{}';
  v_import uuid;
begin
  if not public.is_admin() then raise exception 'not authorised'; end if;
  if not exists (select 1 from suppliers where code = p_supplier_code) then
    raise exception 'unknown supplier %', p_supplier_code;
  end if;

  for v_line in select * from jsonb_array_elements(coalesce(p_lines,'[]'::jsonb)) loop
    v_pn := upper(trim(v_line->>'part_no'));
    v_price := nullif(v_line->>'unit_price','')::numeric;
    if v_pn is null or v_pn = '' or v_price is null then continue; end if;

    select brand, category, description, spec, url into v_canon
    from supplier_materials where upper(part_no) = v_pn
    order by (spec <> '{}'::jsonb) desc, captured_at desc limit 1;

    if not found then
      v_unmatched := array_append(v_unmatched, v_pn);
      continue;
    end if;

    insert into supplier_materials (supplier, brand, category, part_no, description, unit_price, spec, url, active, captured_at)
    values (p_supplier_code, v_canon.brand, v_canon.category, v_pn,
            coalesce(nullif(v_line->>'description',''), v_canon.description),
            v_price, v_canon.spec, v_canon.url, true, now())
    on conflict (supplier, part_no) do update
      set unit_price = excluded.unit_price, description = excluded.description,
          active = true, captured_at = now();
    v_updated := v_updated + 1;
  end loop;

  insert into price_imports (supplier_code, source, status, summary)
  values (p_supplier_code, p_source, 'applied',
          jsonb_build_object('matched', v_updated, 'unmatched', v_unmatched,
                             'unmatched_count', coalesce(array_length(v_unmatched,1),0)))
  returning id into v_import;

  return jsonb_build_object('import_id', v_import, 'matched', v_updated,
    'unmatched', v_unmatched, 'unmatched_count', coalesce(array_length(v_unmatched,1),0));
end $$;
