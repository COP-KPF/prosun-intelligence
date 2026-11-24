-- Migration 046 — Purchases. Run on a replica after 045 + 046 (psql -f), then
-- run 046 once more so the access list picks up the test accounts.
\set ON_ERROR_STOP 1
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000046a1', 'clement@klongphaifarm.com'),
  ('00000000-0000-0000-0000-0000000046b1', 'orawan@klongphaifarm.com'),
  ('00000000-0000-0000-0000-0000000046a2', 'kirana@klongphaifarm.com'),
  ('00000000-0000-0000-0000-0000000046c1', 'jane@klongphaifarm.com')
on conflict do nothing;
insert into public.profiles (id, full_name, role) values
  ('00000000-0000-0000-0000-0000000046a1', 'Clément', 'admin'),
  ('00000000-0000-0000-0000-0000000046b1', 'Orawan', 'purchasing'),
  ('00000000-0000-0000-0000-0000000046a2', 'Kirana', 'admin'),
  ('00000000-0000-0000-0000-0000000046c1', 'Jane', 'sale_support')
on conflict (id) do update set role = excluded.role, full_name = excluded.full_name;
\i sql/migrations/046_purchases.sql

create or replace function pg_temp.ok(cond boolean, label text) returns void language plpgsql as $$
begin if coalesce(cond, false) then raise notice 'PASS %', label; else raise exception 'FAIL %', label; end if; end $$;
create or replace function pg_temp.as_user(uid text) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid)::text, false) $$;

-- a confirmed working paper on Wednesday 25 Nov (production day of the Wed arrival)
insert into public.weighing_papers (id, work_date, photo_path, status, company, po_number, customer_name, delivery_date) values
 ('46000000-0000-0000-0000-000000000001', '2026-11-25', 'a', 'read', 'Prosun Farm', 'PO-46', 'Test Bistro 46', '2026-11-26'),
 ('46000000-0000-0000-0000-000000000002', '2026-11-25', 'b', 'read', 'Prosun Food', 'PO-46F', 'Test Food 46', '2026-11-26')
on conflict do nothing;
insert into public.weighing_lines (paper_id, line_no, description, ordered_text, ordered_qty, ordered_unit, actual_kg) values
 ('46000000-0000-0000-0000-000000000001', 1, 'Chicken breast Red Label', '20 Kg', 20, 'kg', 20),
 ('46000000-0000-0000-0000-000000000001', 2, 'Duck confit', '5 Kg', 5, 'kg', 5),
 ('46000000-0000-0000-0000-000000000002', 1, 'Chicken breast Red Label', '10 Kg', 10, 'kg', 10)
on conflict do nothing;
update public.weighing_papers set status = 'confirmed' where id::text like '46000000-%';

do $$
declare
  v_id uuid; b jsonb; o jsonb; r jsonb; v_ts text; v_red uuid; v_duck uuid; v_eggs uuid; v_l1 uuid; v_l2 uuid;
  n int; v_rev numeric;
