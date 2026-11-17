-- Migration 035 — postponed orders followed until delivered. Run on a replica
-- after 035 (psql -f). Dates assume today is 17 Nov 2026 (Bangkok); the
-- postpone functions refuse past days, so shift them if re-run later.
\set ON_ERROR_STOP 1
\pset tuples_only on
insert into auth.users (id, email) values
 ('00000000-0000-0000-0000-0000000000a1','admin@x'),('00000000-0000-0000-0000-0000000000a2','jum@x'),
 ('00000000-0000-0000-0000-0000000000d1','deliv@x'),('00000000-0000-0000-0000-0000000000b1','ss@x'),
 ('00000000-0000-0000-0000-0000000000c1','acc@x'),('00000000-0000-0000-0000-0000000000f1','prod@x'),
 ('00000000-0000-0000-0000-0000000000e9','julien@x') on conflict do nothing;
insert into public.profiles (id, full_name, role) values
 ('00000000-0000-0000-0000-0000000000a1','Clément','admin'),('00000000-0000-0000-0000-0000000000a2','Khun Jum','admin'),
 ('00000000-0000-0000-0000-0000000000d1','Khun Driver','delivery'),('00000000-0000-0000-0000-0000000000b1','Jane','sale_support'),
 ('00000000-0000-0000-0000-0000000000c1','Ann','accounting'),('00000000-0000-0000-0000-0000000000f1','Muay','production')
on conflict (id) do update set role = excluded.role, full_name = excluded.full_name;
insert into public.profiles (id, full_name, role, company_scope) values
 ('00000000-0000-0000-0000-0000000000e9','Chef Julien','company_director','Prosun Food')
on conflict (id) do update set role = excluded.role, full_name = excluded.full_name, company_scope = excluded.company_scope;
update public.management_settings set delivery_from = '2026-11-10' where id = 1;

