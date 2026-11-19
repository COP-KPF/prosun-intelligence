-- ============================================================================
-- Migration 039 — PACE › Sales: My day, alerts, call-back dates, KPIs
-- ============================================================================
-- Written 19 Nov 2026. Clément: "I agree" to (1) a My day page — the calls that
-- matter most today, call-back dates, today's problems on my clients' orders,
-- new clients waiting for their second order; (2) alerts to the salesperson
-- when a client's order is postponed or has a delivery problem; (5) results
-- — and "a KPI section with ratios in %, both for the salesperson and a
-- section for me and Khun Kirana, Sales KPIs, to pilot the sales".
--
--   sales_clients_core(all)   the client metrics of 037, callable for every
--                             portfolio (team figures), plus month_value and
--                             priority; internal only
--   sales_clients()           unchanged output + call.callback_on, month_value,
--                             priority
--   sales_log_call(code, outcome, note, callback)   + a call-back date
--   sales_my_day(rep)         top calls, call-backs due, problems, new clients
--   sales_alerts(days) / sales_alerts_seen()   postponed / moved / delivery
--                             problem on my clients, unseen count for the badge
--   sales_kpis(from, to)      KPIs in % per salesperson and for the team.
--                             Admin (Clément, Khun Kirana): every salesperson,
--                             House to assign, biggest clients at stake.
--                             A salesperson or the sales director: their own
--                             portfolio and the team average.
--
-- KPI definitions (base = clients with sales in the 12 report months or an
-- order in the last 180 days):
--   Portfolio (today)  active 30 d % · on track % (ok + new) · call now % ·
--                      at risk % · lost %
--   Revenue (report)   last 3 months vs the 3 before % · target achieved,
--                      year to date % (036 targets, months weighted by the
--                      Prosun Farm budget) · top 10 clients' share % ·
--                      Prosun Food share %
--   Activity (period)  calls · clients called · Call now clients called in the
--                      last 7 days % · calls followed by an order within 7
--                      days % · clients reactivated (an order after 30+ days)
--   Service (period)   orders (working papers first due in the period) · postponed % · delivery
--                      problem % · lines within ±5 % of the kg ordered %
--
-- Run after 037 and 038. Safe to re-run.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Call-back date, alerts seen
-- ----------------------------------------------------------------------------
alter table public.sales_calls add column if not exists callback_on date;

create table if not exists public.sales_alert_seen (
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  seen_at    timestamptz not null default now()
);
alter table public.sales_alert_seen enable row level security;
revoke all on public.sales_alert_seen from anon, authenticated;
grant all on public.sales_alert_seen to service_role;


-- ----------------------------------------------------------------------------
-- 2. Client metrics for any scope (internal) and the list
-- ----------------------------------------------------------------------------
create or replace function public.sales_clients_core(p_all boolean)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_scope  text := public.sales_scope();
  v_code   text := public.sales_my_code();
  v_today  date := (now() at time zone 'Asia/Bangkok')::date;
  v_last   date;            -- latest report month
  v_months date[];
  v_rows   jsonb;
  v_hidden int;
  v_inv_to date;
  v_pap_from date;
