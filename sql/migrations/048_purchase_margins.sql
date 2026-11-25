-- ============================================================================
-- Migration 048 — Management › KPI › Purchases › Margins by product
-- ============================================================================
-- Written 24 Nov 2026 from Clément's file "Marge calculs Clement tous produits
-- 2026.xlsx" (sheets "Marge calculs" and "ทุน", supplier cost list updated
-- 24/02/25). Clément: "the buying price of the products, only me and Kirana
-- can see this." Prices change about once a year: no price-change alert.
--
-- One row per product: selling price, buying price, margin, multiple, cost as
-- a % of the price, supplier, date of the price.
--
-- Cost of a product, two bases:
--   direct  the buying price per selling unit (whole birds, special poultry,
--           eggs, dairy, Under Roof, offal bought as such)
--   yield   for cuts (Clément, 24 Nov 2026: "yield-based"): the bird's buying
--           price per kg ÷ usable yield. Replaces the sheet's =1000*83/1450
--           (57.24 THB/kg), which divided the price per kg by the bird's
--           weight and understated every cut's cost. The yield is set per
--           group (Red Label chicken, Barbary duck, Golden Signature Duck) and
--           starts at 75 % — to be confirmed by Clément, changed on screen.
--
-- Who: purchase_access with sees_revenue (Clément, Khun Jum — Migration 047).
-- Nobody else can read the table. Writes go through the functions below.
--
-- Run order: after 047. Safe to re-run (the seed fills an empty table only).
-- ============================================================================

create table if not exists public.purchase_cost_prices (
  id           uuid primary key default gen_random_uuid(),
  section      text not null,                       -- Chicken, Chicken parts (Red Label), Duck, …
  product      text not null,
  size         text,
  sell_price   numeric check (sell_price is null or sell_price >= 0),
  sell_unit    text not null default 'kg' check (sell_unit in ('kg', 'pce')),
  basis        text not null default 'direct' check (basis in ('direct', 'yield')),
  buy_price    numeric check (buy_price is null or buy_price >= 0),   -- direct: per selling unit · yield: bird price per kg
  yield_group  text,                                -- yield basis: which bird
  yield_pct    numeric check (yield_pct is null or (yield_pct > 0 and yield_pct <= 100)),
  supplier     text,
  price_date   date,
  note         text,
  sort         int not null default 100,
  active       boolean not null default true,
  updated_by   uuid references public.profiles(id),
  updated_at   timestamptz not null default now(),
  check (basis <> 'yield' or yield_group is not null)
);

comment on table public.purchase_cost_prices is
  'Buying price and margin per product (Clément''s margin file). Read only by '
  'purchase_access accounts with sees_revenue. Migration 048.';

alter table public.purchase_cost_prices enable row level security;
drop policy if exists "purchase_cost_prices: read" on public.purchase_cost_prices;
create policy "purchase_cost_prices: read" on public.purchase_cost_prices
  for select to authenticated using (public.purchase_sees_revenue());
revoke all on public.purchase_cost_prices from public, anon, authenticated;
grant select on public.purchase_cost_prices to authenticated;
grant all on public.purchase_cost_prices to service_role;

drop trigger if exists purchase_cost_prices_log_activity on public.purchase_cost_prices;
create trigger purchase_cost_prices_log_activity
  after insert or update or delete on public.purchase_cost_prices
  for each row execute function public.log_weighing_activity();

-- Cost per selling unit, margin, multiple, cost % of the price.
create or replace view public.purchase_margins
with (security_invoker = true) as
select c.*,
       case when c.buy_price is null then null
            when c.basis = 'yield' then round(c.buy_price / (coalesce(c.yield_pct, 100) / 100), 2)
            else c.buy_price end as unit_cost
from public.purchase_cost_prices c;
revoke all on public.purchase_margins from public, anon, authenticated;
grant select on public.purchase_margins to authenticated;
grant all on public.purchase_margins to service_role;


