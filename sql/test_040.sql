-- Migration 040 — postpone one product (or part of it) from Confirmed weights.
-- Run on a replica after 040 (psql -f). Dates assume today is 19 Nov 2026
-- (Bangkok); the functions refuse past days, so shift them if re-run later.
\set ON_ERROR_STOP 1
\pset tuples_only on
insert into auth.users (id, email) values
 ('00000000-0000-0000-0000-0000000000a1','admin@x'),('00000000-0000-0000-0000-0000000000a2','jum@x'),
 ('00000000-0000-0000-0000-0000000000d1','deliv@x'),('00000000-0000-0000-0000-0000000000b1','ss@x'),
 ('00000000-0000-0000-0000-0000000000c1','acc@x'),('00000000-0000-0000-0000-0000000000f1','prod@x')
on conflict do nothing;
insert into public.profiles (id, full_name, role) values
 ('00000000-0000-0000-0000-0000000000a1','Clément','admin'),('00000000-0000-0000-0000-0000000000a2','Khun Jum','admin'),
 ('00000000-0000-0000-0000-0000000000d1','Khun Driver','delivery'),('00000000-0000-0000-0000-0000000000b1','Ploy','sale_support'),
 ('00000000-0000-0000-0000-0000000000c1','Ann','accounting'),('00000000-0000-0000-0000-0000000000f1','Muay','production')
on conflict (id) do update set role = excluded.role, full_name = excluded.full_name;

