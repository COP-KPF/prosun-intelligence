-- ============================================================================
-- Migration 045 — Management › Summary › Orders: what we sold, day by day
-- ============================================================================
-- Written 24 Nov 2026. Clément: "I'd like to know how many of which product
-- we sold day by day, what revenue, what quantity, which client".
--
-- A second tab in Management › Summary (Summary | Orders). One function,
-- management_orders(from, to, company, by), returns every product line of the
-- confirmed working papers in the period, with its client, PO, quantity, kg,
-- pieces and approximate revenue. The page groups them (products by day,
-- products, clients, days, every line), filters them and exports them.
--
-- Rules
--   - Confirmed working papers only, from the first counted day
--     (management_settings.count_from, 024) — the same papers as Summary (031).
--   - The day of a line: its delivery day (the paper's delivery date, else its
--     production day) by default — that is when it is sold; or the production
--     day (work_date), which is what Summary counts.
--   - Revenue and pieces: exactly Summary's rules (031) — the price list
--     matched from the words on the paper, Bangkok or up-country price by
--     client, quantity price when enough pieces are ordered, Under Roof list
--     for POs starting with UR. A line not on the price list has no revenue.
--   - Split orders (040/041): a product moved to "part 2" leaves the original
--     paper, so each kilo is counted once, on the day of the part it is
--     delivered with. An order and its parts count as one order.
--   - Postponed papers back in production are not confirmed: they count when
--     they are confirmed, on their new day.
--   - Admin: all companies or one. Company director (032): his company only.
--   - At most about three months per request (92 days).
--
-- Read-only. Run order: after 044. Safe to re-run.
-- ============================================================================

create or replace function public.management_orders(
  p_from date, p_to date, p_company text default null, p_by text default 'delivery')
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_co    text := public.management_company(p_company);   -- a company director always gets his own company (032)
  v_scope text := public.my_company_scope();
  v_start date;
  v_by    text := coalesce(nullif(p_by, ''), 'delivery');
  v_out   jsonb;
