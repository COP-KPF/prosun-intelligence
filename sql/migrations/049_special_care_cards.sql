-- ============================================================================
-- Migration 049 — Special care: client cards and client file
-- ============================================================================
-- Clément, 25 Nov 2026: a new view of Management › Special care — design
-- options A (one card per client) and C (client file) chosen.
--
-- special_care_overview()       (admin)
--   stats  — special care clients, clients with an order today, special care
--            postponements in the last 7 days, clients quiet for more than
--            14 days, clients with no order in PACE;
--   clients — per client code: salesperson, order days of the last 30 days
--            (days ago), orders and kg in 30 days, postponements in 30 days,
--            lines off by more than ±5 % in 30 days, days since the last order.
-- special_care_client_file(code) (admin)
--   orders  — the last 6 working papers: date, PO, part, company, status,
--             delivery mark, last postponement, lines, total kg;
--   basket  — products of the last 30 days: in how many orders, usual quantity;
--   postponements — the client's postponements of the last 30 days.
--
-- Working papers are matched to clients as everywhere in PACE
-- (sales_code_for_name on the printed name). Orders = papers read, confirmed
-- or postponed (uploading, reading, failed are skipped); an order's date is its
-- delivery date, else its production day. Kg = actual kg of confirmed papers.
-- "Off ±5 %": kg lines whose actual kg differs from the ordered kg by more
-- than 5 % (same tolerance as the Management dashboard).
--
-- Run order: after 044. Safe to re-run. No table change.
-- ============================================================================

-- Papers of the active special care clients, with their client code.
create or replace function public.special_care_papers(p_from date default null)
returns table (paper_id uuid, code text, order_date date, work_date date, status text)
language sql
stable
security definer
set search_path = public
as $$
  with sc as (select s.code from public.client_special_care s where s.active),
  names as (
    select n.customer_name, public.sales_code_for_name(n.customer_name) as code
      from (select distinct p.customer_name from public.weighing_papers p
             where p.customer_name is not null and btrim(p.customer_name) <> '') n
  )
  select p.id, nm.code, coalesce(p.delivery_date, p.work_date), p.work_date, p.status
    from public.weighing_papers p
    join names nm on nm.customer_name = p.customer_name
    join sc on sc.code = nm.code
   where p.status in ('read', 'confirmed', 'postponed')
     and (p_from is null or coalesce(p.delivery_date, p.work_date) >= p_from or p.work_date >= p_from);
$$;
revoke all on function public.special_care_papers(date) from public, anon, authenticated;

-- Postponements (weighing and register) of the special care clients since a date.
create or replace function public.special_care_postponements(p_from date)
returns table (code text, created_at timestamptz, source text, what text, from_date date, to_date date,
               reason text, note text, by_dept text, po_number text)
language sql
stable
security definer
set search_path = public
as $$
  with sc as (select s.code from public.client_special_care s where s.active)
  select x.code, x.created_at, x.source, x.what, x.from_date, x.to_date, x.reason, x.note, x.by_dept, x.po_number
    from (
      select public.sales_code_for_name(coalesce(w.customer_name, p.customer_name)) as code, w.created_at,
             'weighing'::text as source,
             case when w.split_mode is not null then 'product' when w.stage = 'delivery' then 'delivery' else 'production' end as what,
             coalesce(w.from_delivery_date, w.from_work_date) as from_date, w.to_delivery_date as to_date,
             w.reason, w.note, coalesce(w.by_dept, case when w.stage = 'delivery' then 'middle' else 'production' end) as by_dept,
             coalesce(w.po_number, p.po_number) as po_number
        from public.weighing_postponements w
        left join public.weighing_papers p on p.id = w.paper_id
       where w.created_at >= p_from
      union all
      select public.sales_code_for_name(o.customer_name), o.created_at, 'register', 'order',
             o.original_date, o.new_date, o.reason, o.note, 'middle', o.po_number
        from public.order_postponements o
       where o.created_at >= p_from
    ) x
    join sc on sc.code = x.code;
$$;
revoke all on function public.special_care_postponements(date) from public, anon, authenticated;


create or replace function public.special_care_overview()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_today date := (now() at time zone 'Asia/Bangkok')::date;
  v_from  date := v_today - 29;
