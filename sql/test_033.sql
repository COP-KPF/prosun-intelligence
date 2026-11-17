-- Migration 033 — pick-up / dispatch flow. Run on a replica after 033 (psql -f).
-- Dates assume the migration ran on 17 Nov 2026 (delivery_from) and today is 17 Nov
-- or a day or two later; shift them if re-run much later.
\set ON_ERROR_STOP 1
\pset tuples_only on
insert into auth.users (id, email) values
 ('00000000-0000-0000-0000-0000000000a1','admin@x'),('00000000-0000-0000-0000-0000000000d1','deliv@x'),
 ('00000000-0000-0000-0000-0000000000b1','ss@x'),('00000000-0000-0000-0000-0000000000c1','acc@x'),
 ('00000000-0000-0000-0000-0000000000e9','julien@x') on conflict do nothing;
insert into public.profiles (id, full_name, role) values
 ('00000000-0000-0000-0000-0000000000a1','Clément','admin'),('00000000-0000-0000-0000-0000000000d1','Khun Driver','delivery'),
 ('00000000-0000-0000-0000-0000000000b1','Jane','sale_support'),('00000000-0000-0000-0000-0000000000c1','Ann','accounting')
on conflict (id) do update set role = excluded.role, full_name = excluded.full_name;
insert into public.profiles (id, full_name, role, company_scope) values
 ('00000000-0000-0000-0000-0000000000e9','Chef Julien','company_director','Prosun Food')
on conflict (id) do update set role = excluded.role, full_name = excluded.full_name, company_scope = excluded.company_scope;
update public.management_settings set delivery_from = '2026-11-17' where id = 1;

insert into public.weighing_papers (id, work_date, photo_path, status, company, po_number, customer_name, delivery_date) values
 ('33000000-0000-0000-0000-00000000000a', '2026-11-17', 'a.jpg', 'read', 'Prosun Farm', 'PO-A', 'Ledu',    '2026-11-18'),
 ('33000000-0000-0000-0000-00000000000b', '2026-11-17', 'b.jpg', 'read', 'Prosun Food', 'PO-B', 'Sloane',  '2026-11-19'),
 ('33000000-0000-0000-0000-00000000000c', '2026-11-17', 'c.jpg', 'read', 'Prosun Farm', 'PO-C', 'Marco',   '2026-11-18'),
 ('33000000-0000-0000-0000-00000000000d', '2026-11-14', 'd.jpg', 'read', 'Prosun Farm', 'PO-D', 'Old one', '2026-11-16'),
 ('33000000-0000-0000-0000-00000000000e', '2026-11-17', 'e.jpg', 'read', 'Prosun Food', 'PO-E', 'Gaggan',  '2026-11-17');
insert into public.weighing_lines (paper_id, line_no, description, ordered_text, ordered_qty, ordered_unit, actual_kg)
select id, 1, 'Breast', '5 Kg', 5, 'kg', 5.2 from public.weighing_papers where po_number in ('PO-A','PO-B','PO-C','PO-D','PO-E');
update public.weighing_papers set status = 'confirmed', confirmed_at = now() where po_number in ('PO-A','PO-B','PO-D','PO-E');

