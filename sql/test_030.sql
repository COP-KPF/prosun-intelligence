-- Migration 030 — invoice marks. Run on a replica after 030 (psql -f).
\set ON_ERROR_STOP 1
\pset tuples_only on
insert into auth.users (id, email) values
 ('00000000-0000-0000-0000-0000000000a1','admin@x'),('00000000-0000-0000-0000-0000000000d1','deliv@x'),
 ('00000000-0000-0000-0000-0000000000b1','ss@x'),('00000000-0000-0000-0000-0000000000c1','acc@x'),
 ('00000000-0000-0000-0000-0000000000f1','muay@x'),('00000000-0000-0000-0000-0000000000e1','eye@x') on conflict do nothing;
insert into public.profiles (id, full_name, role) values
 ('00000000-0000-0000-0000-0000000000a1','Clément','admin'),('00000000-0000-0000-0000-0000000000d1','Khun Driver','delivery'),
 ('00000000-0000-0000-0000-0000000000b1','Jane','sale_support'),('00000000-0000-0000-0000-0000000000c1','Ann','accounting'),
 ('00000000-0000-0000-0000-0000000000f1','Muay','factory_admin'),('00000000-0000-0000-0000-0000000000e1','Eye','purchasing')
on conflict (id) do update set role = excluded.role, full_name = excluded.full_name;
insert into public.weighing_papers (id, work_date, photo_path, status, company, po_number, customer_name, delivery_date) values
 ('30000000-0000-0000-0000-00000000000a', '2026-11-13', 'a.jpg', 'read', 'Prosun Farm', 'PO-A', 'Ledu', '2026-11-14'),
 ('30000000-0000-0000-0000-00000000000b', '2026-11-13', 'b.jpg', 'read', 'Prosun Food', 'PO-B', 'Sloane', '2026-11-14');
insert into public.weighing_lines (paper_id, line_no, description, ordered_text, ordered_qty, ordered_unit, actual_kg) values
 ('30000000-0000-0000-0000-00000000000a', 1, 'Breast', '5 Kg', 5, 'kg', 5.2),
 ('30000000-0000-0000-0000-00000000000b', 1, 'Leg', '3 Kg', 3, 'kg', 3.1);
update public.weighing_papers set status = 'confirmed', confirmed_at = now() - interval '1 hour' where id = '30000000-0000-0000-0000-00000000000a';

