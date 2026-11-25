-- Migration 049 — Special care cards and client file. Run on a replica after 043, 044, 049 (psql -f).
\set ON_ERROR_STOP 1
insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000a1','admin@x'),('00000000-0000-0000-0000-0000000000f1','prod@x') on conflict do nothing;
insert into public.profiles (id, full_name, role) values ('00000000-0000-0000-0000-0000000000a1','Clément','admin'),('00000000-0000-0000-0000-0000000000f1','Muay','production')
  on conflict (id) do update set role = excluded.role;
insert into public.sales_reps (code, short_name, full_name, login_hint) values ('91', 'Tess', 'Test Rep', 'tess') on conflict (code) do nothing;
insert into public.sales_customers (code, name, portfolio, salesperson_code) values
  ('ZC001', 'Card Hotel', 'rep', '91'), ('ZC002', 'Quiet Bistro', 'house', null), ('ZC003', 'Never Ordered', 'house', null), ('ZC004', 'Not Special', 'house', null)
  on conflict (code) do update set portfolio = excluded.portfolio, salesperson_code = excluded.salesperson_code;
insert into public.sales_customer_names (code, name) values ('ZC001', 'Card Hotel'), ('ZC002', 'Quiet Bistro'), ('ZC004', 'Not Special') on conflict do nothing;
insert into public.client_special_care (code, no_postpone) values ('ZC001', true), ('ZC002', true), ('ZC003', true)
  on conflict (code) do update set active = true;
-- Card Hotel: today (being weighed), 3 and 10 days ago (confirmed), 40 days ago (outside 30 d); a failed paper yesterday
insert into public.weighing_papers (id, work_date, photo_path, status, company, po_number, customer_name, delivery_date) values
 ('49000000-0000-0000-0000-000000000001', current_date,      'a', 'read', 'Prosun Farm', 'PO-C1', 'Card Hotel (ZC001)', current_date),
 ('49000000-0000-0000-0000-000000000002', current_date - 3,  'b', 'read', 'Prosun Farm', 'PO-C2', 'Card Hotel', current_date - 3),
 ('49000000-0000-0000-0000-000000000003', current_date - 10, 'c', 'read', 'Prosun Farm', 'PO-C3', 'Card Hotel', current_date - 10),
 ('49000000-0000-0000-0000-000000000004', current_date - 40, 'd', 'read', 'Prosun Farm', 'PO-C0', 'Card Hotel', current_date - 40),
 ('49000000-0000-0000-0000-000000000005', current_date - 1,  'e', 'failed', 'Prosun Farm', 'PO-CX', 'Card Hotel', current_date - 1),
 ('49000000-0000-0000-0000-000000000006', current_date - 20, 'f', 'read', 'Prosun Farm', 'PO-Q1', 'Quiet Bistro', current_date - 20),
 ('49000000-0000-0000-0000-000000000007', current_date,      'g', 'read', 'Prosun Farm', 'PO-N1', 'Not Special', current_date)
 on conflict do nothing;
insert into public.weighing_lines (paper_id, line_no, description, ordered_text, ordered_qty, ordered_unit, actual_kg) values
 ('49000000-0000-0000-0000-000000000001', 1, 'Breast skin-on', '12 Kg', 12, 'kg', null),
 ('49000000-0000-0000-0000-000000000002', 1, 'Breast skin-on', '10 Kg', 10, 'kg', 10.2),
 ('49000000-0000-0000-0000-000000000002', 2, 'Wings', '5 Kg', 5, 'kg', 5.6),
 ('49000000-0000-0000-0000-000000000003', 1, 'Breast skin-on', '14 Kg', 14, 'kg', 14.1),
 ('49000000-0000-0000-0000-000000000003', 2, 'Whole chicken', '10 ตัว', 10, 'pcs', 16.2),
 ('49000000-0000-0000-0000-000000000004', 1, 'Turkey', '2 ตัว', 2, 'pcs', 11)
 on conflict do nothing;
insert into public.special_care_checks (paper_id, code) values
 ('49000000-0000-0000-0000-000000000002','ZC001'),('49000000-0000-0000-0000-000000000003','ZC001'),('49000000-0000-0000-0000-000000000004','ZC001'),('49000000-0000-0000-0000-000000000006','ZC002')
 on conflict do nothing;
update public.weighing_papers set status = 'confirmed'
 where id in ('49000000-0000-0000-0000-000000000002','49000000-0000-0000-0000-000000000003','49000000-0000-0000-0000-000000000004','49000000-0000-0000-0000-000000000006');
