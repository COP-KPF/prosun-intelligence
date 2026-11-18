-- Migration 037 — PACE › Sales. Run on a replica after 037 and the report
-- import (038), with psql -f. Dates assume today is 18 Nov 2026 (Bangkok).
\set ON_ERROR_STOP 1
\pset tuples_only on
insert into auth.users (id, email) values
 ('00000000-0000-0000-0000-0000000000a1','clement@klongphaifarm.com'),
 ('00000000-0000-0000-0000-0000000000a2','kirana@klongphaifarm.com'),
 ('00000000-0000-0000-0000-000000000012','james@klongphaifarm.com'),
 ('00000000-0000-0000-0000-000000000013','chovie@klongphaifarm.com'),
 ('00000000-0000-0000-0000-000000000002','christophe@klongphaifarm.com'),
 ('00000000-0000-0000-0000-0000000000d1','nick@klongphaifarm.com'),
 ('00000000-0000-0000-0000-0000000000b1','jane@klongphaifarm.com'),
 ('00000000-0000-0000-0000-0000000000e1', 'someone@klongphaifarm.com')
on conflict do nothing;
insert into public.profiles (id, full_name, role) values
 ('00000000-0000-0000-0000-0000000000a1','Clément','admin'),
 ('00000000-0000-0000-0000-0000000000a2','Khun Jum','admin'),
 ('00000000-0000-0000-0000-000000000012','James','sales'),
 ('00000000-0000-0000-0000-000000000013','Chovie','sales'),
 ('00000000-0000-0000-0000-000000000002','Christophe','director'),
 ('00000000-0000-0000-0000-0000000000d1','Nick','delivery'),
 ('00000000-0000-0000-0000-0000000000b1','Jane','sale_support')
on conflict (id) do update set role = excluded.role, full_name = excluded.full_name;