begin
  if v_scope is null and not p_all then
    raise exception 'not allowed' using errcode = '42501';
  end if;

  select max(month) into v_last from public.sales_monthly;
  v_last := coalesce(v_last, date_trunc('month', v_today)::date - interval '1 month');
  select array_agg((v_last - make_interval(months => 11 - g))::date order by g)
    into v_months from generate_series(0, 11) g;
  select max(invoice_date) into v_inv_to from public.sales_invoices;
  select min(order_date) into v_pap_from from public.sales_paper_orders();

  with vis as (
    select c.* from public.sales_customers c
    where p_all or v_scope = 'all' or (c.portfolio = 'rep' and c.salesperson_code = v_code)
  ),
  orders as (
    select distinct code, d from (
      select i.code, i.invoice_date as d from public.sales_invoices i
        where i.code in (select code from vis) and coalesce(i.untaxed, i.total, 0) > 0
      union all
      select o.code, o.order_date from public.sales_paper_orders() o
        where o.code in (select code from vis) and o.order_date <= v_today
    ) u
  ),
  last_order as (
    select code, max(d) as last_d, min(d) as first_d, count(*) as n_dates from orders group by code
  ),
  gaps as (
    select code, d - lag(d) over (partition by code order by d) as gap
    from orders where d >= v_today - 180
  ),
  rhythm as (
    select code, round(percentile_cont(0.5) within group (order by gap))::int as rhythm, count(*) as n_gaps
    from gaps where gap is not null group by code having count(*) >= 2
  ),
  rev as (
    select m.code,
           jsonb_agg(coalesce(s.amt, 0) order by m.month) as m12,
           sum(coalesce(s.amt, 0)) filter (where m.month > v_last - interval '3 months') as last3,
           sum(coalesce(s.amt, 0)) filter (where m.month <= v_last - interval '3 months'
                                             and m.month > v_last - interval '6 months') as prev3,
           sum(coalesce(s.amt, 0)) as total12,
           sum(coalesce(s.farm, 0)) as farm12,
           sum(coalesce(s.food, 0)) as food12,
           max(m.month) filter (where coalesce(s.amt, 0) > 0) as last_month,
           min(m.month) filter (where coalesce(s.amt, 0) > 0) as first_month
    from (select v.code, mm as month from vis v, unnest(v_months) mm) m
    left join (select code, month, sum(amount) as amt,
                      sum(amount) filter (where company = 'Prosun Farm') as farm,
                      sum(amount) filter (where company = 'Prosun Food') as food
               from public.sales_monthly group by code, month) s
      on s.code = m.code and s.month = m.month
    group by m.code
  ),
  first_ever as (
    select code, min(month) as first_month from public.sales_monthly where amount > 0 group by code
  ),
  postponed as (
    select o.code, count(distinct h.paper_id) as n
    from public.weighing_postponements h
    join public.sales_paper_orders() o on o.paper_id = h.paper_id
    where h.created_at >= now() - interval '30 days'
    group by o.code
  ),
  calls as (
    select distinct on (code) code, called_at, outcome, note, callback_on, pr.full_name as by_name
    from public.sales_calls k left join public.profiles pr on pr.id = k.called_by
    order by code, called_at desc
  ),
  base as (
    select v.*, lo.last_d, lo.first_d, lo.n_dates, rh.rhythm,
           (v_today - lo.last_d) as days_missing,
           r.m12, coalesce(r.last3, 0) as last3, coalesce(r.prev3, 0) as prev3,
           coalesce(r.total12, 0) as total12, coalesce(r.farm12, 0) as farm12, coalesce(r.food12, 0) as food12,
           r.last_month, fe.first_month,
           coalesce(pp.n, 0) as postponed30,
           k.called_at, k.outcome, k.note as call_note, k.by_name as call_by, k.callback_on,
           -- what a month of this client is worth: the last 6 report months, else the 12
           case when coalesce(r.last3, 0) + coalesce(r.prev3, 0) > 0 then (r.last3 + r.prev3) / 6
                else coalesce(r.total12, 0) / 12 end as month_value,
           -- a lower bound when only the month is known
           case when lo.last_d is null and r.last_month is not null
                then v_today - (r.last_month + interval '1 month - 1 day')::date end as days_min
    from vis v
    left join last_order lo on lo.code = v.code
    left join rhythm rh on rh.code = v.code
    left join rev r on r.code = v.code
    left join first_ever fe on fe.code = v.code
    left join postponed pp on pp.code = v.code
    left join calls k on k.code = v.code
  ),
  judged as (
    select b.*,
      case
        when b.days_missing is not null and b.rhythm is not null and b.days_missing <= 120
             and b.days_missing >= greatest(ceil(b.rhythm * 1.5), b.rhythm + 2) then 'call_now'
        when b.days_missing is not null and b.rhythm is null and b.days_missing between 21 and 120
             and (b.last_d >= v_today - 180 or b.last3 > 0) then 'call_now'
        when b.days_missing is null and b.days_min is not null and b.days_min between 21 and 120 then 'call_now'
        when coalesce(b.days_missing, b.days_min) > 120 and b.total12 > 0 then 'lost'
        when b.prev3 >= 10000 and b.last3 < 0.6 * b.prev3 then 'at_risk'
        when b.postponed30 >= 2 then 'at_risk'
        when b.first_month is not null and b.first_month > v_months[1]
             and b.first_month >= date_trunc('month', v_today - 90)::date then 'new'
        when b.days_missing is not null or b.total12 > 0 then 'ok'
        else 'none'
      end as status
    from base b
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'code', j.code, 'name', j.name, 'odoo_name', j.odoo_name, 'notes', j.notes,
           'area', j.area, 'zone', j.zone, 'portfolio', j.portfolio,
           'salesperson', j.salesperson_code, 'odoo_salesperson', j.odoo_salesperson,
           'last_order', j.last_d, 'days_missing', j.days_missing, 'days_min', j.days_min,
           'last_month', j.last_month, 'rhythm', j.rhythm, 'n_dates', coalesce(j.n_dates, 0),
           'm12', j.m12, 'last3', round(j.last3, 2), 'prev3', round(j.prev3, 2),
           'total12', round(j.total12, 2), 'farm12', round(j.farm12, 2), 'food12', round(j.food12, 2),
           'postponed30', j.postponed30,
           'status', j.status,
           'drop_pct', case when j.prev3 > 0 then round(100 * (j.last3 - j.prev3) / j.prev3) end,
           'call', case when j.called_at is not null then jsonb_build_object(
                     'at', j.called_at, 'outcome', j.outcome, 'note', j.call_note, 'by', j.call_by,
                     'callback_on', j.callback_on) end,
           'month_value', round(j.month_value),
           -- priority = a month of the client × how late (× rhythm, or × 21 days without one), at most × 4
           'priority', case when j.status in ('call_now', 'at_risk', 'lost') then round(j.month_value * least(4,
                         case when j.days_missing is not null and j.rhythm is not null and j.rhythm > 0
                                then j.days_missing::numeric / j.rhythm
                              when coalesce(j.days_missing, j.days_min) is not null
                                then coalesce(j.days_missing, j.days_min)::numeric / 21
                              else 1 end)) else 0 end)
         order by case j.status when 'call_now' then 0 when 'at_risk' then 1 when 'lost' then 2
                                when 'new' then 3 when 'ok' then 4 else 5 end,
                  j.total12 desc, j.name), '[]'::jsonb)
    into v_rows
  from judged j
  where j.portfolio <> 'house' or j.status <> 'none';

  with active as (
    select code from public.sales_monthly where amount <> 0
    union select code from public.sales_invoices where code is not null
    union select code from public.sales_paper_orders() where code is not null)
  select count(*) into v_hidden
  from public.sales_customers c
  where (p_all or v_scope = 'all') and c.portfolio = 'house'
    and c.code not in (select code from active);

  return jsonb_build_object(
    'today', v_today,
    'scope', v_scope,
    'my_code', v_code,
    'months', to_jsonb(v_months),
    -- report months with no figure at all (Oct 2025 is missing from the 09-2026 report)
    'months_empty', (select coalesce(jsonb_agg(mm order by mm), '[]'::jsonb) from unnest(v_months) mm
                     where not exists (select 1 from public.sales_monthly s where s.month = mm)),
    'invoices_to', v_inv_to,
    'invoices_from', (select min(invoice_date) from public.sales_invoices),
    'papers_from', v_pap_from,
    'report_to', (select max(month) from public.sales_monthly),
    'hidden_inactive', v_hidden,
    'clients', v_rows,
    'loaded_at', now());
