-- ============================================================================
-- Migration 051 — Management › Weekly report (ready every Monday at 06:00)
-- ============================================================================
-- Written 27 Nov 2026. Clément: "I'd like to have a weekly report with graphs"
-- for him and Khun Jum (admin), ready on Monday at 06:00.
--
-- What it is
--   One report per week, Monday to Saturday (a Sunday paper, if any, counts in
--   its week). On Monday at 06:00 Bangkok, PACE computes last week's figures
--   and saves them in weekly_reports. A saved week does not move afterwards,
--   so weeks can be compared and the record of each Monday is kept. Admin can
--   rebuild a week on purpose (e.g. after uploading a newer Daily Sales
--   Reporting): the comment is kept and the page shows when and by whom.
--   The week in progress is shown live (not saved) for a mid-week look.
--
-- Where the figures come from (the same rules as the other Management pages)
--   Week value     confirmed working papers × list price, on the production
--                  day — the rule of Migrations 031 / 047. An estimate at list
--                  prices (no discounts; Prosun Food prepared products have no
--                  price yet), not accounting. Compared week to week and with
--                  the budget's weekly pace.
--   Budget pace    the conservative budget (036): each Monday–Saturday day
--                  counts month budget ÷ the month's working days.
--   Month to date  the Daily Sales Reporting as last uploaded on Overview (036):
--                  exact invoiced sales, against the budget for the days it
--                  covers, with the month-end projection.
--   Sales team     sales_kpis for the week (039): calls, call-now clients
--                  called, calls followed by an order, reactivated clients,
--                  portfolio status, target year to date (sales report).
--                  Week value per salesperson: the week's papers of their
--                  clients (client code, 037), against the week's share of
--                  their quarterly target (036 split by the Farm budget).
--   Clients        papers of the week: clients ordering, new (first paper
--                  since count_from, once PACE has 4 weeks of history), silent
--                  14–90 days, the week's biggest clients against their usual
--                  week (average of the 4 weeks before).
--   Execution      orders due in the week, postponements counted on the
--                  delivery date missed (027/028/031 rule), internal vs client,
--                  delivery problems (029), kg given over +5% (036), lines
--                  within ±5 %, papers of the week not yet confirmed.
--   Purchasing     goods + freight of birds arriving in the week ÷ week value
--                  (047 rule).
--   To look at     up to 7 points written by fixed rules from the figures
--                  above (no AI: every point can be traced to a number).
--
-- Access: admin only (Clément, Khun Jum). The table has no policy; it is read
-- and written through the functions below. The automatic run uses an admin
-- identity for the duration of one call only, because the Sales KPIs function
-- (039) decides what it shows from the signed-in person.
--
-- Monday 06:00: pg_cron (Supabase › Database › Extensions › pg_cron). If
-- pg_cron is not enabled when this runs, enable it and run this file again.
-- Also, when admin opens the Weekly report and last week has no report yet,
-- PACE builds it then — so the report exists even without the schedule.
--
-- Run order: after 050. Safe to re-run (reports and comments are kept).
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Saved reports
-- ----------------------------------------------------------------------------
create table if not exists public.weekly_reports (
  week_start  date primary key check (extract(isodow from week_start) = 1),
  data        jsonb not null,
  built_at    timestamptz not null default now(),
  built_by    uuid references public.profiles(id),     -- null = automatic (Monday 06:00) or on first opening
  comment     text check (comment is null or length(comment) <= 4000),
  comment_by  uuid references public.profiles(id),
  comment_at  timestamptz
);

comment on table public.weekly_reports is
  'Management › Weekly report: one saved report per week (Monday = week_start, Monday to Saturday). '
  'Built on Monday 06:00 Bangkok by pg_cron, or by admin. Migration 051.';

alter table public.weekly_reports enable row level security;
revoke all on public.weekly_reports from anon, authenticated;
grant all on public.weekly_reports to service_role;


-- ----------------------------------------------------------------------------
-- 2. Value of each confirmed paper at list price (rule of Migration 047)
-- ----------------------------------------------------------------------------
-- Same pricing as purchase_ratio_days (047), kept per paper so the week can be
-- split by client and salesperson. The day totals equal purchase_ratio_days.
create or replace function public.weekly_paper_values(p_from date, p_to date)
returns table (paper_id uuid, day date, company text, client text, ck text,
               rev numeric, kg numeric, kg_priced numeric)
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
  )
  select paper_id, day, company, min(client), public.client_match_key(min(client)),
         round(coalesce(sum(revenue), 0), 2),
         round(coalesce(sum(actual_kg), 0), 2),
         round(coalesce(sum(actual_kg) filter (where revenue is not null), 0), 2)
  from priced
  group by paper_id, day, company;
$$;
revoke all on function public.weekly_paper_values(date, date) from public, anon, authenticated;
grant execute on function public.weekly_paper_values(date, date) to service_role;


-- ----------------------------------------------------------------------------
-- 3. Budget and target for a run of days (Monday–Saturday days only)
-- ----------------------------------------------------------------------------
-- Conservative budget, both companies: each working day = month budget ÷ the
-- month's working days.
create or replace function public.weekly_budget(p_from date, p_to date)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select round(coalesce(sum(b.amount / nullif(b.working_days, 0)), 0), 2)
  from generate_series(p_from, p_to, interval '1 day') d
  join public.sales_budget b on b.scenario = 'conservative' and b.month = date_trunc('month', d)::date
  where extract(isodow from d) < 7;