create or replace function pg_temp.as_user(u text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', u)::text, false); end $$;
create or replace function pg_temp.ok(cond boolean, label text) returns void language plpgsql as $$
begin if cond then raise notice 'PASS %', label; else raise exception 'FAIL %', label; end if; end $$;
create or replace function pg_temp.pos(b jsonb) returns text language sql as $$
  select string_agg(x->>'po_number', ',' order by ord) from jsonb_array_elements(b->'pickups') with ordinality t(x, ord) $$;
create or replace function pg_temp.mk(b jsonb, po text, key text) returns text language sql as $$
  select x->'mark'->>key from jsonb_array_elements(b->'papers') x where x->>'po_number' = po $$;

select pg_temp.as_user('00000000-0000-0000-0000-0000000000d1'); set role authenticated;
do $$ declare b jsonb := public.delivery_board('2026-11-18'); begin
  perform pg_temp.ok(pg_temp.pos(b) = 'PO-E,PO-A,PO-B', 'pickups: finished orders of every day, by due date (E 17, A 18, B 19): ' || coalesce(pg_temp.pos(b), '-'));
  perform pg_temp.ok(b->>'delivery_from' = '2026-11-17', 'delivery_from returned');
  perform pg_temp.ok(jsonb_array_length(b->'papers') = 2, 'papers due 18: A and C');
end $$;
do $$ begin
  begin perform public.delivery_mark('33000000-0000-0000-0000-00000000000c', 'dispatch'); raise exception 'FAIL unfinished picked up';
  exception when sqlstate '22023' then perform pg_temp.ok(true, 'unfinished order cannot be picked up'); end;
  perform pg_temp.ok(public.delivery_mark_many(array['33000000-0000-0000-0000-00000000000a','33000000-0000-0000-0000-00000000000b']::uuid[], 'dispatch') = 2, 'pick up all: 2 marked');
  perform pg_temp.ok(pg_temp.pos(public.delivery_board('2026-11-18')) = 'PO-E', 'pickups now only E');
  perform pg_temp.ok(pg_temp.mk(public.delivery_board('2026-11-18'), 'PO-A', 'status') = 'dispatch', 'A at the dispatch center');
  begin perform public.delivery_mark_many(array['33000000-0000-0000-0000-00000000000e','33000000-0000-0000-0000-00000000000c']::uuid[], 'dispatch');
        raise exception 'FAIL partial batch';
  exception when sqlstate '22023' then null; end;
  perform pg_temp.ok(pg_temp.pos(public.delivery_board('2026-11-18')) = 'PO-E', 'batch with an unfinished order: nothing marked (E still waiting)');
  begin perform public.delivery_mark_many(array['33000000-0000-0000-0000-00000000000e']::uuid[], 'problem'); raise exception 'FAIL batch problem';
  exception when sqlstate '22023' then perform pg_temp.ok(true, 'batch problem refused (needs a comment each)'); end;
end $$;
reset role;

-- A postponed after pick-up: shows at the dispatch center on its new day, not back at the factory
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b1'); set role authenticated;
select (public.weighing_postpone_delivery('33000000-0000-0000-0000-00000000000a', '2026-11-20', 'client', null)).id is not null;
reset role;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d1'); set role authenticated;
do $$ declare b jsonb := public.delivery_board('2026-11-20'); begin
  perform pg_temp.ok(pg_temp.mk(b, 'PO-A', 'status') = 'dispatch' and pg_temp.mk(b, 'PO-A', 'carried') = 'true', 'postponed after pick-up: at dispatch on the new day (carried)');
  perform pg_temp.ok(position('PO-A' in coalesce(pg_temp.pos(b), '')) = 0, 'and not back in the pick-up list');
  perform public.delivery_mark('33000000-0000-0000-0000-00000000000a', 'out');
  b := public.delivery_board('2026-11-20');
  perform pg_temp.ok(pg_temp.mk(b, 'PO-A', 'status') = 'out' and pg_temp.mk(b, 'PO-A', 'carried') = 'false', 'out on the new day');
end $$;
reset role;
-- B out, then postponed: back at dispatch on its new day
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d1'); set role authenticated;
do $$ begin perform public.delivery_mark('33000000-0000-0000-0000-00000000000b', 'out'); end $$;
reset role;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b1'); set role authenticated;
select (public.weighing_postpone_delivery('33000000-0000-0000-0000-00000000000b', '2026-11-21', 'delivery', null)).id is not null;
reset role;
-- the factory reopens B's paper: it can still move on (already picked up)
update public.weighing_papers set status = 'read' where id = '33000000-0000-0000-0000-00000000000b';
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d1'); set role authenticated;
do $$ declare b jsonb := public.delivery_board('2026-11-21'); begin
  perform pg_temp.ok(pg_temp.mk(b, 'PO-B', 'status') = 'dispatch', 'out then postponed: at dispatch on the new day');
  perform public.delivery_mark('33000000-0000-0000-0000-00000000000b', 'out');
  perform pg_temp.ok(pg_temp.mk(public.delivery_board('2026-11-21'), 'PO-B', 'status') = 'out', 'reopened paper already picked up can still go out');
  perform public.delivery_mark('33000000-0000-0000-0000-00000000000b', 'dispatch');
  perform pg_temp.ok(pg_temp.mk(public.delivery_board('2026-11-21'), 'PO-B', 'status') = 'dispatch', 'step back to dispatch');
  perform public.delivery_mark('33000000-0000-0000-0000-00000000000b', null);
  perform pg_temp.ok(pg_temp.mk(public.delivery_board('2026-11-21'), 'PO-B', 'status') is null, 'undo pick-up');
  -- B is not confirmed any more → not in the pick-up list, and cannot be picked up again
  perform pg_temp.ok(position('PO-B' in coalesce(pg_temp.pos(public.delivery_board('2026-11-21')), '')) = 0, 'reopened paper not in pick-ups');
end $$;
reset role;

-- company director: his company only, cannot mark
select pg_temp.as_user('00000000-0000-0000-0000-0000000000e9'); set role authenticated;
do $$ declare b jsonb := public.delivery_board('2026-11-18'); begin
  perform pg_temp.ok(pg_temp.pos(b) = 'PO-E', 'company director: Prosun Food pick-ups only');
  perform pg_temp.ok(not (b->>'can_mark')::boolean, 'company director: no marks');
  begin perform public.delivery_mark_many(array['33000000-0000-0000-0000-00000000000e']::uuid[], 'dispatch'); raise exception 'FAIL director marked';
  exception when insufficient_privilege then perform pg_temp.ok(true, 'company director cannot pick up'); end;
end $$;
reset role;
-- others refused / read-only
select pg_temp.as_user('00000000-0000-0000-0000-0000000000c1'); set role authenticated;
do $$ begin
  begin perform public.delivery_board('2026-11-18'); raise exception 'FAIL accounting';
  exception when insufficient_privilege then perform pg_temp.ok(true, 'accounting refused the board'); end;
end $$;
reset role;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b1'); set role authenticated;
do $$ begin
  perform pg_temp.ok(pg_temp.pos(public.delivery_board('2026-11-18')) = 'PO-E', 'middle office reads pick-ups');
  begin perform public.delivery_mark_many(array['33000000-0000-0000-0000-00000000000e']::uuid[], 'dispatch'); raise exception 'FAIL ss';
  exception when insufficient_privilege then perform pg_temp.ok(true, 'middle office cannot pick up'); end;
  begin perform public.delivery_paper_json(p) from public.weighing_papers p limit 1; raise exception 'FAIL helper';
  exception when insufficient_privilege then perform pg_temp.ok(true, 'helper not callable directly'); end;
end $$;
reset role;
-- an older paper (before delivery_from) never shows; moving delivery_from back brings it
do $$ begin
  update public.management_settings set delivery_from = '2026-11-15' where id = 1;
  perform set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000d1"}', true);
end $$;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d1'); set role authenticated;
do $$ begin perform pg_temp.ok(position('PO-D' in pg_temp.pos(public.delivery_board('2026-11-18'))) = 1, 'delivery_from earlier → older finished order listed first (late)'); end $$;
reset role;
update public.management_settings set delivery_from = '2026-11-17' where id = 1;
