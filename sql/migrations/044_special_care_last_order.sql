-- ============================================================================
-- Migration 044 — Special care: last order of each client
-- ============================================================================
-- Clément, 24 Nov 2026: the Special care page should show, for each client,
-- the last order — date, products and quantities.
--
-- special_care_last_orders() (admin) → { code: {...} } for every active
-- special care client:
--   last      — the latest working paper of the client (latest delivery date,
--               then production day): date, PO, status, part, and its lines
--               (product, ordered quantity as written, number + unit, actual
--               kg when weighed), total kg;
--   orders_30 — working papers of the client delivered in the last 30 days
--               (parts of the same PO counted once);
--   invoice   — when PACE has no working paper for the client: the last Odoo
--               invoice loaded in Sales (date, number, amount; no products).
-- Papers are matched to the client like everywhere else in PACE
-- (sales_code_for_name on the name written on the paper). Papers still being
-- uploaded or read, or that failed, are not orders yet and are skipped.
--
-- Run order: after 043. Safe to re-run. No table change.
-- ============================================================================

create or replace function public.special_care_last_orders()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_today date := (now() at time zone 'Asia/Bangkok')::date;
begin
  if public.current_role() is distinct from 'admin' then
    raise exception 'admin only' using errcode = '42501';
  end if;

  return coalesce((
    with sc as (
      select s.code from public.client_special_care s where s.active
    ),
    -- one row per distinct name written on papers (cheaper than matching every paper)
    names as (
      select n.customer_name, public.sales_code_for_name(n.customer_name) as code
        from (select distinct p.customer_name from public.weighing_papers p
               where p.customer_name is not null and btrim(p.customer_name) <> '') n
    ),
    papers as (
      select p.*, nm.code, coalesce(p.delivery_date, p.work_date) as order_date
        from public.weighing_papers p
        join names nm on nm.customer_name = p.customer_name
        join sc on sc.code = nm.code
       where p.status in ('read', 'confirmed', 'postponed')
    ),
    last as (
      select distinct on (code) *
        from papers
       order by code, order_date desc, work_date desc, coalesce(split_part, 1) desc, uploaded_at desc nulls last
    ),
    cnt as (
      select code, count(distinct coalesce(po_number, id::text)) as orders_30
        from papers
       where order_date between v_today - 30 and v_today
       group by code
    ),
    inv as (
      select distinct on (i.code) i.code, i.invoice_date, i.number, i.company, i.total
        from public.sales_invoices i join sc on sc.code = i.code
       order by i.code, i.invoice_date desc, i.number desc
    )
    select jsonb_object_agg(sc.code, jsonb_build_object(
      'orders_30', coalesce(cnt.orders_30, 0),
      'last', case when l.id is null then null else jsonb_build_object(
          'paper_id', l.id,
          'order_date', l.order_date,
          'delivery_date', l.delivery_date,
          'work_date', l.work_date,
          'po_number', l.po_number,
          'company', l.company,
          'status', l.status,
          'part', l.split_part,
          'customer_name', l.customer_name,
          'total_kg', (select round(sum(wl.actual_kg), 2) from public.weighing_lines wl where wl.paper_id = l.id),
          'lines', coalesce((select jsonb_agg(jsonb_build_object(
                       'description', wl.description,
                       'ordered_text', wl.ordered_text,
                       'ordered_qty', wl.ordered_qty,
                       'ordered_unit', wl.ordered_unit,
                       'actual_kg', wl.actual_kg) order by wl.line_no)
                     from public.weighing_lines wl where wl.paper_id = l.id), '[]'::jsonb)) end,
      'invoice', case when l.id is not null or inv.code is null then null else jsonb_build_object(
          'invoice_date', inv.invoice_date, 'number', inv.number, 'company', inv.company, 'total', inv.total) end))
      from sc
      left join last l on l.code = sc.code
      left join cnt on cnt.code = sc.code
      left join inv on inv.code = sc.code), '{}'::jsonb);
end;
$$;

revoke all on function public.special_care_last_orders() from public, anon;
grant execute on function public.special_care_last_orders() to authenticated, service_role;
