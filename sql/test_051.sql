-- Migration 051 — Weekly report. Run on a replica with 001–051 and test data
-- (papers 2–27 Nov 2026, the Daily Sales Reporting of 17 Nov, purchases).
\set ON_ERROR_STOP 1
\pset tuples_only on
create or replace function pg_temp.as_user(u text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', case when u is null then '' else json_build_object('sub', u)::text end, false);
      perform set_config('request.jwt.claim.sub', coalesce(u, ''), false); end $$;
create or replace function pg_temp.ok(cond boolean, label text) returns void language plpgsql as $$
begin if coalesce(cond, false) then raise notice 'PASS %', label; else raise exception 'FAIL %', label; end if; end $$;
create or replace function pg_temp.denied(q text) returns boolean language plpgsql as $$
begin execute q; return false; exception when insufficient_privilege then return true; end $$;
create or replace function pg_temp.d() returns jsonb language sql as $$
  select data from public.weekly_reports where week_start = '2026-11-16' $$;

-- ---------------------------------------------------------------- saved on install
select pg_temp.ok((select count(*) from public.weekly_reports) = 3, 'Finished weeks since count_from saved on install (2, 9, 16 Nov)');
select pg_temp.ok(not exists (select 1 from public.weekly_reports where week_start = date_trunc('week', (now() at time zone 'Asia/Bangkok')::date)),
                  'Week in progress not saved');
select pg_temp.ok((select bool_and(built_by is null) from public.weekly_reports), 'Install reports are automatic (no author)');
select pg_temp.ok((select count(*) from public.notifications where kind = 'weekly_report') = 6, 'Bell: 3 weeks × 2 admins');
select pg_temp.ok(not exists (select 1 from public.notifications n join public.profiles p on p.id = n.recipient
                              where n.kind = 'weekly_report' and p.role <> 'admin'), 'Bell only for admins');

-- ---------------------------------------------------------------- arithmetic (week of 16 Nov)
select pg_temp.ok((pg_temp.d()->'top'->>'value')::numeric =
                  (select sum(rev) from public.purchase_ratio_days('2026-11-16', '2026-11-22', null)),
                  'Week value = purchase_ratio_days (047 rule)');
select pg_temp.ok((pg_temp.d()->'top'->>'value')::numeric =
                  (select sum((x->>'value')::numeric) from jsonb_array_elements(pg_temp.d()->'top'->'days') x),
                  'Days add up to the week');
select pg_temp.ok((pg_temp.d()->'top'->>'value')::numeric =
                  (pg_temp.d()->'top'->>'farm_value')::numeric + (pg_temp.d()->'top'->>'food_value')::numeric,
                  'Farm + Food = week');
select pg_temp.ok((pg_temp.d()->'top'->>'value')::numeric =
                  (select sum((x->>'value')::numeric) from jsonb_array_elements(pg_temp.d()->'sales'->'reps') x)
                  + (pg_temp.d()->'sales'->>'house_value')::numeric + (pg_temp.d()->'sales'->>'unlinked_value')::numeric,
                  'Salespeople + House + unlinked = week');
select pg_temp.ok((pg_temp.d()->'top'->>'prev_value')::numeric =
                  (select sum(rev) from public.purchase_ratio_days('2026-11-09', '2026-11-15', null)),
                  'Last week value');
select pg_temp.ok((pg_temp.d()->'top'->>'prev_value')::numeric =
                  (select (data->'top'->>'value')::numeric from public.weekly_reports where week_start = '2026-11-09'),
                  'Last week = the saved report of 9 Nov');
select pg_temp.ok((pg_temp.d()->'top'->>'budget')::numeric = round(6986954.04 / 25 * 6, 2), 'Budget pace: Nov budget ÷ 25 × 6 days');
select pg_temp.ok((pg_temp.d()->'top'->>'papers')::int =
                  (select count(*) from public.weighing_papers where status = 'confirmed' and work_date between '2026-11-16' and '2026-11-22'),
                  'Confirmed papers of the week');
select pg_temp.ok(jsonb_array_length(pg_temp.d()->'top'->'days') = 6, 'Six days Mon–Sat');
select pg_temp.ok(jsonb_array_length(pg_temp.d()->'top'->'trend') = 3, 'Trend starts at count_from (3 weeks)');
select pg_temp.ok((pg_temp.d()->'top'->'trend'->2->>'value')::numeric = (pg_temp.d()->'top'->>'value')::numeric, 'Trend ends on this week');
-- Month to date (Daily Sales Reporting, 13 days uploaded 17 Nov)
select pg_temp.ok((pg_temp.d()->'mtd'->>'actual')::numeric = 3426558.01, 'MTD actual = Farm + Food uploaded');
select pg_temp.ok((pg_temp.d()->'mtd'->>'budget_to_date')::numeric = round(6986954.04 * 13 / 25, 2), 'MTD budget for 13 of 25 days');
select pg_temp.ok((pg_temp.d()->'mtd'->>'projection')::numeric = round(3426558.01 / 13 * 25, 2), 'Projection = actual ÷ 13 × 25');
select pg_temp.ok((pg_temp.d()->'mtd'->>'as_of')::date = '2026-11-16', 'As of the 13th working day (16 Nov)');
-- Target pace: James Q4 3,285,887.42 × 6.0 / 21.8 (Farm Oct–Dec) ÷ 25 × 6
select pg_temp.ok(abs((select (x->>'target_week')::numeric from jsonb_array_elements(pg_temp.d()->'sales'->'reps') x where x->>'code' = '12')
                      - round(3285887.42 * 6000000 / 21800000 / 25 * 6, 2)) < 0.02, 'James weekly target pace');
select pg_temp.ok((select x->>'target_week' from jsonb_array_elements(pg_temp.d()->'sales'->'reps') x where x->>'code' = '02') is null,
                  'Christophe: no target');
select pg_temp.ok((select (x->>'calls')::int from jsonb_array_elements(pg_temp.d()->'sales'->'reps') x where x->>'code' = '12') =
                  (select count(*) from public.sales_calls k join public.sales_customers c on c.code = k.code
                   where c.salesperson_code = '12' and (k.called_at at time zone 'Asia/Bangkok')::date between '2026-11-16' and '2026-11-22'),
                  'James calls in the week (Sales KPIs 039 on the automatic run)');
-- Execution
select pg_temp.ok((pg_temp.d()->'execution'->>'postponed')::int =
                  (select count(*) from public.weighing_postponements where coalesce(from_delivery_date, from_work_date) between '2026-11-16' and '2026-11-22')
                  + (select count(*) from public.order_postponements where original_date between '2026-11-16' and '2026-11-22'),
                  'Postponements on the delivery date missed');
select pg_temp.ok((pg_temp.d()->'execution'->>'internal')::int + (pg_temp.d()->'execution'->>'client')::int
                  = (pg_temp.d()->'execution'->>'postponed')::int, 'Internal + client = postponed');
select pg_temp.ok((pg_temp.d()->'execution'->>'problems')::int = 2, 'Two delivery problems');
select pg_temp.ok((pg_temp.d()->'execution'->>'not_confirmed')::int = 1, 'One paper not confirmed (20 Nov)');
select pg_temp.ok((pg_temp.d()->'execution'->>'orders')::int =
                  (select count(*) from public.weighing_papers where status <> 'failed'
                   and coalesce(delivery_date, work_date) between '2026-11-16' and '2026-11-22'), 'Orders due in the week');
-- Purchasing: 3 arrivals × (520 kg × 83 + 1,500 freight)
select pg_temp.ok((pg_temp.d()->'purchasing'->>'cost')::numeric = 3 * (520 * 83 + 1500), 'Purchase cost of the week');
select pg_temp.ok((pg_temp.d()->'purchasing'->>'ratio')::numeric =
                  round(100 * 3 * (520 * 83 + 1500) / (pg_temp.d()->'top'->>'value')::numeric, 1), 'Purchase ratio');
-- Clients
select pg_temp.ok((pg_temp.d()->'clients'->>'ordering')::int =
                  (select count(distinct public.client_match_key(customer_name)) from public.weighing_papers
                   where status <> 'failed' and work_date between '2026-11-16' and '2026-11-22'), 'Clients ordering');
select pg_temp.ok(pg_temp.d()->'clients'->'new' = 'null'::jsonb, 'No "new clients" before 4 weeks of history');
-- Points
select pg_temp.ok(jsonb_array_length(pg_temp.d()->'points') between 1 and 7, 'Between 1 and 7 points');
select pg_temp.ok(pg_temp.d()->'points'->0->>'key' = 'not_confirmed', 'Unconfirmed papers come first');
select pg_temp.ok(exists (select 1 from jsonb_array_elements(pg_temp.d()->'points') x where x->>'key' = 'calls_13'),
                  'Chovie: no call logged');
select pg_temp.ok((select bool_and(x ? 'th' and x ? 'en') from jsonb_array_elements(pg_temp.d()->'points') x), 'Every point in Thai and English');
select pg_temp.ok((select bool_and(prev is null or prev <= lv) from (
    select case x->>'level' when 'warn' then 0 when 'info' then 1 else 2 end lv,
           lag(case x->>'level' when 'warn' then 0 when 'info' then 1 else 2 end) over (order by o) prev
    from jsonb_array_elements(pg_temp.d()->'points') with ordinality t(x, o)) s), 'Warnings, then information, then good news');

-- ---------------------------------------------------------------- the automatic run leaves no identity behind
select pg_temp.as_user(null);
select public.weekly_report_auto();
select pg_temp.ok(auth.uid() is null, 'After the automatic run nobody is signed in');
select pg_temp.ok((select count(*) from public.notifications where kind = 'weekly_report') = 6, 'Rebuilding a saved week does not ring again');

-- ---------------------------------------------------------------- admin
select pg_temp.as_user('00000000-0000-0000-0000-00000000000b');   -- Khun Jum
select pg_temp.ok((public.weekly_report()->>'week_start')::date = date_trunc('week', (now() at time zone 'Asia/Bangkok')::date)::date - 7,
                  'Default = last finished week');
select pg_temp.ok((public.weekly_report()->>'live')::boolean = false, 'A finished week is the saved one');
select pg_temp.ok((public.weekly_report(date_trunc('week', (now() at time zone 'Asia/Bangkok')::date)::date)->>'live')::boolean,
                  'Week in progress is live');
select pg_temp.ok(not exists (select 1 from public.weekly_reports where week_start = date_trunc('week', (now() at time zone 'Asia/Bangkok')::date)),
                  'Opening the week in progress saves nothing');
select pg_temp.ok(auth.uid() = '00000000-0000-0000-0000-00000000000b', 'Admin identity unchanged after a live week');
select pg_temp.ok((public.weekly_report('2026-11-18')->>'week_start')::date = '2026-11-16', 'Any day opens its week');
select pg_temp.ok(jsonb_array_length(public.weekly_report()->'weeks') = 4, 'Week list: 2, 9, 16, 23 Nov');
select pg_temp.ok(public.weekly_report()->>'schedule' = 'none', 'Schedule state reported (no pg_cron here)');
do $$ begin perform public.weekly_report('2027-01-04'); raise exception 'FAIL future week';
exception when invalid_parameter_value then raise notice 'PASS Future week refused'; end $$;
do $$ begin perform public.weekly_report('2026-10-19'); raise exception 'FAIL week before count_from';
exception when invalid_parameter_value then raise notice 'PASS Week before count_from refused'; end $$;
-- Rebuild keeps the comment and records who
select public.weekly_report_comment('2026-11-16', '  Chovie to restart calls; check raw material with the farm.  ');
select pg_temp.ok((select comment from public.weekly_reports where week_start = '2026-11-16') = 'Chovie to restart calls; check raw material with the farm.',
                  'Comment saved, trimmed');
select pg_temp.ok((select comment_by from public.weekly_reports where week_start = '2026-11-16') = '00000000-0000-0000-0000-00000000000b', 'Comment author');
update public.sales_actuals set amount = amount + 100000, days_counted = 18 where month = '2026-11-01' and company = 'Prosun Farm';
select pg_temp.ok((pg_temp.d()->'mtd'->>'days')::int = 13, 'Saved week does not move when figures change');
select public.weekly_report_rebuild('2026-11-16');
select pg_temp.ok((pg_temp.d()->'mtd'->>'days')::int = 18, 'Rebuild takes the newer upload');
select pg_temp.ok((select built_by from public.weekly_reports where week_start = '2026-11-16') = '00000000-0000-0000-0000-00000000000b', 'Rebuild records who');
select pg_temp.ok((select comment from public.weekly_reports where week_start = '2026-11-16') is not null, 'Rebuild keeps the comment');
select public.weekly_report_comment('2026-11-16', '');
select pg_temp.ok((select comment from public.weekly_reports where week_start = '2026-11-16') is null, 'Empty comment clears it');
do $$ begin perform public.weekly_report_rebuild(date_trunc('week', (now() at time zone 'Asia/Bangkok')::date)::date);
  raise exception 'FAIL rebuild current week';
exception when invalid_parameter_value then raise notice 'PASS Week in progress cannot be saved'; end $$;
do $$ begin perform public.weekly_report_comment('2026-11-16', repeat('x', 4001)); raise exception 'FAIL long comment';
exception when invalid_parameter_value then raise notice 'PASS Comment over 4,000 characters refused'; end $$;
-- A finished week without a report is built when opened (schedule missed)
reset role;
delete from public.weekly_reports where week_start = '2026-11-09';
select pg_temp.ok((public.weekly_report('2026-11-09')->'data'->'top'->>'value')::numeric > 0, 'Missing finished week built on opening');
select pg_temp.ok(exists (select 1 from public.weekly_reports where week_start = '2026-11-09' and built_by is null), 'Saved as automatic');

-- ---------------------------------------------------------------- everyone else
do $$
declare u text; r text;
begin
  for u, r in select p.id::text, p.role from public.profiles p where p.role <> 'admin' loop
    perform pg_temp.as_user(u);
    perform pg_temp.ok(pg_temp.denied('select public.weekly_report()'), r || ': weekly_report refused');
    perform pg_temp.ok(pg_temp.denied('select public.weekly_report_rebuild(''2026-11-16'')'), r || ': rebuild refused');
    perform pg_temp.ok(pg_temp.denied('select public.weekly_report_comment(''2026-11-16'', ''x'')'), r || ': comment refused');
  end loop;
end $$;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000c3');
set role authenticated;
select pg_temp.ok(pg_temp.denied('select * from public.weekly_reports'), 'Signed-in user cannot read the table');
select pg_temp.ok(pg_temp.denied('select public.weekly_report_compute(''2026-11-16'')'), 'Internal compute not callable');
select pg_temp.ok(pg_temp.denied('select public.weekly_report_save(''2026-11-16'', null)'), 'Internal save not callable');
select pg_temp.ok(pg_temp.denied('select public.weekly_report_auto()'), 'Automatic run not callable');
select pg_temp.ok(pg_temp.denied('select * from public.weekly_paper_values(''2026-11-16'', ''2026-11-22'')'), 'Paper values not callable');
reset role;
set role anon;
select pg_temp.ok(pg_temp.denied('select public.weekly_report()'), 'anon refused');
select pg_temp.ok(pg_temp.denied('select * from public.weekly_reports'), 'anon cannot read the table');
reset role;
select pg_temp.ok((select count(*) from pg_policy p join pg_class c on c.oid = p.polrelid
                   where c.relname = 'weekly_reports' and p.polname = 'mfa: code required') = 1, '2FA policy on the new table');