create or replace function pg_temp.as_user(u text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', u)::text, false); end $$;
create or replace function pg_temp.ok(cond boolean, label text) returns void language plpgsql as $$
begin if coalesce(cond, false) then raise notice 'PASS %', label; else raise exception 'FAIL %', label; end if; end $$;
create or replace function pg_temp.c(t jsonb, code text) returns jsonb language sql as $$
  select x from jsonb_array_elements(t->'clients') x where x->>'code' = code limit 1 $$;
create or replace function pg_temp.denied(q text) returns boolean language plpgsql as $$
begin execute q; return false; exception when insufficient_privilege then return true; end $$;

-- Working papers since 2 Nov (as production photographs them)
delete from public.weighing_postponements where po_number in ('AB-1','AB-2','AB-3','AB-4','LD-1','PH-1','PH-2','XX-1');
delete from public.weighing_papers where id::text like '37000000%';
delete from public.sales_calls; delete from public.sales_customer_names where name = 'Unknown Bistro';
update public.sales_customers set portfolio = 'house', salesperson_code = null, assigned_manually = false where code = 'CB001';
insert into public.weighing_papers (id, work_date, photo_path, status, company, po_number, customer_name, delivery_date) values
 -- James: Accidental Butcher (CB005), printed name as the middle office types it
 ('37000000-0000-0000-0000-000000000001', '2026-11-03', 'a.jpg', 'read'     , 'Prosun Farm', 'AB-1', 'ACCIDENTAL BUTCHER', '2026-11-04'),
 ('37000000-0000-0000-0000-000000000002', '2026-11-07', 'b.jpg', 'read'     , 'Prosun Farm', 'AB-2', 'Accidental  Butcher', '2026-11-08'),
 ('37000000-0000-0000-0000-000000000003', '2026-11-11', 'c.jpg', 'read'     , 'Prosun Farm', 'AB-3', 'Accidental Butcher', '2026-11-12'),
 ('37000000-0000-0000-0000-000000000004', '2026-11-17', 'd.jpg', 'read'     , 'Prosun Farm', 'AB-4', 'Accidental Butcher', '2026-11-18'),
 -- Chovie: Le Du with its code in the name; Park Hyatt today, postponed twice
 ('37000000-0000-0000-0000-000000000005', '2026-11-17', 'e.jpg', 'read'     , 'Prosun Farm', 'LD-1', 'Le Du (CR010)', '2026-11-18'),
 ('37000000-0000-0000-0000-000000000006', '2026-11-17', 'f.jpg', 'read',      'Prosun Farm', 'PH-1', 'Park Hyatt', '2026-11-18'),
 ('37000000-0000-0000-0000-000000000007', '2026-11-16', 'g.jpg', 'read'     , 'Prosun Farm', 'PH-2', 'Park Hyatt', '2026-11-20'),
 -- Nobody's: a name PACE cannot read
 ('37000000-0000-0000-0000-000000000008', '2026-11-17', 'h.jpg', 'read'     , 'Prosun Food', 'XX-1', 'Unknown Bistro', '2026-11-18'),
 -- failed photo: not an order
 ('37000000-0000-0000-0000-000000000009', '2026-11-17', 'i.jpg', 'failed',    'Prosun Farm', null, 'Mandarin Hotel', '2026-11-18');
insert into public.weighing_lines (paper_id, line_no, description, ordered_text, ordered_qty, ordered_unit, actual_kg)
select id, 1, 'Breast', '10 Kg', 10, 'kg', 10.2 from public.weighing_papers where id::text like '37000000%';
update public.weighing_papers set status = 'confirmed', confirmed_at = now() - interval '1 hour'
 where id::text like '37000000%' and right(id::text, 1) in ('1', '2', '3', '4', '5', '7', '8');
insert into public.delivery_marks (paper_id, delivery_date, status, marked_by) values
 ('37000000-0000-0000-0000-000000000004', '2026-11-18', 'out', '00000000-0000-0000-0000-0000000000d1'),
 ('37000000-0000-0000-0000-000000000005', '2026-11-18', 'delivered', '00000000-0000-0000-0000-0000000000d1');
insert into public.weighing_postponements (paper_id, customer_name, po_number, company, from_work_date, to_work_date,
                                           from_delivery_date, to_delivery_date, reason, stage, created_at) values
 ('37000000-0000-0000-0000-000000000007', 'Park Hyatt', 'PH-2', 'Prosun Farm', '2026-11-16', '2026-11-16', '2026-11-18', '2026-11-20', 'production', 'delivery', now() - interval '2 days'),
 ('37000000-0000-0000-0000-000000000007', 'Park Hyatt', 'PH-2', 'Prosun Farm', '2026-11-16', '2026-11-16', '2026-11-17', '2026-11-18', 'client',     'delivery', now() - interval '3 days');

-- ---------------------------------------------------------------- access
select pg_temp.as_user('00000000-0000-0000-0000-000000000012');
select pg_temp.ok(public.sales_scope() = 'own' and public.sales_my_code() = '12', 'James: own portfolio 12 (linked by email)');
select pg_temp.ok((select count(*) from jsonb_array_elements(public.sales_clients()->'clients') x where x->>'salesperson' <> '12') = 0,
                  'James sees only his clients');
select pg_temp.ok(jsonb_array_length(public.sales_clients()->'clients') = 234, 'James: his 234 clients');
select pg_temp.ok(pg_temp.denied($$select public.sales_client_detail('CH022')$$), 'James cannot open Chovie''s client');
select pg_temp.ok(pg_temp.denied($$select public.sales_log_call('CH022', 'ordered')$$), 'James cannot log a call on Chovie''s client');
select pg_temp.ok(pg_temp.denied($$select public.sales_unmatched_names()$$), 'James cannot see unmatched names');
select pg_temp.ok(pg_temp.denied($$select public.sales_assign('CB005', '13', 'rep')$$), 'James cannot move a client');
set role authenticated;
select pg_temp.ok(pg_temp.denied($$select * from public.sales_customers$$)
              and pg_temp.denied($$select * from public.sales_monthly$$)
              and pg_temp.denied($$insert into public.sales_calls (code, outcome) values ('CB005', 'ordered')$$),
              'Tables closed to a signed-in user (functions only)');
select pg_temp.ok(jsonb_array_length(public.sales_clients()->'clients') = 234, 'Functions work as authenticated');
reset role;

select pg_temp.as_user('00000000-0000-0000-0000-000000000002');
select pg_temp.ok(public.sales_scope() = 'all', 'Christophe (sales director): all');
select pg_temp.ok(exists (select 1 from jsonb_array_elements(public.sales_clients()->'clients') x where x->>'portfolio' = 'not_transferred'),
                  'Sales director sees Not transferred');
select pg_temp.ok(exists (select 1 from jsonb_array_elements(public.sales_clients()->'clients') x where x->>'portfolio' = 'house'),
                  'Sales director sees House');

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a2');
select pg_temp.ok(public.sales_scope() = 'all', 'Khun Jum (admin): all');

select pg_temp.as_user('00000000-0000-0000-0000-0000000000d1');
select pg_temp.ok(pg_temp.denied($$select public.sales_clients()$$), 'Delivery: no Sales section');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b1');
select pg_temp.ok(pg_temp.denied($$select public.sales_clients()$$), 'Sale support: no Sales section');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000e1'::text);
select pg_temp.ok(pg_temp.denied($$select public.sales_clients()$$), 'A login with no profile: no Sales section');

-- ---------------------------------------------------------------- matching
select pg_temp.ok(public.sales_code_for_name('ACCIDENTAL  BUTCHER') = 'CB005', 'Name read regardless of case and spaces');
select pg_temp.ok(public.sales_code_for_name('Le Du (CR010)') = 'CR010', 'Code in the name');
select pg_temp.ok(public.sales_code_for_name('Unknown Bistro') is null, 'Unknown name: no client');
select pg_temp.ok(public.sales_code_for_name('XX (ZZ999)') is null, 'Code that does not exist: no client');

-- ---------------------------------------------------------------- the list
select pg_temp.as_user('00000000-0000-0000-0000-000000000012');
select pg_temp.ok((pg_temp.c(public.sales_clients(), 'CB005')->>'last_order') = '2026-11-18', 'CB005 last order = today''s paper');
select pg_temp.ok((pg_temp.c(public.sales_clients(), 'CB005')->>'rhythm')::int between 3 and 5, 'CB005 rhythm ~4 days (Sept invoices + Nov papers)');
select pg_temp.ok((pg_temp.c(public.sales_clients(), 'CB005')->>'status') = 'ok', 'CB005 on track');
select pg_temp.ok(jsonb_array_length(pg_temp.c(public.sales_clients(), 'CB005')->'m12') = 12, '12 months of revenue');
-- On rhythm but buying much less: at risk
update public.sales_monthly set amount = amount * 0.3 where code = 'CB005' and month >= '2026-07-01';
select pg_temp.ok((pg_temp.c(public.sales_clients(), 'CB005')->>'status') = 'at_risk'
              and (pg_temp.c(public.sales_clients(), 'CB005')->>'drop_pct')::int <= -40, 'CB005 at risk: revenue down');
update public.sales_monthly set amount = amount / 0.3 where code = 'CB005' and month >= '2026-07-01';

select pg_temp.as_user('00000000-0000-0000-0000-000000000013');
select pg_temp.ok((pg_temp.c(public.sales_clients(), 'CH022')->>'postponed30')::int = 1, 'Park Hyatt: 1 postponed paper in 30 days');
-- A weekly client silent since Sept: call now
select pg_temp.ok(
  (select count(*) from jsonb_array_elements(public.sales_clients()->'clients') x
    where x->>'status' = 'call_now' and (x->>'days_missing')::int >= (x->>'rhythm')::int * 1.5) > 0,
  'Call now: late against their own rhythm');
select pg_temp.ok(
  (select bool_and((x->>'days_missing')::int <= 120 or x->>'days_missing' is null)
     from jsonb_array_elements(public.sales_clients()->'clients') x where x->>'status' = 'call_now'),
  'Call now never older than 120 days');
select pg_temp.ok(
  (select bool_and(coalesce((x->>'days_missing')::int, (x->>'days_min')::int) > 120)
     from jsonb_array_elements(public.sales_clients()->'clients') x where x->>'status' = 'lost') is not false,
  'Lost = more than 120 days');
select pg_temp.ok(
  (select bool_and((x->>'last3')::numeric < 0.6 * (x->>'prev3')::numeric or (x->>'postponed30')::int >= 2)
     from jsonb_array_elements(public.sales_clients()->'clients') x where x->>'status' = 'at_risk') is not false,
  'At risk = revenue down 40 % or more, or 2 postponements');

-- ---------------------------------------------------------------- calls
select pg_temp.ok(public.sales_log_call('CR010', 'ordered', 'Will order 20 kg Friday') is not null, 'Chovie logs a call');
select pg_temp.ok((pg_temp.c(public.sales_clients(), 'CR010')->'call'->>'outcome') = 'ordered', 'Call shows on the list');
select pg_temp.ok((select (public.sales_client_detail('CR010')->'calls'->0->>'by')) = 'Chovie', 'Call in the detail with who called');
do $$ begin perform public.sales_log_call('CR010', 'problem', '  '); raise exception 'FAIL problem without note';
exception when invalid_parameter_value then raise notice 'PASS A problem needs a note'; end $$;

-- ---------------------------------------------------------------- detail
select pg_temp.ok(jsonb_array_length(public.sales_client_detail('CR010')->'invoices') = 4, 'Le Du: 4 September invoices');
select pg_temp.ok(jsonb_array_length(public.sales_client_detail('CR010')->'orders') = 1, 'Le Du: 1 working paper');
select pg_temp.ok((public.sales_client_detail('CR010')->'orders'->0) ? 'photo_path' is false, 'No photo path for sales');
select pg_temp.ok((public.sales_client_detail('CR010')->>'can_assign')::boolean is false, 'Chovie cannot move clients');

-- ---------------------------------------------------------------- deliveries
select pg_temp.ok(jsonb_array_length(public.sales_deliveries('2026-11-18')->'orders') = 2, 'Chovie today: Le Du + Park Hyatt (not produced)');
select pg_temp.ok((select x->'mark'->>'status' from jsonb_array_elements(public.sales_deliveries('2026-11-18')->'orders') x
                   where x->>'code' = 'CR010') = 'delivered', 'Le Du delivered (delivery team''s mark)');
select pg_temp.ok((select x->>'status' from jsonb_array_elements(public.sales_deliveries('2026-11-18')->'orders') x
                   where x->>'code' = 'CH022') = 'read', 'Park Hyatt today: not finished yet');
select pg_temp.ok((public.sales_clients()->'months_empty') = '["2025-10-01"]'::jsonb, 'October 2025 flagged as not in the report');
select pg_temp.ok(jsonb_array_length(public.sales_deliveries('2026-11-18')->'moved') = 1, 'PH-2: moved away from the 18th (now the 20th)');
select pg_temp.ok((select x->>'new_date' from jsonb_array_elements(public.sales_deliveries('2026-11-17')->'moved') x
                   where x->>'po_number' = 'PH-2') = '2026-11-20', 'PH-2: due 17th, now on the 20th');
select pg_temp.ok((select bool_and(not (x ? 'reason')) from jsonb_array_elements(public.sales_deliveries('2026-11-17')->'moved') x),
                  'No postponement reason for sales');
select pg_temp.ok((public.sales_deliveries('2026-11-18')->>'unmatched')::int = 0, 'Unmatched count hidden from a salesperson');
select pg_temp.as_user('00000000-0000-0000-0000-000000000012');
select pg_temp.ok((select bool_and(x->>'code' = 'CB005') from jsonb_array_elements(public.sales_deliveries('2026-11-18')->'orders') x),
                  'James today: only his client');

-- ---------------------------------------------------------------- admin
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.ok((public.sales_deliveries('2026-11-18')->>'unmatched')::int = 1, 'Admin: 1 paper today with an unknown client');
select pg_temp.ok((public.sales_unmatched_names()->0->>'name') = 'Unknown Bistro', 'Unmatched names list');
select public.sales_link_name('Unknown Bistro', 'cb002');
select pg_temp.ok(public.sales_code_for_name('unknown bistro') = 'CB002', 'Admin links a name to a code');
select public.sales_link_name('Unknown Bistro', 'CB001');
select pg_temp.ok(public.sales_code_for_name('Unknown Bistro') = 'CB001', 'Relinking moves the name');
select public.sales_assign('CB001', '12', 'rep');
select pg_temp.as_user('00000000-0000-0000-0000-000000000012');
select pg_temp.ok(pg_temp.c(public.sales_clients(), 'CB001') is not null, 'James sees a client moved to him');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
-- A re-import keeps the hand-made move
select public.sales_import('{"customers":[{"code":"CB001","name":"Boucherie Jean Pierre","portfolio":"house"}]}'::jsonb, 'test');
select pg_temp.ok((select salesperson_code from public.sales_customers where code = 'CB001') = '12', 'Re-import keeps a manual assignment');
select pg_temp.as_user('00000000-0000-0000-0000-000000000013');
select pg_temp.ok(pg_temp.denied($$select public.sales_import('{}'::jsonb)$$), 'Salesperson cannot import');