create or replace function pg_temp.as_user(u text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', u)::text, false); end $$;
create or replace function pg_temp.ok(cond boolean, label text) returns void language plpgsql as $$
begin if cond then raise notice 'PASS %', label; else raise exception 'FAIL %', label; end if; end $$;

-- accounting marks A invoiced
select pg_temp.as_user('00000000-0000-0000-0000-0000000000c1'); set role authenticated;
do $$ declare r jsonb; begin
  r := public.weighing_mark_invoiced('30000000-0000-0000-0000-00000000000a', true, ' INV/2026/01234 ');
  perform pg_temp.ok(r->>'invoice_no' = 'INV/2026/01234' and r->>'invoiced_by_name' = 'Ann', 'accounting marks invoiced (number trimmed)');
  begin perform public.weighing_mark_invoiced('30000000-0000-0000-0000-00000000000b', true, null); raise exception 'FAIL unconfirmed';
  exception when sqlstate '22023' then perform pg_temp.ok(true, 'paper not confirmed cannot be invoiced'); end;
  r := public.weighing_mark_invoiced('30000000-0000-0000-0000-00000000000a', true, null);
  perform pg_temp.ok(r->'invoice_no' = 'null'::jsonb, 'remark without number (same row)');
  r := public.weighing_mark_invoiced('30000000-0000-0000-0000-00000000000a', true, 'INV/2026/01234');
  perform pg_temp.ok((select count(*) from public.weighing_invoice_marks(array['30000000-0000-0000-0000-00000000000a'::uuid, '30000000-0000-0000-0000-00000000000b'::uuid])) = 1, 'marks: one row');
  begin perform 1 from public.weighing_invoices; raise exception 'FAIL direct read';
  exception when insufficient_privilege then perform pg_temp.ok(true, 'no direct table access'); end;
end $$;
reset role;

-- delivery reads it on the board; cannot mark
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d1'); set role authenticated;
do $$ declare b jsonb := public.delivery_board('2026-11-14'); begin
  perform pg_temp.ok((select x->'invoice'->>'invoice_no' from jsonb_array_elements(b->'papers') x where x->>'po_number' = 'PO-A') = 'INV/2026/01234', 'board shows invoice number');
  perform pg_temp.ok((select (x->'invoice'->>'changed')::boolean from jsonb_array_elements(b->'papers') x where x->>'po_number' = 'PO-A') = false, 'not changed');
  perform pg_temp.ok((select x->'invoice' from jsonb_array_elements(b->'papers') x where x->>'po_number' = 'PO-B') = 'null'::jsonb, 'B: no invoice');
  perform pg_temp.ok((select count(*) from public.weighing_invoice_marks(array['30000000-0000-0000-0000-00000000000a'::uuid])) = 1, 'delivery reads marks');
  begin perform public.weighing_mark_invoiced('30000000-0000-0000-0000-00000000000b', true, null); raise exception 'FAIL delivery marked';
  exception when insufficient_privilege then perform pg_temp.ok(true, 'delivery cannot mark invoiced'); end;
end $$;
reset role;
-- sale support / purchasing read, cannot mark
select pg_temp.as_user('00000000-0000-0000-0000-0000000000e1'); set role authenticated;
do $$ begin
  perform pg_temp.ok((select count(*) from public.weighing_invoice_marks(array['30000000-0000-0000-0000-00000000000a'::uuid])) = 1, 'purchasing reads marks');
  begin perform public.weighing_mark_invoiced('30000000-0000-0000-0000-00000000000a', false); raise exception 'FAIL purchasing unmarked';
  exception when insufficient_privilege then perform pg_temp.ok(true, 'purchasing cannot unmark'); end;
end $$;
reset role;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f1'); set role authenticated;
do $$ begin
  begin perform public.weighing_invoice_marks(array['30000000-0000-0000-0000-00000000000a'::uuid]); raise exception 'FAIL factory read';
  exception when insufficient_privilege then perform pg_temp.ok(true, 'factory admin refused'); end;
end $$;
reset role;

-- factory reopens and re-confirms → changed + bell for accounting
update public.weighing_papers set status = 'read' where id = '30000000-0000-0000-0000-00000000000a';
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d1'); set role authenticated;
do $$ begin
  perform pg_temp.ok((select changed from public.weighing_invoice_marks(array['30000000-0000-0000-0000-00000000000a'::uuid])), 'reopened → changed');
end $$;
reset role;
update public.weighing_lines set actual_kg = 5.4 where paper_id = '30000000-0000-0000-0000-00000000000a';
update public.weighing_papers set status = 'confirmed', confirmed_at = now() where id = '30000000-0000-0000-0000-00000000000a';
do $$ begin
  perform pg_temp.ok((select count(*) from public.notifications where kind = 'invoice_weights_changed'
     and recipient = '00000000-0000-0000-0000-0000000000c1' and body like '%INV/2026/01234%') = 1, 'accounting bell on re-confirm');
end $$;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000c1'); set role authenticated;
do $$ begin
  perform pg_temp.ok((select changed from public.weighing_invoice_marks(array['30000000-0000-0000-0000-00000000000a'::uuid])), 're-confirmed → still changed');
  perform public.weighing_mark_invoiced('30000000-0000-0000-0000-00000000000a', true, 'INV/2026/01299');
  perform pg_temp.ok(not (select changed from public.weighing_invoice_marks(array['30000000-0000-0000-0000-00000000000a'::uuid])), 're-marked → no longer changed');
  perform public.weighing_mark_invoiced('30000000-0000-0000-0000-00000000000a', false);
  perform pg_temp.ok((select count(*) from public.weighing_invoice_marks(array['30000000-0000-0000-0000-00000000000a'::uuid])) = 0, 'unmark');
end $$;
reset role;
do $$ begin
  perform pg_temp.ok((select count(*) from public.activity_log where table_name = 'weighing_invoices') >= 5, 'changes logged');
end $$;
-- admin can mark
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1'); set role authenticated;
do $$ begin perform public.weighing_mark_invoiced('30000000-0000-0000-0000-00000000000a', true, null); perform pg_temp.ok(true, 'admin can mark'); end $$;
reset role;
-- the 029 delivery tests still pass on the new delivery_board (run separately)