begin
  if public.current_role() is distinct from 'admin' then
    raise exception 'admin only' using errcode = '42501';
  end if;

  return (
    with sc as (
      select s.code, c.salesperson_code, c.portfolio, r.short_name
        from public.client_special_care s
        join public.sales_customers c on c.code = s.code
        left join public.sales_reps r on r.code = c.salesperson_code
       where s.active
    ),
    allp as (select * from public.special_care_papers(null)),
    lastd as (select code, max(order_date) filter (where order_date <= v_today) as last_past, max(order_date) as last_any
                from allp group by code),
    p30 as (select * from allp where order_date between v_from and v_today),
    days as (select code, array_agg(distinct (v_today - order_date) order by (v_today - order_date)) as d,
                    count(distinct order_date) as n_days
               from p30 group by code),
    kg as (select a.code, round(sum(l.actual_kg), 1) as kg30,
                  count(*) filter (where l.ordered_unit = 'kg' and l.ordered_qty > 0 and l.actual_kg is not null
                                     and abs(l.actual_kg - l.ordered_qty) > 0.05 * l.ordered_qty) as off5
             from p30 a join public.weighing_lines l on l.paper_id = a.paper_id
            where a.status = 'confirmed'
            group by a.code),
    cnt as (select a.code, count(distinct coalesce(wp.po_number, wp.id::text)) as n30
              from p30 a join public.weighing_papers wp on wp.id = a.paper_id group by a.code),
    pp30 as (select code, count(*) as n from public.special_care_postponements(v_from) group by code),
    pp7  as (select count(*) as n from public.special_care_postponements(v_today - 6)),
    today as (select count(distinct code) as n from allp where order_date = v_today)
    select jsonb_build_object(
      'today', v_today,
      'stats', jsonb_build_object(
        'clients', (select count(*) from sc),
        'ordering_today', (select n from today),
        'postponed_7d', (select n from pp7),
        'quiet_14', (select count(*) from sc left join lastd l on l.code = sc.code
                      where l.last_past is not null and v_today - l.last_past > 14 and coalesce(l.last_any, l.last_past) <= v_today),
        'no_order', (select count(*) from sc left join lastd l on l.code = sc.code where l.code is null)),
      'clients', coalesce((select jsonb_object_agg(sc.code, jsonb_build_object(
          'rep', case when sc.portfolio = 'rep' then sc.short_name
                      when sc.portfolio = 'not_transferred' then 'Not transferred'
                      else 'House' end,
          'rep_code', sc.salesperson_code,
          'days30', coalesce(to_jsonb(d.d), '[]'::jsonb),
          'n30', coalesce(cn.n30, 0),
          'kg30', coalesce(k.kg30, 0),
          'off5_30', coalesce(k.off5, 0),
          'postponed30', coalesce(pp.n, 0),
          'days_since', case when l.last_past is null then null else v_today - l.last_past end,
          'next_order', case when l.last_any > v_today then l.last_any end))
        from sc
        left join lastd l on l.code = sc.code
        left join days d on d.code = sc.code
        left join kg k on k.code = sc.code
        left join cnt cn on cn.code = sc.code
        left join pp30 pp on pp.code = sc.code), '{}'::jsonb)));
end;
$$;


create or replace function public.special_care_client_file(p_code text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_today date := (now() at time zone 'Asia/Bangkok')::date;
  v_code  text := upper(btrim(coalesce(p_code, '')));
begin
  if public.current_role() is distinct from 'admin' then
    raise exception 'admin only' using errcode = '42501';
  end if;

  return (
    with mine as (select * from public.special_care_papers(null) where code = v_code),
    last6 as (
      select m.*, p.po_number, p.company, p.split_part, p.delivery_date, p.uploaded_at
        from mine m join public.weighing_papers p on p.id = m.paper_id
       order by m.order_date desc, m.work_date desc, coalesce(p.split_part, 1) desc, p.uploaded_at desc nulls last
       limit 6
    ),
    lines30 as (
      select l.*, m.paper_id as pid
        from mine m join public.weighing_lines l on l.paper_id = m.paper_id
       where m.order_date between v_today - 29 and v_today
    ),
    n30 as (select count(distinct paper_id) as n from mine where order_date between v_today - 29 and v_today),
    basket as (
      select lower(btrim(description)) as k,
             mode() within group (order by description) as description,
             count(distinct pid) as orders,
             round(avg(ordered_qty), 1) as avg_qty,
             mode() within group (order by ordered_unit) as unit
        from lines30
       where btrim(coalesce(description, '')) <> ''
       group by lower(btrim(description))
    )
    select jsonb_build_object(
      'code', v_code,
      'orders', coalesce((select jsonb_agg(jsonb_build_object(
          'paper_id', o.paper_id,
          'order_date', o.order_date,
          'work_date', o.work_date,
          'po_number', o.po_number,
          'company', o.company,
          'part', o.split_part,
          'status', o.status,
          'delivery', (select dm.status from public.delivery_marks dm where dm.paper_id = o.paper_id),
          'postponed', (select jsonb_build_object('from', coalesce(w.from_delivery_date, w.from_work_date), 'to', w.to_delivery_date,
                                                  'reason', w.reason, 'product', w.split_mode is not null)
                          from public.weighing_postponements w where w.paper_id = o.paper_id
                         order by w.created_at desc limit 1),
          'total_kg', (select round(sum(l.actual_kg), 2) from public.weighing_lines l where l.paper_id = o.paper_id),
          'lines', coalesce((select jsonb_agg(jsonb_build_object(
                      'description', l.description, 'ordered_text', l.ordered_text, 'ordered_qty', l.ordered_qty,
                      'ordered_unit', l.ordered_unit, 'actual_kg', l.actual_kg) order by l.line_no)
                    from public.weighing_lines l where l.paper_id = o.paper_id), '[]'::jsonb))
        order by o.order_date desc, o.work_date desc, coalesce(o.split_part, 1) desc) from last6 o), '[]'::jsonb),
      'orders_30', (select n from n30),
      'basket', coalesce((select jsonb_agg(jsonb_build_object('description', b.description, 'orders', b.orders,
                                   'avg_qty', b.avg_qty, 'unit', b.unit) order by b.orders desc, b.description)
                            from (select * from basket order by orders desc, description limit 8) b), '[]'::jsonb),
      'postponements', coalesce((select jsonb_agg(jsonb_build_object('at', x.created_at, 'what', x.what, 'from', x.from_date,
                                   'to', x.to_date, 'reason', x.reason, 'by', x.by_dept, 'po', x.po_number) order by x.created_at desc)
                                   from public.special_care_postponements(v_today - 29) x where x.code = v_code), '[]'::jsonb)));
end;
$$;

revoke all on function public.special_care_overview(), public.special_care_client_file(text) from public, anon;
grant execute on function public.special_care_overview(), public.special_care_client_file(text) to authenticated, service_role;
