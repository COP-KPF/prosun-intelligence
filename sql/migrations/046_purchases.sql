-- ============================================================================
-- Migration 046 — Purchasing › Purchases: bird orders, arrivals, cost ratio
-- ============================================================================
-- Written 24 Nov 2026. Clément: "I'd like to make the purchase section more
-- detailed. To be able to follow the purchase ratio versus the revenue. I'd
-- like also to be able to follow the current purchased products I order every
-- Monday, Wednesday and Saturday, which come to the factory on Wednesday,
-- Friday and Monday."
--
-- Two pages under Purchasing › Purchases:
--   1. Orders & arrivals — each order to a supplier (normally Mon / Wed / Sat)
--      with its lines (item, size band, quantity, price), then what really
--      arrived (normally Wed / Fri / Mon): received quantity and kg, rejected
--      birds, the final price and the freight. Shortfall and late arrivals
--      show at once.
--   2. Cost ratio — purchase cost (birds + freight) against revenue:
--        * approximate revenue of the confirmed working papers, with exactly
--          the Summary rules (031): price list, no discounts, by production day;
--        * invoiced revenue per month (sales_actuals, 036) where it is loaded.
--      Targets (process notes, 4 Sep 2026): Prosun Farm 55–60 %, Prosun Food
--      below 50 %. The ratio starts on the later of the first counted paper
--      day (management_settings.count_from) and the first purchase entered.
--
-- Who: bird cost and freight are known only to Clément and the purchasing
-- manager (4 Sep 2026: "exactly two named individuals, not a role"). So access
-- is a list of accounts, purchase_access, seeded with clement@ and orawan@.
-- Another person is added from the Supabase SQL editor only:
--   insert into public.purchase_access (user_id)
--   select id from auth.users where lower(email) = 'kirana@klongphaifarm.com';
--
-- Every write goes through the functions below (one call = header + lines,
-- all or nothing). Rows are never deleted: an order is cancelled with a reason.
-- Every change is in activity_log.
--
-- Cost of a line:
--   price per kg   → kg × price      (received kg once arrived, else the
--                                      estimated kg of the order)
--   price per unit → quantity × price (received quantity once arrived — the
--                                      rejected birds are not paid — else the
--                                      ordered quantity)
-- Before the arrival is recorded the cost is an estimate, and shown as one.
--
-- Run order: after 045. Safe to re-run.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Who may see and enter purchases
-- ----------------------------------------------------------------------------
create table if not exists public.purchase_access (
  user_id    uuid primary key references public.profiles(id) on delete cascade,
  added_at   timestamptz not null default now()
);

comment on table public.purchase_access is
  'Accounts that see and enter purchase quantities, prices, freight and the '
  'cost ratio. Changed only from the Supabase SQL editor. Migration 046.';

alter table public.purchase_access enable row level security;
revoke all on public.purchase_access from public, anon, authenticated;
grant all on public.purchase_access to service_role;

insert into public.purchase_access (user_id)
select u.id
from auth.users u
join public.profiles p on p.id = u.id
where lower(u.email) in ('clement@klongphaifarm.com', 'orawan@klongphaifarm.com')
on conflict (user_id) do nothing;

create or replace function public.purchase_can()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.purchase_access where user_id = auth.uid());
$$;
revoke all on function public.purchase_can() from public, anon;
grant execute on function public.purchase_can() to authenticated, service_role;


-- ----------------------------------------------------------------------------
-- 2. Tables
-- ----------------------------------------------------------------------------
-- What is bought. unit = how it is counted on an order: bird, pcs or kg.
create table if not exists public.purchase_items (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  name_th    text,
  unit       text not null default 'bird' check (unit in ('bird', 'pcs', 'kg')),
  sort       int not null default 100,
  active     boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid references public.profiles(id)
);
create unique index if not exists purchase_items_name_key on public.purchase_items (lower(name));