insert into public.delivery_marks (paper_id, delivery_date, status) values ('49000000-0000-0000-0000-000000000002', current_date - 3, 'delivered') on conflict do nothing;
insert into public.order_postponements (customer_name, po_number, company, original_date, new_date, reason)
  values ('Card Hotel', 'PO-C9', 'Prosun Farm', current_date - 2, current_date - 1, 'client');
insert into public.weighing_postponements (paper_id, customer_name, po_number, company, from_work_date, to_work_date, from_delivery_date, to_delivery_date, reason, stage)
  values ('49000000-0000-0000-0000-000000000003', 'Card Hotel', 'PO-C3', 'Prosun Farm', current_date - 11, current_date - 10, current_date - 11, current_date - 10, 'production', 'production');

create or replace function pg_temp.ok(cond boolean, label text) returns void language plpgsql as $$
begin if coalesce(cond, false) then raise notice 'PASS %', label; else raise exception 'FAIL %', label; end if; end $$;

do $$ declare o jsonb; f jsonb; c jsonb; begin
  perform set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000f1"}', false);
  begin perform public.special_care_overview(); raise exception 'FAIL production reads overview';
  exception when others then perform pg_temp.ok(sqlerrm ~ 'admin only', 'overview is admin only'); end;
  begin perform public.special_care_client_file('ZC001'); raise exception 'FAIL production reads file';
  exception when others then perform pg_temp.ok(sqlerrm ~ 'admin only', 'client file is admin only'); end;

  perform set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1"}', false);
  o := public.special_care_overview();
  c := o->'clients'->'ZC001';
  perform pg_temp.ok(c->>'rep' = 'Tess' and o->'clients'->'ZC002'->>'rep' = 'House', 'salesperson, House for no salesperson');
  perform pg_temp.ok(c->'days30' = '[0, 3, 10]'::jsonb, 'order days in 30 d: today, 3 and 10 days ago (failed and 40-day-old skipped)');
  perform pg_temp.ok((c->>'n30')::int = 3, '3 orders in 30 days');
  perform pg_temp.ok((c->>'kg30')::numeric = 46.1, 'kg of confirmed papers in 30 days');
  perform pg_temp.ok((c->>'off5_30')::int = 1, 'one kg line off by more than 5 % (wings 5 → 5.6)');
  perform pg_temp.ok((c->>'postponed30')::int = 2, '2 postponements in 30 days (register + weighing)');
  perform pg_temp.ok((c->>'days_since')::int = 0, 'last order today');
  perform pg_temp.ok((o->'clients'->'ZC002'->>'days_since')::int = 20, 'quiet client: 20 days');
  perform pg_temp.ok(o->'clients'->'ZC003'->>'days_since' is null, 'never ordered: no last order');
  perform pg_temp.ok(not (o->'clients' ? 'ZC004'), 'unflagged client not in the overview');
  perform pg_temp.ok((o->'stats'->>'ordering_today')::int >= 1, 'stats: ordering today');
  perform pg_temp.ok((o->'stats'->>'quiet_14')::int >= 1 and (o->'stats'->>'no_order')::int >= 1, 'stats: quiet and never ordered');
  perform pg_temp.ok((o->'stats'->>'postponed_7d')::int >= 1, 'stats: postponements in 7 days');

  f := public.special_care_client_file('zc001');
  perform pg_temp.ok(jsonb_array_length(f->'orders') = 4, 'file: 4 orders (failed paper skipped)');
  perform pg_temp.ok(f->'orders'->0->>'po_number' = 'PO-C1' and f->'orders'->3->>'po_number' = 'PO-C0', 'file: newest first');
  perform pg_temp.ok(f->'orders'->1->>'delivery' = 'delivered', 'file: delivery mark');
  perform pg_temp.ok(f->'orders'->2->'postponed'->>'reason' = 'production', 'file: last postponement of the paper');
  perform pg_temp.ok((f->'orders'->1->>'total_kg')::numeric = 15.8 and jsonb_array_length(f->'orders'->1->'lines') = 2, 'file: lines and total kg');
  perform pg_temp.ok(f->'basket'->0->>'description' = 'Breast skin-on' and (f->'basket'->0->>'orders')::int = 3, 'basket: breast in 3 orders');
  perform pg_temp.ok((f->'basket'->0->>'avg_qty')::numeric = 12 and f->'basket'->0->>'unit' = 'kg', 'basket: usual quantity 12 kg');
  perform pg_temp.ok(not exists (select 1 from jsonb_array_elements(f->'basket') b where b->>'description' = 'Turkey'), 'basket: 40-day-old product not counted');
  perform pg_temp.ok(jsonb_array_length(f->'postponements') = 2, 'file: 2 postponements in 30 days');
  perform pg_temp.ok((f->>'orders_30')::int = 3, 'file: 3 orders in 30 days');
end $$;
\echo done
