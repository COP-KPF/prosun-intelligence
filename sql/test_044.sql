-- Migration 044 — Special care last order. Run on a replica after 043 + 044 (psql -f).
-- Needs the users of test_043.sql (it creates them if missing).
\set ON_ERROR_STOP 1
insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000a1','admin@x'),('00000000-0000-0000-0000-0000000000f1','prod@x') on conflict do nothing;
insert into public.profiles (id, full_name, role) values ('00000000-0000-0000-0000-0000000000a1','Clément','admin'),('00000000-0000-0000-0000-0000000000f1','Muay','production')
  on conflict (id) do update set role = excluded.role;
insert into public.sales_customers (code, name, portfolio) values ('ZT001', 'Test Hotel', 'house'), ('ZT002', 'Invoice Only Bistro', 'house'), ('ZT003', 'Never Ordered', 'house')
  on conflict (code) do nothing;
insert into public.sales_customer_names (code, name) values ('ZT001', 'Test Hotel'), ('ZT001', 'โรงแรมเทสต์') on conflict do nothing;
insert into public.client_special_care (code, no_postpone) values ('ZT001', true), ('ZT002', true), ('ZT003', true)
  on conflict (code) do update set active = true;
insert into public.sales_invoices (company, number, code, partner_name, invoice_date, total) values
  ('Prosun Farm', 'INV/T/1', 'ZT002', 'Invoice Only Bistro', '2026-09-20', 1234.5),
  ('Prosun Farm', 'INV/T/0', 'ZT002', 'Invoice Only Bistro', '2026-09-02', 99),
  ('Prosun Farm', 'INV/T/2', 'ZT001', 'Test Hotel', '2026-09-25', 500)
  on conflict do nothing;
insert into public.weighing_papers (id, work_date, photo_path, status, company, po_number, customer_name, delivery_date) values
 ('44000000-0000-0000-0000-000000000001', current_date - 10, 'a', 'read', 'Prosun Farm', 'PO-T1', 'Test Hotel', current_date - 10),
 ('44000000-0000-0000-0000-000000000002', current_date - 3,  'b', 'read', 'Prosun Farm', 'PO-T2', 'โรงแรมเทสต์', current_date - 3),
 ('44000000-0000-0000-0000-000000000003', current_date - 1,  'c', 'failed',    'Prosun Farm', 'PO-T3', 'Test Hotel', current_date - 1),
 ('44000000-0000-0000-0000-000000000004', current_date - 60, 'd', 'read', 'Prosun Farm', 'PO-T0', 'Test Hotel', current_date - 60)
 on conflict do nothing;
insert into public.weighing_lines (paper_id, line_no, description, ordered_text, ordered_qty, ordered_unit, actual_kg) values
 ('44000000-0000-0000-0000-000000000002', 1, 'Chicken breast Red Label', '20 Kg', 20, 'kg', 20.4),
 ('44000000-0000-0000-0000-000000000002', 2, 'Whole chicken 1.6 kg', '10 ตัว', 10, 'pcs', 16.1),
 ('44000000-0000-0000-0000-000000000001', 1, 'Wings', '5 Kg', 5, 'kg', 5)
 on conflict do nothing;
-- confirm them (special care: production's tick first)
insert into public.special_care_checks (paper_id, code) select id, 'ZT001' from public.weighing_papers
 where id in ('44000000-0000-0000-0000-000000000001','44000000-0000-0000-0000-000000000002','44000000-0000-0000-0000-000000000004') on conflict do nothing;
update public.weighing_papers set status = 'confirmed'
 where id in ('44000000-0000-0000-0000-000000000001','44000000-0000-0000-0000-000000000002','44000000-0000-0000-0000-000000000004');

create or replace function pg_temp.ok(cond boolean, label text) returns void language plpgsql as $$
begin if coalesce(cond, false) then raise notice 'PASS %', label; else raise exception 'FAIL %', label; end if; end $$;

do $$ declare r jsonb; begin
  perform set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000f1"}', false);
  begin
    perform public.special_care_last_orders();
    raise exception 'FAIL production can read last orders';
  exception when others then
    perform pg_temp.ok(sqlerrm ~ 'admin only', 'last orders are admin only');
  end;
  perform set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1"}', false);
  r := public.special_care_last_orders();
  perform pg_temp.ok(r ? 'ZT001' and r ? 'ZT002' and r ? 'ZT003', 'every active special care client is in the result');
  perform pg_temp.ok(r->'ZT001'->'last'->>'po_number' = 'PO-T2', 'last order = latest paper, matched through the Thai name too');
  perform pg_temp.ok((r->'ZT001'->'last'->>'order_date')::date = current_date - 3, 'failed paper of yesterday is skipped');
  perform pg_temp.ok(jsonb_array_length(r->'ZT001'->'last'->'lines') = 2, 'its two products are returned');
  perform pg_temp.ok(r->'ZT001'->'last'->'lines'->0->>'description' = 'Chicken breast Red Label'
                     and (r->'ZT001'->'last'->'lines'->0->>'ordered_qty')::numeric = 20
                     and (r->'ZT001'->'last'->'lines'->0->>'actual_kg')::numeric = 20.4, 'product, ordered quantity and actual kg');
  perform pg_temp.ok((r->'ZT001'->'last'->>'total_kg')::numeric = 36.5, 'total kg');
  perform pg_temp.ok((r->'ZT001'->>'orders_30')::int = 2, '2 orders in the last 30 days (60-day-old and failed ones not counted)');
  perform pg_temp.ok(r->'ZT001'->'invoice' = 'null'::jsonb, 'no invoice fallback when a paper exists');
  perform pg_temp.ok(r->'ZT002'->'last' = 'null'::jsonb and r->'ZT002'->'invoice'->>'number' = 'INV/T/1', 'invoice-only client: last Odoo invoice');
  perform pg_temp.ok(r->'ZT003'->'last' = 'null'::jsonb and r->'ZT003'->'invoice' = 'null'::jsonb and (r->'ZT003'->>'orders_30')::int = 0, 'client never ordered: empty');
  update public.client_special_care set active = false where code = 'ZT003';
  perform pg_temp.ok(not (public.special_care_last_orders() ? 'ZT003'), 'removed client not returned');
end $$;
\echo done