insert into public.purchase_items (name, name_th, unit, sort) values
  ('Red Label chicken',          'ไก่เรดเลเบิ้ล',              'bird', 10),
  ('Green Label chicken',        'ไก่กรีนเลเบิ้ล',             'bird', 20),
  ('Baby chicken',               'ไก่เบบี้',                   'bird', 30),
  ('Spring chicken',             'ไก่สปริง',                   'bird', 40),
  ('Capon',                      'ไก่ตอน',                     'bird', 50),
  ('Duck Barbary male',          'เป็ดบาร์บารี่ ตัวผู้',         'bird', 60),
  ('Duck Barbary female',        'เป็ดบาร์บารี่ ตัวเมีย',        'bird', 70),
  ('Golden Signature Duck',      'เป็ดโกลเด้นซิกเนเจอร์',        'bird', 80),
  ('Guinea fowl',                'ไก่ต๊อก',                    'bird', 90),
  ('Pigeon',                     'นกพิราบ',                    'bird', 100),
  ('Quail',                      'นกกระทา',                    'bird', 110),
  ('Turkey',                     'ไก่งวง',                     'bird', 120),
  ('Rabbit',                     'กระต่าย',                    'pcs',  130),
  ('Eggs',                       'ไข่',                        'pcs',  140),
  ('Other (by kg)',              'อื่นๆ (กก.)',                 'kg',   900)
on conflict do nothing;

-- One order to one supplier, for one company.
create table if not exists public.purchase_orders (
  id             uuid primary key default gen_random_uuid(),
  order_date     date not null,
  arrival_date   date not null,                     -- planned arrival at the factory
  company        text not null default 'Prosun Farm' check (company in ('Prosun Farm', 'Prosun Food')),
  supplier       text not null check (length(trim(supplier)) > 0),
  ref            text,                              -- supplier's order / invoice number
  note           text,
  status         text not null default 'ordered' check (status in ('ordered', 'received', 'cancelled')),
  -- the arrival
  arrived_on     date,                              -- the day it really came
  freight_thb    numeric check (freight_thb is null or freight_thb >= 0),
  arrival_note   text,
  received_by    uuid references public.profiles(id),
  received_at    timestamptz,
  -- cancelling
  cancel_reason  text,
  cancelled_by   uuid references public.profiles(id),
  cancelled_at   timestamptz,
  created_by     uuid references public.profiles(id),
  created_at     timestamptz not null default now(),
  updated_by     uuid references public.profiles(id),
  updated_at     timestamptz not null default now(),
  check (arrival_date >= order_date),
  check (status <> 'received' or arrived_on is not null)
);
create index if not exists purchase_orders_order_date_idx   on public.purchase_orders (order_date);
create index if not exists purchase_orders_arrival_date_idx on public.purchase_orders (coalesce(arrived_on, arrival_date));

create table if not exists public.purchase_order_lines (
  id             uuid primary key default gen_random_uuid(),
  order_id       uuid not null references public.purchase_orders(id) on delete cascade,
  line_no        int not null default 1,
  item_id        uuid not null references public.purchase_items(id),
  size_band      text,                              -- e.g. 1.4-1.6
  ordered_qty    numeric not null check (ordered_qty > 0),
  ordered_kg     numeric check (ordered_kg is null or ordered_kg >= 0),   -- estimate, for kg prices
  price          numeric check (price is null or price >= 0),
  price_per      text not null default 'kg' check (price_per in ('kg', 'unit')),
  received_qty   numeric check (received_qty is null or received_qty >= 0),
  received_kg    numeric check (received_kg is null or received_kg >= 0),
  rejected_qty   numeric check (rejected_qty is null or rejected_qty >= 0),   -- dead / refused, not paid
  note           text
);
create index if not exists purchase_order_lines_order_idx on public.purchase_order_lines (order_id);

comment on table public.purchase_orders is
  'Purchases of birds and other products: the order (normally Mon/Wed/Sat) and '
  'its arrival (normally Wed/Fri/Mon). Written only through purchase_save_order, '
  'purchase_record_arrival and purchase_cancel_order. Migration 046.';


-- Cost of each line, and whether it is still an estimate.
create or replace view public.purchase_line_costs
with (security_invoker = true) as
select l.id as line_id, l.order_id, o.company, o.status,
       coalesce(o.arrived_on, o.arrival_date) as arrival_day,
       i.unit as item_unit,
       case when o.status = 'received' then coalesce(l.received_qty, 0) else l.ordered_qty end as qty,
       case when o.status = 'received'
              then coalesce(l.received_kg, case when i.unit = 'kg' then l.received_qty end)
            else coalesce(l.ordered_kg, case when i.unit = 'kg' then l.ordered_qty end) end as kg,
       case
         when l.price is null then null
         when l.price_per = 'unit' then
           round(l.price * case when o.status = 'received' then coalesce(l.received_qty, 0) else l.ordered_qty end, 2)
         else
           round(l.price * case when o.status = 'received'
                                  then coalesce(l.received_kg, case when i.unit = 'kg' then l.received_qty end)
                                else coalesce(l.ordered_kg, case when i.unit = 'kg' then l.ordered_qty end) end, 2)
       end as cost,
       o.status <> 'received' as estimate