begin
  if coalesce(public.current_role(), '') not in ('admin', 'company_director') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'choose a start and an end date' using errcode = '22023';
  end if;
  if p_to - p_from > 92 then
    raise exception 'choose a period of about three months or less' using errcode = '22023';
  end if;
  if v_by not in ('delivery', 'production') then
    raise exception 'unknown day' using errcode = '22023';
  end if;
  if v_co is not null and v_co not in ('Prosun Farm', 'Prosun Food') then
    raise exception 'unknown company' using errcode = '22023';
  end if;

  select s.count_from into v_start from public.management_settings s where s.id = 1;

  with raw as materialized (
    select p.id as paper_id, coalesce(p.split_from, p.id) as order_id, p.split_part,
           case when v_by = 'production' then p.work_date else coalesce(p.delivery_date, p.work_date) end as day,
           p.company, coalesce(nullif(trim(p.po_number), ''), '') as po,
           coalesce(nullif(trim(p.customer_name), ''), '—') as client,
           l.line_no, l.description, l.actual_kg, l.ordered_qty, l.ordered_unit,
           coalesce(p.po_number, '') ~* '^\s*UR' as ur
    from public.weighing_papers p
    join public.weighing_lines l on l.paper_id = p.id
    where p.status = 'confirmed'
      and p.work_date >= coalesce(v_start, p.work_date)
      and (case when v_by = 'production' then p.work_date else coalesce(p.delivery_date, p.work_date) end)
          between p_from and p_to
      and (v_co is null or p.company = v_co)
  ),
  -- Papers repeat the same few hundred descriptions: match each one once (as 031).
  matched as materialized (
    select d.description, d.ur,
           public.price_list_match(d.description, case when d.ur then 'UR' end) as price_id
    from (select distinct description, ur from raw) d
  ),
  priced as materialized (
    select x.*,
           case
             when x.price_unit = 'kg' then
               case when x.actual_kg > 0 then round(x.actual_kg * x.unit_price, 2) end
             when x.price_unit = 'pce' then
               case when x.pieces > 0 then round(x.pieces * x.unit_price, 2) end
           end as revenue,
           case when x.price_unit in ('kg', 'pce') then 'p:' || x.price_id
                else 'd:' || lower(regexp_replace(trim(coalesce(x.description, '—')), '\s+', ' ', 'g')) end as product_key
    from (
      select r.*, m.price_id, pl.unit as price_unit, pl.name as price_name,
             coalesce(z.zone, 'bangkok') as zone,
             case
               when r.ordered_unit = 'pcs' and r.ordered_qty > 0 then r.ordered_qty
               when pl.unit = 'pce' and r.actual_kg > 0 and pl.piece_kg > 0 then round(r.actual_kg / pl.piece_kg)
             end as pieces,
             case
               when pl.bulk_min is not null
                    and (case when r.ordered_unit = 'pcs' then r.ordered_qty end) >= pl.bulk_min
                 then case when z.zone = 'upcountry' then coalesce(pl.bulk_up, pl.bulk_bkk) else pl.bulk_bkk end
               else case when z.zone = 'upcountry' then coalesce(pl.price_up, pl.price_bkk) else pl.price_bkk end
             end as unit_price
      from raw r
      join matched m on m.description is not distinct from r.description and m.ur = r.ur
      left join public.price_list pl on pl.id = m.price_id
      left join public.client_price_zones z on z.client_key = lower(r.client)
    ) x
  ),
  -- Short lists the lines point to by position (keeps the answer small).
  prods as (
    select product_key,
           (row_number() over (order by product_key)) - 1 as ix,
           case when min(price_unit) in ('kg', 'pce') then min(price_name) else min(trim(description)) end as name,
           case when min(price_unit) in ('kg', 'pce') then min(price_unit) end as unit,
           min(price_id) filter (where price_unit in ('kg', 'pce')) as price_id
    from priced group by product_key
  ),
  papers as (
    select paper_id,
           (row_number() over (order by min(day), min(client), paper_id)) - 1 as ix,
           min(client) as client, min(po) as po,
           min(company) as company, min(zone) as zone, min(split_part) as part,
           -- an order and its split parts share one number
           dense_rank() over (order by min(order_id::text)) as order_no
    from priced group by paper_id
  ),
  descs as (
    select description, (row_number() over (order by description)) - 1 as ix
    from (select distinct coalesce(description, '—') as description from priced) d
  )
  select jsonb_build_object(
    'from', p_from, 'to', p_to, 'by', v_by, 'count_from', v_start, 'scope', v_scope,
    'products', coalesce((select jsonb_agg(jsonb_build_array(name, unit, price_id) order by ix) from prods), '[]'::jsonb),
    'papers',   coalesce((select jsonb_agg(jsonb_build_array(client, po, company, zone, part, order_no) order by ix) from papers), '[]'::jsonb),
    'descs',    coalesce((select jsonb_agg(description order by ix) from descs), '[]'::jsonb),
    -- papers: [client, PO, company, price zone, part number, order number]
    -- one line per product line:
    -- [day, paper, description, product, ordered qty, ordered unit, actual kg, pieces, unit price, revenue]
    'lines', coalesce((select jsonb_agg(jsonb_build_array(
                 q.day, pa.ix, de.ix, pr.ix, q.ordered_qty, q.ordered_unit, q.actual_kg, q.pieces,
                 case when q.revenue is not null then q.unit_price end, q.revenue)
               order by q.day, pa.ix, q.line_no)
             from priced q
             join papers pa on pa.paper_id = q.paper_id
             join prods pr on pr.product_key = q.product_key
             join descs de on de.description = coalesce(q.description, '—')), '[]'::jsonb)
  ) into v_out;

  return v_out;
end;
$$;

comment on function public.management_orders(date, date, text, text) is
  'Management › Summary › Orders: confirmed product lines by delivery (or production) day, with client, quantity and approximate revenue. Admin; company director for his company. Migration 045.';

revoke all on function public.management_orders(date, date, text, text) from public, anon;
grant execute on function public.management_orders(date, date, text, text) to authenticated, service_role;
