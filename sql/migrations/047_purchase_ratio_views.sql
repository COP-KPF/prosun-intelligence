-- ============================================================================
-- Migration 047 — Purchases: the full cost ratio in Management › KPI, the
-- ratio only for purchasing
-- ============================================================================
-- Written 24 Nov 2026. Clément: the purchasing manager sees only the ratio;
-- he sees the cost ratio data in full in the Management section (KPI ›
-- Purchases). Khun Jum (kirana@) sees it too, for now. Chef Julien later.
--
-- purchase_access gets a second right, sees_revenue:
--   sees_revenue = true   the full view: purchase cost, approximate and
--                         invoiced revenue, ratio, cost per kg sold
--                         (Clément, Khun Jum)
--   sees_revenue = false  orders & arrivals, and the ratio as a percentage per
--                         cycle / week / month — no revenue amount, no kg
--                         sold, no cost total on the ratio page (Orawan)
-- The database decides: purchase_ratio sends revenue figures only to accounts
-- with sees_revenue. The percentages are computed here for the others.
--
-- Note kept on purpose: the purchasing manager enters the prices, so she
-- knows each cycle's cost; with the ratio she could work out the revenue by
-- hand. Clément chose to show her the exact ratio anyway (24 Nov 2026).
--
-- Run order: after 046. Safe to re-run.
-- ============================================================================

alter table public.purchase_access add column if not exists sees_revenue boolean not null default false;

-- Khun Jum joins the list (Clément, 24 Nov 2026), with the full view.
insert into public.purchase_access (user_id)
select u.id from auth.users u join public.profiles p on p.id = u.id
where lower(u.email) = 'kirana@klongphaifarm.com'
on conflict (user_id) do nothing;

update public.purchase_access a set sees_revenue = true
from auth.users u
where u.id = a.user_id and lower(u.email) in ('clement@klongphaifarm.com', 'kirana@klongphaifarm.com');

comment on column public.purchase_access.sees_revenue is
  'true: the full cost ratio with revenue (Management › KPI › Purchases). '
  'false: orders, arrivals and the ratio as a percentage only. Migration 047.';

create or replace function public.purchase_sees_revenue()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select sees_revenue from public.purchase_access where user_id = auth.uid()), false);
$$;
revoke all on function public.purchase_sees_revenue() from public, anon;
grant execute on function public.purchase_sees_revenue() to authenticated, service_role;

-- What the screens need to know about the account.
create or replace function public.purchase_me()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object('access', public.purchase_can(), 'sees_revenue', public.purchase_sees_revenue());
$$;
revoke all on function public.purchase_me() from public, anon;
grant execute on function public.purchase_me() to authenticated, service_role;


-- ----------------------------------------------------------------------------
-- Day by day, both sides (not callable from the app: the two readers below
-- decide what leaves the database).
-- ----------------------------------------------------------------------------
create or replace function public.purchase_ratio_days(p_from date, p_to date, p_co text)
returns table (day date, company text, rev numeric, kg numeric, kg_priced numeric, papers bigint,
               cost numeric, freight numeric, est boolean, birds_ordered numeric, birds_received numeric,
               kg_bought numeric, no_price bigint, orders bigint)