from public.purchase_order_lines l
join public.purchase_orders o on o.id = l.order_id
join public.purchase_items i on i.id = l.item_id;


-- ----------------------------------------------------------------------------
-- 3. Row Level Security, grants, activity log
-- ----------------------------------------------------------------------------
alter table public.purchase_items       enable row level security;
alter table public.purchase_orders      enable row level security;
alter table public.purchase_order_lines enable row level security;

drop policy if exists "purchase_items: read" on public.purchase_items;
create policy "purchase_items: read" on public.purchase_items
  for select to authenticated using (public.purchase_can());
drop policy if exists "purchase_orders: read" on public.purchase_orders;
create policy "purchase_orders: read" on public.purchase_orders
  for select to authenticated using (public.purchase_can());
drop policy if exists "purchase_order_lines: read" on public.purchase_order_lines;
create policy "purchase_order_lines: read" on public.purchase_order_lines
  for select to authenticated using (public.purchase_can());

revoke all on public.purchase_items, public.purchase_orders, public.purchase_order_lines, public.purchase_line_costs
  from public, anon, authenticated;
grant select on public.purchase_items, public.purchase_orders, public.purchase_order_lines, public.purchase_line_costs
  to authenticated;
grant all on public.purchase_items, public.purchase_orders, public.purchase_order_lines, public.purchase_line_costs
  to service_role;

drop trigger if exists purchase_items_log_activity on public.purchase_items;
create trigger purchase_items_log_activity
  after insert or update or delete on public.purchase_items
  for each row execute function public.log_weighing_activity();
drop trigger if exists purchase_orders_log_activity on public.purchase_orders;
create trigger purchase_orders_log_activity
  after insert or update or delete on public.purchase_orders
  for each row execute function public.log_weighing_activity();
drop trigger if exists purchase_order_lines_log_activity on public.purchase_order_lines;
create trigger purchase_order_lines_log_activity
  after insert or update or delete on public.purchase_order_lines
  for each row execute function public.log_weighing_activity();


-- ----------------------------------------------------------------------------
-- 4. Writing
-- ----------------------------------------------------------------------------
create or replace function public.purchase_check()
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.purchase_can() then
    raise exception 'purchases: not allowed for this account' using errcode = '42501';
  end if;
end $$;
revoke all on function public.purchase_check() from public, anon, authenticated;