-- ----------------------------------------------------------------------------
-- Seed: Clément's file, 24 Nov 2026 (only into an empty table)
-- ----------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from public.purchase_cost_prices) then return; end if;
  insert into public.purchase_cost_prices
    (sort, section, product, size, sell_price, sell_unit, basis, buy_price, yield_group, yield_pct, supplier, price_date, note) values
  -- Whole chicken
  (110, 'Chicken', 'Yellow chicken',          '1.8 – 2.0 kg', 558, 'kg',  'direct', 180,  null, null, 'K. Pornthip Meesat', '2025-02-24', null),
  (120, 'Chicken', 'Chicken Green Label',     '1.7 – 1.8 kg', 298, 'kg',  'direct', 165,  null, null, 'K. Pornthip Meesat', '2025-02-24', null),
  (130, 'Chicken', 'Chicken Red Label',       '1.4 – 1.5 kg', 222, 'kg',  'direct', 83,   null, null, 'K. Pornthip Meesat', '2025-02-24', null),
  (140, 'Chicken', 'Spring chicken',          '400 – 600 g',  228, 'pce', 'direct', 88,   null, null, 'K. Pornthip Meesat', '2025-02-24', null),
  (150, 'Chicken', 'Baby chicken',            '600 – 800 g',  178, 'pce', 'direct', 88,   null, null, 'K. Pornthip Meesat', '2025-02-24', 'Cost list: sometimes 92 THB; FARM K. NAT sells baby chicken at 70 THB'),
  -- Red Label cuts: 83 THB/kg ÷ yield
  (210, 'Chicken parts (Red Label)', 'Wing Red Label',              '90 g',        162, 'kg', 'yield', 83, 'Red Label chicken', 75, 'K. Pornthip Meesat', '2025-02-24', null),
  (220, 'Chicken parts (Red Label)', 'Leg Red Label',               '220 – 240 g', 283, 'kg', 'yield', 83, 'Red Label chicken', 75, 'K. Pornthip Meesat', '2025-02-24', null),
  (230, 'Chicken parts (Red Label)', 'Drumstick Red Label',         '100 – 120 g', 294, 'kg', 'yield', 83, 'Red Label chicken', 75, 'K. Pornthip Meesat', '2025-02-24', null),
  (240, 'Chicken parts (Red Label)', 'Leg thigh Red Label',         '120 – 140 g', 294, 'kg', 'yield', 83, 'Red Label chicken', 75, 'K. Pornthip Meesat', '2025-02-24', 'Cost list: thigh also bought as such at 95 THB/kg'),
  (250, 'Chicken parts (Red Label)', 'Breasts Red Label',           '180 – 200 g', 342, 'kg', 'yield', 83, 'Red Label chicken', 75, 'K. Pornthip Meesat', '2025-02-24', null),
  (260, 'Chicken parts (Red Label)', 'Supreme Red Label',           '200 – 220 g', 354, 'kg', 'yield', 83, 'Red Label chicken', 75, 'K. Pornthip Meesat', '2025-02-24', null),
  (270, 'Chicken parts (Red Label)', 'Chicken carcass',             '600 g',        46, 'kg', 'yield', 83, 'Red Label chicken', 75, 'K. Pornthip Meesat', '2025-02-24', 'By-product: with a yield cost it shows a loss'),
  (280, 'Chicken parts (Red Label)', 'Chicken liver Red Label',     '500 g/pack',  167, 'kg', 'yield', 83, 'Red Label chicken', 75, 'K. Pornthip Meesat', '2025-02-24', null),
  (290, 'Chicken parts (Red Label)', 'Chicken gizzard Red Label',   '500 g/pack',  167, 'kg', 'yield', 83, 'Red Label chicken', 75, 'K. Pornthip Meesat', '2025-02-24', null),
  (300, 'Chicken parts (Red Label)', 'Chicken heart Red Label',     '500 g/pack',  157, 'kg', 'yield', 83, 'Red Label chicken', 75, 'K. Pornthip Meesat', '2025-02-24', 'Cost list: heart also bought as such at 55 THB/kg'),
  (310, 'Chicken parts (Red Label)', 'Chicken feet Red Label',      '1 kg/pack',   183, 'kg', 'yield', 83, 'Red Label chicken', 75, 'K. Pornthip Meesat', '2025-02-24', null),
  (320, 'Chicken parts (Red Label)', 'Chicken neck Red Label',      '1 kg/pack',    46, 'kg', 'yield', 83, 'Red Label chicken', 75, 'K. Pornthip Meesat', '2025-02-24', 'By-product: with a yield cost it shows a loss'),
  (330, 'Chicken parts (Red Label)', 'Chicken sot-l''y-laisse (oyster)', '500 g/pack', 259, 'kg', 'yield', 83, 'Red Label chicken', 75, 'K. Pornthip Meesat', '2025-02-24', 'No buying price in the file: costed as a Red Label cut'),
  -- Whole duck
  (410, 'Duck', 'Golden Signature Duck female',  '2.3 – 2.9 kg', 400, 'kg', 'direct', 130, null, null, null,            '2025-02-24', 'Supplier not on the cost list'),
  (420, 'Duck', 'Golden Signature Duck male',    '3.0 – 3.6 kg', 420, 'kg', 'direct', 130, null, null, null,            '2025-02-24', 'Supplier not on the cost list'),
  (430, 'Duck', 'Moscovy / Barbary duck female', '1.8 – 2.0 kg', 320, 'kg', 'direct', 155, null, null, 'Pairatch Farm', '2025-02-24', 'Cost list: 140 – 155 THB/kg'),
  (440, 'Duck', 'Moscovy / Barbary duck male',   '3.5 – 3.8 kg', 340, 'kg', 'direct', 155, null, null, 'Pairatch Farm', '2025-02-24', 'Cost list: 140 – 155 THB/kg'),
  -- Duck cuts: whole-duck price per kg ÷ yield
  (510, 'Duck parts', 'Golden Signature Duck female fillet', '300 – 350 g/pce', 820, 'kg', 'yield', 130, 'Golden Signature Duck', 75, null, '2025-02-24', null),
  (520, 'Duck parts', 'Golden Signature Duck male fillet',   '370 – 400 g/pce', 900, 'kg', 'yield', 130, 'Golden Signature Duck', 75, null, '2025-02-24', 'Price list says 900 THB/kg; the file''s margin used 820'),
  (530, 'Duck parts', 'Moscovy / Barbary duck female fillet', '180 – 200 g/pce', 746, 'kg', 'yield', 155, 'Barbary duck', 75, 'Pairatch Farm', '2025-02-24', null),
  (540, 'Duck parts', 'Moscovy / Barbary duck male fillet',   '300 – 350 g/pce', 746, 'kg', 'yield', 155, 'Barbary duck', 75, 'Pairatch Farm', '2025-02-24', null),
  (550, 'Duck parts', 'Moscovy / Barbary duck female leg',    '180 – 200 g/pce', 533, 'kg', 'yield', 155, 'Barbary duck', 75, 'Pairatch Farm', '2025-02-24', null),
  (560, 'Duck parts', 'Moscovy / Barbary duck male leg',      '300 – 320 g/pce', 533, 'kg', 'yield', 155, 'Barbary duck', 75, 'Pairatch Farm', '2025-02-24', null),
  (570, 'Duck parts', 'Duck carcass',                         '600 g',            76, 'kg', 'yield', 155, 'Barbary duck', 75, 'Pairatch Farm', '2025-02-24', 'By-product: with a yield cost it shows a loss'),
  (580, 'Duck parts', 'Duck aiguillettes / fillets',          '20 – 30 g/pce',   350, 'kg', 'yield', 155, 'Barbary duck', 75, 'Pairatch Farm', '2025-02-24', null),
  (590, 'Duck parts', 'Duck wings + manchon',                 'about 150 g',     231, 'kg', 'yield', 155, 'Barbary duck', 75, 'Pairatch Farm', '2025-02-24', null),
  (600, 'Duck parts', 'Duck liver',                           '1 kg/pack',       259, 'kg', 'direct', 150, null, null, 'Pairatch Farm', '2025-02-24', 'Cost list: duck offal (liver + heart + gizzard) 150 THB/kg'),
  (610, 'Duck parts', 'Duck gizzard',                         '1 kg/pack',       259, 'kg', 'direct', 150, null, null, 'Pairatch Farm', '2025-02-24', 'Cost list: duck offal (liver + heart + gizzard) 150 THB/kg'),
  (620, 'Duck parts', 'Duck female trachea / windpipe',       '10 – 15 g',        15, 'pce', 'direct', null, null, null, 'Pairatch Farm', null, 'No buying price per piece in the file'),
  (630, 'Duck parts', 'Duck male trachea / windpipe',         '20 – 30 g',        15, 'pce', 'direct', null, null, null, 'Pairatch Farm', null, 'No buying price per piece in the file'),
  -- Special poultry: selling price for 11 pieces and more (as in the file)
  (710, 'Special poultry', 'Capon',       '3 – 4 kg',         508, 'kg',  'direct', 260, null, null, 'K. Pornthip Meesat', '2025-02-24', '1 – 10 pcs: 520 THB/kg'),
  (720, 'Special poultry', 'Guinea fowl', '0.9 – 1.1 kg/pce', 720, 'pce', 'direct', 400, null, null, 'CHAIRAT FARM',       '2025-02-24', '1 – 10 pcs: 780 THB/pce · FARM K. NAT: 490 THB/pce'),
  (730, 'Special poultry', 'Goose',       '3 – 4 kg/pce',     580, 'kg',  'direct', 300, null, null, 'FARM K. NAT',        '2025-02-24', '1 – 10 pcs: 620 THB/kg'),
  (740, 'Special poultry', 'Quails',      '130 – 160 g/pce',  335, 'kg',  'direct', 75,  null, null, 'CHAIRAT FARM',       '2025-02-24', 'To check: sold per kg (6 pcs/kg), cost list 20 – 50 THB per bird'),
  (750, 'Special poultry', 'Quails',      '190 – 250 g/pce',  426, 'kg',  'direct', 55,  null, null, 'CHAIRAT FARM',       '2025-02-24', 'To check: sold per kg (4 – 5 pcs/kg), cost list 20 – 50 THB per bird'),
  (760, 'Special poultry', 'Pigeon',      '300 – 350 g/pce',  508, 'pce', 'direct', 230, null, null, 'FARM K. KORN',       '2025-02-24', '1 – 10 pcs: 550 THB/pce · CHAIRAT FARM: 230'),
  (770, 'Special poultry', 'Pigeon',      '350 – 400 g/pce',  589, 'pce', 'direct', 320, null, null, 'FARM K. KORN',       '2025-02-24', '1 – 10 pcs: 630 THB/pce · CHAIRAT FARM: 300'),
  (780, 'Special poultry', 'Pigeon',      '400 g + /pce',     639, 'pce', 'direct', null, null, null, 'FARM K. KORN',      null, '1 – 10 pcs: 680 THB/pce · no buying price in the file'),
  (790, 'Special poultry', 'Turkey',      '4.5 – 6 kg',       497, 'kg',  'direct', 250, null, null, 'FARM K. NAT',        '2025-02-24', '1 – 10 pcs: 517 THB/kg'),
  (800, 'Special poultry', 'Turkey',      '6 – 9 kg',         497, 'kg',  'direct', 280, null, null, 'FARM K. NAT',        '2025-02-24', '1 – 10 pcs: 517 THB/kg · giant double breast'),
  (810, 'Special poultry', 'Rabbit',      '1.1 – 1.4 kg/pce', 467, 'kg',  'direct', 280, null, null, 'FARM K. KORN',       '2025-02-24', '1 – 10 pcs: 490 THB/kg'),
  -- Eggs and dairy
  (910, 'Eggs & dairy', 'Eggs',              'below 90 pcs', 7.5, 'pce', 'direct', 4.8,  null, null, 'Naeville Food', '2025-02-24', null),
  (920, 'Eggs & dairy', 'Eggs',              '90 pcs +',     7,   'pce', 'direct', 4.8,  null, null, 'Naeville Food', '2025-02-24', null),
  (930, 'Eggs & dairy', 'Duck eggs size 0',  '30 pcs +',     14,  'pce', 'direct', 7.26, null, null, 'Pairatch Farm', '2025-02-24', null),
  (940, 'Eggs & dairy', 'Greek yogurt',      '450 g',        230, 'pce', 'direct', 152,  null, null, 'Dairy Home',    '2025-02-24', null),
  (950, 'Eggs & dairy', 'Grass fed milk',    '1200 ml',      130, 'pce', 'direct', 33.98, null, null, 'Dairy Home',   '2025-02-24', 'To check: the cost list says 107.20 THB per 1200 ml gallon'),
  -- Under Roof (Halal), price list valid 01.07.2025 ("New price" column)
  (1010, 'Under Roof (Halal)', 'Chicken',              '1.4 – 1.6 kg', 167.64, 'kg', 'direct', 67,  null, null, 'K. Pom', '2025-02-24', 'Cost list: 58 THB/kg'),
  (1020, 'Under Roof (Halal)', 'Chicken',              '1.0 – 1.1 kg', 184.15, 'kg', 'direct', null, null, null, 'K. Pom', null, 'No buying price in the file'),
  (1030, 'Under Roof (Halal)', 'Full wing',            '90 g',         222.25, 'kg', 'direct', 90,  null, null, 'K. Pom', '2025-02-24', null),
  (1040, 'Under Roof (Halal)', 'Middle wing',          null,           304.80, 'kg', 'direct', 145, null, null, 'K. Pom', '2025-02-24', null),
  (1050, 'Under Roof (Halal)', 'Top wing',             null,           198.12, 'kg', 'direct', 115, null, null, 'K. Pom', '2025-02-24', null),
  (1060, 'Under Roof (Halal)', 'Leg',                  '180 – 230 g',  187.96, 'kg', 'direct', 85,  null, null, 'K. Pom', '2025-02-24', 'Cost list: 75 THB/kg'),
  (1070, 'Under Roof (Halal)', 'Thigh',                null,           154.94, 'kg', 'direct', 95,  null, null, 'K. Pom', '2025-02-24', 'Cost list: 80 THB/kg'),
  (1080, 'Under Roof (Halal)', 'Drumstick',            null,           177.80, 'kg', 'direct', null, null, null, 'K. Pom', null, 'No buying price in the file'),
  (1090, 'Under Roof (Halal)', 'Chicken feet',         null,           241.30, 'kg', 'direct', null, null, null, 'K. Pom', null, 'No buying price in the file'),
  (1100, 'Under Roof (Halal)', 'Breasts with skin',    '180 – 270 g',  170.00, 'kg', 'direct', 75,  null, null, 'K. Pom', '2025-02-24', 'Cost list: 70 THB/kg'),
  (1110, 'Under Roof (Halal)', 'Breasts without skin', '180 – 270 g',  150.45, 'kg', 'direct', 90,  null, null, 'K. Pom', '2025-02-24', 'To check: the PACE price list (01.07.2025) says 177 THB/kg · cost list 75 THB/kg');
