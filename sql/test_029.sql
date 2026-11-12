\set ON_ERROR_STOP 1
\pset tuples_only on
-- ---------- fixtures (as owner)
insert into auth.users (id, email) values
 ('00000000-0000-0000-0000-0000000000a1','admin@x'),('00000000-0000-0000-0000-0000000000d1','deliv@x'),
 ('00000000-0000-0000-0000-0000000000b1','ss@x'),('00000000-0000-0000-0000-0000000000c1','acc@x'),
 ('00000000-0000-0000-0000-0000000000f1','muay@x') on conflict do nothing;
insert into public.profiles (id, full_name, role) values
 ('00000000-0000-0000-0000-0000000000a1','Clément','admin'),('00000000-0000-0000-0000-0000000000d1','Khun Driver','delivery'),
 ('00000000-0000-0000-0000-0000000000b1','Jane','sale_support'),('00000000-0000-0000-0000-0000000000c1','Ann','accounting'),
 ('00000000-0000-0000-0000-0000000000f1','Muay','factory_admin')
on conflict (id) do update set role = excluded.role, full_name = excluded.full_name;

insert into public.weighing_papers (id, work_date, photo_path, status, company, po_number, customer_name, delivery_date) values
 ('10000000-0000-0000-0000-00000000000a', '2026-11-11', 'a.jpg', 'read', 'Prosun Farm', 'PO-A', 'Ledu', '2026-11-12'),
 ('10000000-0000-0000-0000-00000000000b', '2026-11-11', 'b.jpg', 'read', 'Prosun Food', 'PO-B', 'Sloane', '2026-11-12'),
 ('10000000-0000-0000-0000-00000000000c', '2026-11-11', 'c.jpg', 'read', 'Prosun Farm', 'PO-C', 'Marco', '2026-11-11'),
 ('10000000-0000-0000-0000-00000000000e', '2026-11-11', 'e.jpg', 'read', 'Prosun Farm', 'PO-E', 'Gourmet', '2026-11-12');
insert into public.weighing_lines (paper_id, line_no, description, ordered_text, ordered_qty, ordered_unit, actual_kg) values
 ('10000000-0000-0000-0000-00000000000a', 1, 'Breast อกไก่', '5 Kg', 5, 'kg', 5.2),
 ('10000000-0000-0000-0000-00000000000a', 2, 'Wing', '10 ตัว', 10, 'pcs', 1.1),
 ('10000000-0000-0000-0000-00000000000b', 1, 'Duck leg', '3 Kg', 3, 'kg', 3.05),
 ('10000000-0000-0000-0000-00000000000e', 1, 'Thigh', '2 Kg', 2, 'kg', 2.1);
update public.weighing_papers set status = 'confirmed' where id in ('10000000-0000-0000-0000-00000000000a','10000000-0000-0000-0000-00000000000e');