-- A new item (name, name_th, unit) or a change to one (id, … , active).
create or replace function public.purchase_save_item(p jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id   uuid := nullif(p->>'id', '')::uuid;
  v_name text := nullif(trim(p->>'name'), '');
  v_unit text := coalesce(nullif(p->>'unit', ''), 'bird');
begin
  perform public.purchase_check();
  if v_name is null then raise exception 'purchases: the item needs a name' using errcode = '22023'; end if;
  if v_unit not in ('bird', 'pcs', 'kg') then raise exception 'purchases: unknown unit' using errcode = '22023'; end if;
  if v_id is null then
    insert into public.purchase_items (name, name_th, unit, sort, created_by)
    values (v_name, nullif(trim(p->>'name_th'), ''), v_unit,
            coalesce((p->>'sort')::int, (select coalesce(max(sort), 0) + 10 from public.purchase_items where sort < 900)),
            auth.uid())
    returning id into v_id;
  else
    update public.purchase_items
       set name = v_name, name_th = nullif(trim(p->>'name_th'), ''), unit = v_unit,
           active = coalesce((p->>'active')::boolean, active)
     where id = v_id;
    if not found then raise exception 'purchases: item not found' using errcode = 'P0002'; end if;
  end if;
  return v_id;
exception when unique_violation then
  raise exception 'purchases: an item with this name already exists' using errcode = '23505';
end $$;

-- Create or change an order: header + every line in one call. Lines that
-- carry an id are updated (their arrival figures are kept), lines without one
-- are added, lines left out are removed. p.updated_at, when given, must match
-- the stored one: a screen opened before someone else's change cannot
-- overwrite it.
create or replace function public.purchase_save_order(p jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id      uuid := nullif(p->>'id', '')::uuid;
  v_order   date := (p->>'order_date')::date;
  v_arrival date := (p->>'arrival_date')::date;
  v_company text := coalesce(nullif(p->>'company', ''), 'Prosun Farm');
  v_supp    text := nullif(trim(p->>'supplier'), '');
  v_cur     public.purchase_orders;
  v_keep    uuid[] := '{}';
  l         jsonb;
  n         int := 0;
  v_line    uuid;
begin
  perform public.purchase_check();
  if v_order is null or v_arrival is null then
    raise exception 'purchases: choose the order date and the arrival date' using errcode = '22023';
  end if;
  if v_arrival < v_order then
    raise exception 'purchases: the arrival cannot be before the order' using errcode = '22023';
  end if;
  if v_supp is null then raise exception 'purchases: write the supplier' using errcode = '22023'; end if;
  if v_company not in ('Prosun Farm', 'Prosun Food') then
    raise exception 'purchases: unknown company' using errcode = '22023';
  end if;
  if jsonb_typeof(p->'lines') is distinct from 'array' or jsonb_array_length(p->'lines') = 0 then
    raise exception 'purchases: add at least one line' using errcode = '22023';
  end if;

  if v_id is null then
    insert into public.purchase_orders (order_date, arrival_date, company, supplier, ref, note, created_by, updated_by)
    values (v_order, v_arrival, v_company, v_supp, nullif(trim(p->>'ref'), ''), nullif(trim(p->>'note'), ''),
            auth.uid(), auth.uid())
    returning id into v_id;
  else
    select * into v_cur from public.purchase_orders where id = v_id for update;
    if not found then raise exception 'purchases: order not found' using errcode = 'P0002'; end if;
    if v_cur.status = 'cancelled' then
      raise exception 'purchases: this order was cancelled' using errcode = '22023';
    end if;
    if nullif(p->>'updated_at', '') is not null
       and date_trunc('milliseconds', (p->>'updated_at')::timestamptz) <> date_trunc('milliseconds', v_cur.updated_at) then
      raise exception 'purchases: someone changed this order meanwhile — refresh and try again' using errcode = '40001';
    end if;
    update public.purchase_orders
       set order_date = v_order, arrival_date = v_arrival, company = v_company, supplier = v_supp,
           ref = nullif(trim(p->>'ref'), ''), note = nullif(trim(p->>'note'), ''),
           updated_by = auth.uid(), updated_at = now()
     where id = v_id;
  end if;

  for l in select * from jsonb_array_elements(p->'lines') loop
    n := n + 1;
    if nullif(l->>'item_id', '') is null then
      raise exception 'purchases: line %: choose the item', n using errcode = '22023';
    end if;
    if coalesce((l->>'ordered_qty')::numeric, 0) <= 0 then
      raise exception 'purchases: line %: write the quantity ordered', n using errcode = '22023';
    end if;
    if coalesce(l->>'price_per', 'kg') not in ('kg', 'unit') then
      raise exception 'purchases: line %: price per kg or per unit', n using errcode = '22023';
    end if;
    v_line := nullif(l->>'id', '')::uuid;
    if v_line is not null then
      update public.purchase_order_lines
         set line_no = n, item_id = (l->>'item_id')::uuid, size_band = nullif(trim(l->>'size_band'), ''),
             ordered_qty = (l->>'ordered_qty')::numeric, ordered_kg = nullif(l->>'ordered_kg', '')::numeric,
             price = nullif(l->>'price', '')::numeric, price_per = coalesce(nullif(l->>'price_per', ''), 'kg'),
             note = nullif(trim(l->>'note'), '')
       where id = v_line and order_id = v_id;
      if not found then v_line := null; end if;
    end if;
    if v_line is null then
      insert into public.purchase_order_lines (order_id, line_no, item_id, size_band, ordered_qty, ordered_kg, price, price_per, note)
      values (v_id, n, (l->>'item_id')::uuid, nullif(trim(l->>'size_band'), ''),
              (l->>'ordered_qty')::numeric, nullif(l->>'ordered_kg', '')::numeric,
              nullif(l->>'price', '')::numeric, coalesce(nullif(l->>'price_per', ''), 'kg'),
              nullif(trim(l->>'note'), ''))
      returning id into v_line;
    end if;
    v_keep := v_keep || v_line;
  end loop;

  delete from public.purchase_order_lines where order_id = v_id and not (id = any (v_keep));
  -- A line added to an order already received has no arrival figures yet: the
  -- order goes back to "ordered" until the arrival is recorded again.
  update public.purchase_orders o set status = 'ordered'
   where o.id = v_id and o.status = 'received'
     and exists (select 1 from public.purchase_order_lines l
                 where l.order_id = v_id and l.received_qty is null and l.received_kg is null);
  return v_id;
end $$;

-- What really arrived: date, per line received / kg / rejected / final
-- price, the freight. Can be recorded again to correct it.
create or replace function public.purchase_record_arrival(p jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id  uuid := (p->>'id')::uuid;
  v_cur public.purchase_orders;
  v_day date := nullif(p->>'arrived_on', '')::date;
  l     jsonb;
begin
  perform public.purchase_check();
  select * into v_cur from public.purchase_orders where id = v_id for update;
  if not found then raise exception 'purchases: order not found' using errcode = 'P0002'; end if;
  if v_cur.status = 'cancelled' then raise exception 'purchases: this order was cancelled' using errcode = '22023'; end if;
  if v_day is null then raise exception 'purchases: choose the day it arrived' using errcode = '22023'; end if;
  if v_day < v_cur.order_date then
    raise exception 'purchases: the arrival cannot be before the order' using errcode = '22023';
  end if;
  if nullif(p->>'updated_at', '') is not null
     and date_trunc('milliseconds', (p->>'updated_at')::timestamptz) <> date_trunc('milliseconds', v_cur.updated_at) then
    raise exception 'purchases: someone changed this order meanwhile — refresh and try again' using errcode = '40001';
  end if;

  for l in select * from jsonb_array_elements(coalesce(p->'lines', '[]'::jsonb)) loop
    update public.purchase_order_lines
       set received_qty = nullif(l->>'received_qty', '')::numeric,
           received_kg  = nullif(l->>'received_kg', '')::numeric,
           rejected_qty = nullif(l->>'rejected_qty', '')::numeric,
           price        = case when l ? 'price' then nullif(l->>'price', '')::numeric else price end,
           price_per    = coalesce(nullif(l->>'price_per', ''), price_per)
     where id = (l->>'id')::uuid and order_id = v_id;
  end loop;

  if exists (select 1 from public.purchase_order_lines
             where order_id = v_id and received_qty is null and received_kg is null) then
    raise exception 'purchases: write what arrived on every line (0 if nothing came)' using errcode = '22023';
  end if;

  update public.purchase_orders
     set status = 'received', arrived_on = v_day,
         freight_thb = nullif(p->>'freight_thb', '')::numeric,
         arrival_note = nullif(trim(p->>'arrival_note'), ''),
         received_by = auth.uid(), received_at = now(),
         updated_by = auth.uid(), updated_at = now()
   where id = v_id;
end $$;

create or replace function public.purchase_cancel_order(p_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.purchase_check();
  if nullif(trim(p_reason), '') is null then
    raise exception 'purchases: write why the order is cancelled' using errcode = '22023';
  end if;
  update public.purchase_orders
     set status = 'cancelled', cancel_reason = trim(p_reason), cancelled_by = auth.uid(), cancelled_at = now(),
         updated_by = auth.uid(), updated_at = now()
   where id = p_id and status <> 'cancelled';
  if not found then raise exception 'purchases: order not found or already cancelled' using errcode = 'P0002'; end if;
end $$;


-- ----------------------------------------------------------------------------
-- 5. Reading
-- ----------------------------------------------------------------------------
-- Orders placed or arriving between two dates, with their lines and costs,
-- the items, and the suppliers used before (for the form's suggestions).
create or replace function public.purchase_board(p_from date, p_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare v_out jsonb;
begin
  perform public.purchase_check();
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 120 then
    raise exception 'purchases: choose a period of four months or less' using errcode = '22023';
  end if;
  select jsonb_build_object(
    'from', p_from, 'to', p_to,
    'items', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'name', i.name, 'name_th', i.name_th,
                                                           'unit', i.unit, 'active', i.active) order by i.sort, i.name)
                       from public.purchase_items i), '[]'::jsonb),
    'suppliers', coalesce((select jsonb_agg(s order by s) from (
                             select distinct supplier as s from public.purchase_orders
                             where order_date > current_date - 365) x), '[]'::jsonb),
    'orders', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', o.id, 'order_date', o.order_date, 'arrival_date', o.arrival_date, 'company', o.company,
               'supplier', o.supplier, 'ref', o.ref, 'note', o.note, 'status', o.status,
               'arrived_on', o.arrived_on, 'freight_thb', o.freight_thb, 'arrival_note', o.arrival_note,
               'cancel_reason', o.cancel_reason,
               'created_by', (select full_name from public.profiles where id = o.created_by), 'created_at', o.created_at,
               'received_by', (select full_name from public.profiles where id = o.received_by), 'received_at', o.received_at,
               'updated_at', o.updated_at,
               'lines', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'id', l.id, 'item_id', l.item_id, 'size_band', l.size_band,
                          'ordered_qty', l.ordered_qty, 'ordered_kg', l.ordered_kg,
                          'price', l.price, 'price_per', l.price_per,
                          'received_qty', l.received_qty, 'received_kg', l.received_kg,
                          'rejected_qty', l.rejected_qty, 'note', l.note,
                          'cost', c.cost) order by l.line_no)
                 from public.purchase_order_lines l
                 join public.purchase_line_costs c on c.line_id = l.id
                 where l.order_id = o.id), '[]'::jsonb))
             order by o.order_date, o.supplier, o.created_at)
      from public.purchase_orders o
      where o.order_date between p_from and p_to
         or coalesce(o.arrived_on, o.arrival_date) between p_from and p_to), '[]'::jsonb)
  ) into v_out;
  return v_out;