create or replace function pg_temp.as_user(u text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', u)::text, false); end $$;
create or replace function pg_temp.ok(cond boolean, label text) returns void language plpgsql as $$
begin if coalesce(cond, false) then raise notice 'PASS %', label; else raise exception 'FAIL %', label; end if; end $$;

-- Paper A: confirmed, 3 products; paper B: confirmed, picked up
insert into public.weighing_papers (id, work_date, photo_path, status, company, po_number, customer_name, delivery_date) values
 ('40000000-0000-0000-0000-00000000000a', '2026-11-19', 'a.jpg', 'read', 'Prosun Farm', 'PO-A', 'Bangkok Air', '2026-11-19'),
 ('40000000-0000-0000-0000-00000000000b', '2026-11-19', 'b.jpg', 'read', 'Prosun Farm', 'PO-B', 'Villa', '2026-11-19');
insert into public.weighing_lines (id, paper_id, line_no, description, ordered_text, ordered_qty, ordered_unit, weights, actual_kg) values
 ('40000000-0000-0000-0000-0000000000a1', '40000000-0000-0000-0000-00000000000a', 1, 'Breast', '25 Kg', 25, 'kg', '{12.7,12.7}', 25.4),
 ('40000000-0000-0000-0000-0000000000a2', '40000000-0000-0000-0000-00000000000a', 2, 'Whole chicken', '10 pcs', 10, 'pcs', '{14.2}', 14.2),
 ('40000000-0000-0000-0000-0000000000a3', '40000000-0000-0000-0000-00000000000a', 3, 'Thigh', '5 Kg', 5, 'kg', '{}', null),
 ('40000000-0000-0000-0000-0000000000b1', '40000000-0000-0000-0000-00000000000b', 1, 'Breast', '8 Kg', 8, 'kg', '{8.1}', 8.1),
 ('40000000-0000-0000-0000-0000000000b2', '40000000-0000-0000-0000-00000000000b', 2, 'Wings', '4 Kg', 4, 'kg', '{4.0}', 4.0);
update public.weighing_papers set status = 'confirmed' where id::text like '40000000%';
update public.weighing_papers set confirmed_at = now() - interval '2 hours' where id::text like '40000000%';
-- accounting already invoiced paper A
insert into public.weighing_invoices (paper_id, invoice_no, invoiced_by, invoiced_at, confirmed_at_seen)
select id, 'INV-1', '00000000-0000-0000-0000-0000000000c1', now() - interval '1 hour', confirmed_at
from public.weighing_papers where id = '40000000-0000-0000-0000-00000000000a';
insert into public.delivery_marks (paper_id, delivery_date, status, marked_by)
values ('40000000-0000-0000-0000-00000000000b', '2026-11-19', 'dispatch', '00000000-0000-0000-0000-0000000000d1');

-- 1. Produced, delivered later: 10 of the 25 kg breast
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b1'); set role authenticated;
do $$ declare r jsonb; begin
  r := public.weighing_postpone_lines('40000000-0000-0000-0000-00000000000a',
         '[{"line_id":"40000000-0000-0000-0000-0000000000a1","qty":10}]', 'later', '2026-11-21', null, 'client', 'Kitchen closed Friday');
  perform pg_temp.ok((r->>'part')::int = 2 and r->>'mode' = 'later', 'part 2 created (produced, delivered later)');
end $$;
reset role;
do $$ declare c record; o record; begin
  select * into c from public.weighing_papers where split_part = 2;
  perform pg_temp.ok(c.status = 'confirmed' and c.delivery_date = '2026-11-21' and c.po_number = 'PO-A' and c.split_part = 2
                     and c.split_from = '40000000-0000-0000-0000-00000000000a' and c.photo_path = 'a.jpg' and c.work_date = '2026-11-19',
                     'part 2: confirmed, same PO and photo, delivery 21 Nov');
  select * into o from public.weighing_lines where paper_id = c.id;
  perform pg_temp.ok(o.description = 'Breast' and o.ordered_qty = 10 and o.ordered_text = '10 Kg' and o.actual_kg = 10.16,
                     'part 2 line: Breast 10 Kg, 10.16 kg (proportional)');
  select * into o from public.weighing_lines where id = '40000000-0000-0000-0000-0000000000a1';
  perform pg_temp.ok(o.ordered_qty = 15 and o.ordered_text = '15 Kg' and o.actual_kg = 15.24, 'original line: Breast 15 Kg, 15.24 kg');
end $$;
do $$ begin
  perform pg_temp.ok((select status = 'confirmed' and confirmed_at > now() - interval '1 minute' from public.weighing_papers
                      where id = '40000000-0000-0000-0000-00000000000a'), 'original stays confirmed, confirmation time renewed');
  perform pg_temp.ok((select count(*) from public.notifications where kind = 'invoice_weights_changed'
                      and paper_id = '40000000-0000-0000-0000-00000000000a') = 1, 'accounting: weights changed after invoice');
  perform pg_temp.ok((select count(*) from public.notifications where kind = 'product_postponed') = 2, 'admins: product postponed bell (2 admins)');
  perform pg_temp.ok((select body from public.notifications where kind = 'product_postponed' limit 1)
                     like 'Breast 10 Kg of 25 Kg → part 2, delivery 21 Nov (produced, delivered later). Client request. Kitchen closed Friday',
                     'bell text: ' || (select body from public.notifications where kind = 'product_postponed' limit 1));
  perform pg_temp.ok((select count(*) from public.notifications where kind in ('weighing_changed', 'delivery_postponed')) = 0, 'no other bells');
end $$;

-- 2. Not produced: the whole thigh line back to production on 20 Nov, delivery 21 Nov
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b1'); set role authenticated;
select (public.weighing_postpone_lines('40000000-0000-0000-0000-00000000000a',
         '[{"line_id":"40000000-0000-0000-0000-0000000000a3"}]', 'production', '2026-11-21', '2026-11-20', 'raw_material', null))->>'part' = '3';
reset role;
do $$ declare c record; n int; begin
  select * into c from public.weighing_papers where split_part = 3;
  perform pg_temp.ok(c.status = 'postponed' and c.work_date = '2026-11-20' and c.delivery_date = '2026-11-21' and c.split_part = 3,
                     'part 3: postponed to production on 20 Nov, delivery 21 Nov');
  perform pg_temp.ok((select count(*) = 1 and bool_and(id = '40000000-0000-0000-0000-0000000000a3' and actual_kg is null and line_no = 1)
                      from public.weighing_lines where paper_id = c.id), 'part 3: the thigh line itself moved, no weight');
  select count(*) into n from public.weighing_lines where paper_id = '40000000-0000-0000-0000-00000000000a';
  perform pg_temp.ok(n = 2, 'original keeps 2 products');
end $$;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b1'); set role authenticated;
do $$ declare r jsonb; begin
  -- 3. moving every remaining product is refused
  begin
    perform public.weighing_postpone_lines('40000000-0000-0000-0000-00000000000a',
      '[{"line_id":"40000000-0000-0000-0000-0000000000a1"},{"line_id":"40000000-0000-0000-0000-0000000000a2"}]', 'later', '2026-11-22', null, 'client', null);
    raise exception 'FAIL moved every product';
  exception when sqlstate '22023' then perform pg_temp.ok(sqlerrm like 'every product would move%', 'every product: use Postpone instead');
  end;
  -- partial pieces with a typed weight
  r := public.weighing_postpone_lines('40000000-0000-0000-0000-00000000000a',
         '[{"line_id":"40000000-0000-0000-0000-0000000000a2","qty":4,"actual_kg":5.6}]', 'later', '2026-11-22', null, 'delivery', null);
  perform pg_temp.ok((r->>'part')::int = 4, 'part 4: 4 of 10 pcs');
  -- refusals
  begin
    perform public.weighing_postpone_lines('40000000-0000-0000-0000-00000000000a',
      '[{"line_id":"40000000-0000-0000-0000-0000000000a1","qty":5,"actual_kg":20}]', 'later', '2026-11-22', null, 'client', null);
    raise exception 'FAIL kg too high';
  exception when sqlstate '22023' then perform pg_temp.ok(true, 'kg moved must be less than the line''s kg'); end;
  begin
    perform public.weighing_postpone_lines('40000000-0000-0000-0000-00000000000a',
      '[{"line_id":"40000000-0000-0000-0000-0000000000a1","qty":5}]', 'later', '2026-11-19', null, 'client', null);
    raise exception 'FAIL same date';
  exception when sqlstate '22023' then perform pg_temp.ok(true, 'new date must be after the current one'); end;
  begin
    perform public.weighing_postpone_lines('40000000-0000-0000-0000-00000000000a',
      '[{"line_id":"40000000-0000-0000-0000-0000000000a1","qty":5}]', 'production', '2026-11-22', '2026-11-19', 'client', null);
    raise exception 'FAIL same production day';
  exception when sqlstate '22023' then perform pg_temp.ok(true, 'back to production needs another production day'); end;
  begin
    perform public.weighing_postpone_lines('40000000-0000-0000-0000-00000000000a',
      '[{"line_id":"40000000-0000-0000-0000-0000000000a1","qty":5}]', 'later', '2026-11-22', null, 'other', null);
    raise exception 'FAIL other without comment';
  exception when sqlstate '22023' then perform pg_temp.ok(true, 'Other needs a comment'); end;
  begin
    perform public.weighing_postpone_lines('40000000-0000-0000-0000-00000000000b',
      '[{"line_id":"40000000-0000-0000-0000-0000000000b1"}]', 'later', '2026-11-22', null, 'client', null);
    raise exception 'FAIL picked up';
  exception when sqlstate '22023' then perform pg_temp.ok(sqlerrm like '%already picked up%', 'picked-up order refused'); end;
  begin
    perform public.weighing_postpone_lines('40000000-0000-0000-0000-00000000000a',
      '[{"line_id":"40000000-0000-0000-0000-0000000000b1"}]', 'later', '2026-11-22', null, 'client', null);
    raise exception 'FAIL line of another paper';
  exception when sqlstate '22023' then perform pg_temp.ok(true, 'a product of another paper refused'); end;
end $$;
reset role;

do $$ begin
  perform pg_temp.ok((select count(*) from public.weighing_lines where paper_id = '40000000-0000-0000-0000-00000000000a') = 2,
                     'refused moves left the original as it was');
  perform pg_temp.ok((select actual_kg = 8.6 and ordered_text = '6 pcs' from public.weighing_lines where id = '40000000-0000-0000-0000-0000000000a2'),
                     'original: 6 pcs, 8.6 kg left');
end $$;

-- who may
select pg_temp.as_user('00000000-0000-0000-0000-0000000000c1'); set role authenticated;
do $$ begin
  begin perform public.weighing_postpone_lines('40000000-0000-0000-0000-00000000000a',
      '[{"line_id":"40000000-0000-0000-0000-0000000000a1","qty":1}]', 'later', '2026-11-22', null, 'client', null);
    raise exception 'FAIL accounting';
  exception when sqlstate '42501' then perform pg_temp.ok(true, 'accounting cannot postpone products'); end;
end $$;
reset role;
-- (production postponing products came with Migration 041: see test_041.sql)
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1'); set role authenticated;
do $$ begin
  begin update public.weighing_lines set actual_kg = 1 where id = '40000000-0000-0000-0000-0000000000a1'; raise exception 'FAIL guard';
  exception when sqlstate '42501' then perform pg_temp.ok(true, 'a confirmed paper''s lines still cannot be changed directly'); end;
end $$;
reset role;

-- Confirmed weights marks, tracker, delivery board
select pg_temp.as_user('00000000-0000-0000-0000-0000000000c1'); set role authenticated;
do $$ declare f jsonb; n int; begin
  select family into f from public.weighing_split_marks(array['40000000-0000-0000-0000-00000000000a'::uuid]);
  perform pg_temp.ok(jsonb_array_length(f) = 3 and f->0->>'mode' = 'later' and f->1->>'mode' = 'production'
                     and f->0->>'reason' is null, 'accounting: the order''s 3 parts, no reasons');
  select count(*) into n from public.weighing_split_marks(array['40000000-0000-0000-0000-00000000000b'::uuid]);
  perform pg_temp.ok(n = 0, 'an order never split: nothing');
end $$;
reset role;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b1'); set role authenticated;
do $$ declare t jsonb; o jsonb; f jsonb; begin
  select family into f from public.weighing_split_marks(array['40000000-0000-0000-0000-00000000000a'::uuid]);
  perform pg_temp.ok(f->0->>'reason' = 'client' and f->0->>'note' = 'Kitchen closed Friday', 'middle office: reasons shown');
  t := public.postponed_orders_tracker(30);
  perform pg_temp.ok((select count(*) from jsonb_array_elements(t->'orders') x where x->>'po_number' = 'PO-A') = 3, 'tracker: 3 parts of PO-A followed');
  o := (select x from jsonb_array_elements(t->'orders') x where (x->>'part')::int = 2);
  perform pg_temp.ok(o->>'state' = 'factory' and o->>'last_source' = 'middle' and o->>'split_mode' = 'later'
                     and o->'lines_moved'->0->>'description' = 'Breast' and o->>'due_date' = '2026-11-21',
                     'tracker part 2: produced at the factory, by the middle office, Breast, due 21');
  o := (select x from jsonb_array_elements(t->'orders') x where (x->>'part')::int = 3);
  perform pg_temp.ok(o->>'state' = 'waiting' and o->>'last_source' = 'middle', 'tracker part 3: waiting for production, by the middle office');
  perform pg_temp.ok((select count(*) from jsonb_array_elements(public.postponed_order_timeline((o->>'paper_id')::uuid, null)->'events') e
                      where e->>'kind' = 'moved' and e->>'split_mode' = 'production' and e->'lines'->0->>'description' = 'Thigh') = 1,
                     'timeline: the move names the product');
end $$;
reset role;
do $$ declare b jsonb; begin
  perform set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000d1"}', false);
  b := public.delivery_board('2026-11-21');
  perform pg_temp.ok(exists (select 1 from jsonb_each(b) k, jsonb_array_elements(case jsonb_typeof(k.value) when 'array' then k.value else '[]'::jsonb end) x
                             where x->>'po_number' = 'PO-A' and (x->>'part')::int = 2), 'delivery board 21 Nov: PO-A part 2');
end $$;

-- Production links the filled paper of part 3: the shared photo stays
insert into public.weighing_papers (id, work_date, photo_path, status, company, po_number, customer_name, delivery_date) values
 ('40000000-0000-0000-0000-0000000000c3', '2026-11-20', 'c.jpg', 'read', 'Prosun Farm', 'PO-A', 'Bangkok Air', '2026-11-21');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f1'); set role authenticated;
do $$ declare part3 uuid; ret text; begin
  select id into part3 from public.weighing_papers where split_part = 3;
  ret := public.weighing_link_postponed(part3, '40000000-0000-0000-0000-0000000000c3');
  perform pg_temp.ok(ret is null, 'link: the original''s photo is not deleted');
end $$;
reset role;
do $$ begin
  perform pg_temp.ok((select split_part = 3 and split_from = '40000000-0000-0000-0000-00000000000a'
                      from public.weighing_papers where id = '40000000-0000-0000-0000-0000000000c3'), 'the filled paper is part 3');
  perform pg_temp.ok((select count(*) from public.weighing_postponements where paper_id = '40000000-0000-0000-0000-0000000000c3' and split_mode = 'production') = 1,
                     'its history moved with it');
end $$;
\echo 'test_040: all checks passed'