end;
$$;
revoke all on function public.sales_clients_core(boolean) from public, anon, authenticated;

create or replace function public.sales_clients()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$ select public.sales_clients_core(false) $$;
revoke all on function public.sales_clients() from public, anon;
grant execute on function public.sales_clients() to authenticated, service_role;


-- ----------------------------------------------------------------------------
-- 3. Calls with a call-back date
-- ----------------------------------------------------------------------------
drop function if exists public.sales_log_call(text, text, text);
create or replace function public.sales_log_call(p_code text, p_outcome text, p_note text default null,
                                                 p_callback date default null)
returns uuid
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v uuid;
  v_today date := (now() at time zone 'Asia/Bangkok')::date;
begin
  if not public.sales_can_see(p_code) then raise exception 'not allowed' using errcode = '42501'; end if;
  if p_outcome not in ('ordered', 'call_back', 'no_answer', 'no_need', 'problem') then
    raise exception 'unknown outcome' using errcode = '22023';
  end if;
  if p_outcome = 'problem' and nullif(btrim(coalesce(p_note, '')), '') is null then
    raise exception 'write what the problem is' using errcode = '22023';
  end if;
  if p_callback is not null and (p_callback < v_today or p_callback > v_today + 90) then
    raise exception 'call-back date: today to 90 days' using errcode = '22023';
  end if;
  insert into public.sales_calls (code, called_by, outcome, note, callback_on)
  values (p_code, auth.uid(), p_outcome, nullif(btrim(coalesce(p_note, '')), ''),
          case when p_outcome = 'call_back' then coalesce(p_callback, v_today + 2)
               when p_outcome = 'no_answer' then p_callback end)
  returning id into v;
  return v;