end $$;

-- Purchase cost against revenue. Days are lists to keep the answer small:
--   revenue:   [production day, company, approx. revenue, kg, kg priced, papers]
--              — confirmed working papers, Summary's rules (031), from count_from
--   purchases: [arrival day, company, cost of the goods, freight, estimate?,
--               birds ordered, birds received, kg, lines without a price, orders]
--              — arrival day = the day it came, or the planned day if not yet in
--   invoiced:  [month, company, invoiced amount, days counted] (sales_actuals, 036)
create or replace function public.purchase_ratio(p_from date, p_to date, p_company text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_co    text := nullif(nullif(p_company, ''), 'all');
  v_start date;
  v_rev   jsonb;
  v_pur   jsonb;
  v_inv   jsonb;
  v_first date;
  v_eff   date;
begin
  perform public.purchase_check();
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'purchases: choose a start and an end date' using errcode = '22023';
  end if;
  if p_to - p_from > 400 then
    raise exception 'purchases: choose a period of about a year or less' using errcode = '22023';
  end if;
  if v_co is not null and v_co not in ('Prosun Farm', 'Prosun Food') then
    raise exception 'purchases: unknown company' using errcode = '22023';
  end if;

  select s.count_from into v_start from public.management_settings s where s.id = 1;
  -- The ratio starts when both sides are counted: the first counted working
  -- paper day (count_from) and the first purchase entered in PACE. Before
  -- that, revenue without its purchases would make the ratio look too good.
  select min(coalesce(o.arrived_on, o.arrival_date)) into v_first
  from public.purchase_orders o
  where o.status <> 'cancelled' and (v_co is null or o.company = v_co);
  v_eff := greatest(p_from, coalesce(v_start, p_from), coalesce(v_first, p_from));

  with raw as materialized (
    select p.id as paper_id, p.work_date as day, p.company,
           coalesce(nullif(trim(p.customer_name), ''), '—') as client,
           l.description, l.actual_kg, l.ordered_qty, l.ordered_unit,
           coalesce(p.po_number, '') ~* '^\s*UR' as ur
    from public.weighing_papers p
    join public.weighing_lines l on l.paper_id = p.id
    where p.status = 'confirmed'
      and p.work_date between v_eff and p_to
      and (v_co is null or p.company = v_co)
  ),
  matched as materialized (
    select d.description, d.ur,
           public.price_list_match(d.description, case when d.ur then 'UR' end) as price_id
    from (select distinct description, ur from raw) d
  ),
  priced as (
    select x.*,
           case
             when x.price_unit = 'kg' then
               case when x.actual_kg > 0 then round(x.actual_kg * x.unit_price, 2) end
             when x.price_unit = 'pce' then
               case when x.pieces > 0 then round(x.pieces * x.unit_price, 2) end
           end as revenue
    from (
      select r.*, pl.unit as price_unit,
             case
               when r.ordered_unit = 'pcs' and r.ordered_qty > 0 then r.ordered_qty
               when pl.unit = 'pce' and r.actual_kg > 0 and pl.piece_kg > 0 then round(r.actual_kg / pl.piece_kg)
             end as pieces,
             case
               when pl.bulk_min is not null
                    and (case when r.ordered_unit = 'pcs' then r.ordered_qty end) >= pl.bulk_min
                 then case when z.zone = 'upcountry' then coalesce(pl.bulk_up, pl.bulk_bkk) else pl.bulk_bkk end
               else case when z.zone = 'upcountry' then coalesce(pl.price_up, pl.price_bkk) else pl.price_bkk end
             end as unit_price
      from raw r
      join matched m on m.description is not distinct from r.description and m.ur = r.ur
      left join public.price_list pl on pl.id = m.price_id
      left join public.client_price_zones z on z.client_key = lower(r.client)
    ) x
  )
  select coalesce(jsonb_agg(jsonb_build_array(day, company, rev, kg, kg_priced, papers) order by day, company), '[]'::jsonb)
    into v_rev
  from (
    select day, company,
           round(coalesce(sum(revenue), 0), 2) as rev,
           round(coalesce(sum(actual_kg), 0), 2) as kg,
           round(coalesce(sum(actual_kg) filter (where revenue is not null), 0), 2) as kg_priced,
           count(distinct paper_id) as papers
    from priced
    group by day, company
  ) g;

  with o as (
    select o.*, coalesce(o.arrived_on, o.arrival_date) as day
    from public.purchase_orders o
    where o.status <> 'cancelled'
      and coalesce(o.arrived_on, o.arrival_date) between v_eff and p_to
      and (v_co is null or o.company = v_co)
  ),
  goods as (
    select o.day, o.company,
           round(coalesce(sum(c.cost), 0), 2) as cost,
           bool_or(o.status <> 'received') as est,
           coalesce(sum(l.ordered_qty) filter (where c.item_unit = 'bird'), 0) as birds_ordered,
           coalesce(sum(l.received_qty) filter (where c.item_unit = 'bird' and o.status = 'received'), 0) as birds_received,
           round(coalesce(sum(c.kg), 0), 2) as kg,
           count(*) filter (where c.cost is null) as no_price
    from o
    join public.purchase_order_lines l on l.order_id = o.id
    join public.purchase_line_costs c on c.line_id = l.id
    group by o.day, o.company
  ),
  freight as (
    select day, company, round(coalesce(sum(freight_thb), 0), 2) as freight, count(*) as orders
    from o group by day, company
  )
  select coalesce(jsonb_agg(jsonb_build_array(f.day, f.company, coalesce(g.cost, 0), f.freight, coalesce(g.est, true),
                                              coalesce(g.birds_ordered, 0), coalesce(g.birds_received, 0),
                                              coalesce(g.kg, 0), coalesce(g.no_price, 0), f.orders)
                            order by f.day, f.company), '[]'::jsonb)
    into v_pur
  from freight f
  left join goods g on g.day = f.day and g.company = f.company;

  select coalesce(jsonb_agg(jsonb_build_array(a.month, a.company, a.amount, a.days_counted) order by a.month, a.company), '[]'::jsonb)
    into v_inv
  from public.sales_actuals a
  where a.month between date_trunc('month', p_from)::date and p_to
    and (v_co is null or a.company = v_co);

  return jsonb_build_object('from', p_from, 'to', p_to, 'company', coalesce(v_co, 'all'), 'count_from', v_start,
                            'first_purchase', v_first, 'from_effective', v_eff,
                            'revenue', v_rev, 'purchases', v_pur, 'invoiced', v_inv);
end $$;

revoke all on function public.purchase_save_item(jsonb)           from public, anon;
revoke all on function public.purchase_save_order(jsonb)          from public, anon;
revoke all on function public.purchase_record_arrival(jsonb)      from public, anon;
revoke all on function public.purchase_cancel_order(uuid, text)   from public, anon;
revoke all on function public.purchase_board(date, date)          from public, anon;
revoke all on function public.purchase_ratio(date, date, text)    from public, anon;
grant execute on function public.purchase_save_item(jsonb)         to authenticated, service_role;
grant execute on function public.purchase_save_order(jsonb)        to authenticated, service_role;
grant execute on function public.purchase_record_arrival(jsonb)    to authenticated, service_role;
grant execute on function public.purchase_cancel_order(uuid, text) to authenticated, service_role;
grant execute on function public.purchase_board(date, date)        to authenticated, service_role;
grant execute on function public.purchase_ratio(date, date, text)  to authenticated, service_role;