-- ---------- helpers
create or replace function pg_temp.as_user(u text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', u)::text, false); end $$;
create or replace function pg_temp.ok(cond boolean, label text) returns void language plpgsql as $$
begin if cond then raise notice 'PASS %', label; else raise exception 'FAIL %', label; end if; end $$;

-- Production postpones C (unproduced) from today to the 12th: production day 12, delivery 12
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f1'); set role authenticated;
select (public.weighing_postpone('10000000-0000-0000-0000-00000000000c', '2026-11-12', '2026-11-12', 'production', null)).id is not null;
-- Middle office postpones E's delivery from 12 → 14
reset role; select pg_temp.as_user('00000000-0000-0000-0000-0000000000b1'); set role authenticated;
select (public.weighing_postpone_delivery('10000000-0000-0000-0000-00000000000e', '2026-11-14', 'client', 'asked by chef')).id is not null;
insert into public.order_postponements (customer_name, po_number, original_date, new_date, reason, note)
values ('Paleo Robbie', 'PO-R', '2026-11-12', '2026-11-13', 'raw_material', 'birds short');
reset role;

-- ---------- 1. delivery reads the board for the 12th
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d1'); set role authenticated;
do $$ declare b jsonb := public.delivery_board('2026-11-12'); begin
  perform pg_temp.ok(jsonb_array_length(b->'papers') = 3, 'delivery: 3 papers due on the 12th (A, B, C)');
  perform pg_temp.ok((select count(*) from jsonb_array_elements(b->'papers') x where x->>'po_number' = 'PO-E') = 0, 'E moved away is not in papers');
  perform pg_temp.ok((select x->>'status' from jsonb_array_elements(b->'papers') x where x->>'po_number' = 'PO-C') = 'postponed', 'C is postponed-in (to produce)');
  perform pg_temp.ok((select x->>'moved_from' from jsonb_array_elements(b->'papers') x where x->>'po_number' = 'PO-C') = '2026-11-11', 'C shows moved from the 11th');
  perform pg_temp.ok((select jsonb_array_length(x->'lines') from jsonb_array_elements(b->'papers') x where x->>'po_number' = 'PO-A') = 2, 'A carries its 2 lines');
  perform pg_temp.ok(jsonb_array_length(b->'moved') = 1 and b->'moved'->0->>'po_number' = 'PO-E' and b->'moved'->0->>'new_date' = '2026-11-14', 'E listed as pushed to the 14th');
  perform pg_temp.ok(b->'moved'->0->'reason' = 'null'::jsonb and b->'moved'->0->'note' = 'null'::jsonb, 'delivery sees no reason/comment (moved)');
  perform pg_temp.ok(jsonb_array_length(b->'register') = 1 and b->'register'->0->'reason' = 'null'::jsonb, 'register row, no reason for delivery');
  perform pg_temp.ok((b->>'can_mark')::boolean and not (b->>'reasons_visible')::boolean, 'delivery can mark, no reasons');
end $$;
-- the 11th: C moved away by production
do $$ declare b jsonb := public.delivery_board('2026-11-11'); begin
  perform pg_temp.ok(jsonb_array_length(b->'papers') = 0 and jsonb_array_length(b->'moved') = 1
    and b->'moved'->0->>'po_number' = 'PO-C' and b->'moved'->0->>'paper_status' = 'postponed', 'the 11th: C pushed to the 12th by production');
end $$;
-- the 14th: E arrives with moved_from 12
do $$ declare b jsonb := public.delivery_board('2026-11-14'); begin
  perform pg_temp.ok(b->'papers'->0->>'po_number' = 'PO-E' and b->'papers'->0->>'moved_from' = '2026-11-12', 'the 14th: E with moved from the 12th');
end $$;

-- ---------- 2. marks
do $$ begin perform public.delivery_mark('10000000-0000-0000-0000-00000000000a', 'out'); end $$;
do $$ declare b jsonb := public.delivery_board('2026-11-12'); begin
  perform pg_temp.ok((select x->'mark'->>'status' from jsonb_array_elements(b->'papers') x where x->>'po_number' = 'PO-A') = 'out', 'A marked out');
  perform pg_temp.ok((select x->'mark'->>'by' from jsonb_array_elements(b->'papers') x where x->>'po_number' = 'PO-A') = 'Khun Driver', 'mark carries the name');
end $$;
do $$ begin perform public.delivery_mark('10000000-0000-0000-0000-00000000000a', 'delivered'); end $$;
do $$ begin perform pg_temp.ok((select x->'mark'->>'status' from jsonb_array_elements(public.delivery_board('2026-11-12')->'papers') x where x->>'po_number' = 'PO-A') = 'delivered', 'A delivered (same row updated)'); end $$;
-- B is produced but not confirmed: allowed
do $$ begin perform public.delivery_mark('10000000-0000-0000-0000-00000000000b', 'out'); perform pg_temp.ok(true, 'B (weights not confirmed) can go out'); end $$;
-- problem without a comment refused
do $$ begin
  begin perform public.delivery_mark('10000000-0000-0000-0000-00000000000b', 'problem', '  ');
        raise exception 'FAIL problem without comment accepted';
  exception when sqlstate '22023' then perform pg_temp.ok(true, 'problem without comment refused'); end;
end $$;
do $$ begin perform public.delivery_mark('10000000-0000-0000-0000-00000000000b', 'problem', 'Client closed, returned'); end $$;
-- C postponed (not produced) cannot be marked
do $$ begin
  begin perform public.delivery_mark('10000000-0000-0000-0000-00000000000c', 'out');
        raise exception 'FAIL postponed paper marked';
  exception when sqlstate '22023' then perform pg_temp.ok(true, 'not-produced paper cannot be marked'); end;
end $$;
-- no direct table access
do $$ begin
  begin perform 1 from public.delivery_marks limit 1; raise exception 'FAIL direct read of delivery_marks';
  exception when insufficient_privilege then perform pg_temp.ok(true, 'delivery cannot read delivery_marks directly'); end;
  begin insert into public.delivery_marks (paper_id, delivery_date, status) values ('10000000-0000-0000-0000-00000000000a', '2026-11-12', 'out');
        raise exception 'FAIL direct insert';
  exception when insufficient_privilege then perform pg_temp.ok(true, 'delivery cannot write delivery_marks directly'); end;
  perform pg_temp.ok((select count(*) from public.weighing_papers) = 0, 'delivery reads no weighing_papers directly');
  begin perform public.weighing_confirmed_lines('2026-11-12', '2026-11-12'); raise exception 'FAIL confirmed lines';
  exception when insufficient_privilege then perform pg_temp.ok(true, 'delivery refused Confirmed weights'); end;
end $$;
-- undo
do $$ begin perform public.delivery_mark('10000000-0000-0000-0000-00000000000a', null);
  perform pg_temp.ok((select x->'mark' from jsonb_array_elements(public.delivery_board('2026-11-12')->'papers') x where x->>'po_number' = 'PO-A') = 'null'::jsonb, 'undo clears the mark'); end $$;
reset role;

-- ---------- 3. admin bell for the problem
do $$ begin
  perform pg_temp.ok((select count(*) from public.notifications where kind = 'delivery_problem'
                      and recipient = '00000000-0000-0000-0000-0000000000a1' and body like '%returned%') = 1, 'admin notified of the problem');
  perform pg_temp.ok((select count(*) from public.activity_log where table_name = 'delivery_marks') >= 5, 'every mark logged in activity_log');
end $$;

-- ---------- 4. middle office: reads with reasons, cannot mark
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b1'); set role authenticated;
do $$ declare b jsonb := public.delivery_board('2026-11-12'); begin
  perform pg_temp.ok(b->'moved'->0->>'reason' = 'client' and b->'moved'->0->>'note' = 'asked by chef', 'sale support sees the reason and comment');
  perform pg_temp.ok(b->'register'->0->>'reason' = 'raw_material', 'sale support sees register reason');
  perform pg_temp.ok(not (b->>'can_mark')::boolean, 'sale support: can_mark false');
  begin perform public.delivery_mark('10000000-0000-0000-0000-00000000000b', 'delivered'); raise exception 'FAIL ss marked';
  exception when insufficient_privilege then perform pg_temp.ok(true, 'sale support cannot mark'); end;
end $$;
reset role;

-- ---------- 5. accounting refused; admin marks
select pg_temp.as_user('00000000-0000-0000-0000-0000000000c1'); set role authenticated;
do $$ begin
  begin perform public.delivery_board('2026-11-12'); raise exception 'FAIL accounting read board';
  exception when insufficient_privilege then perform pg_temp.ok(true, 'accounting refused the board'); end;
end $$;
reset role;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1'); set role authenticated;
do $$ begin perform public.delivery_mark('10000000-0000-0000-0000-00000000000a', 'out');
  perform pg_temp.ok(true, 'admin can mark'); end $$;
reset role;

-- ---------- 6. a mark does not follow a postponed delivery
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b1'); set role authenticated;
select (public.weighing_postpone_delivery('10000000-0000-0000-0000-00000000000a', '2026-11-13', 'delivery', null)).id is not null;
reset role;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d1'); set role authenticated;
do $$ declare b jsonb := public.delivery_board('2026-11-13'); begin
  perform pg_temp.ok((select x->'mark' from jsonb_array_elements(b->'papers') x where x->>'po_number' = 'PO-A') = 'null'::jsonb, 'old "out" mark does not carry to the new date');
  perform pg_temp.ok((select x->>'moved_from' from jsonb_array_elements(b->'papers') x where x->>'po_number' = 'PO-A') = '2026-11-12', 'A shows moved from the 12th');
end $$;
reset role;
-- ---------- 7. anon
set role anon;
do $$ begin
  begin perform public.delivery_board('2026-11-12'); raise exception 'FAIL anon';
  exception when insufficient_privilege then perform pg_temp.ok(true, 'anon refused'); end;
end $$;
reset role;