language sql
stable
security definer
set search_path = public
as $$
  with raw as materialized (
    select p.id as paper_id, p.work_date as day, p.company,
           coalesce(nullif(trim(p.customer_name), ''), '—') as client,
           l.description, l.actual_kg, l.ordered_qty, l.ordered_unit,
           coalesce(p.po_number, '') ~* '^\s*UR' as ur
    from public.weighing_papers p
    join public.weighing_lines l on l.paper_id = p.id
    where p.status = 'confirmed'
      and p.work_date between p_from and p_to
      and (p_co is null or p.company = p_co)
  ),
  matched as materialized (
    select d.description, d.ur,
           public.price_list_match(d.description, case when d.ur then 'UR' end) as price_id
    from (select distinct description, ur from raw) d
  ),
  priced as (
    select x.*,
           case
             when x.price_unit = 'kg' then
               case when x.actual_kg > 0 then round(x.actual_kg * x.unit_price, 2) end
             when x.price_unit = 'pce' then
               case when x.pieces > 0 then round(x.pieces * x.unit_price, 2) end
           end as revenue
    from (
      select r.*, pl.unit as price_unit,
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
  rev as (
    select day, company,
           round(coalesce(sum(revenue), 0), 2) as rev,
           round(coalesce(sum(actual_kg), 0), 2) as kg,
           round(coalesce(sum(actual_kg) filter (where revenue is not null), 0), 2) as kg_priced,
           count(distinct paper_id) as papers
    from priced group by day, company
  ),
  o as (
    select o.*, coalesce(o.arrived_on, o.arrival_date) as day
    from public.purchase_orders o
    where o.status <> 'cancelled'
      and coalesce(o.arrived_on, o.arrival_date) between p_from and p_to
      and (p_co is null or o.company = p_co)
  ),
  goods as (
    select o.day, o.company,
           round(coalesce(sum(c.cost), 0), 2) as cost,
           bool_or(o.status <> 'received') as est,
           coalesce(sum(l.ordered_qty) filter (where c.item_unit = 'bird'), 0) as birds_ordered,
           coalesce(sum(l.received_qty) filter (where c.item_unit = 'bird' and o.status = 'received'), 0) as birds_received,
           round(coalesce(sum(c.kg), 0), 2) as kg_bought,
           count(*) filter (where c.cost is null) as no_price
    from o
    join public.purchase_order_lines l on l.order_id = o.id
    join public.purchase_line_costs c on c.line_id = l.id
    group by o.day, o.company
  ),
  fr as (
    select day, company, round(coalesce(sum(freight_thb), 0), 2) as freight, count(*) as orders
    from o group by day, company
  ),
  pur as (
    select f.day, f.company, coalesce(g.cost, 0) as cost, f.freight, coalesce(g.est, true) as est,
           coalesce(g.birds_ordered, 0) as birds_ordered, coalesce(g.birds_received, 0) as birds_received,
           coalesce(g.kg_bought, 0) as kg_bought, coalesce(g.no_price, 0) as no_price, f.orders
    from fr f left join goods g on g.day = f.day and g.company = f.company
  )
  select coalesce(r.day, p.day), coalesce(r.company, p.company),
         coalesce(r.rev, 0), coalesce(r.kg, 0), coalesce(r.kg_priced, 0), coalesce(r.papers, 0),
         coalesce(p.cost, 0), coalesce(p.freight, 0), coalesce(p.est, false),
         coalesce(p.birds_ordered, 0), coalesce(p.birds_received, 0), coalesce(p.kg_bought, 0),
         coalesce(p.no_price, 0), coalesce(p.orders, 0)
  from rev r
  full join pur p on p.day = r.day and p.company = r.company;
$$;
revoke all on function public.purchase_ratio_days(date, date, text) from public, anon, authenticated;
grant execute on function public.purchase_ratio_days(date, date, text) to service_role;


-- ----------------------------------------------------------------------------
-- The reader. Replaces 046's three-argument version.
--   Full view (sees_revenue):
--     revenue:   [production day, company, approx. revenue, kg, kg priced, papers]
--     purchases: [arrival day, company, goods, freight, estimate?, birds ordered,
--                 birds received, kg bought, lines without a price, orders]
--     invoiced:  [month, company, invoiced amount, days counted]
--   Ratio only (the others):
--     groups:    [period start, ratio %, estimate?, birds ordered, birds received,
--                 orders, still in progress?]   — period = p_group
--     total:     [ratio %, estimate?, birds ordered, birds received, orders]
--                — completed arrival cycles only (before complete_before)
-- ----------------------------------------------------------------------------
drop function if exists public.purchase_ratio(date, date, text);

create or replace function public.purchase_ratio(p_from date, p_to date, p_company text default null,
                                                 p_group text default 'cycle')
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_co    text := nullif(nullif(p_company, ''), 'all');
  v_grp   text := coalesce(nullif(p_group, ''), 'cycle');
  v_start date;
  v_first date;
  v_eff   date;
  v_today date := (now() at time zone 'Asia/Bangkok')::date;
  v_cut   date;   -- first day of the arrival cycle in progress: totals stop the day before
  v_head  jsonb;
  v_out   jsonb;
begin
  perform public.purchase_check();
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'purchases: choose a start and an end date' using errcode = '22023';
  end if;
  if p_to - p_from > 400 then
    raise exception 'purchases: choose a period of about a year or less' using errcode = '22023';
  end if;
  if v_co is not null and v_co not in ('Prosun Farm', 'Prosun Food') then
    raise exception 'purchases: unknown company' using errcode = '22023';
  end if;
  if v_grp not in ('cycle', 'week', 'month') then
    raise exception 'purchases: group by cycle, week or month' using errcode = '22023';
  end if;

  select s.count_from into v_start from public.management_settings s where s.id = 1;
  -- The ratio starts when both sides are counted: the first counted working
  -- paper day (count_from) and the first purchase entered in PACE.
  select min(coalesce(o.arrived_on, o.arrival_date)) into v_first
  from public.purchase_orders o
  where o.status <> 'cancelled' and (v_co is null or o.company = v_co);
  v_eff := greatest(p_from, coalesce(v_start, p_from), coalesce(v_first, p_from));
  v_cut := v_today - (case extract(dow from v_today)::int when 0 then 2 when 2 then 1 when 4 then 1 when 6 then 1 else 0 end);

  v_head := jsonb_build_object('from', p_from, 'to', p_to, 'company', coalesce(v_co, 'all'), 'count_from', v_start,
                               'first_purchase', v_first, 'from_effective', v_eff,
                               'complete_before', v_cut,
                               'full', public.purchase_sees_revenue());

  if public.purchase_sees_revenue() then
    select v_head || jsonb_build_object(
      'revenue', coalesce((select jsonb_agg(jsonb_build_array(d.day, d.company, d.rev, d.kg, d.kg_priced, d.papers) order by d.day, d.company)
                           from public.purchase_ratio_days(v_eff, p_to, v_co) d where d.papers > 0), '[]'::jsonb),
      'purchases', coalesce((select jsonb_agg(jsonb_build_array(d.day, d.company, d.cost, d.freight, d.est, d.birds_ordered,
                                                                d.birds_received, d.kg_bought, d.no_price, d.orders) order by d.day, d.company)
                             from public.purchase_ratio_days(v_eff, p_to, v_co) d where d.orders > 0), '[]'::jsonb),
      'invoiced', coalesce((select jsonb_agg(jsonb_build_array(a.month, a.company, a.amount, a.days_counted) order by a.month, a.company)
                            from public.sales_actuals a
                            where a.month between date_trunc('month', p_from)::date and p_to
                              and (v_co is null or a.company = v_co)), '[]'::jsonb))
      into v_out;
    return v_out;
  end if;

  -- Ratio only.
  with d as (select * from public.purchase_ratio_days(v_eff, p_to, v_co)),
  k as (
    select case v_grp
             when 'month' then date_trunc('month', d.day)::date
             when 'week'  then date_trunc('week', d.day)::date
             else d.day - (case extract(dow from d.day)::int when 0 then 2 when 2 then 1 when 4 then 1 when 6 then 1 else 0 end)
           end as key, d.*
    from d
  ),
  g as (
    select key, sum(rev) as rev, sum(cost + freight) as total, bool_or(est) as est,
           sum(birds_ordered) as bo, sum(birds_received) as br, sum(orders) as orders
    from k group by key
  ),
  t as (   -- totals: completed cycles only (the cycle in production would swing them)
    select sum(rev) as rev, sum(cost + freight) as total, bool_or(est) as est,
           sum(birds_ordered) as bo, sum(birds_received) as br, sum(orders) as orders
    from d where d.day < v_cut
  )
  select v_head || jsonb_build_object(
    'groups', coalesce((select jsonb_agg(jsonb_build_array(
                 g.key,
                 case when g.rev > 0 then round(g.total / g.rev * 100, 1) end,
                 g.est, g.bo, g.br, g.orders,
                 (case v_grp
                    when 'month' then (g.key + interval '1 month' - interval '1 day')::date
                    when 'week'  then g.key + 6
                    else g.key + (case extract(dow from g.key)::int when 5 then 2 else 1 end)
                  end) >= v_today) order by g.key) from g), '[]'::jsonb),
    'total', (select jsonb_build_array(
                case when t.rev > 0 then round(t.total / t.rev * 100, 1) end,
                coalesce(t.est, false), coalesce(t.bo, 0), coalesce(t.br, 0), coalesce(t.orders, 0))
              from t))
  into v_out;
  return v_out;
end $$;

revoke all on function public.purchase_ratio(date, date, text, text) from public, anon;
grant execute on function public.purchase_ratio(date, date, text, text) to authenticated, service_role;