end $$;


-- ----------------------------------------------------------------------------
-- Writing (Clément, Khun Jum)
-- ----------------------------------------------------------------------------
create or replace function public.purchase_margin_check()
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.purchase_sees_revenue() then
    raise exception 'purchases: not allowed for this account' using errcode = '42501';
  end if;
end $$;
revoke all on function public.purchase_margin_check() from public, anon, authenticated;

-- Create (no id) or change a product. p.active = false retires it.
create or replace function public.purchase_save_cost(p jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id    uuid := nullif(p->>'id', '')::uuid;
  v_basis text := coalesce(nullif(p->>'basis', ''), 'direct');
  v_unit  text := coalesce(nullif(p->>'sell_unit', ''), 'kg');
begin
  perform public.purchase_margin_check();
  if nullif(trim(p->>'product'), '') is null or nullif(trim(p->>'section'), '') is null then
    raise exception 'purchases: write the section and the product' using errcode = '22023';
  end if;
  if v_basis not in ('direct', 'yield') then raise exception 'purchases: cost basis direct or yield' using errcode = '22023'; end if;
  if v_unit not in ('kg', 'pce') then raise exception 'purchases: sold per kg or per piece' using errcode = '22023'; end if;
  if v_basis = 'yield' and (nullif(trim(p->>'yield_group'), '') is null or coalesce(nullif(p->>'yield_pct', '')::numeric, 0) <= 0
                            or (p->>'yield_pct')::numeric > 100) then
    raise exception 'purchases: a yield cost needs the bird and a yield between 1 and 100 %%' using errcode = '22023';
  end if;
  if v_id is null then
    insert into public.purchase_cost_prices (section, product, size, sell_price, sell_unit, basis, buy_price, yield_group, yield_pct,
                                             supplier, price_date, note, sort, updated_by)
    values (trim(p->>'section'), trim(p->>'product'), nullif(trim(p->>'size'), ''), nullif(p->>'sell_price', '')::numeric, v_unit,
            v_basis, nullif(p->>'buy_price', '')::numeric,
            case when v_basis = 'yield' then trim(p->>'yield_group') end,
            case when v_basis = 'yield' then (p->>'yield_pct')::numeric end,
            nullif(trim(p->>'supplier'), ''), nullif(p->>'price_date', '')::date, nullif(trim(p->>'note'), ''),
            coalesce((select max(sort) + 1 from public.purchase_cost_prices where section = trim(p->>'section')), 2000),
            auth.uid())
    returning id into v_id;
  else
    update public.purchase_cost_prices
       set section = trim(p->>'section'), product = trim(p->>'product'), size = nullif(trim(p->>'size'), ''),
           sell_price = nullif(p->>'sell_price', '')::numeric, sell_unit = v_unit, basis = v_basis,
           buy_price = nullif(p->>'buy_price', '')::numeric,
           yield_group = case when v_basis = 'yield' then trim(p->>'yield_group') end,
           yield_pct = case when v_basis = 'yield' then (p->>'yield_pct')::numeric end,
           supplier = nullif(trim(p->>'supplier'), ''), price_date = nullif(p->>'price_date', '')::date,
           note = nullif(trim(p->>'note'), ''), active = coalesce((p->>'active')::boolean, active),
           updated_by = auth.uid(), updated_at = now()
     where id = v_id;
    if not found then raise exception 'purchases: product not found' using errcode = 'P0002'; end if;
  end if;
  return v_id;
end $$;

-- One yield for every cut of a bird (e.g. all Red Label cuts at 72 %).
create or replace function public.purchase_set_yield(p_group text, p_pct numeric)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare n int;
begin
  perform public.purchase_margin_check();
  if p_pct is null or p_pct <= 0 or p_pct > 100 then
    raise exception 'purchases: a yield between 1 and 100 %%' using errcode = '22023';
  end if;
  update public.purchase_cost_prices set yield_pct = p_pct, updated_by = auth.uid(), updated_at = now()
   where basis = 'yield' and yield_group = p_group;
  get diagnostics n = row_count;
  if n = 0 then raise exception 'purchases: no cut uses this bird' using errcode = 'P0002'; end if;
  return n;
end $$;

revoke all on function public.purchase_save_cost(jsonb)          from public, anon;
revoke all on function public.purchase_set_yield(text, numeric)  from public, anon;
grant execute on function public.purchase_save_cost(jsonb)         to authenticated, service_role;
grant execute on function public.purchase_set_yield(text, numeric) to authenticated, service_role;