end;
$$;
revoke all on function public.sales_log_call(text, text, text, date) from public, anon;
grant execute on function public.sales_log_call(text, text, text, date) to authenticated, service_role;


-- ----------------------------------------------------------------------------
-- 4. Every order date known per client (invoices + working papers), internal
-- ----------------------------------------------------------------------------
create or replace function public.sales_order_dates()
returns table (code text, d date)
language sql
stable
security definer
set search_path = public
as $$
  select distinct code, d from (
    select i.code, i.invoice_date as d from public.sales_invoices i
      where i.code is not null and coalesce(i.untaxed, i.total, 0) > 0
    union all
    select o.code, o.order_date from public.sales_paper_orders() o where o.code is not null
  ) u;
$$;
revoke all on function public.sales_order_dates() from public, anon, authenticated;


-- ----------------------------------------------------------------------------
-- 5. Alerts: my clients' orders postponed, moved, or with a delivery problem
-- ----------------------------------------------------------------------------
create or replace function public.sales_alerts(p_days int default 7)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_seen timestamptz;
  v_events jsonb;
begin
  if public.sales_scope() is null then raise exception 'not allowed' using errcode = '42501'; end if;
  select seen_at into v_seen from public.sales_alert_seen where profile_id = auth.uid();

  with ev as (
    -- production or middle office moved a working paper (reason not shown)
    select h.created_at as at, 'postponed' as kind, c.code, c.name as client, c.salesperson_code as rep,
           h.po_number, h.company, coalesce(h.from_delivery_date, h.from_work_date) as from_date,
           coalesce(p.delivery_date, h.to_delivery_date) as new_date, null::text as note
    from public.weighing_postponements h
    left join public.weighing_papers p on p.id = h.paper_id
    join public.sales_customers c on c.code = public.sales_code_for_name(coalesce(p.customer_name, h.customer_name))
    where h.created_at >= now() - make_interval(days => p_days) and public.sales_can_see(c.code)
    union all
    -- an order moved before production (middle office register)
    select r.created_at, 'postponed', c.code, c.name, c.salesperson_code, r.po_number, r.company,
           r.original_date, r.new_date, null
    from public.order_postponements r
    join public.sales_customers c on c.code = public.sales_code_for_name(r.customer_name)
    where r.created_at >= now() - make_interval(days => p_days) and public.sales_can_see(c.code)
    union all
    -- the delivery team marked a problem (their note is shown)
    select m.marked_at, 'problem', c.code, c.name, c.salesperson_code, p.po_number, p.company,
           m.delivery_date, null, m.note
    from public.delivery_marks m
    join public.weighing_papers p on p.id = m.paper_id
    join public.sales_customers c on c.code = public.sales_code_for_name(p.customer_name)
    where m.status = 'problem' and m.marked_at >= now() - make_interval(days => p_days)
      and public.sales_can_see(c.code)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'at', at, 'kind', kind, 'code', code, 'client', client, 'salesperson', rep, 'po_number', po_number,
           'company', company, 'from_date', from_date, 'new_date', new_date, 'note', note,
           'new', v_seen is null or at > v_seen) order by at desc), '[]'::jsonb)
    into v_events from ev;

  return jsonb_build_object(
    'events', v_events,
    'unseen', (select count(*) from jsonb_array_elements(v_events) e where (e->>'new')::boolean),
    'seen_at', v_seen);