create or replace function pg_temp.as_user(u text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', u)::text, false); end $$;
create or replace function pg_temp.ok(cond boolean, label text) returns void language plpgsql as $$
begin if coalesce(cond, false) then raise notice 'PASS %', label; else raise exception 'FAIL %', label; end if; end $$;
-- one order of the tracker by PO
create or replace function pg_temp.o(t jsonb, po text) returns jsonb language sql as $$
  select x from jsonb_array_elements(t->'orders') x where x->>'po_number' = po limit 1 $$;

-- Papers
insert into public.weighing_papers (id, work_date, photo_path, status, company, po_number, customer_name, delivery_date) values
 ('35000000-0000-0000-0000-000000000001', '2026-11-17', '1.jpg', 'read',      'Prosun Food', 'PO-1', 'Easy Health',   '2026-11-17'),
 ('35000000-0000-0000-0000-000000000002', '2026-11-12', '2.jpg', 'read',      'Prosun Farm', 'PO-2', 'Bangkok Air',   '2026-11-15'),
 ('35000000-0000-0000-0000-000000000003', '2026-11-17', '3.jpg', 'read',      'Prosun Food', 'PO-3', 'PurePurr',      '2026-11-17'),
 ('35000000-0000-0000-0000-000000000006', '2026-11-17', '6.jpg', 'read',      'Prosun Farm', 'PO-6', 'Gone',          '2026-11-17'),
 ('35000000-0000-0000-0000-000000000007', '2026-11-17', '7.jpg', 'read',      'Prosun Farm', 'PO-7', 'Villa',         '2026-11-17');
insert into public.weighing_lines (paper_id, line_no, description, ordered_text, ordered_qty, ordered_unit, actual_kg)
select id, 1, 'Breast', '10 Kg', 10, 'kg', 10.4 from public.weighing_papers where id::text like '35000000%';
update public.weighing_papers set status = 'confirmed', confirmed_at = now() - interval '1 hour'
 where id in ('35000000-0000-0000-0000-000000000002', '35000000-0000-0000-0000-000000000003');

-- 1. Production postpones PO-1 (17 → 18)
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f1'); set role authenticated;
select (public.weighing_postpone('35000000-0000-0000-0000-000000000001', '2026-11-18', '2026-11-18', 'production', null)).id is not null;
select (public.weighing_postpone('35000000-0000-0000-0000-000000000006', '2026-11-18', '2026-11-18', 'raw_material', null)).id is not null;
select (public.weighing_postpone('35000000-0000-0000-0000-000000000007', '2026-11-18', '2026-11-19', 'production', null)).id is not null;
-- 2. Middle office postpones PO-3 (confirmed, 17 → 19)
reset role; select pg_temp.as_user('00000000-0000-0000-0000-0000000000b1'); set role authenticated;
select (public.weighing_postpone_delivery('35000000-0000-0000-0000-000000000003', '2026-11-19', 'delivery', null)).id is not null;
-- Register: PO-4 (no paper yet), no new date, PO-5 (date passed), PO-1 (same order as production's)
insert into public.order_postponements (id, customer_name, po_number, company, original_date, new_date, reason, quantity_kg) values
 ('35000000-0000-0000-0000-0000000000a4', 'Paleo Robbie', 'PO-4', 'Prosun Food', '2026-11-16', '2026-11-19', 'client', 12),
 ('35000000-0000-0000-0000-0000000000a5', 'Hotel A',      null,   'Prosun Farm', '2026-11-16', null,         'client', null),
 ('35000000-0000-0000-0000-0000000000a6', 'Catering C',   'PO-5', 'Prosun Farm', '2026-11-13', '2026-11-15', 'production', 8),
 ('35000000-0000-0000-0000-0000000000a7', 'Easy Health',  'po-1 ', 'Prosun Food', '2026-11-17', '2026-11-18', 'client', null);
reset role;

-- PO-2 moved twice in the past (written directly: the functions refuse past days)
insert into public.weighing_postponements (paper_id, customer_name, po_number, company, stage, from_work_date, to_work_date,
   from_delivery_date, to_delivery_date, reason, created_at) values
 ('35000000-0000-0000-0000-000000000002', 'Bangkok Air', 'PO-2', 'Prosun Farm', 'delivery', '2026-11-12', '2026-11-12', '2026-11-12', '2026-11-14', 'delivery', now() - interval '5 days'),
 ('35000000-0000-0000-0000-000000000002', 'Bangkok Air', 'PO-2', 'Prosun Farm', 'delivery', '2026-11-12', '2026-11-12', '2026-11-14', '2026-11-15', 'delivery', now() - interval '3 days');

-- The paper of PO-6 is deleted; PO-7's filled paper is photographed and linked
delete from public.weighing_papers where id = '35000000-0000-0000-0000-000000000006';
insert into public.weighing_papers (id, work_date, photo_path, status, company, po_number, customer_name, delivery_date) values
 ('35000000-0000-0000-0000-000000000008', '2026-11-18', '8.jpg', 'read', 'Prosun Farm', 'PO-7', 'Villa', '2026-11-17');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f1'); set role authenticated;
select public.weighing_link_postponed('35000000-0000-0000-0000-000000000007', '35000000-0000-0000-0000-000000000008') = '7.jpg';
reset role;

-- ---------------------------------------------------------------- the list
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b1'); set role authenticated;
do $$ declare t jsonb := public.postponed_orders_tracker(30); o jsonb; begin
  perform pg_temp.ok((t->>'can_edit')::boolean and not (t->>'can_delete')::boolean, 'middle office: can edit, cannot delete');
  o := pg_temp.o(t, 'PO-1');
  perform pg_temp.ok(o->>'state' = 'waiting' and (o->>'times')::int = 2 and o->>'due_date' = '2026-11-18'
                     and o->>'original_date' = '2026-11-17' and (o->>'open')::boolean and not (o->>'late')::boolean,
                     'PO-1: production move + register = one order, 2×, waiting for production, due 18');
  perform pg_temp.ok(o->'sources' ? 'production' and o->'sources' ? 'register', 'PO-1 sources: production and register');
  o := pg_temp.o(t, 'PO-2');
  perform pg_temp.ok(o->>'state' = 'factory' and (o->>'late')::boolean and (o->>'days_late')::int = 2 and (o->>'times')::int = 2
                     and o->>'original_date' = '2026-11-12' and (o->>'delay_days')::int = 3,
                     'PO-2: produced, not picked up, late again by 2 days, moved twice, +3 days');
  o := pg_temp.o(t, 'PO-3');
  perform pg_temp.ok(o->>'state' = 'factory' and o->>'last_source' = 'middle' and o->>'reason' = 'delivery'
                     and (o->>'kg_actual')::numeric = 10.4, 'PO-3: produced at the factory, moved by the middle office, reason shown, 10.4 kg');
  o := pg_temp.o(t, 'PO-4');
  perform pg_temp.ok(o->>'state' = 'no_paper' and o->>'key' like 'r:%' and not (o->>'late')::boolean, 'PO-4: register, no paper yet');
  o := (select x from jsonb_array_elements(t->'orders') x where x->>'customer_name' = 'Hotel A');
  perform pg_temp.ok(o->>'state' = 'no_date' and o->>'due_date' is null and not (o->>'late')::boolean, 'Hotel A: register, no new date');
  o := pg_temp.o(t, 'PO-5');
  perform pg_temp.ok(o->>'state' = 'no_paper' and (o->>'late')::boolean, 'PO-5: no paper and its new date passed: late again');
  o := pg_temp.o(t, 'PO-6');
  perform pg_temp.ok(o->>'state' = 'deleted' and not (o->>'open')::boolean, 'PO-6: paper deleted, closed');
  perform pg_temp.ok((select count(*) from jsonb_array_elements(t->'orders') x where x->>'po_number' = 'PO-7') = 1, 'PO-7 linked: one row');
  o := pg_temp.o(t, 'PO-7');
  perform pg_temp.ok(o->>'paper_id' = '35000000-0000-0000-0000-000000000008' and o->>'state' = 'checking' and o->>'due_date' = '2026-11-19',
                     'PO-7: follows the new photo, weights being checked, keeps the postponed date 19');
  perform pg_temp.ok((t->'orders'->0->>'late')::boolean, 'late orders first');
end $$;
reset role;

-- PO-4's paper arrives (due 19): the register record follows it
insert into public.weighing_papers (id, work_date, photo_path, status, company, po_number, customer_name, delivery_date) values
 ('35000000-0000-0000-0000-000000000004', '2026-11-18', '4.jpg', 'read', 'Prosun Food', 'PO-4', 'Paleo Robbie', '2026-11-19');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b1'); set role authenticated;
do $$ declare o jsonb := pg_temp.o(public.postponed_orders_tracker(30), 'PO-4'); begin
  perform pg_temp.ok(o->>'state' = 'checking' and o->>'paper_id' = '35000000-0000-0000-0000-000000000004'
                     and o->>'original_date' = '2026-11-16', 'PO-4: register follows the paper with the same PO on the new date');
end $$;
reset role;

-- PO-3 delivered on the board: closed
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d1'); set role authenticated;
do $$ begin
  perform public.delivery_mark('35000000-0000-0000-0000-000000000003', 'dispatch');
  perform public.delivery_mark('35000000-0000-0000-0000-000000000003', 'out');
  perform public.delivery_mark('35000000-0000-0000-0000-000000000003', 'delivered');
end $$;
reset role;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b1'); set role authenticated;
do $$ declare o jsonb := pg_temp.o(public.postponed_orders_tracker(30), 'PO-3'); tl jsonb; kinds text; begin
  perform pg_temp.ok(o->>'state' = 'delivered' and not (o->>'open')::boolean and o->>'mark_at' is not null, 'PO-3 delivered: closed');
  tl := public.postponed_order_timeline('35000000-0000-0000-0000-000000000003', null);
  select string_agg(coalesce(e->>'status', e->>'kind'), ',' order by ord) into kinds
    from jsonb_array_elements(tl->'events') with ordinality t(e, ord);
  perform pg_temp.ok(kinds = 'photographed,confirmed,moved,dispatch,out,delivered', 'PO-3 timeline: ' || kinds);
  tl := public.postponed_order_timeline(null, '35000000-0000-0000-0000-0000000000a7');
  perform pg_temp.ok(tl->'order'->>'po_number' = 'PO-1'
                     and (select count(*) from jsonb_array_elements(tl->'events') e where e->>'kind' in ('moved', 'register')) = 2,
                     'timeline from a register record: the same order as PO-1, both moves');
  tl := public.postponed_order_timeline('35000000-0000-0000-0000-000000000002', null);
  perform pg_temp.ok((select e->>'at' from jsonb_array_elements(tl->'events') e where e->>'kind' = 'late')::timestamptz = '2026-11-15T17:00:00+00:00'::timestamptz,
                     'PO-2 timeline: Late again from 16 Nov 00:00 Bangkok');
end $$;

-- Closing by hand
do $$ declare o jsonb; begin
  o := public.postponement_close(null, '35000000-0000-0000-0000-0000000000a6', true, 'Delivered by the old process');
  perform pg_temp.ok(o->>'state' = 'closed' and not (o->>'late')::boolean and o->>'closed_by' = 'Jane', 'PO-5 closed by hand');
  o := public.postponement_close('35000000-0000-0000-0000-000000000002', null, true, null);
  perform pg_temp.ok(o->>'state' = 'closed', 'PO-2 closed by hand');
  o := public.postponement_close('35000000-0000-0000-0000-000000000002', null, false, null);
  perform pg_temp.ok(o->>'state' = 'factory' and (o->>'late')::boolean, 'PO-2 reopened: late again');
  begin perform public.postponement_close('35000000-0000-0000-0000-000000000003', null, true, null); raise exception 'FAIL closed a delivered order';
  exception when sqlstate '22023' then perform pg_temp.ok(true, 'a delivered order cannot be closed by hand'); end;
end $$;
reset role;

-- Who may
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d1'); set role authenticated;
do $$ begin
  begin perform public.postponement_close('35000000-0000-0000-0000-000000000002', null, true, null); raise exception 'FAIL delivery closed';
  exception when sqlstate '42501' then perform pg_temp.ok(true, 'delivery team cannot close by hand'); end;
  begin perform public.postponed_orders_tracker(30); raise exception 'FAIL delivery read';
  exception when sqlstate '42501' then perform pg_temp.ok(true, 'delivery team: no tracker (it has the board)'); end;
end $$;
reset role;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000c1'); set role authenticated;
do $$ begin
  begin perform public.postponed_orders_tracker(30); raise exception 'FAIL accounting read';
  exception when sqlstate '42501' then perform pg_temp.ok(true, 'accounting refused'); end;
  begin perform public.postponed_late_check(); raise exception 'FAIL accounting check';
  exception when sqlstate '42501' then perform pg_temp.ok(true, 'accounting cannot ring the bell'); end;
end $$;
reset role;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000e9'); set role authenticated;
do $$ declare t jsonb := public.postponed_orders_tracker(30); begin
  perform pg_temp.ok(not (t->>'can_edit')::boolean, 'company director: read-only');
  perform pg_temp.ok((select bool_and(x->>'company' = 'Prosun Food') from jsonb_array_elements(t->'orders') x)
                     and pg_temp.o(t, 'PO-1') is not null and pg_temp.o(t, 'PO-2') is null, 'company director: Prosun Food only');
  begin perform public.postponed_order_timeline('35000000-0000-0000-0000-000000000002', null); raise exception 'FAIL director other company';
  exception when sqlstate '22023' then perform pg_temp.ok(true, 'company director: no timeline for the other company'); end;
  begin perform public.postponement_close('35000000-0000-0000-0000-000000000001', null, true, null); raise exception 'FAIL director closed';
  exception when sqlstate '42501' then perform pg_temp.ok(true, 'company director cannot close'); end;
end $$;
reset role;

-- Bell: late again, once
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b1'); set role authenticated;
do $$ declare n int; begin
  n := public.postponed_late_check();
  perform pg_temp.ok(n = 1, 'late check: 1 order newly late (PO-2; PO-5 was closed): ' || n);
  perform pg_temp.ok(public.postponed_late_check() = 0, 'late check again: nothing new');
end $$;
reset role;
do $$ begin
  perform pg_temp.ok((select count(*) from public.notifications where kind = 'postponed_late') = 2, 'bell for both admins');
  perform pg_temp.ok((select title from public.notifications where kind = 'postponed_late' limit 1) = 'Late again — PO PO-2 · Bangkok Air', 'bell title');
end $$;
select public.postponed_late_check() = 0;   -- a scheduled job (no user) may run it

-- Management dashboard
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1'); set role authenticated;
do $$ declare d jsonb := public.management_postponed_open(null); begin
  perform pg_temp.ok((d->>'open')::int = 5 and (d->>'late')::int = 1 and (d->>'twice')::int = 2 and (d->>'closed')::int = 2,
                     'dashboard: 5 open, 1 late, 2 moved twice, 2 closed: ' || d::text);
  perform pg_temp.ok(d->'oldest'->0->>'po_number' = 'PO-2', 'oldest open: the late one first');
end $$;
reset role;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000e9'); set role authenticated;
do $$ declare d jsonb := public.management_postponed_open('all'); begin
  perform pg_temp.ok((d->>'open')::int = 2, 'dashboard, company director: Prosun Food only (PO-1, PO-4): ' || (d->>'open'));
  begin perform public.management_postponed_open('Prosun Farm'); raise exception 'FAIL director other company';
  exception when sqlstate '42501' then perform pg_temp.ok(true, 'company director: the other company refused'); end;
end $$;
reset role;
\echo 'test_035: all checks passed'
