-- Migration 039 — My day, alerts, call-backs, KPIs. Run after test_037.sql on the same replica.
\set ON_ERROR_STOP 1
\pset tuples_only on
create or replace function pg_temp.as_user(u text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', u)::text, false); end $$;
create or replace function pg_temp.ok(cond boolean, label text) returns void language plpgsql as $$
begin if coalesce(cond, false) then raise notice 'PASS %', label; else raise exception 'FAIL %', label; end if; end $$;
create or replace function pg_temp.denied(q text) returns boolean language plpgsql as $$
begin execute q; return false; exception when insufficient_privilege then return true; end $$;
create or replace function pg_temp.k(j jsonb, rep text, kpi text) returns jsonb language sql as $$
  select case when rep = 'team' then j->'team'->kpi
              else (select x->kpi from jsonb_array_elements(j->'reps') x where x->>'code' = rep) end $$;

delete from public.sales_calls; delete from public.sales_alert_seen;
delete from public.delivery_marks where paper_id = '37000000-0000-0000-0000-000000000003';
insert into public.delivery_marks (paper_id, delivery_date, status, note, marked_by, marked_at) values
 ('37000000-0000-0000-0000-000000000003', '2026-11-12', 'problem', 'Restaurant closed, back tomorrow',
  '00000000-0000-0000-0000-0000000000d1', now() - interval '1 day');
-- Two calls by James: one followed by an order within 7 days (AB-3 due 12 Nov), one not
insert into public.sales_calls (code, called_by, called_at, outcome) values
 ('CB005', '00000000-0000-0000-0000-000000000012', '2026-11-10 10:00+07', 'ordered'),
 ('CB001', '00000000-0000-0000-0000-000000000012', '2026-11-10 11:00+07', 'no_answer');

-- ---------------------------------------------------------------- My day
select pg_temp.as_user('00000000-0000-0000-0000-000000000012');
select pg_temp.ok(public.sales_my_day('13')->>'rep' = '12', 'James asking for Chovie''s day gets his own');
select pg_temp.ok(jsonb_array_length(public.sales_my_day()->'top_calls') <= 10, 'At most 10 calls');
select pg_temp.ok((select bool_and(x->>'salesperson' = '12') from jsonb_array_elements(public.sales_my_day()->'top_calls') x), 'Only his clients');
select pg_temp.ok((select bool_and(prev is null or prev >= p) from (
    select (x->>'priority')::numeric p, lag((x->>'priority')::numeric) over (order by ord) prev
    from jsonb_array_elements(public.sales_my_day()->'top_calls') with ordinality t(x, ord)
    where x->>'status' = 'call_now') s), 'Top calls ranked by money at stake');
select pg_temp.ok((public.sales_my_day()->'top_calls'->0->>'priority')::numeric > 0, 'Top call has a value');
-- Log a call-back on the top client: it leaves the top list and returns on its date
create temp table t_top as select public.sales_my_day()->'top_calls'->0->>'code' as code;
select public.sales_log_call((select code from t_top), 'call_back', 'Chef on holiday', (now() at time zone 'Asia/Bangkok')::date);
select pg_temp.ok(not exists (select 1 from jsonb_array_elements(public.sales_my_day()->'top_calls') x where x->>'code' = (select code from t_top)),
                  'Client just called leaves the top list');
select pg_temp.ok(exists (select 1 from jsonb_array_elements(public.sales_my_day()->'callbacks') x where x->>'code' = (select code from t_top)),
                  'Call-back due today shows');
select public.sales_log_call((select code from t_top), 'call_back', null, (now() at time zone 'Asia/Bangkok')::date + 5);
select pg_temp.ok(not exists (select 1 from jsonb_array_elements(public.sales_my_day()->'callbacks') x where x->>'code' = (select code from t_top)),
                  'Call-back moved to later: not due today');
do $$ begin perform public.sales_log_call('CB005', 'call_back', null, '2020-01-01'); raise exception 'FAIL past call-back';
exception when invalid_parameter_value then raise notice 'PASS Call-back in the past refused'; end $$;
select public.sales_log_call('CB001', 'call_back');
select pg_temp.ok((select callback_on from public.sales_calls where code = 'CB001' order by called_at desc limit 1)
                  = (now() at time zone 'Asia/Bangkok')::date + 2, 'Call back without a date: in 2 days');
select pg_temp.ok(jsonb_typeof(public.sales_my_day()->'kpis'->'reps'->0->'active30') = 'object', 'My day carries my KPIs');

-- ---------------------------------------------------------------- Alerts
select pg_temp.ok((public.sales_alerts()->>'unseen')::int = 1, 'James: 1 new alert (delivery problem)');
select pg_temp.ok((public.sales_alerts()->'events'->0->>'note') = 'Restaurant closed, back tomorrow', 'Delivery team''s note shown');
select public.sales_alerts_seen();
select pg_temp.ok((public.sales_alerts()->>'unseen')::int = 0, 'Seen: badge back to 0');
select pg_temp.as_user('00000000-0000-0000-0000-000000000013');
select pg_temp.ok((select count(*) from jsonb_array_elements(public.sales_alerts()->'events') e where e->>'kind' = 'postponed') >= 1,
                  'Chovie: Park Hyatt postponed');
select pg_temp.ok((select bool_and(not (e ? 'reason')) from jsonb_array_elements(public.sales_alerts()->'events') e), 'No postponement reason');
select pg_temp.ok(not exists (select 1 from jsonb_array_elements(public.sales_alerts()->'events') e where e->>'code' = 'CB005'),
                  'Chovie does not get James''s alerts');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d1');
select pg_temp.ok(pg_temp.denied($$select public.sales_alerts()$$), 'Delivery: no sales alerts');

-- ---------------------------------------------------------------- KPIs, salesperson
select pg_temp.as_user('00000000-0000-0000-0000-000000000012');
create temp table t_k as select public.sales_kpis('2026-10-21', '2026-11-19') as j;
select pg_temp.ok(jsonb_array_length((select j from t_k)->'reps') = 1 and (select j from t_k)->'reps'->0->>'code' = '12', 'James: his own KPIs');
select pg_temp.ok((select j from t_k)->'team' is not null, 'James: team average');
select pg_temp.ok((select j from t_k)->'at_stake' = 'null'::jsonb and (select j from t_k)->'house_to_assign' = 'null'::jsonb, 'James: no team lists');
-- by hand: active 30 days
select pg_temp.ok((pg_temp.k((select j from t_k), '12', 'active30')->>'n')::numeric =
  (select count(*) from jsonb_array_elements(public.sales_clients()->'clients') x
    where ((x->>'total12')::numeric > 0 or (x->>'days_missing')::int <= 180) and (x->>'days_missing')::int <= 30), 'Active 30 d counted right');
select pg_temp.ok((pg_temp.k((select j from t_k), '12', 'base')::int) =
  (select count(*) from jsonb_array_elements(public.sales_clients()->'clients') x
    where (x->>'total12')::numeric > 0 or (x->>'days_missing')::int <= 180), 'Base counted right');
-- target: Jan–Sep 2026 = Q1 + Q2 + Q3 of the agreement
select pg_temp.ok(abs((pg_temp.k((select j from t_k), '12', 'target_ytd')->>'d')::numeric - (3772476.58 + 3449237.86 + 3477932.92)) < 1,
                  'Target YTD = Q1+Q2+Q3 (10,699,647)');
select pg_temp.ok(abs((pg_temp.k((select j from t_k), '12', 'target_ytd')->>'n')::numeric -
  (select sum(m.amount) from sales_monthly m join sales_customers c using (code)
    where c.salesperson_code = '12' and c.portfolio = 'rep' and m.month between '2026-01-01' and '2026-09-01')) < 1,
  'Actual YTD = report Jan–Sep for his clients');
select pg_temp.ok((pg_temp.k((select j from t_k), '12', 'call_to_order')->>'n')::numeric = 1, 'Call → order: 1 call followed by an order');
select pg_temp.ok((pg_temp.k((select j from t_k), '12', 'problem')->>'pct')::numeric = 20, 'Delivery problem 1 of 5 orders = 20 % (4 Accidental Butcher + Unknown Bistro linked to CB001)');
select pg_temp.ok((pg_temp.k((select j from t_k), '12', 'weight_ok')->>'pct')::numeric = 100, 'Weight within ±5 %: 100 %');
select pg_temp.ok((pg_temp.k((select j from t_k), '12', 'reactivated'))::int >= 1, 'Accidental Butcher reactivated (Sept → Nov)');
select pg_temp.as_user('00000000-0000-0000-0000-000000000013');
select pg_temp.ok(abs((pg_temp.k(public.sales_kpis('2026-10-21', '2026-11-19'), '13', 'postponed')->>'pct')::numeric - 33.3) < 0.1,
                  'Chovie postponed: 1 of 3 orders = 33.3 %');

-- ---------------------------------------------------------------- KPIs, management
select pg_temp.as_user('00000000-0000-0000-0000-000000000002');
select pg_temp.ok(jsonb_array_length(public.sales_kpis('2026-10-21', '2026-11-19')->'reps') = 1, 'Sales director: his own + team (management page is admin only)');
select pg_temp.ok((pg_temp.k(public.sales_kpis('2026-10-21', '2026-11-19'), '02', 'target_ytd')->>'pct') is null, 'Christophe: no target, no %');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a2');
create temp table t_a as select public.sales_kpis('2026-10-21', '2026-11-19') as j;
select pg_temp.ok(jsonb_array_length((select j from t_a)->'reps') = 4, 'Khun Kirana: the 4 salespeople');
select pg_temp.ok((select j from t_a)->'team'->>'clients' = (select count(*)::text from sales_customers where portfolio = 'rep'), 'Team = every portfolio');
select pg_temp.ok(jsonb_array_length((select j from t_a)->'at_stake') between 1 and 15, 'Biggest clients at stake (≤15)');
select pg_temp.ok(jsonb_typeof((select j from t_a)->'house_to_assign') = 'array', 'House clients to assign');
select pg_temp.ok((select sum((x->>'calls')::int) from jsonb_array_elements((select j from t_a)->'reps') x) = ((select j from t_a)->'team'->>'calls')::int,
                  'Team calls = sum of the salespeople');
select pg_temp.ok(abs(((select j from t_a)->'team'->'target_ytd'->>'d')::numeric -
  (select sum(amount) from sales_targets where quarter between '2026-01-01' and '2026-07-01')) < 1, 'Team target = sum of the three agreements');
do $$ begin perform public.sales_kpis('2026-11-19', '2026-01-01'); raise exception 'FAIL bad period';
exception when invalid_parameter_value then raise notice 'PASS Period end before start refused'; end $$;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b1');
select pg_temp.ok(pg_temp.denied($$select public.sales_kpis('2026-10-21', '2026-11-19')$$), 'Sale support: no sales KPIs');
set role authenticated;
select pg_temp.ok(pg_temp.denied($$select public.sales_clients_core(true)$$), 'Internal function closed to users');
reset role;