end;
$$;

create or replace function public.sales_alerts_seen()
returns void
language sql
volatile
security definer
set search_path = public
as $$
  insert into public.sales_alert_seen (profile_id, seen_at)
  select auth.uid(), now() where auth.uid() is not null and public.sales_scope() is not null
  on conflict (profile_id) do update set seen_at = now();
$$;
revoke all on function public.sales_alerts(int), public.sales_alerts_seen() from public, anon;
grant execute on function public.sales_alerts(int), public.sales_alerts_seen() to authenticated, service_role;


-- ----------------------------------------------------------------------------
-- 6. My day
-- ----------------------------------------------------------------------------
-- p_rep: admin and sales director may look at one salesperson ('12') or the
-- whole team (null); a salesperson always gets their own day.
create or replace function public.sales_my_day(p_rep text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_scope text := public.sales_scope();
  v_rep   text;
  v_today date := (now() at time zone 'Asia/Bangkok')::date;
  v_all   jsonb;
  v_rows  jsonb;
  v_deliv jsonb;
begin
  if v_scope is null then raise exception 'not allowed' using errcode = '42501'; end if;
  v_rep := case when v_scope = 'own' then public.sales_my_code() else p_rep end;

  v_all := public.sales_clients_core(false);
  select coalesce(jsonb_agg(x), '[]'::jsonb) into v_rows
  from jsonb_array_elements(v_all->'clients') x
  where x->>'portfolio' = 'rep' and (v_rep is null or x->>'salesperson' = v_rep);

  v_deliv := public.sales_deliveries(v_today);

  return jsonb_build_object(
    'today', v_today,
    'rep', v_rep,
    'scope', v_scope,
    'report_to', v_all->'report_to',
    'invoices_to', v_all->'invoices_to',
    'papers_from', v_all->'papers_from',
    -- the 10 calls worth the most today: call now first by priority; a client
    -- called in the last 2 days waits (unless a call-back is due)
    'top_calls', (select coalesce(jsonb_agg(x order by (x->>'priority')::numeric desc), '[]'::jsonb) from (
        select x from jsonb_array_elements(v_rows) x
        where x->>'status' in ('call_now', 'at_risk')
          and coalesce((x->'call'->>'at')::timestamptz, '-infinity') <= now() - interval '2 days'
        order by (x->>'status' = 'call_now') desc, (x->>'priority')::numeric desc
        limit 10) s),
    'call_now_total', (select count(*) from jsonb_array_elements(v_rows) x where x->>'status' = 'call_now'),
    -- call-backs due today or overdue, unless the client ordered since the call
    'callbacks', (select coalesce(jsonb_agg(x order by x->'call'->>'callback_on'), '[]'::jsonb)
        from jsonb_array_elements(v_rows) x
        where (x->'call'->>'callback_on')::date <= v_today
          and coalesce((x->>'last_order')::date, '1900-01-01') < ((x->'call'->>'at')::timestamptz at time zone 'Asia/Bangkok')::date),
    -- first sale in the last 3 months and not yet a regular rhythm
    'new_clients', (select coalesce(jsonb_agg(x order by x->>'last_order' nulls last), '[]'::jsonb)
        from jsonb_array_elements(v_rows) x where x->>'status' = 'new'),
    -- today's orders of these clients that need attention
    'today_orders', (select coalesce(jsonb_agg(o), '[]'::jsonb) from jsonb_array_elements(v_deliv->'orders') o
        where (v_rep is null or o->>'salesperson' = v_rep)),
    'today_moved', (select coalesce(jsonb_agg(m), '[]'::jsonb) from jsonb_array_elements(v_deliv->'moved') m
        where v_rep is null or exists (select 1 from public.sales_customers c where c.code = m->>'code' and c.salesperson_code = v_rep)),
    'kpis', public.sales_kpis(v_today - 29, v_today, v_rep));
end;
$$;


-- ----------------------------------------------------------------------------
-- 7. KPIs
-- ----------------------------------------------------------------------------
-- Ratios as {n, d, pct}: pct = 100 × n / d (null when d = 0).
create or replace function public.sales_ratio(n numeric, d numeric)
returns jsonb language sql immutable as $$
  select jsonb_build_object('n', round(coalesce(n, 0), 2), 'd', round(coalesce(d, 0), 2),
                            'pct', case when coalesce(d, 0) <> 0 then round(100 * coalesce(n, 0) / d, 1) end)
$$;

-- KPIs of one group of clients (codes) over a period.
create or replace function public.sales_kpi_block(p_rows jsonb, p_codes text[], p_from date, p_to date,
                                                  p_target numeric, p_target_actual numeric, p_od jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_today date := (now() at time zone 'Asia/Bangkok')::date;
  r jsonb;
begin
  with c as (
    select x from jsonb_array_elements(p_rows) x where x->>'code' = any(p_codes)
  ), base as (
    select x from c where (x->>'total12')::numeric > 0 or (x->>'days_missing')::int <= 180
  ), od as (
    select e->>'code' as code, (e->>'d')::date as d from jsonb_array_elements(p_od) e where e->>'code' = any(p_codes)
  ), calls as (
    select k.* from public.sales_calls k
    where k.code = any(p_codes) and (k.called_at at time zone 'Asia/Bangkok')::date between p_from and p_to
  ), papers as (
    -- counted on the day the order was first due (a postponed order stays in its own period)
    select o.paper_id, o.code from public.sales_paper_orders() o
    where o.code = any(p_codes)
      and coalesce((select min(coalesce(h.from_delivery_date, h.from_work_date)) from public.weighing_postponements h
                    where h.paper_id = o.paper_id), o.order_date) between p_from and p_to
  ), lines as (
    select l.ordered_qty, l.actual_kg from public.weighing_lines l
    join papers p on p.paper_id = l.paper_id
    join public.weighing_papers wp on wp.id = l.paper_id and wp.status = 'confirmed'
    where lower(coalesce(l.ordered_unit, '')) in ('kg', 'kgs', 'กก', 'กก.') and l.ordered_qty > 0 and l.actual_kg is not null
  ), ranked as (
    select (x->>'total12')::numeric as t, row_number() over (order by (x->>'total12')::numeric desc) as rk from c
  ), react as (
    -- orders in the period whose previous order was 30+ days before
    select distinct a.code from od a
    where a.d between p_from and p_to
      and exists (select 1 from od b where b.code = a.code and b.d < a.d)
      and not exists (select 1 from od b where b.code = a.code and b.d < a.d and b.d > a.d - 30)
  )
  select jsonb_build_object(
    'clients', (select count(*) from c),
    'base', (select count(*) from base),
    'active30', public.sales_ratio((select count(*) from base where (x->>'days_missing')::int <= 30), (select count(*) from base)),
    'on_track', public.sales_ratio((select count(*) from base where x->>'status' in ('ok', 'new')), (select count(*) from base)),
    'call_now', public.sales_ratio((select count(*) from base where x->>'status' = 'call_now'), (select count(*) from base)),
    'at_risk',  public.sales_ratio((select count(*) from base where x->>'status' = 'at_risk'), (select count(*) from base)),
    'lost',     public.sales_ratio((select count(*) from base where x->>'status' = 'lost'), (select count(*) from base)),
    'growth',   (select jsonb_build_object('last3', round(sum((x->>'last3')::numeric)), 'prev3', round(sum((x->>'prev3')::numeric)),
                   'pct', case when sum((x->>'prev3')::numeric) > 0
                               then round(100 * (sum((x->>'last3')::numeric) - sum((x->>'prev3')::numeric)) / sum((x->>'prev3')::numeric), 1) end)
                 from c),
    'target_ytd', public.sales_ratio(p_target_actual, p_target),
    'top10',    public.sales_ratio((select sum(t) from ranked where rk <= 10), (select sum(t) from ranked)),
    'food',     public.sales_ratio((select sum((x->>'food12')::numeric) from c), (select sum((x->>'total12')::numeric) from c)),
    'revenue12', (select round(sum((x->>'total12')::numeric)) from c),
    'calls', (select count(*) from calls),
    'clients_called', (select count(distinct code) from calls),
    'coverage', public.sales_ratio(
        (select count(*) from c where x->>'status' = 'call_now'
            and exists (select 1 from public.sales_calls k where k.code = x->>'code' and k.called_at >= now() - interval '7 days')),
        (select count(*) from c where x->>'status' = 'call_now')),
    'call_to_order', public.sales_ratio(
        (select count(*) from calls k where exists (select 1 from od where od.code = k.code
            and od.d between (k.called_at at time zone 'Asia/Bangkok')::date and (k.called_at at time zone 'Asia/Bangkok')::date + 7)),
        (select count(*) from calls)),
    'reactivated', (select count(*) from react),
    'orders', (select count(*) from papers),
    'postponed', public.sales_ratio(
        (select count(*) from papers p where exists (select 1 from public.weighing_postponements h where h.paper_id = p.paper_id)),
        (select count(*) from papers)),
    'problem', public.sales_ratio(
        (select count(*) from papers p join public.delivery_marks m on m.paper_id = p.paper_id and m.status = 'problem'),
        (select count(*) from papers)),
    'weight_ok', public.sales_ratio(
        (select count(*) from lines where abs(actual_kg - ordered_qty) <= 0.05 * ordered_qty),
        (select count(*) from lines))
  ) into r;
  return r;
end;
$$;
revoke all on function public.sales_kpi_block(jsonb, text[], date, date, numeric, numeric, jsonb) from public, anon, authenticated;

-- Target and actual, year to date over the report months (036 targets: each
-- quarter split by month in proportion to the Prosun Farm budget).
create or replace function public.sales_target_ytd(p_codes_rep text[])
returns table (code text, target numeric, actual numeric)
language sql
stable
security definer
set search_path = public
as $$
  with last as (select max(month) as m from public.sales_monthly),
  q_month as (
    select t.code, b.month, t.amount * b.amount / nullif(sum(b.amount) over (partition by t.code, t.quarter), 0) as target
    from public.sales_targets t
    join public.sales_budget b on b.company = 'Prosun Farm' and b.scenario = 'conservative'
      and b.month >= t.quarter and b.month < (t.quarter + interval '3 months')
  )
  select r.code,
         (select sum(q.target) from q_month q, last
           where q.code = r.code and q.month <= last.m and q.month >= date_trunc('year', last.m)),
         (select sum(m.amount) from public.sales_monthly m join public.sales_customers c on c.code = m.code, last
           where c.portfolio = 'rep' and c.salesperson_code = r.code
             and m.month <= last.m and m.month >= date_trunc('year', last.m))
  from unnest(p_codes_rep) r(code);
$$;
revoke all on function public.sales_target_ytd(text[]) from public, anon, authenticated;

-- p_rep (internal use by My day): one salesperson's block only.
create or replace function public.sales_kpis(p_from date, p_to date, p_rep text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_scope text := public.sales_scope();
  v_admin boolean := coalesce(public.current_role(), '') = 'admin';
  v_me    text := public.sales_my_code();
  v_core  jsonb;
  v_rows  jsonb;
  v_od    jsonb;
  v_reps  jsonb := '[]'::jsonb;
  v_team  jsonb;
  rec     record;
  v_codes text[];
  v_tt numeric := 0; v_ta numeric := 0;
  v_show  text[];
begin
  if v_scope is null then raise exception 'not allowed' using errcode = '42501'; end if;
  if p_from is null or p_to is null or p_from > p_to or p_to - p_from > 400 then
    raise exception 'choose a period (at most 400 days)' using errcode = '22023';
  end if;

  v_core := public.sales_clients_core(true);           -- every portfolio, for the team figures
  select coalesce(jsonb_agg(x), '[]'::jsonb) into v_rows
  from jsonb_array_elements(v_core->'clients') x where x->>'portfolio' = 'rep';
  select coalesce(jsonb_agg(jsonb_build_object('code', code, 'd', d)), '[]'::jsonb) into v_od
  from public.sales_order_dates() where code in (select x->>'code' from jsonb_array_elements(v_rows) x);

  -- whose blocks this person may see
  v_show := case
    when p_rep is not null and (v_admin or v_scope = 'all' or p_rep = v_me) then array[p_rep]
    when v_admin then (select array_agg(code order by code) from public.sales_reps where active)
    when v_me is not null then array[v_me]
    else array[]::text[] end;

  for rec in select r.code, r.short_name, r.is_director, t.target, t.actual
             from public.sales_reps r
             left join public.sales_target_ytd(array[r.code]) t on t.code = r.code
             where r.active order by r.code loop
    select array_agg(x->>'code') into v_codes from jsonb_array_elements(v_rows) x where x->>'salesperson' = rec.code;
    v_tt := v_tt + coalesce(rec.target, 0);
    v_ta := v_ta + case when rec.target is not null then coalesce(rec.actual, 0) else 0 end;
    if rec.code = any(v_show) then
      v_reps := v_reps || jsonb_build_array(
                  jsonb_build_object('code', rec.code, 'name', rec.short_name, 'director', rec.is_director)
                  || public.sales_kpi_block(v_rows, coalesce(v_codes, array[]::text[]), p_from, p_to,
                                            rec.target, rec.actual, v_od));
    end if;
  end loop;

  if p_rep is null then
    select array_agg(x->>'code') into v_codes from jsonb_array_elements(v_rows) x;
    v_team := jsonb_build_object('code', 'team', 'name', 'Team')
              || public.sales_kpi_block(v_rows, coalesce(v_codes, array[]::text[]), p_from, p_to,
                                        nullif(v_tt, 0), v_ta, v_od);
  end if;

  return jsonb_build_object(
    'from', p_from, 'to', p_to, 'scope', case when v_admin then 'admin' else v_scope end,
    'report_to', v_core->'report_to', 'papers_from', v_core->'papers_from',
    'invoices_from', v_core->'invoices_from', 'invoices_to', v_core->'invoices_to',
    'reps', v_reps, 'team', v_team,
    -- admin only: what to act on across the team
    'at_stake', case when v_admin and p_rep is null then (
        select coalesce(jsonb_agg(x order by (x->>'priority')::numeric desc), '[]'::jsonb) from (
          select x from jsonb_array_elements(v_rows) x where (x->>'priority')::numeric > 0
          order by (x->>'priority')::numeric desc limit 15) s) end,
    'house_to_assign', case when v_admin and p_rep is null then (
        select coalesce(jsonb_agg(x order by (x->>'total12')::numeric desc), '[]'::jsonb)
        from jsonb_array_elements(v_core->'clients') x
        where x->>'portfolio' = 'house' and coalesce((x->>'days_missing')::int, 999) <= 60
          and x->>'code' <> 'ZA001') end,
    'loaded_at', now());
end;
$$;
revoke all on function public.sales_kpis(date, date, text), public.sales_my_day(text) from public, anon;
grant execute on function public.sales_kpis(date, date, text), public.sales_my_day(text) to authenticated, service_role;