$$;
revoke all on function public.weekly_budget(date, date) from public, anon, authenticated;

-- A salesperson's target for a run of days: the quarter split into months by
-- the Prosun Farm budget (036), each month ÷ its working days.
create or replace function public.weekly_target(p_code text, p_from date, p_to date)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  with q_month as (
    select b.month, b.working_days,
           t.amount * b.amount / nullif(sum(b.amount) over (partition by t.quarter), 0) as target
    from public.sales_targets t
    join public.sales_budget b on b.company = 'Prosun Farm' and b.scenario = 'conservative'
      and b.month >= t.quarter and b.month < (t.quarter + interval '3 months')
    where t.code = p_code
  )
  select case when count(q.month) = 0 then null
              else round(sum(q.target / nullif(q.working_days, 0)), 2) end
  from generate_series(p_from, p_to, interval '1 day') d
  left join q_month q on q.month = date_trunc('month', d)::date
  where extract(isodow from d) < 7;
$$;
revoke all on function public.weekly_target(text, date, date) from public, anon, authenticated;


-- Postponement reason in Thai or English (labels of 027/028).
create or replace function public.weekly_reason_label(p_reason text, p_th boolean)
returns text
language sql
immutable
as $$
  select case when p_th then
    case p_reason when 'production' then 'ผลิตไม่ทัน' when 'raw_material' then 'สินค้าไม่พอ'
                  when 'delivery' then 'ส่งไม่ทันเวลา' when 'client' then 'ลูกค้าขอเลื่อน' else 'อื่นๆ' end
  else public.postponement_reason_label(p_reason) end;
$$;


-- ----------------------------------------------------------------------------
-- 4. The week's figures
-- ----------------------------------------------------------------------------
-- Internal: no role check here (admin entry points and pg_cron call it).
create or replace function public.weekly_report_compute(p_week date)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_ws     date := date_trunc('week', p_week)::date;          -- Monday
  v_we     date := date_trunc('week', p_week)::date + 6;      -- Sunday (papers); the report reads Mon–Sat
  v_sat    date := date_trunc('week', p_week)::date + 5;
  v_pws    date := date_trunc('week', p_week)::date - 7;
  v_today  date := (now() at time zone 'Asia/Bangkok')::date;
  v_start  date;
  v_t0     date;                 -- first week of the 12-week trend
  v_p0     date;                 -- first week of the 8-week postponement series
  v_month  date;                 -- month of the Saturday (month-to-date block)
  v_hist   boolean;              -- PACE has 4 full weeks before this one
  v_admin  uuid;
  v_c1     text;
  v_c2     text;
  v_sales  jsonb;
  v_top    jsonb;
  v_mtd    jsonb;
  v_team   jsonb;
  v_cli    jsonb;
  v_exe    jsonb;
  v_pur    jsonb;
  v_pts    jsonb := '[]'::jsonb;
  v_rec    record;
  v_n      numeric;
  v_m      numeric;
