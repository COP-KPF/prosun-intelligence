-- Migration 041 — production postpones products too; live stamp. Run on a
-- replica after 041 (psql -f). Dates assume today is 20 Nov 2026 (Bangkok).
\set ON_ERROR_STOP 1
\pset tuples_only on
insert into auth.users (id, email) values
 ('00000000-0000-0000-0000-0000000000a1','admin@x'),('00000000-0000-0000-0000-0000000000b1','ss@x'),
 ('00000000-0000-0000-0000-0000000000c1','acc@x'),('00000000-0000-0000-0000-0000000000f1','prod@x'),
 ('00000000-0000-0000-0000-0000000000f2','fadmin@x') on conflict do nothing;
insert into public.profiles (id, full_name, role) values
 ('00000000-0000-0000-0000-0000000000a1','Clément','admin'),('00000000-0000-0000-0000-0000000000b1','Ploy','sale_support'),
 ('00000000-0000-0000-0000-0000000000c1','Ann','accounting'),('00000000-0000-0000-0000-0000000000f1','Muay','production'),
 ('00000000-0000-0000-0000-0000000000f2','Factory admin','factory_admin')
on conflict (id) do update set role = excluded.role, full_name = excluded.full_name;

create or replace function pg_temp.as_user(u text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', u)::text, false); end $$;
create or replace function pg_temp.ok(cond boolean, label text) returns void language plpgsql as $$
begin if coalesce(cond, false) then raise notice 'PASS %', label; else raise exception 'FAIL %', label; end if; end $$;

insert into public.weighing_papers (id, work_date, photo_path, status, company, po_number, customer_name, delivery_date) values
 ('41000000-0000-0000-0000-00000000000a', '2026-11-20', 'a.jpg', 'read', 'Prosun Farm', 'PO-R', 'Villa', '2026-11-20'),
 ('41000000-0000-0000-0000-00000000000b', '2026-11-20', 'b.jpg', 'read', 'Prosun Food', 'PO-C', 'Easy Health', '2026-11-20'),
 ('41000000-0000-0000-0000-00000000000e', '2026-11-20', 'e.jpg', 'reading', 'Prosun Farm', 'PO-X', 'Reading', '2026-11-20');
insert into public.weighing_lines (id, paper_id, line_no, description, ordered_text, ordered_qty, ordered_unit, weights, actual_kg) values
 ('41000000-0000-0000-0000-0000000000a1', '41000000-0000-0000-0000-00000000000a', 1, 'Breast', '20 Kg', 20, 'kg', '{12}', 12),
 ('41000000-0000-0000-0000-0000000000a2', '41000000-0000-0000-0000-00000000000a', 2, 'Wings', '6 Kg', 6, 'kg', '{}', null),
 ('41000000-0000-0000-0000-0000000000b1', '41000000-0000-0000-0000-00000000000b', 1, 'Sous-vide', '10 Kg', 10, 'kg', '{10.1}', 10.1),
 ('41000000-0000-0000-0000-0000000000b2', '41000000-0000-0000-0000-00000000000b', 2, 'Thigh', '4 Kg', 4, 'kg', '{4.1}', 4.1),
 ('41000000-0000-0000-0000-0000000000e1', '41000000-0000-0000-0000-00000000000e', 1, 'X', '1 Kg', 1, 'kg', '{}', null),
 ('41000000-0000-0000-0000-0000000000e2', '41000000-0000-0000-0000-00000000000e', 2, 'Y', '1 Kg', 1, 'kg', '{}', null);
update public.weighing_papers set status = 'confirmed' where id = '41000000-0000-0000-0000-00000000000b';

-- live stamp
do $$ declare s0 bigint; s1 bigint; begin
  select seq into s0 from public.pace_live where topic = 'orders';
  update public.weighing_papers set note = 'x' where id = '41000000-0000-0000-0000-00000000000a';
  select seq into s1 from public.pace_live where topic = 'orders';
  perform pg_temp.ok(s1 = s0 + 1, 'a change to a paper renews the live stamp');
  perform pg_temp.ok((select count(*) from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'pace_live') = 1,
                     'pace_live is published to realtime');
end $$;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000c1'); set role authenticated;
do $$ begin perform pg_temp.ok((select count(*) from public.pace_live) = 1, 'every signed-in user reads the stamp (no data in it)'); end $$;
reset role;
set role anon;
do $$ begin
  begin perform 1 from public.pace_live; raise exception 'FAIL anon read';
  exception when insufficient_privilege then perform pg_temp.ok(true, 'not signed in: no access'); end;
end $$;
reset role;

-- production, paper not confirmed: back to production only
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f1'); set role authenticated;
do $$ declare r jsonb; begin
  begin
    perform public.weighing_postpone_lines('41000000-0000-0000-0000-00000000000a', '[{"line_id":"41000000-0000-0000-0000-0000000000a2"}]',
      'later', '2026-11-22', null, 'production', null, 'weighing');
    raise exception 'FAIL later on unconfirmed';
  exception when sqlstate '22023' then perform pg_temp.ok(sqlerrm like '%can only go back to production%', 'not confirmed: "delivered later" refused'); end;
  r := public.weighing_postpone_lines('41000000-0000-0000-0000-00000000000a',
         '[{"line_id":"41000000-0000-0000-0000-0000000000a2"},{"line_id":"41000000-0000-0000-0000-0000000000a1","qty":8}]',
         'production', '2026-11-22', '2026-11-21', 'raw_material', null, 'weighing');
  perform pg_temp.ok((r->>'part')::int = 2 and r->>'by_dept' = 'production', 'production: part 2 back to production (wings + 8 kg breast)');
  begin
    perform public.weighing_postpone_lines('41000000-0000-0000-0000-00000000000e', '[{"line_id":"41000000-0000-0000-0000-0000000000e1"}]',
      'production', '2026-11-22', '2026-11-21', 'production', null, 'weighing');
    raise exception 'FAIL reading';
  exception when sqlstate '22023' then perform pg_temp.ok(sqlerrm like '%still being read%', 'a paper still being read is refused'); end;
end $$;
reset role;
do $$ declare c record; begin
  select * into c from public.weighing_papers where split_from = '41000000-0000-0000-0000-00000000000a';
  perform pg_temp.ok(c.status = 'postponed' and c.work_date = '2026-11-21' and c.split_part = 2, 'part 2 waits for production on 21 Nov');
  perform pg_temp.ok((select status = 'read' and confirmed_at is null from public.weighing_papers where id = '41000000-0000-0000-0000-00000000000a'),
                     'the original is still being weighed (not confirmed)');
  perform pg_temp.ok((select ordered_qty = 12 and actual_kg = 12 from public.weighing_lines where id = '41000000-0000-0000-0000-0000000000a1'),
                     'original breast: 12 Kg ordered left, its 12 kg weighed kept');
  perform pg_temp.ok((select by_dept = 'production' from public.weighing_postponements where paper_id = c.id), 'history: by production');
  perform pg_temp.ok((select title from public.notifications where kind = 'product_postponed' limit 1) like 'Product postponed by production — %', 'bell: by production');
end $$;

-- production, confirmed paper: both choices
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f2'); set role authenticated;
do $$ declare r jsonb; begin
  r := public.weighing_postpone_lines('41000000-0000-0000-0000-00000000000b', '[{"line_id":"41000000-0000-0000-0000-0000000000b2"}]',
         'later', '2026-11-23', null, 'client', null, 'weighing');
  perform pg_temp.ok((r->>'part')::int = 2 and r->>'mode' = 'later', 'factory admin, confirmed paper: produced, delivered later');
end $$;
reset role;

-- the middle office: confirmed papers only
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b1'); set role authenticated;
do $$ declare t jsonb; o jsonb; begin
  begin
    perform public.weighing_postpone_lines('41000000-0000-0000-0000-00000000000a', '[{"line_id":"41000000-0000-0000-0000-0000000000a1","qty":2}]',
      'production', '2026-11-22', '2026-11-21', 'client', null, 'weights');
    raise exception 'FAIL middle office unconfirmed';
  exception when sqlstate '22023' then perform pg_temp.ok(sqlerrm like '%confirmed papers only%', 'middle office: not on a paper being weighed'); end;
  t := public.postponed_orders_tracker(30);
  o := (select x from jsonb_array_elements(t->'orders') x where x->>'po_number' = 'PO-R');
  perform pg_temp.ok(o->>'last_source' = 'production' and o->>'state' = 'waiting' and (o->>'part')::int = 2,
                     'Postponed orders: PO-R part 2, by production, waiting for production');
  perform pg_temp.ok((select e->>'by_dept' from jsonb_array_elements(public.postponed_order_timeline((o->>'paper_id')::uuid, null)->'events') e
                      where e->>'kind' = 'moved') = 'production', 'timeline: moved by production');
  o := (select x from jsonb_array_elements(t->'orders') x where x->>'po_number' = 'PO-C');
  perform pg_temp.ok(o->>'last_source' = 'production' and o->>'state' = 'factory', 'PO-C part 2: by production, produced');
end $$;
reset role;

-- admin: whose move depends on the screen
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1'); set role authenticated;
select (public.weighing_postpone_lines('41000000-0000-0000-0000-00000000000b', '[{"line_id":"41000000-0000-0000-0000-0000000000b1","qty":3}]',
        'later', '2026-11-24', null, 'client', null, 'weights'))->>'by_dept' = 'middle';
reset role;
do $$ begin
  perform pg_temp.ok((select by_dept from public.weighing_postponements order by created_at desc limit 1) = 'middle', 'admin from Confirmed weights: middle office');
end $$;
\echo 'test_041: all checks passed'