begin
  select id into v_red  from public.purchase_items where name = 'Red Label chicken';
  select id into v_duck from public.purchase_items where name = 'Duck Barbary male';
  select id into v_eggs from public.purchase_items where name = 'Eggs';
  perform pg_temp.ok((select count(*) from public.purchase_access) = 2, 'access list = Clément + Orawan only');

  -- not on the list: refused, whatever the role
  foreach v_ts in array array['00000000-0000-0000-0000-0000000046a2', '00000000-0000-0000-0000-0000000046c1'] loop
    perform pg_temp.as_user(v_ts);
    begin
      perform public.purchase_board('2026-11-23', '2026-11-29');
      raise exception 'FAIL board open to %', v_ts;
    exception when insufficient_privilege then perform pg_temp.ok(true, 'board refused for ' || v_ts); end;
    begin
      perform public.purchase_ratio('2026-11-01', '2026-11-30', 'Prosun Farm');
      raise exception 'FAIL ratio open to %', v_ts;
    exception when insufficient_privilege then perform pg_temp.ok(true, 'ratio refused for ' || v_ts); end;
  end loop;

  -- Orawan enters Monday's order
  perform pg_temp.as_user('00000000-0000-0000-0000-0000000046b1');
  begin
    perform public.purchase_save_order('{"order_date":"2026-11-23","arrival_date":"2026-11-25","supplier":"","lines":[]}');
    raise exception 'FAIL empty order saved';
  exception when sqlstate '22023' then perform pg_temp.ok(sqlerrm ~ 'supplier', 'supplier required'); end;
  begin
    perform public.purchase_save_order('{"order_date":"2026-11-23","arrival_date":"2026-11-22","supplier":"Farm A","lines":[{"item_id":"x"}]}');
    raise exception 'FAIL arrival before order';
  exception when sqlstate '22023' then perform pg_temp.ok(sqlerrm ~ 'before the order', 'arrival before order refused'); end;

  v_id := public.purchase_save_order(jsonb_build_object(
    'order_date', '2026-11-23', 'arrival_date', '2026-11-25', 'supplier', 'Farm A', 'ref', 'PO-F-1',
    'lines', jsonb_build_array(
      jsonb_build_object('item_id', v_red, 'size_band', '1.4-1.6', 'ordered_qty', 300, 'ordered_kg', 450, 'price', 85, 'price_per', 'kg'),
      jsonb_build_object('item_id', v_duck, 'ordered_qty', 40, 'price', 420, 'price_per', 'unit'))));
  b := public.purchase_board('2026-11-23', '2026-11-29');
  o := b->'orders'->0;
  perform pg_temp.ok(jsonb_array_length(b->'orders') = 1 and o->>'status' = 'ordered' and o->>'created_by' = 'Orawan', 'order saved, status ordered, by Orawan');
  perform pg_temp.ok(jsonb_array_length(o->'lines') = 2, 'two lines');
  perform pg_temp.ok((o->'lines'->0->>'cost')::numeric = 38250 and (o->'lines'->1->>'cost')::numeric = 16800,
                     'estimated cost: 450 kg × 85 and 40 × 420');
  perform pg_temp.ok(b->'suppliers' ? 'Farm A' and jsonb_array_length(b->'items') >= 15, 'suppliers and items returned');
  v_l1 := (o->'lines'->0->>'id')::uuid; v_l2 := (o->'lines'->1->>'id')::uuid;

  -- arrival: a line left empty is refused
  begin
    perform public.purchase_record_arrival(jsonb_build_object('id', v_id, 'arrived_on', '2026-11-25',
      'lines', jsonb_build_array(jsonb_build_object('id', v_l1, 'received_qty', 270, 'received_kg', 405.5))));
    raise exception 'FAIL arrival with an empty line';
  exception when sqlstate '22023' then perform pg_temp.ok(sqlerrm ~ 'every line', 'every line must say what arrived'); end;
  perform pg_temp.ok((select status from public.purchase_orders where id = v_id) = 'ordered', 'refused arrival changed nothing');

  -- stale screen
  begin
    perform public.purchase_record_arrival(jsonb_build_object('id', v_id, 'arrived_on', '2026-11-25', 'updated_at', '2020-01-01T00:00:00Z',
      'lines', jsonb_build_array(jsonb_build_object('id', v_l1, 'received_qty', 1), jsonb_build_object('id', v_l2, 'received_qty', 1))));
    raise exception 'FAIL stale arrival';
  exception when sqlstate '40001' then perform pg_temp.ok(true, 'stale screen refused'); end;

  perform public.purchase_record_arrival(jsonb_build_object('id', v_id, 'arrived_on', '2026-11-25', 'freight_thb', 1500,
    'updated_at', (select updated_at from public.purchase_orders where id = v_id),
    'lines', jsonb_build_array(
      jsonb_build_object('id', v_l1, 'received_qty', 270, 'received_kg', 405.5, 'rejected_qty', 3),
      jsonb_build_object('id', v_l2, 'received_qty', 40))));
  o := public.purchase_board('2026-11-23', '2026-11-29')->'orders'->0;
  perform pg_temp.ok(o->>'status' = 'received' and o->>'received_by' = 'Orawan' and (o->>'freight_thb')::numeric = 1500, 'arrival recorded');
  perform pg_temp.ok((o->'lines'->0->>'cost')::numeric = 34467.5, 'cost after arrival: 405.5 kg × 85 (rejected birds not paid)');

  -- Clément edits the order: duck line removed, eggs added; Red Label arrival kept
  perform pg_temp.as_user('00000000-0000-0000-0000-0000000046a1');
  perform public.purchase_save_order(jsonb_build_object('id', v_id,
    'order_date', '2026-11-23', 'arrival_date', '2026-11-25', 'supplier', 'Farm A',
    'updated_at', (select updated_at from public.purchase_orders where id = v_id),
    'lines', jsonb_build_array(
      jsonb_build_object('id', v_l1, 'item_id', v_red, 'size_band', '1.4-1.6', 'ordered_qty', 300, 'ordered_kg', 450, 'price', 86, 'price_per', 'kg'),
      jsonb_build_object('item_id', v_eggs, 'ordered_qty', 300, 'price', 6, 'price_per', 'unit'))));
  perform pg_temp.ok((select count(*) from public.purchase_order_lines where order_id = v_id) = 2, 'line removed, line added');
  perform pg_temp.ok((select received_kg from public.purchase_order_lines where id = v_l1) = 405.5, 'arrival figures kept on an edited line');
  perform pg_temp.ok((select status from public.purchase_orders where id = v_id) = 'ordered', 'a new line without arrival reopens the arrival');
  perform public.purchase_record_arrival(jsonb_build_object('id', v_id, 'arrived_on', '2026-11-25', 'freight_thb', 1500,
    'lines', jsonb_build_array(
      jsonb_build_object('id', v_l1, 'received_qty', 270, 'received_kg', 405.5, 'rejected_qty', 3),
      jsonb_build_object('id', (select id from public.purchase_order_lines where order_id = v_id and item_id = v_eggs), 'received_qty', 0))));
  perform pg_temp.ok((select cost from public.purchase_line_costs where line_id = v_l1) = 34873, 'new price × received kg');

  -- writing straight to the tables is impossible
  perform set_config('role', 'authenticated', true);
  begin
    insert into public.purchase_orders (order_date, arrival_date, supplier) values ('2026-11-23', '2026-11-25', 'x');
    raise exception 'FAIL direct insert';
  exception when insufficient_privilege then perform pg_temp.ok(true, 'no direct insert'); end;
  begin
    update public.purchase_order_lines set price = 1;
    raise exception 'FAIL direct update';
  exception when insufficient_privilege then perform pg_temp.ok(true, 'no direct update'); end;
  perform pg_temp.ok((select count(*) from public.purchase_orders) = 1, 'Clément reads the orders');
  perform pg_temp.as_user('00000000-0000-0000-0000-0000000046a2');
  perform pg_temp.ok((select count(*) from public.purchase_orders) = 0 and (select count(*) from public.purchase_line_costs) = 0,
                     'Kirana (admin, not on the list) reads nothing');
  perform set_config('role', 'anon', true);
  begin
    perform count(*) from public.purchase_orders;
    raise exception 'FAIL anon read';
  exception when insufficient_privilege then perform pg_temp.ok(true, 'anon cannot read'); end;
  perform set_config('role', 'postgres', true);

  -- ratio
  perform pg_temp.as_user('00000000-0000-0000-0000-0000000046a1');
  -- an open order for Friday, a cancelled one, a Food order
  perform public.purchase_save_order(jsonb_build_object('order_date', '2026-11-25', 'arrival_date', '2026-11-27', 'supplier', 'Farm A',
    'lines', jsonb_build_array(jsonb_build_object('item_id', v_red, 'ordered_qty', 100, 'ordered_kg', 150, 'price', 85, 'price_per', 'kg'))));
  v_id := public.purchase_save_order(jsonb_build_object('order_date', '2026-11-25', 'arrival_date', '2026-11-27', 'supplier', 'Farm B',
    'lines', jsonb_build_array(jsonb_build_object('item_id', v_red, 'ordered_qty', 999, 'price', 999, 'price_per', 'unit'))));
  begin
    perform public.purchase_cancel_order(v_id, ' ');
    raise exception 'FAIL cancel without reason';
  exception when sqlstate '22023' then perform pg_temp.ok(true, 'cancel needs a reason'); end;
  perform public.purchase_cancel_order(v_id, 'Farm B had no birds');
  perform public.purchase_save_order(jsonb_build_object('order_date', '2026-11-23', 'arrival_date', '2026-11-25', 'supplier', 'Spice shop',
    'company', 'Prosun Food', 'lines', jsonb_build_array(jsonb_build_object('item_id', v_eggs, 'ordered_qty', 10, 'price', 5, 'price_per', 'unit'))));

  r := public.purchase_ratio('2026-11-01', '2026-11-30', 'Prosun Farm');
  perform pg_temp.ok(jsonb_array_length(r->'revenue') = 1 and r->'revenue'->0->>0 = '2026-11-25', 'Farm revenue: one production day');
  v_rev := (r->'revenue'->0->>2)::numeric;
  perform pg_temp.ok(v_rev > 0 and (r->'revenue'->0->>3)::numeric = 25 and (r->'revenue'->0->>4)::numeric = 20,
                     'revenue priced for the breast only (confit is never priced): kg 25, priced 20');
  perform pg_temp.ok(v_rev = (select (public.management_orders('2026-11-25', '2026-11-25', 'Prosun Farm', 'production')->'lines'->0->>9)::numeric
                              + coalesce((public.management_orders('2026-11-25', '2026-11-25', 'Prosun Farm', 'production')->'lines'->1->>9)::numeric, 0)),
                     'same revenue as Management › Summary › Orders');
  n := jsonb_array_length(r->'purchases');
  perform pg_temp.ok(n = 2, 'two arrival days (cancelled order left out)');
  perform pg_temp.ok(r->>'first_purchase' = '2026-11-25' and r->>'from_effective' = '2026-11-25', 'ratio starts with the first purchase entered');
  perform pg_temp.ok((r->'purchases'->0->>2)::numeric = 34873 and (r->'purchases'->0->>3)::numeric = 1500
                     and (r->'purchases'->0->>4)::boolean = false, 'Wed: goods 34,873 + freight 1,500, not an estimate');
  perform pg_temp.ok((r->'purchases'->0->>5)::numeric = 300 and (r->'purchases'->0->>6)::numeric = 270, 'Wed: 300 birds ordered, 270 received');
  perform pg_temp.ok((r->'purchases'->1->>2)::numeric = 12750 and (r->'purchases'->1->>4)::boolean = true, 'Fri: open order counted as an estimate (150 kg × 85)');
  r := public.purchase_ratio('2026-11-01', '2026-11-30', 'Prosun Food');
  perform pg_temp.ok(jsonb_array_length(r->'purchases') = 1 and (r->'purchases'->0->>2)::numeric = 50, 'Food: its own purchases only');
  r := public.purchase_ratio('2026-11-01', '2026-11-30', 'all');
  perform pg_temp.ok(jsonb_array_length(r->'revenue') = 2 and jsonb_array_length(r->'purchases') = 3, 'all companies');
  begin
    perform public.purchase_ratio('2025-01-01', '2026-11-30', 'Prosun Farm');
    raise exception 'FAIL long period';
  exception when sqlstate '22023' then perform pg_temp.ok(true, 'period limited to about a year'); end;

  perform pg_temp.ok((select count(*) from public.activity_log where table_name like 'purchase_%') >= 8, 'changes are in activity_log');
end $$;
