-- Migration 048 — margins by product. Run on a replica after test_046.sql and test_047.sql.
\set ON_ERROR_STOP 1
\i sql/migrations/048_purchase_margins.sql

create or replace function pg_temp.ok(cond boolean, label text) returns void language plpgsql as $$
begin if coalesce(cond, false) then raise notice 'PASS %', label; else raise exception 'FAIL %', label; end if; end $$;
create or replace function pg_temp.as_user(uid text) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'aal', 'aal2')::text, false) $$;

do $$
declare v_id uuid; n int;
begin
  perform pg_temp.ok((select count(*) from public.purchase_cost_prices) = 62, 'file loaded: 62 products');
  perform pg_temp.ok((select unit_cost from public.purchase_margins where product = 'Breasts Red Label') = 110.67, 'Red Label breast cost = 83 ÷ 75 % = 110.67');
  perform pg_temp.ok((select unit_cost from public.purchase_margins where product = 'Chicken Red Label') = 83, 'whole Red Label: direct 83');
  perform pg_temp.ok((select unit_cost from public.purchase_margins where product = 'Moscovy / Barbary duck female fillet') = 206.67, 'Barbary fillet = 155 ÷ 75 %');

  perform set_config('role', 'authenticated', true);
  -- Orawan (purchase access, no revenue): nothing
  perform pg_temp.as_user('00000000-0000-0000-0000-0000000046b1');
  perform pg_temp.ok((select count(*) from public.purchase_cost_prices) = 0 and (select count(*) from public.purchase_margins) = 0, 'purchasing manager reads no buying price');
  begin
    perform public.purchase_set_yield('Red Label chicken', 70);
    raise exception 'FAIL Orawan set a yield';
  exception when insufficient_privilege then perform pg_temp.ok(true, 'purchasing manager cannot change yields'); end;
  -- Jane: nothing
  perform pg_temp.as_user('00000000-0000-0000-0000-0000000046c1');
  perform pg_temp.ok((select count(*) from public.purchase_margins) = 0, 'sale support reads nothing');
  -- Khun Jum: reads
  perform pg_temp.as_user('00000000-0000-0000-0000-0000000046a2');
  perform pg_temp.ok((select count(*) from public.purchase_margins) = 62, 'Khun Jum reads the margins');
  begin
    update public.purchase_cost_prices set buy_price = 1;
    raise exception 'FAIL direct update';
  exception when insufficient_privilege then perform pg_temp.ok(true, 'no direct update'); end;
  -- Clément: yield for all Red Label cuts, edit, add
  perform pg_temp.as_user('00000000-0000-0000-0000-0000000046a1');
  n := public.purchase_set_yield('Red Label chicken', 80);
  perform pg_temp.ok(n = 13, '13 Red Label cuts set to 80 %');
  perform pg_temp.ok((select unit_cost from public.purchase_margins where product = 'Breasts Red Label') = 103.75, 'breast cost now 83 ÷ 80 % = 103.75');
  begin
    perform public.purchase_set_yield('Red Label chicken', 0);
    raise exception 'FAIL yield 0';
  exception when sqlstate '22023' then perform pg_temp.ok(true, 'yield 0 refused'); end;
  select id into v_id from public.purchase_cost_prices where product = 'Chicken Red Label';
  perform public.purchase_save_cost(jsonb_build_object('id', v_id, 'section', 'Chicken', 'product', 'Chicken Red Label',
    'size', '1.4 – 1.5 kg', 'sell_price', 222, 'sell_unit', 'kg', 'basis', 'direct', 'buy_price', 86, 'supplier', 'K. Pornthip Meesat', 'price_date', '2026-11-24'));
  perform pg_temp.ok((select buy_price from public.purchase_cost_prices where id = v_id) = 86, 'buying price updated to 86');
  begin
    perform public.purchase_save_cost(jsonb_build_object('section', 'Chicken parts (Red Label)', 'product', 'X', 'basis', 'yield', 'buy_price', 83));
    raise exception 'FAIL yield without group';
  exception when sqlstate '22023' then perform pg_temp.ok(true, 'yield cost needs the bird and the yield'); end;
  v_id := public.purchase_save_cost(jsonb_build_object('section', 'Special poultry', 'product', 'Poussin', 'size', '400 g', 'sell_price', 250, 'sell_unit', 'pce', 'basis', 'direct', 'buy_price', 100));
  perform pg_temp.ok((select count(*) from public.purchase_margins where active) = 63, 'new product added');
  perform public.purchase_save_cost(jsonb_build_object('id', v_id, 'section', 'Special poultry', 'product', 'Poussin', 'sell_unit', 'pce', 'basis', 'direct', 'active', false));
  perform pg_temp.ok((select count(*) from public.purchase_margins where active) = 62, 'product retired, not deleted');
  perform set_config('role', 'postgres', true);
  perform pg_temp.ok((select count(*) from public.activity_log where table_name = 'purchase_cost_prices') >= 15, 'changes in activity_log');
end $$;
