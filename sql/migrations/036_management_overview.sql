-- ============================================================================
-- Migration 036 — Management › Overview: top line vs budget, sales team,
-- clients, execution
-- ============================================================================
-- Written 17 Nov 2026. Clément, after the supervisory board meeting of
-- 14 Nov: the focus is now the top line — sales, sale support, stopping
-- postponed orders — and he needs a clear view. Mockup approved 17 Nov.
--
-- Sources
--   Budget: "PSFarm x PSFood Daily Sales reporting - 2026.xlsx", Summary
--     sheet, CONSERVATIVE budget (Clément's choice) and working days.
--   Actual sales: the same workbook, uploaded by admin on the Overview page
--     (the page reads the Summary sheet in the browser and saves one row per
--     company and month here). PACE does not compute them.
--   Salesperson targets: the signed 2026 agreements (Chovie code 13, James
--     code 12, Pammy code 14): quarterly revenue, active customers on 1 Jan
--     and 31 Dec, new customers in the year. A quarter is split into months in
--     proportion to the Prosun Farm budget of its months (Clément, 17 Nov).
--   Clients, orders, postponements, weights, invoices: PACE's own tables,
--     from management_settings.count_from (Migration 024).
--
-- Clients on working papers are linked to the CRM (and so to a salesperson)
-- by name, ignoring case, spaces and punctuation. The page shows how many
-- were linked.
--
-- Revenue per salesperson is not here: the Daily Sales Reporting has no split
-- by salesperson. It needs Odoo sales by customer (next step).
--
-- Access: admin only (Clément, Khun Jum). Tables have no policies; reached
-- through the functions below.
--
-- Run order: after 035. Safe to re-run (budget and targets are reloaded;
-- uploaded sales figures are kept).
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Budget
-- ----------------------------------------------------------------------------
create table if not exists public.sales_budget (
  month         date not null check (extract(day from month) = 1),
  company       text not null check (company in ('Prosun Farm', 'Prosun Food')),
  scenario      text not null default 'conservative' check (scenario in ('conservative', 'neutral', 'high')),
  amount        numeric not null check (amount >= 0),
  working_days  int not null check (working_days between 1 and 31),
  primary key (month, company, scenario)
);

comment on table public.sales_budget is
  'Monthly sales budget per company (Daily Sales Reporting 2026, Summary sheet). Migration 036.';

alter table public.sales_budget enable row level security;
revoke all on public.sales_budget from anon, authenticated;
grant all on public.sales_budget to service_role;

delete from public.sales_budget where scenario = 'conservative' and extract(year from month) = 2026;
insert into public.sales_budget (month, company, scenario, amount, working_days) values
  ('2026-01-01', 'Prosun Farm', 'conservative', 6000000, 27), ('2026-01-01', 'Prosun Food', 'conservative', 588894.21, 27),
  ('2026-02-01', 'Prosun Farm', 'conservative', 5800000, 24), ('2026-02-01', 'Prosun Food', 'conservative', 684397.99, 24),
  ('2026-03-01', 'Prosun Farm', 'conservative', 5750000, 26), ('2026-03-01', 'Prosun Food', 'conservative', 828394.30, 26),
  ('2026-04-01', 'Prosun Farm', 'conservative', 5750000, 23), ('2026-04-01', 'Prosun Food', 'conservative', 753352.76, 23),
  ('2026-05-01', 'Prosun Farm', 'conservative', 6000000, 26), ('2026-05-01', 'Prosun Food', 'conservative', 640392.87, 26),
  ('2026-06-01', 'Prosun Farm', 'conservative', 5800000, 26), ('2026-06-01', 'Prosun Food', 'conservative', 540731.22, 26),
  ('2026-07-01', 'Prosun Farm', 'conservative', 6600000, 27), ('2026-07-01', 'Prosun Food', 'conservative', 809491.48, 27),
  ('2026-08-01', 'Prosun Farm', 'conservative', 7000000, 26), ('2026-08-01', 'Prosun Food', 'conservative', 986954.04, 26),
  ('2026-09-01', 'Prosun Farm', 'conservative', 6800000, 26), ('2026-09-01', 'Prosun Food', 'conservative', 986954.04, 26),
  ('2026-10-01', 'Prosun Farm', 'conservative', 6800000, 27), ('2026-10-01', 'Prosun Food', 'conservative', 986954.04, 27),
  ('2026-11-01', 'Prosun Farm', 'conservative', 6000000, 25), ('2026-11-01', 'Prosun Food', 'conservative', 986954.04, 25),
  ('2026-12-01', 'Prosun Farm', 'conservative', 9000000, 27), ('2026-12-01', 'Prosun Food', 'conservative', 1043328.35, 27);


-- ----------------------------------------------------------------------------
-- 2. Actual sales (uploaded from the Daily Sales Reporting)
-- ----------------------------------------------------------------------------
create table if not exists public.sales_actuals (
  month         date not null check (extract(day from month) = 1),
  company       text not null check (company in ('Prosun Farm', 'Prosun Food')),
  amount        numeric not null check (amount >= 0),
  days_counted  int not null check (days_counted between 0 and 31),
  source        text,
  uploaded_by   uuid references public.profiles(id),
  uploaded_at   timestamptz not null default now(),
  primary key (month, company)
);

-- activity_log identifies a row by its id.
alter table public.sales_actuals add column if not exists id uuid not null default gen_random_uuid();

comment on table public.sales_actuals is
  'Actual sales per company and month as in the Daily Sales Reporting (Summary sheet), '
  'saved by admin from the Overview page. days_counted = working days included. Migration 036.';

alter table public.sales_actuals enable row level security;
revoke all on public.sales_actuals from anon, authenticated;
grant all on public.sales_actuals to service_role;

drop trigger if exists sales_actuals_log_activity on public.sales_actuals;
create trigger sales_actuals_log_activity
  after insert or update or delete on public.sales_actuals
  for each row execute function public.log_weighing_activity();


-- ----------------------------------------------------------------------------
-- 3. Salespeople and their 2026 targets
-- ----------------------------------------------------------------------------
create table if not exists public.sales_people (
  code          text primary key,
  short_name    text not null,
  full_name     text not null,
  login_hint    text not null,                 -- matches the CRM login (email before @, or name)
  profile_id    uuid references public.profiles(id),
  year          int not null,
  revenue_2025  numeric,
  active_start  int,                           -- active customers on 1 Jan
  active_end    int,                           -- target on 31 Dec
  new_target    int,                           -- new customers in the year
  new_note      text
);

create table if not exists public.sales_targets (
  code     text not null references public.sales_people(code) on delete cascade,
  quarter  date not null check (extract(day from quarter) = 1 and extract(month from quarter) in (1, 4, 7, 10)),
  amount   numeric not null check (amount >= 0),
  primary key (code, quarter)
);

comment on table public.sales_people is 'Salespeople with a signed 2026 target agreement. Migration 036.';
comment on table public.sales_targets is 'Quarterly revenue targets from the 2026 agreements. Migration 036.';

alter table public.sales_people enable row level security;
alter table public.sales_targets enable row level security;
revoke all on public.sales_people, public.sales_targets from anon, authenticated;
grant all on public.sales_people, public.sales_targets to service_role;

insert into public.sales_people (code, short_name, full_name, login_hint, year, revenue_2025, active_start, active_end, new_target, new_note) values
  ('13', 'Chovie', 'Chotika Suksomboon',          'chovie', 2026, 18060000, 112, 160, 48, '+36 Bangkok / +12 Pattaya'),
  ('12', 'James',  'Thananat Popeung',            'james',  2026, 12160000, 105, 153, 48, '+48 Bangkok'),
  ('14', 'Pammy',  'Thanidaphan Jirajarasthana',  'pammy',  2026, 14000000, 101, 149, 48, '+36 Islands / +12 Bangkok')
on conflict (code) do update set
  short_name = excluded.short_name, full_name = excluded.full_name, login_hint = excluded.login_hint,
  year = excluded.year, revenue_2025 = excluded.revenue_2025, active_start = excluded.active_start,
  active_end = excluded.active_end, new_target = excluded.new_target, new_note = excluded.new_note;

delete from public.sales_targets where extract(year from quarter) = 2026;
insert into public.sales_targets (code, quarter, amount) values
  ('13', '2026-01-01', 5711962.00), ('13', '2026-04-01', 5000772.79), ('13', '2026-07-01', 5023271.67), ('13', '2026-10-01', 5035935.20),
  ('12', '2026-01-01', 3772476.58), ('12', '2026-04-01', 3449237.86), ('12', '2026-07-01', 3477932.92), ('12', '2026-10-01', 3285887.42),
  ('14', '2026-01-01', 4736092.19), ('14', '2026-04-01', 3944057.57), ('14', '2026-07-01', 3513312.71), ('14', '2026-10-01', 3908273.23);

-- Link each salesperson to their CRM login: the email before @, else the name.
update public.sales_people sp
   set profile_id = coalesce(
     (select u.id from auth.users u join public.profiles p on p.id = u.id
       where lower(split_part(u.email, '@', 1)) = sp.login_hint limit 1),
     (select p.id from public.profiles p
       where lower(p.full_name) like sp.login_hint || '%' or lower(p.full_name) like '%' || lower(split_part(sp.full_name, ' ', 1)) || '%'
       order by (p.role = 'sales') desc limit 1))
 where sp.profile_id is null;


-- ----------------------------------------------------------------------------
-- 4. Helpers
-- ----------------------------------------------------------------------------
-- A client name reduced for matching: lower case, no spaces or punctuation.
create or replace function public.client_match_key(p text)
returns text
language sql
immutable
as $$
  select nullif(regexp_replace(lower(coalesce(p, '')), '[[:space:][:punct:]]+', '', 'g'), '');
$$;

-- The n-th working day (Monday to Saturday) of a month.
create or replace function public.nth_working_day(p_month date, p_n int)
returns date
language sql
immutable
as $$
  select d::date
  from generate_series(p_month, (p_month + interval '1 month' - interval '1 day'), interval '1 day') d
  where extract(isodow from d) < 7
  order by d
  offset greatest(p_n, 1) - 1 limit 1;
$$;


-- ----------------------------------------------------------------------------
-- 5. Save uploaded sales figures
-- ----------------------------------------------------------------------------
-- p_rows: [{"month":"2026-11-01","company":"Prosun Farm","amount":2934607.95,"days":13}, …]
create or replace function public.management_save_sales(p_rows jsonb, p_source text default null)
returns int
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  r jsonb;
  n int := 0;
begin
  if coalesce(public.current_role(), '') <> 'admin' then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 or jsonb_array_length(p_rows) > 48 then
    raise exception 'no sales figures to save' using errcode = '22023';
  end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    insert into public.sales_actuals (month, company, amount, days_counted, source, uploaded_by, uploaded_at)
    values (date_trunc('month', (r->>'month')::date)::date, r->>'company', (r->>'amount')::numeric,
            (r->>'days')::int, left(p_source, 200), auth.uid(), now())
    on conflict (month, company) do update
      set amount = excluded.amount, days_counted = excluded.days_counted, source = excluded.source,
          uploaded_by = excluded.uploaded_by, uploaded_at = excluded.uploaded_at;
    n := n + 1;
  end loop;
  return n;
end;
$$;

comment on function public.management_save_sales(jsonb, text) is
  'Saves the actual sales read from the Daily Sales Reporting. Admin only. Migration 036.';


-- ----------------------------------------------------------------------------
-- 6. The Overview's numbers
-- ----------------------------------------------------------------------------
create or replace function public.management_overview(p_month date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_today  date := (now() at time zone 'Asia/Bangkok')::date;
  v_month  date := date_trunc('month', coalesce(p_month, (now() at time zone 'Asia/Bangkok')::date))::date;
  v_prev   date;
  v_end    date;
  v_upto   date;                 -- last day counted in this month (today at the latest)
  v_start  date;
  v_year   date;
  v_days   int;                  -- working days in the uploaded figures (this month)
  v_wd     int;                  -- working days in the month (budget)
  v_asof   date;
  v_compare boolean;             -- PACE has the whole previous month
  v_quotes jsonb := '{}'::jsonb;
  v_out    jsonb;
begin
  if coalesce(public.current_role(), '') <> 'admin' then
    raise exception 'not allowed' using errcode = '42501';
  end if;

  v_prev  := (v_month - interval '1 month')::date;
  v_end   := (v_month + interval '1 month' - interval '1 day')::date;
  v_upto  := least(v_end, v_today);
  v_year  := date_trunc('year', v_month)::date;
  select s.count_from into v_start from public.management_settings s where s.id = 1;
  v_compare := v_start <= v_prev;

  select max(working_days) into v_wd from public.sales_budget where month = v_month and scenario = 'conservative';
  select max(days_counted) into v_days from public.sales_actuals where month = v_month;
  v_asof := case when coalesce(v_days, 0) > 0 then public.nth_working_day(v_month, v_days) end;

  -- Quotations per CRM user this month (the CRM table is not part of these migrations).
  if to_regclass('public.quotations') is not null then
    begin
      execute 'select coalesce(jsonb_object_agg(created_by, n), ''{}''::jsonb) from (
                 select created_by::text as created_by, count(*) as n from public.quotations
                 where created_at >= $1 and created_at < $2 group by created_by) q'
        into v_quotes using v_month, (v_end + 1);
    exception when others then v_quotes := '{}'::jsonb;
    end;
  end if;

  with
  -- ---- money ----------------------------------------------------------------
  budget as (
    select month, company, amount, working_days from public.sales_budget
    where scenario = 'conservative' and month >= v_year and month < (v_year + interval '1 year')
  ),
  actual as (
    select month, company, amount, days_counted, uploaded_at, uploaded_by, source from public.sales_actuals
    where month >= v_year and month < (v_year + interval '1 year')
  ),
  company_month as (
    select c.company,
           b.amount as budget, b.working_days as wd,
           a.amount as actual, a.days_counted as days,
           pa.amount as prev_actual, pa.days_counted as prev_days
    from (values ('Prosun Farm'), ('Prosun Food')) c(company)
    left join budget b on b.company = c.company and b.month = v_month
    left join actual a on a.company = c.company and a.month = v_month
    left join public.sales_actuals pa on pa.company = c.company and pa.month = v_prev
  ),
  ytd as (
    select coalesce(sum(a.amount) filter (where a.month < v_month), 0)
             + coalesce((select sum(actual) from company_month), 0) as actual,
           coalesce(sum(b.amount) filter (where b.month < v_month), 0)
             + coalesce((select sum(budget * least(coalesce(days, 0), wd)::numeric / nullif(wd, 0)) from company_month), 0) as budget
    from budget b
    left join actual a on a.month = b.month and a.company = b.company
  ),
  -- ---- papers and clients --------------------------------------------------------
  papers as (
    select p.id, p.work_date, coalesce(p.delivery_date, p.work_date) as day, p.status, p.company,
           p.customer_name, public.client_match_key(p.customer_name) as ck, p.confirmed_at
    from public.weighing_papers p
    where p.work_date >= v_start and p.work_date <= v_today
  ),
  crm as (
    select distinct on (public.client_match_key(c.name))
           public.client_match_key(c.name) as ck, c.id, c.name, c.assigned_to
    from public.clients c
    where public.client_match_key(c.name) is not null
    order by public.client_match_key(c.name), (c.assigned_to is not null) desc, c.created_at
  ),
  month_clients as (
    select ck, min(customer_name) as name, count(*) as papers
    from papers where work_date between v_month and v_upto and ck is not null group by ck
  ),
  prev_clients as (
    select distinct ck from papers where work_date between v_prev and (v_month - 1) and ck is not null
  ),
  before_clients as (
    select distinct ck from papers where work_date < v_month and ck is not null
  ),
  last_seen as (
    select ck, min(customer_name) as name, max(work_date) as last_day,
           count(*) filter (where work_date > v_today - 60) as papers_60
    from papers where ck is not null group by ck
  ),
  silent as (
    select l.*, v_today - l.last_day as days_silent, crm.assigned_to
    from last_seen l left join crm using (ck)
    where l.last_day <= v_today - 14 and l.last_day > v_today - 90
  ),
  -- ---- execution ----------------------------------------------------------------
  postp as (
    select coalesce(w.from_delivery_date, w.from_work_date) as day, w.reason
    from public.weighing_postponements w
    union all
    select r.original_date, r.reason from public.order_postponements r
  ),
  postp_month as (
    select * from postp where day between v_month and v_upto and day >= v_start
  ),
  give as (
    select coalesce(sum(l.actual_kg - case when l.ordered_unit = 'g' then l.ordered_qty / 1000 else l.ordered_qty end), 0) as kg,
           coalesce(sum((l.actual_kg - case when l.ordered_unit = 'g' then l.ordered_qty / 1000 else l.ordered_qty end)
                         * coalesce(pl.price_bkk, 0)) filter (where pl.unit = 'kg'), 0) as value
    from papers p
    join public.weighing_lines l on l.paper_id = p.id
    left join public.price_list pl on pl.id = public.price_list_match(l.description, null)
    where p.status = 'confirmed' and p.work_date between v_month and v_upto
      and l.ordered_unit in ('kg', 'g') and l.ordered_qty > 0 and l.actual_kg is not null
      and l.actual_kg > (case when l.ordered_unit = 'g' then l.ordered_qty / 1000 else l.ordered_qty end) * 1.05
  ),
  inv as (
    select count(*) filter (where i.paper_id is not null) as invoiced,
           count(*) filter (where i.paper_id is null) as waiting,
           round((percentile_cont(0.5) within group (order by extract(epoch from i.invoiced_at - p.confirmed_at))
                  filter (where i.paper_id is not null))::numeric / 86400, 1) as median_days
    from papers p left join public.weighing_invoices i on i.paper_id = p.id
    where p.status = 'confirmed' and p.work_date between v_month and v_upto
  ),
  -- ---- sales team -----------------------------------------------------------------
  q_month as (
    -- each month of the target's quarter, weighted by the Prosun Farm budget
    select t.code, b.month, t.amount * b.amount / sum(b.amount) over (partition by t.code, t.quarter) as target
    from public.sales_targets t
    join budget b on b.company = 'Prosun Farm' and b.month >= t.quarter and b.month < (t.quarter + interval '3 months')
  ),
  team as (
    select sp.code, sp.short_name, sp.full_name, sp.profile_id, sp.active_start, sp.active_end, sp.new_target, sp.new_note,
           (select round(target) from q_month q where q.code = sp.code and q.month = v_month) as month_target,
           (select round(sum(target)) from q_month q where q.code = sp.code and q.month < v_month) as ytd_target_before,
           (select count(*) from public.clients c where c.assigned_to = sp.profile_id) as crm_clients,
           (select count(*) from month_clients m join crm using (ck) where crm.assigned_to = sp.profile_id) as ordering,
           (select count(*) from silent s where s.assigned_to = sp.profile_id) as silent,
           (v_quotes ->> sp.profile_id::text)::int as quotes
    from public.sales_people sp
    where sp.year = extract(year from v_month)
  )
  select jsonb_build_object(
    'today', v_today, 'month', v_month, 'month_end', v_end, 'count_from', v_start, 'comparable', v_compare,
    'working_days', v_wd, 'days_counted', v_days, 'as_of', v_asof,
    'uploaded', (select jsonb_build_object('at', max(uploaded_at),
                    'by', (select full_name from public.profiles where id = (select uploaded_by from public.sales_actuals where month = v_month order by uploaded_at desc limit 1)),
                    'source', (select source from public.sales_actuals where month = v_month order by uploaded_at desc limit 1))
                 from public.sales_actuals where month = v_month),
    'companies', (select jsonb_agg(to_jsonb(cm) order by cm.company) from company_month cm),
    'ytd', (select to_jsonb(ytd) from ytd),
    'year', coalesce((select jsonb_agg(jsonb_build_object('month', m.month,
                 'budget', (select sum(amount) from budget b where b.month = m.month),
                 'actual', (select sum(amount) from actual a where a.month = m.month),
                 'days', (select max(days_counted) from actual a where a.month = m.month),
                 'wd', (select max(working_days) from budget b where b.month = m.month)) order by m.month)
               from (select distinct month from budget) m), '[]'::jsonb),
    'papers', jsonb_build_object(
        'month', (select count(*) from papers where work_date between v_month and v_upto),
        'to_asof', (select count(*) from papers where v_asof is not null and work_date between v_month and v_asof)),
    'clients', jsonb_build_object(
        'active', (select count(*) from month_clients),
        'prev_active', case when v_compare then (select count(*) from prev_clients) end,
        'new', case when v_compare then (select count(*) from month_clients m where m.ck not in (select ck from before_clients)) end,
        'lost', case when v_compare then (select count(*) from prev_clients p where p.ck not in (select ck from month_clients)) end,
        'linked', (select count(*) from month_clients m join crm using (ck)),
        'linked_assigned', (select count(*) from month_clients m join crm using (ck) where crm.assigned_to is not null),
        'silent', (select count(*) from silent),
        'silent_list', coalesce((select jsonb_agg(x order by x.papers_60 desc, x.days_silent desc) from (
            select s.name, s.last_day, s.days_silent, s.papers_60,
                   (select coalesce(sp.short_name, pr.full_name) from public.profiles pr
                      left join public.sales_people sp on sp.profile_id = pr.id where pr.id = s.assigned_to) as salesperson
            from silent s order by s.papers_60 desc, s.days_silent desc limit 12) x), '[]'::jsonb)),
    'execution', jsonb_build_object(
        'orders', (select count(*) from papers where day between v_month and v_upto),
        'postponed', (select count(*) from postp_month),
        'internal', (select count(*) from postp_month where reason <> 'client'),
        'production', (select count(*) from postp_month where reason = 'production'),
        'client', (select count(*) from postp_month where reason = 'client'),
        'reasons', coalesce((select jsonb_agg(x order by x.n desc) from (
            select reason, count(*) as n from postp_month group by reason) x), '[]'::jsonb),
        'give_kg', (select round(kg, 1) from give),
        'give_value', (select round(value) from give),
        'invoiced', (select invoiced from inv),
        'not_invoiced', (select waiting from inv),
        'invoice_days', (select median_days from inv)),
    'team', coalesce((select jsonb_agg(to_jsonb(t) order by t.code) from team t), '[]'::jsonb),
    'unassigned_ordering', (select count(*) from month_clients m left join crm using (ck)
                            where crm.assigned_to is null
                               or crm.assigned_to not in (select profile_id from public.sales_people where profile_id is not null))
  ) into v_out;

  return v_out;
end;
$$;

comment on function public.management_overview(date) is
  'Management › Overview: sales vs conservative budget, sales team targets, clients, execution. Admin only; read-only. Migration 036.';

revoke all on function public.management_overview(date)              from public, anon;
revoke all on function public.management_save_sales(jsonb, text)     from public, anon;
grant execute on function public.management_overview(date)           to authenticated, service_role;
grant execute on function public.management_save_sales(jsonb, text)  to authenticated, service_role;