begin
  select s.count_from into v_start from public.management_settings s where s.id = 1;
  v_start := coalesce(v_start, date '2026-11-02');
  v_t0    := greatest(v_ws - 77, date_trunc('week', v_start)::date);
  v_p0    := greatest(v_ws - 49, date_trunc('week', v_start)::date);
  v_month := date_trunc('month', v_sat)::date;
  v_hist  := v_start <= v_ws - 28;

  -- -------------------------------------------------------------------------
  -- Sales KPIs (039) read the signed-in person. On the automatic run nobody is
  -- signed in: use an admin identity for this one call, then put it back.
  -- -------------------------------------------------------------------------
  v_c1 := current_setting('request.jwt.claims', true);
  v_c2 := current_setting('request.jwt.claim.sub', true);
  if auth.uid() is null then
    select p.id into v_admin from public.profiles p where p.role = 'admin' order by p.created_at, p.id limit 1;
    if v_admin is not null then
      perform set_config('request.jwt.claims', jsonb_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
      perform set_config('request.jwt.claim.sub', v_admin::text, true);
    end if;
  end if;
  begin
    v_sales := public.sales_kpis(v_ws, v_we);
  exception when others then
    v_sales := jsonb_build_object('error', sqlerrm);
  end;
  if v_admin is not null then
    perform set_config('request.jwt.claims', coalesce(v_c1, ''), true);
    perform set_config('request.jwt.claim.sub', coalesce(v_c2, ''), true);
  end if;

  -- -------------------------------------------------------------------------
  -- Top line: week value, days, trend, budget pace
  -- -------------------------------------------------------------------------
  create temporary table if not exists _wr_pv (paper_id uuid, day date, company text, client text, ck text,
                                               rev numeric, kg numeric, kg_priced numeric) on commit drop;
  truncate _wr_pv;
  insert into _wr_pv select * from public.weekly_paper_values(least(v_t0, v_ws - 28), v_we);

  select jsonb_build_object(
    'value',      coalesce(sum(rev) filter (where day between v_ws and v_we), 0),
    'kg',         coalesce(sum(kg) filter (where day between v_ws and v_we), 0),
    'kg_priced',  coalesce(sum(kg_priced) filter (where day between v_ws and v_we), 0),
    'papers',     count(*) filter (where day between v_ws and v_we),
    'prev_value', coalesce(sum(rev) filter (where day between v_pws and v_ws - 1), 0),
    'prev_kg',    coalesce(sum(kg) filter (where day between v_pws and v_ws - 1), 0),
    'prev_papers', count(*) filter (where day between v_pws and v_ws - 1),
    'avg4_value', case when v_hist then round(coalesce(sum(rev) filter (where day between v_ws - 28 and v_ws - 1), 0) / 4, 2) end,
    'budget',     public.weekly_budget(v_ws, v_sat),
    'farm_value', coalesce(sum(rev) filter (where day between v_ws and v_we and company = 'Prosun Farm'), 0),
    'food_value', coalesce(sum(rev) filter (where day between v_ws and v_we and company = 'Prosun Food'), 0),
    'farm_kg',    coalesce(sum(kg) filter (where day between v_ws and v_we and company = 'Prosun Farm'), 0),
    'food_kg',    coalesce(sum(kg) filter (where day between v_ws and v_we and company = 'Prosun Food'), 0),
    'days', (select jsonb_agg(jsonb_build_object(
                 'day', d::date,
                 'value', coalesce((select sum(rev) from _wr_pv x where x.day = d::date), 0),
                 'kg', coalesce((select sum(kg) from _wr_pv x where x.day = d::date), 0),
                 'papers', (select count(*) from _wr_pv x where x.day = d::date),
                 'prev_value', coalesce((select sum(rev) from _wr_pv x where x.day = d::date - 7), 0)) order by d)
             from generate_series(v_ws, v_we, interval '1 day') d
             where extract(isodow from d) < 7
                or exists (select 1 from _wr_pv x where x.day = d::date)),
    'trend', (select jsonb_agg(jsonb_build_object(
                 'week', w::date,
                 'value', coalesce((select sum(rev) from _wr_pv x where x.day between w::date and w::date + 6), 0),
                 'kg', coalesce((select sum(kg) from _wr_pv x where x.day between w::date and w::date + 6), 0),
                 'budget', public.weekly_budget(w::date, w::date + 5),
                 'partial', w::date < v_start) order by w)
              from generate_series(v_t0, v_ws, interval '7 days') w)
  ) into v_top
  from _wr_pv;

  -- Month to date from the Daily Sales Reporting (036).
  select jsonb_build_object(
    'month', v_month,
    'actual', sum(a.amount),
    'days', max(a.days_counted),
    'working_days', (select max(working_days) from public.sales_budget where month = v_month and scenario = 'conservative'),
    'budget_month', (select sum(amount) from public.sales_budget where month = v_month and scenario = 'conservative'),
    'as_of', case when max(a.days_counted) > 0 then public.nth_working_day(v_month, max(a.days_counted)) end,
    'uploaded_at', max(a.uploaded_at))
  into v_mtd
  from public.sales_actuals a where a.month = v_month;
  v_mtd := v_mtd || jsonb_build_object(
    'budget_to_date', case when (v_mtd->>'days')::int > 0 and (v_mtd->>'working_days')::int > 0
                           then round((v_mtd->>'budget_month')::numeric * least((v_mtd->>'days')::int, (v_mtd->>'working_days')::int)
                                      / (v_mtd->>'working_days')::int, 2) end,
    'projection', case when (v_mtd->>'days')::int > 0
                       then round((v_mtd->>'actual')::numeric / (v_mtd->>'days')::int * (v_mtd->>'working_days')::int, 2) end);

  -- -------------------------------------------------------------------------
  -- Sales team: KPIs (039) + week value of their clients' papers + target pace
  -- -------------------------------------------------------------------------
  with po as (
    select o.paper_id, o.code from public.sales_paper_orders() o
  ),
  wk as (
    select v.rev, v.kg, coalesce(case when c.portfolio = 'rep' then c.salesperson_code end,
                                 case when c.code is null then 'unlinked' else 'house' end) as who
    from _wr_pv v
    left join po on po.paper_id = v.paper_id
    left join public.sales_customers c on c.code = po.code
    where v.day between v_ws and v_we
  ),
  vals as (select who, sum(rev) as value, sum(kg) as kg, count(*) as papers from wk group by who)
  select jsonb_build_object(
    'reps', coalesce((select jsonb_agg(
               jsonb_build_object('code', r.code, 'name', r.short_name, 'director', r.is_director,
                                  'value', coalesce(v.value, 0), 'kg', coalesce(v.kg, 0), 'papers', coalesce(v.papers, 0),
                                  'target_week', public.weekly_target(r.code, v_ws, v_sat))
               || coalesce((select k - 'code' - 'name' - 'director'
                            from jsonb_array_elements(v_sales->'reps') k where k->>'code' = r.code), '{}'::jsonb)
               order by r.code)
             from public.sales_reps r left join vals v on v.who = r.code where r.active), '[]'::jsonb),
    'team', v_sales->'team',
    'house_value', coalesce((select value from vals where who = 'house'), 0),
    'unlinked_value', coalesce((select value from vals where who = 'unlinked'), 0),
    'unlinked_papers', coalesce((select papers from vals where who = 'unlinked'), 0),
    'report_to', v_sales->'report_to',
    'error', v_sales->'error')
  into v_team;

  -- -------------------------------------------------------------------------
  -- Clients
  -- -------------------------------------------------------------------------
  with pp as (
    select coalesce(nullif(trim(p.customer_name), ''), '—') as name, public.client_match_key(p.customer_name) as ck,
           p.work_date
    from public.weighing_papers p
    where p.status <> 'failed' and p.work_date >= v_start and p.work_date <= v_we
      and public.client_match_key(p.customer_name) is not null
  ),
  this_w as (select ck, min(name) as name from pp where work_date between v_ws and v_we group by ck),
  prev_w as (select distinct ck from pp where work_date between v_pws and v_ws - 1),
  before as (select distinct ck from pp where work_date < v_ws),
  last_seen as (
    select ck, min(name) as name, max(work_date) as last_day,
           count(*) filter (where work_date > v_we - 60) as papers_60
    from pp group by ck
  ),
  silent as (
    select l.*, v_we - l.last_day as days_silent from last_seen l
    where l.last_day <= v_we - 14 and l.last_day > v_we - 90
  ),
  big as (
    select ck, min(client) as name,
           sum(rev) filter (where day between v_ws and v_we) as value,
           sum(rev) filter (where day between v_ws - 28 and v_ws - 1) / 4 as usual
    from _wr_pv where ck is not null group by ck
  )
  select jsonb_build_object(
    'ordering', (select count(*) from this_w),
    'prev_ordering', (select count(*) from prev_w),
    'new', case when v_hist then (select count(*) from this_w where ck not in (select ck from before)) end,
    'new_list', case when v_hist then coalesce((select jsonb_agg(name order by name) from this_w
                                               where ck not in (select ck from before)), '[]'::jsonb) end,
    'back', case when v_hist then (select count(*) from this_w t where t.ck in (select ck from before)
                                     and t.ck not in (select ck from pp where work_date between v_ws - 28 and v_ws - 1)) end,
    'silent', (select count(*) from silent),
    'silent_list', coalesce((select jsonb_agg(x order by x.papers_60 desc, x.days_silent desc) from (
                     select name, last_day, days_silent, papers_60 from silent
                     order by papers_60 desc, days_silent desc limit 8) x), '[]'::jsonb),
    'top', coalesce((select jsonb_agg(x order by x.value desc) from (
              select name, round(value) as value, case when v_hist then round(coalesce(usual, 0)) end as usual
              from big where value > 0 order by value desc limit 10) x), '[]'::jsonb),
    'drops', case when v_hist then coalesce((select jsonb_agg(x order by x.gap desc) from (
              select name, round(coalesce(value, 0)) as value, round(usual) as usual, round(usual - coalesce(value, 0)) as gap
              from big where usual >= 5000 and coalesce(value, 0) < usual * 0.5
              order by usual - coalesce(value, 0) desc limit 8) x), '[]'::jsonb) end)
  into v_cli;

  -- -------------------------------------------------------------------------
  -- Execution
  -- -------------------------------------------------------------------------
  with papers as (
    select p.id, p.status, coalesce(p.delivery_date, p.work_date) as due, p.work_date
    from public.weighing_papers p
    where p.status <> 'failed'
      and (coalesce(p.delivery_date, p.work_date) between v_ws and v_we or p.work_date between v_ws and v_we)
  ),
  postp as (
    select coalesce(w.from_delivery_date, w.from_work_date) as day, w.reason
    from public.weighing_postponements w
    union all
    select r.original_date, r.reason from public.order_postponements r
  ),
  pw as (select * from postp where day between v_ws and v_we and day >= v_start),
  lines as (
    select l.actual_kg,
           case when l.ordered_unit = 'g' then l.ordered_qty / 1000 else l.ordered_qty end as kg_o,
           l.description
    from papers p join public.weighing_lines l on l.paper_id = p.id
    where p.status = 'confirmed' and p.work_date between v_ws and v_we
      and l.ordered_unit in ('kg', 'g') and l.ordered_qty > 0 and l.actual_kg is not null
  ),
  give as (
    select coalesce(sum(l.actual_kg - l.kg_o), 0) as kg,
           coalesce(sum((l.actual_kg - l.kg_o) * coalesce(pl.price_bkk, 0)) filter (where pl.unit = 'kg'), 0) as value
    from lines l
    left join public.price_list pl on pl.id = public.price_list_match(l.description, null)
    where l.actual_kg > l.kg_o * 1.05
  )
  select jsonb_build_object(
    'orders', (select count(*) from papers where due between v_ws and v_we),
    'not_confirmed', (select count(*) from papers where work_date between v_ws and v_we and status <> 'confirmed'),
    'postponed', (select count(*) from pw),
    'internal', (select count(*) from pw where reason <> 'client'),
    'client', (select count(*) from pw where reason = 'client'),
    'reasons', coalesce((select jsonb_agg(x order by x.n desc, x.reason) from (
                 select reason, count(*) as n from pw group by reason) x), '[]'::jsonb),
    'problems', (select count(*) from public.delivery_marks m join papers p on p.id = m.paper_id
                 where m.status = 'problem' and p.due between v_ws and v_we),
    'problem_notes', coalesce((select jsonb_agg(x) from (
                 select coalesce(nullif(trim(wp.customer_name), ''), '—') as client, m.note, m.delivery_date
                 from public.delivery_marks m join papers p on p.id = m.paper_id
                 join public.weighing_papers wp on wp.id = m.paper_id
                 where m.status = 'problem' and p.due between v_ws and v_we
                 order by m.delivery_date limit 8) x), '[]'::jsonb),
    'give_kg', (select round(kg, 1) from give),
    'give_value', (select round(value) from give),
    'lines', (select count(*) from lines),
    'lines_ok', (select count(*) from lines where abs(actual_kg - kg_o) <= 0.05 * kg_o),
    'series', (select jsonb_agg(jsonb_build_object(
                  'week', w::date,
                  'internal', (select count(*) from postp x where x.day between w::date and w::date + 6
                                 and x.day >= v_start and x.reason <> 'client'),
                  'client', (select count(*) from postp x where x.day between w::date and w::date + 6
                                 and x.day >= v_start and x.reason = 'client'),
                  'orders', (select count(*) from public.weighing_papers p where p.status <> 'failed'
                                 and coalesce(p.delivery_date, p.work_date) between greatest(w::date, v_start) and w::date + 6))
                  order by w)
               from generate_series(v_p0, v_ws, interval '7 days') w)
  ) into v_exe;

  -- -------------------------------------------------------------------------
  -- Purchasing (047): birds arriving in the week against the week's value
  -- -------------------------------------------------------------------------
  select jsonb_build_object(
    'cost', coalesce(sum(cost + freight) filter (where day between v_ws and v_we), 0),
    'value', coalesce(sum(rev) filter (where day between v_ws and v_we), 0),
    'estimate', coalesce(bool_or(est) filter (where day between v_ws and v_we), false),
    'birds_ordered', coalesce(sum(birds_ordered) filter (where day between v_ws and v_we), 0),
    'birds_received', coalesce(sum(birds_received) filter (where day between v_ws and v_we), 0),
    'orders', coalesce(sum(orders) filter (where day between v_ws and v_we), 0),
    'no_price', coalesce(sum(no_price) filter (where day between v_ws and v_we), 0),
    'prev_cost', coalesce(sum(cost + freight) filter (where day between v_pws and v_ws - 1), 0),
    'prev_value', coalesce(sum(rev) filter (where day between v_pws and v_ws - 1), 0))
  into v_pur
  from public.purchase_ratio_days(v_pws, v_we, null);
  v_pur := v_pur || jsonb_build_object(
    'ratio', case when (v_pur->>'value')::numeric > 0 and (v_pur->>'cost')::numeric > 0
                  then round(100 * (v_pur->>'cost')::numeric / (v_pur->>'value')::numeric, 1) end,
    'prev_ratio', case when (v_pur->>'prev_value')::numeric > 0 and (v_pur->>'prev_cost')::numeric > 0
                       then round(100 * (v_pur->>'prev_cost')::numeric / (v_pur->>'prev_value')::numeric, 1) end);

  -- -------------------------------------------------------------------------
  -- To look at: fixed rules, most important first (warn, then info, then good)
  -- -------------------------------------------------------------------------
  -- Papers not confirmed: the figures are incomplete.
  if (v_exe->>'not_confirmed')::int > 0 then
    v_pts := v_pts || jsonb_build_object('level', 'warn', 'key', 'not_confirmed', 'n', (v_exe->>'not_confirmed')::int,
      'th', format('ใบงาน %s ใบของสัปดาห์ยังไม่ยืนยันน้ำหนัก — ตัวเลขยังไม่ครบ', v_exe->>'not_confirmed'),
      'en', format('%s of the week''s working papers %s not confirmed — the figures are incomplete', v_exe->>'not_confirmed',
                   case when (v_exe->>'not_confirmed')::int = 1 then 'is' else 'are' end));
  end if;

  -- Week value against budget pace and last week.
  v_n := (v_top->>'value')::numeric;
  v_m := (v_top->>'budget')::numeric;
  if v_m > 0 and v_n < v_m * 0.9 then
    v_pts := v_pts || jsonb_build_object('level', 'warn', 'key', 'budget',
      'th', format('มูลค่าสัปดาห์ (ประมาณ) %s%% ของงบประมาณสัปดาห์', round(100 * v_n / v_m)),
      'en', format('Week value (estimate) at %s%% of the weekly budget pace', round(100 * v_n / v_m)));
  elsif v_m > 0 and v_n >= v_m then
    v_pts := v_pts || jsonb_build_object('level', 'good', 'key', 'budget',
      'th', format('มูลค่าสัปดาห์ (ประมาณ) %s%% ของงบประมาณสัปดาห์', round(100 * v_n / v_m)),
      'en', format('Week value (estimate) at %s%% of the weekly budget pace', round(100 * v_n / v_m)));
  end if;
  v_m := (v_top->>'prev_value')::numeric;
  if v_m > 0 and abs(v_n - v_m) >= v_m * 0.1 then
    v_pts := v_pts || jsonb_build_object('level', case when v_n < v_m then 'warn' else 'good' end, 'key', 'week',
      'th', format('มูลค่าสัปดาห์ %s%% เทียบกับสัปดาห์ก่อน', to_char(round(100 * (v_n - v_m) / v_m), 'FMSG999')),
      'en', format('Week value %s%% against last week', to_char(round(100 * (v_n - v_m) / v_m), 'FMSG999')));
  end if;

  -- Month to date (exact, Daily Sales Reporting).
  if (v_mtd->>'budget_to_date')::numeric > 0 then
    v_n := round(100 * (v_mtd->>'actual')::numeric / (v_mtd->>'budget_to_date')::numeric);
    if v_n < 95 then
      v_pts := v_pts || jsonb_build_object('level', 'warn', 'key', 'mtd',
        'th', format('ยอดขายเดือนนี้ (Daily Sales ถึง %s) %s%% ของงบประมาณ — คาดการณ์สิ้นเดือน %s บาท',
                     to_char((v_mtd->>'as_of')::date, 'DD/MM'), v_n, to_char(round((v_mtd->>'projection')::numeric), 'FM999,999,999')),
        'en', format('Month to date (Daily Sales to %s) at %s%% of budget — month-end projection %s THB',
                     to_char((v_mtd->>'as_of')::date, 'DD Mon'), v_n, to_char(round((v_mtd->>'projection')::numeric), 'FM999,999,999')));
    end if;
  end if;
  if v_mtd->>'uploaded_at' is null or (v_mtd->>'uploaded_at')::timestamptz < (v_we::timestamp at time zone 'Asia/Bangkok') - interval '7 days' then
    v_pts := v_pts || jsonb_build_object('level', 'info', 'key', 'upload',
      'th', 'ยังไม่ได้อัปโหลด Daily Sales Reporting ในสัปดาห์นี้ (หน้า Overview)',
      'en', 'The Daily Sales Reporting was not uploaded this week (Overview page)');
  end if;

  -- Internal postponements.
  if (v_exe->>'internal')::int > 0 then
    v_pts := v_pts || jsonb_build_object('level', 'warn', 'key', 'postponed', 'n', (v_exe->>'internal')::int,
      'th', format('เลื่อนออเดอร์จากภายใน %s ครั้ง (สาเหตุหลัก: %s)', v_exe->>'internal',
                   public.weekly_reason_label((select x->>'reason' from jsonb_array_elements(v_exe->'reasons') x
                                               where x->>'reason' <> 'client' limit 1), true)),
      'en', format('%s internal postponement%s (main reason: %s)', v_exe->>'internal',
                   case when (v_exe->>'internal')::int = 1 then '' else 's' end,
                   public.weekly_reason_label((select x->>'reason' from jsonb_array_elements(v_exe->'reasons') x
                                               where x->>'reason' <> 'client' limit 1), false)));
  end if;

  -- Delivery problems.
  if (v_exe->>'problems')::int > 0 then
    v_pts := v_pts || jsonb_build_object('level', 'warn', 'key', 'problems', 'n', (v_exe->>'problems')::int,
      'th', format('ปัญหาการจัดส่ง %s รายการ', v_exe->>'problems'),
      'en', format('%s delivery problem%s', v_exe->>'problems', case when (v_exe->>'problems')::int = 1 then '' else 's' end));
  end if;

  -- Clients well under their usual week.
  if jsonb_typeof(v_cli->'drops') = 'array' and jsonb_array_length(v_cli->'drops') > 0 then
    v_pts := v_pts || jsonb_build_object('level', 'warn', 'key', 'drops',
      'th', format('ลูกค้า %s รายสั่งน้อยกว่าครึ่งของปกติ (มากสุด: %s)',
                   jsonb_array_length(v_cli->'drops'), v_cli->'drops'->0->>'name'),
      'en', format('%s client(s) ordered under half their usual week (largest: %s)',
                   jsonb_array_length(v_cli->'drops'), v_cli->'drops'->0->>'name'));
  end if;

  -- Salespeople: call-now clients not called; no call logged.
  for v_rec in select x from jsonb_array_elements(coalesce(v_team->'reps', '[]'::jsonb)) x
               where not coalesce((x->>'director')::boolean, false) loop
    if coalesce((v_rec.x->>'calls')::int, 0) = 0 then
      v_pts := v_pts || jsonb_build_object('level', 'warn', 'key', 'calls_' || (v_rec.x->>'code'),
        'th', format('%s: ไม่มีการบันทึกการโทรในสัปดาห์นี้', v_rec.x->>'name'),
        'en', format('%s: no call logged this week', v_rec.x->>'name'));
    elsif (v_rec.x->'coverage'->>'d')::numeric > 0 and (v_rec.x->'coverage'->>'pct')::numeric < 50 then
      v_pts := v_pts || jsonb_build_object('level', 'warn', 'key', 'coverage_' || (v_rec.x->>'code'),
        'th', format('%s: โทรหาลูกค้า "โทรเลย" ใน 7 วัน %s จาก %s ราย', v_rec.x->>'name',
                     round((v_rec.x->'coverage'->>'n')::numeric), round((v_rec.x->'coverage'->>'d')::numeric)),
        'en', format('%s: called %s of %s call-now clients within 7 days', v_rec.x->>'name',
                     round((v_rec.x->'coverage'->>'n')::numeric), round((v_rec.x->'coverage'->>'d')::numeric)));
    end if;
  end loop;

  -- Weight given away.
  if (v_exe->>'give_value')::numeric >= 1000 then
    v_pts := v_pts || jsonb_build_object('level', 'info', 'key', 'give',
      'th', format('ให้น้ำหนักเกิน +5%% รวม %s กก. (ประมาณ %s บาท)', v_exe->>'give_kg',
                   to_char((v_exe->>'give_value')::numeric, 'FM999,999,999')),
      'en', format('%s kg given over +5%% (about %s THB)', v_exe->>'give_kg',
                   to_char((v_exe->>'give_value')::numeric, 'FM999,999,999')));
  end if;

  -- Purchase ratio up 3 points or more.
  if (v_pur->>'ratio')::numeric is not null and (v_pur->>'prev_ratio')::numeric is not null
     and (v_pur->>'ratio')::numeric - (v_pur->>'prev_ratio')::numeric >= 3 then
    v_pts := v_pts || jsonb_build_object('level', 'warn', 'key', 'ratio',
      'th', format('ต้นทุนซื้อ/มูลค่าขาย %s%% (สัปดาห์ก่อน %s%%)', v_pur->>'ratio', v_pur->>'prev_ratio'),
      'en', format('Purchase cost to value %s%% (last week %s%%)', v_pur->>'ratio', v_pur->>'prev_ratio'));
  end if;

  -- Good news: reactivated clients, new clients.
  if coalesce((v_team->'team'->>'reactivated')::int, 0) > 0 then
    v_pts := v_pts || jsonb_build_object('level', 'good', 'key', 'reactivated',
      'th', format('ลูกค้ากลับมาสั่งหลังหายไป 30 วันขึ้นไป %s ราย', v_team->'team'->>'reactivated'),
      'en', format('%s client%s ordered again after 30+ days', v_team->'team'->>'reactivated',
                   case when (v_team->'team'->>'reactivated')::int = 1 then '' else 's' end));
  end if;
  if coalesce((v_cli->>'new')::int, 0) > 0 then
    v_pts := v_pts || jsonb_build_object('level', 'good', 'key', 'new',
      'th', format('ลูกค้าใหม่ %s ราย', v_cli->>'new'),
      'en', format('%s new client%s', v_cli->>'new', case when (v_cli->>'new')::int = 1 then '' else 's' end));
  end if;

  select coalesce(jsonb_agg(x order by case x->>'level' when 'warn' then 0 when 'info' then 1 else 2 end, o), '[]'::jsonb)
    into v_pts
  from (select x, o from jsonb_array_elements(v_pts) with ordinality t(x, o)
        order by case x->>'level' when 'warn' then 0 when 'info' then 1 else 2 end, o limit 7) s;

  return jsonb_build_object(
    'version', 1,
    'week_start', v_ws, 'week_end', v_sat, 'iso_week', extract(week from v_ws)::int,
    'iso_year', extract(isoyear from v_ws)::int,
    'count_from', v_start, 'history', v_hist,
    'complete', v_we < v_today,
    'computed_at', now(),
    'top', v_top, 'mtd', v_mtd, 'sales', v_team, 'clients', v_cli,
    'execution', v_exe, 'purchasing', v_pur, 'points', v_pts);
end;
$$;

comment on function public.weekly_report_compute(date) is
  'Figures of one week (Monday to Saturday) for Management › Weekly report. Internal. Migration 051.';
revoke all on function public.weekly_report_compute(date) from public, anon, authenticated;
grant execute on function public.weekly_report_compute(date) to service_role;


-- ----------------------------------------------------------------------------
-- 5. Save a week; the automatic Monday run
-- ----------------------------------------------------------------------------
create or replace function public.weekly_report_save(p_week date, p_by uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_ws  date := date_trunc('week', p_week)::date;
  v_new boolean;
  v_d   jsonb;
begin
  v_d := public.weekly_report_compute(v_ws);
  v_new := not exists (select 1 from public.weekly_reports where week_start = v_ws);
  insert into public.weekly_reports (week_start, data, built_at, built_by)
  values (v_ws, v_d, now(), p_by)
  on conflict (week_start) do update set data = excluded.data, built_at = excluded.built_at, built_by = excluded.built_by;

  -- Bell (021) for each admin, the first time a week is saved.
  if v_new then
    insert into public.notifications (recipient, kind, title, body, details, work_date)
    select p.id, 'weekly_report',
           format('Weekly report ready — week %s', extract(week from v_ws)),
           format('%s – %s · Management › Weekly report', to_char(v_ws, 'DD Mon'), to_char(v_ws + 5, 'DD Mon YYYY')),
           jsonb_build_object('week_start', v_ws, 'view', 'weekly'), v_ws
    from public.profiles p where p.role = 'admin';
  end if;
  return v_d;
end;
$$;
revoke all on function public.weekly_report_save(date, uuid) from public, anon, authenticated;
grant execute on function public.weekly_report_save(date, uuid) to service_role;

-- pg_cron, Monday 06:00 Bangkok: last week's report.
create or replace function public.weekly_report_auto()
returns date
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_ws date := date_trunc('week', (now() at time zone 'Asia/Bangkok')::date)::date - 7;
begin
  perform public.weekly_report_save(v_ws, null);
  return v_ws;
end;
$$;
revoke all on function public.weekly_report_auto() from public, anon, authenticated;
grant execute on function public.weekly_report_auto() to service_role;


-- ----------------------------------------------------------------------------
-- 6. Admin: read, rebuild, comment
-- ----------------------------------------------------------------------------
-- p_week null = last complete week. A complete week without a saved report is
-- built now (the schedule may not have run). The week in progress is computed
-- live and not saved.
create or replace function public.weekly_report(p_week date default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_today date := (now() at time zone 'Asia/Bangkok')::date;
  v_cur   date := date_trunc('week', (now() at time zone 'Asia/Bangkok')::date)::date;
  v_ws    date;
  v_start date;
  v_row   public.weekly_reports;
  v_live  boolean := false;
  v_data  jsonb;
  v_sched text := 'none';
begin
  if coalesce(public.current_role(), '') <> 'admin' then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  select s.count_from into v_start from public.management_settings s where s.id = 1;
  v_ws := date_trunc('week', coalesce(p_week, v_cur - 7))::date;
  if v_ws > v_cur then
    raise exception 'that week has not started' using errcode = '22023';
  end if;
  if v_ws + 6 < coalesce(v_start, date '2026-11-02') then
    raise exception 'PACE counts from %', to_char(v_start, 'DD Mon YYYY') using errcode = '22023';
  end if;

  -- Is the Monday 06:00 job there? (cron.job exists only with pg_cron.)
  if to_regclass('cron.job') is not null then
    begin
      execute 'select case when exists (select 1 from cron.job where jobname = ''pace-weekly-report'' and active) then ''on'' else ''off'' end'
        into v_sched;
    exception when others then v_sched := 'unknown';
    end;
  end if;

  if v_ws = v_cur then
    v_live := true;
    v_data := public.weekly_report_compute(v_ws);
  else
    select * into v_row from public.weekly_reports where week_start = v_ws;
    if not found then
      perform public.weekly_report_save(v_ws, null);
      select * into v_row from public.weekly_reports where week_start = v_ws;
    end if;
    v_data := v_row.data;
  end if;

  return jsonb_build_object(
    'week_start', v_ws, 'live', v_live, 'data', v_data,
    'built_at', case when v_live then now() else v_row.built_at end,
    'built_by', (select full_name from public.profiles where id = v_row.built_by),
    'comment', v_row.comment,
    'comment_by', (select full_name from public.profiles where id = v_row.comment_by),
    'comment_at', v_row.comment_at,
    'current_week', v_cur, 'count_from', v_start,
    'weeks', coalesce((select jsonb_agg(jsonb_build_object('week_start', w::date,
                 'saved', exists (select 1 from public.weekly_reports r where r.week_start = w::date)) order by w desc)
               from generate_series(date_trunc('week', coalesce(v_start, date '2026-11-02'))::date, v_cur, interval '7 days') w), '[]'::jsonb),
    'schedule', v_sched);
end;
$$;

create or replace function public.weekly_report_rebuild(p_week date)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_cur date := date_trunc('week', (now() at time zone 'Asia/Bangkok')::date)::date;
  v_ws  date := date_trunc('week', p_week)::date;
begin
  if coalesce(public.current_role(), '') <> 'admin' then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if p_week is null or v_ws >= v_cur then
    raise exception 'only a finished week can be saved' using errcode = '22023';
  end if;
  perform public.weekly_report_save(v_ws, auth.uid());
  return public.weekly_report(v_ws);
end;
$$;

create or replace function public.weekly_report_comment(p_week date, p_comment text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_ws date := date_trunc('week', p_week)::date;
begin
  if coalesce(public.current_role(), '') <> 'admin' then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if length(coalesce(p_comment, '')) > 4000 then
    raise exception 'comment too long (4,000 characters at most)' using errcode = '22023';
  end if;
  update public.weekly_reports
     set comment = nullif(trim(p_comment), ''), comment_by = auth.uid(), comment_at = now()
   where week_start = v_ws;
  if not found then
    raise exception 'no saved report for that week' using errcode = '22023';
  end if;
  return jsonb_build_object('comment', nullif(trim(p_comment), ''),
                            'comment_by', (select full_name from public.profiles where id = auth.uid()),
                            'comment_at', now());
end;
$$;

comment on function public.weekly_report(date) is
  'Management › Weekly report: the saved week (built if missing) or the week in progress (live). Admin only. Migration 051.';
comment on function public.weekly_report_rebuild(date) is
  'Recomputes and saves a finished week (comment kept). Admin only. Migration 051.';
comment on function public.weekly_report_comment(date, text) is
  'Saves the comment of a saved week. Admin only. Migration 051.';

revoke all on function public.weekly_report(date), public.weekly_report_rebuild(date),
                       public.weekly_report_comment(date, text) from public, anon;
grant execute on function public.weekly_report(date), public.weekly_report_rebuild(date),
                          public.weekly_report_comment(date, text) to authenticated, service_role;


-- ----------------------------------------------------------------------------
-- 7. Weeks since PACE started counting, and the Monday 06:00 schedule
-- ----------------------------------------------------------------------------
-- Finished weeks without a report are built now (as automatic reports).
do $$
declare
  v_start date;
  w date;
begin
  select count_from into v_start from public.management_settings where id = 1;
  for w in select g::date from generate_series(date_trunc('week', coalesce(v_start, date '2026-11-02'))::date,
                                               date_trunc('week', (now() at time zone 'Asia/Bangkok')::date)::date - 7,
                                               interval '7 days') g loop
    if not exists (select 1 from public.weekly_reports where week_start = w) then
      perform public.weekly_report_save(w, null);
    end if;
  end loop;
end $$;

-- Monday 06:00 Bangkok = Sunday 23:00 UTC (pg_cron runs in UTC).
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'pace-weekly-report';
    perform cron.schedule('pace-weekly-report', '0 23 * * 0', 'select public.weekly_report_auto()');
    raise notice 'Weekly report scheduled: Monday 06:00 Bangkok.';
  else
    raise notice 'pg_cron is not enabled: enable it (Database › Extensions › pg_cron) and run this file again. '
                 'Until then the report is built when admin opens it.';
  end if;
end $$;

-- 2FA (050): the new table gets the "code required" policy.
select public.mfa_gate_tables();

-- What it did.
select (select count(*) from public.weekly_reports) as weekly_reports_saved,
       (select string_agg(to_char(week_start, 'DD Mon'), ', ' order by week_start) from public.weekly_reports) as weeks,
       case when exists (select 1 from pg_extension where extname = 'pg_cron')
            then 'Monday 06:00 (pg_cron)' else 'pg_cron not enabled — enable it and run again' end as schedule;
