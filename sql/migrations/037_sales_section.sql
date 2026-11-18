-- ============================================================================
-- Migration 037 — PACE › Sales: one customer list, sales history, call list
-- ============================================================================
-- Written 18 Nov 2026. The sales team's email (7 requests) and Clément's
-- answer: everything moves into PROSUN PACE — a Sales section inside PACE,
-- the old CRM retired later. Each salesperson sees only their own clients.
-- PACE must tell them which client is at risk and which one to call NOW.
-- Days missing are calculated from the client and the working papers; the
-- sales report brings the past. Export to Excel for their reporting. Order
-- follow-up uses the delivery team's data. Birds coming in: not needed.
--
-- Decisions (Clément, 18 Nov):
--   * Client code (CR / CH / CM / CB / CO / RT / ZA…) is the key — the sales
--     report, Odoo and PACE customers all use it.
--   * Portfolios: one per salesperson (02 Christophe, 12 James, 13 Chovie,
--     14 Pammy, from the report's sheets). "Not transferred yet" (K. Pom's
--     clients, sheet 08) is its own category; clients with no salesperson in
--     the report are "House". Both are seen only by admin (Clément, Khun Jum)
--     and the sales director.
--   * Christophe's clients stay under him for now (until the LINE robot is in
--     each client group).
--   * PSFood (ZA001) is another company: its purchases are sales, recorded
--     for the company (House).
--
-- What this adds
--   1. sales_reps            — code ↔ login (email before @), director flag
--   2. sales_customers       — one row per client code, portfolio, zone
--   3. sales_customer_names  — every name a client goes by (to read papers)
--   4. sales_monthly         — revenue per client, month, company (report)
--   5. sales_invoices        — Odoo invoices (dates → order rhythm)
--   6. sales_calls           — "called" log, one click from the call list
--   7. Functions:
--        sales_me()                     who am I, what may I see
--        sales_clients()                the list with days missing, rhythm,
--                                       status (call now / at risk / lost /
--                                       new / ok) and the reason
--        sales_client_detail(code)      history, invoices, orders, calls
--        sales_deliveries(day)          my clients' orders due that day,
--                                       with the delivery team's status
--        sales_log_call(code, outcome, note)
--        sales_unmatched_names()        paper names not linked to a code
--        sales_link_name(name, code)    link one (admin, sales director)
--        sales_assign(code, rep, portfolio)   move a client (admin)
--        sales_import(data, source)     load a sales report (admin)
--
-- Order dates come from two places: Odoo invoices (the report has September
-- 2026; more months as accounting exports them) and working papers (every
-- paper photographed since 2 Nov is an order on its delivery day). Monthly
-- revenue comes from the report.
--
-- Run order: after 036 (uses client_match_key). Safe to re-run.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Salespeople
-- ----------------------------------------------------------------------------
create table if not exists public.sales_reps (
  code         text primary key,                 -- '02', '12', '13', '14' (report sheet = Odoo S02…)
  short_name   text not null,
  full_name    text not null,
  login_hint   text not null,                    -- the login email before @
  profile_id   uuid references public.profiles(id),
  is_director  boolean not null default false,   -- sees every portfolio, Not transferred and House
  active       boolean not null default true
);
comment on table public.sales_reps is
  'Salespeople of PACE › Sales. A login is linked by profile_id or, until set, by its email before @ = login_hint. Migration 037.';

insert into public.sales_reps (code, short_name, full_name, login_hint, is_director) values
  ('02', 'Christophe', 'Christophe Louis Georges Noth', 'christophe', true),
  ('12', 'James',      'Thananat Popeung',              'james',      false),
  ('13', 'Chovie',     'Chotika Suksomboon',            'chovie',     false),
  ('14', 'Pammy',      'Thanidaphan Jirajarasthana',    'pammy',      false)
on conflict (code) do update set short_name = excluded.short_name, full_name = excluded.full_name,
  login_hint = excluded.login_hint, is_director = excluded.is_director;


-- ----------------------------------------------------------------------------
-- 2. Customers
-- ----------------------------------------------------------------------------
create table if not exists public.sales_customers (
  code              text primary key,
  name              text not null,                -- clean name (report, else Odoo)
  report_name       text,                         -- as written in the report, notes included
  notes             text,                         -- "*11/25 Come from 08", "**23/2/26 to 12"…
  odoo_name         text,                         -- Odoo "Complete Name" (often the legal name)
  area              text,                         -- BKK / UPCOUNTRY
  zone              text,                         -- Bangkok, Phuket, Samui, Pattaya…
  city              text,
  phone             text,
  email             text,
  salesperson_code  text references public.sales_reps(code),
  portfolio         text not null default 'house'
                      check (portfolio in ('rep', 'not_transferred', 'house')),
  odoo_salesperson  text,                         -- S08, S12… as in Odoo
  assigned_manually boolean not null default false,   -- a later import keeps the hand-made assignment
  source            text,
  updated_at        timestamptz not null default now(),
  constraint sales_customers_rep_needs_code check (portfolio <> 'rep' or salesperson_code is not null)
);
create index if not exists sales_customers_rep_idx on public.sales_customers (salesperson_code, portfolio);
comment on table public.sales_customers is
  'One row per client code (Odoo reference). portfolio rep = a salesperson''s client; not_transferred and house: '
  'admin and sales director only. Migration 037.';

create table if not exists public.sales_customer_names (
  code      text not null references public.sales_customers(code) on delete cascade,
  name      text not null,
  name_key  text generated always as (public.client_match_key(name)) stored,
  linked_by uuid references public.profiles(id),     -- null = from an import
  linked_at timestamptz not null default now(),
  primary key (code, name)
);
create index if not exists sales_customer_names_key_idx on public.sales_customer_names (name_key);

create table if not exists public.sales_monthly (
  code     text not null references public.sales_customers(code) on delete cascade,
  month    date not null check (extract(day from month) = 1),
  company  text not null check (company in ('Prosun Farm', 'Prosun Food')),
  amount   numeric not null,
  source   text,
  primary key (code, month, company)
);
create index if not exists sales_monthly_month_idx on public.sales_monthly (month);

create table if not exists public.sales_invoices (
  company          text not null check (company in ('Prosun Farm', 'Prosun Food')),
  number           text not null,
  code             text references public.sales_customers(code) on delete set null,
  partner_name     text,
  invoice_date     date not null,
  untaxed          numeric,
  total            numeric,
  odoo_salesperson text,
  payment_status   text,
  source           text,
  primary key (company, number)
);
create index if not exists sales_invoices_code_idx on public.sales_invoices (code, invoice_date);

create table if not exists public.sales_calls (
  id         uuid primary key default gen_random_uuid(),
  code       text not null references public.sales_customers(code) on delete cascade,
  called_by  uuid not null references public.profiles(id) default auth.uid(),
  called_at  timestamptz not null default now(),
  outcome    text not null check (outcome in ('ordered', 'call_back', 'no_answer', 'no_need', 'problem')),
  note       text
);
create index if not exists sales_calls_code_idx on public.sales_calls (code, called_at desc);

-- Read and written only through the functions below.
alter table public.sales_reps           enable row level security;
alter table public.sales_customers      enable row level security;
alter table public.sales_customer_names enable row level security;
alter table public.sales_monthly        enable row level security;
alter table public.sales_invoices       enable row level security;
alter table public.sales_calls          enable row level security;
revoke all on public.sales_reps, public.sales_customers, public.sales_customer_names,
              public.sales_monthly, public.sales_invoices, public.sales_calls from anon, authenticated;
grant all on public.sales_reps, public.sales_customers, public.sales_customer_names,
             public.sales_monthly, public.sales_invoices, public.sales_calls to service_role;


-- ----------------------------------------------------------------------------
-- 3. Who is asking
-- ----------------------------------------------------------------------------
-- The salesperson code of the person signed in (null if not a salesperson).
create or replace function public.sales_my_code()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select r.code
  from public.sales_reps r
  left join auth.users u on u.id = auth.uid()
  where r.active
    and (r.profile_id = auth.uid()
         or (r.profile_id is null and lower(split_part(u.email, '@', 1)) = r.login_hint))
  order by (r.profile_id = auth.uid()) desc nulls last
  limit 1;
$$;

-- 'all' (admin, sales director), 'own' (a salesperson) or null.
create or replace function public.sales_scope()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select case
    when coalesce(public.current_role(), '') in ('admin', 'director') then 'all'
    when exists (select 1 from public.sales_reps r where r.code = public.sales_my_code() and r.is_director) then 'all'
    when public.sales_my_code() is not null and coalesce(public.current_role(), '') in ('sales', 'director') then 'own'
  end;
$$;

create or replace function public.sales_can_see(p_code text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select case public.sales_scope()
    when 'all' then true
    when 'own' then exists (select 1 from public.sales_customers c
                            where c.code = p_code and c.portfolio = 'rep'
                              and c.salesperson_code = public.sales_my_code())
    else false
  end;
$$;

revoke all on function public.sales_my_code(), public.sales_scope(), public.sales_can_see(text) from public, anon;
grant execute on function public.sales_my_code(), public.sales_scope(), public.sales_can_see(text) to authenticated, service_role;


-- ----------------------------------------------------------------------------
-- 4. Reading a client off a working paper
-- ----------------------------------------------------------------------------
-- 1) a code written in the name ("Ledu (CR010)"); 2) a name the client goes
-- by, exactly (case, spaces and punctuation ignored); 3) the same without
-- anything in brackets. Only an unambiguous match counts.
create or replace function public.sales_code_for_name(p_name text)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v text;
  k text;
begin
  if p_name is null or btrim(p_name) = '' then return null; end if;
  v := substring(upper(p_name) from '([A-Z]{2}[0-9]{3,4})');
  if v is not null and exists (select 1 from public.sales_customers where code = v) then return v; end if;
  v := null;
  foreach k in array array[public.client_match_key(p_name),
                           public.client_match_key(regexp_replace(p_name, '\([^)]*\)', '', 'g'))] loop
    continue when k is null;
    select min(n.code) into v from public.sales_customer_names n where n.name_key = k
      having count(distinct n.code) = 1;
    if v is not null then return v; end if;
    v := null;
  end loop;
  return null;
end;
$$;
revoke all on function public.sales_code_for_name(text) from public, anon, authenticated;

-- Every working paper with its client code (one paper = one order on its delivery day).
create or replace function public.sales_paper_orders()
returns table (paper_id uuid, code text, order_date date, company text, customer_name text, status text)
language sql
stable
security definer
set search_path = public
as $$
  with names as (
    select k.customer_name, public.sales_code_for_name(k.customer_name) as code
    from (select distinct p.customer_name from public.weighing_papers p where p.customer_name is not null) k)
  select p.id, n.code, coalesce(p.delivery_date, p.work_date), p.company, p.customer_name, p.status
  from public.weighing_papers p
  join names n on n.customer_name = p.customer_name
  where p.status <> 'failed';
$$;
revoke all on function public.sales_paper_orders() from public, anon, authenticated;


-- ----------------------------------------------------------------------------
-- 5. sales_me
-- ----------------------------------------------------------------------------
create or replace function public.sales_me()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'scope', public.sales_scope(),
    'code', public.sales_my_code(),
    'is_admin', coalesce(public.current_role(), '') = 'admin',
    'reps', (select coalesce(jsonb_agg(jsonb_build_object('code', r.code, 'name', r.short_name,
                                                           'full_name', r.full_name, 'director', r.is_director)
                                       order by r.code), '[]'::jsonb)
             from public.sales_reps r where r.active
               and (public.sales_scope() = 'all' or r.code = public.sales_my_code())));
$$;
revoke all on function public.sales_me() from public, anon;
grant execute on function public.sales_me() to authenticated, service_role;


-- ----------------------------------------------------------------------------
-- 6. sales_clients — the list
-- ----------------------------------------------------------------------------
-- Per client:
--   last_order     latest order date known (invoice or working paper)
--   days_missing   today − last_order
--   rhythm         usual days between orders: median gap over the last 180
--                  days, from 3 order dates or more
--   m12            revenue per month, the 12 report months (Farm + Food)
--   last3 / prev3  revenue of the 3 latest report months / the 3 before
--   status, reason:
--     call_now  late against their own rhythm: days_missing ≥ rhythm × 1.5
--               (and ≥ rhythm + 2); without a rhythm, 21 days or more
--               silent after buying in the last 6 months
--     lost      nothing for more than 120 days, but revenue in the report
--     at_risk   last 3 months under 60 % of the 3 before (≥ 10,000 THB
--               before), or 2 postponed orders or more in 30 days
--     new       first sale (report) in the last 3 months, after a year of history
--     ok        ordering on rhythm
--     none      no sale known
-- House clients with no sale at all are left out of the list (counted in
-- 'hidden_inactive'); Not transferred clients are always listed.
create or replace function public.sales_clients()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_scope  text := public.sales_scope();
  v_code   text := public.sales_my_code();
  v_today  date := (now() at time zone 'Asia/Bangkok')::date;
  v_last   date;            -- latest report month
  v_months date[];
  v_rows   jsonb;
  v_hidden int;
  v_inv_to date;
  v_pap_from date;
begin
  if v_scope is null then
    raise exception 'not allowed' using errcode = '42501';
  end if;

  select max(month) into v_last from public.sales_monthly;
  v_last := coalesce(v_last, date_trunc('month', v_today)::date - interval '1 month');
  select array_agg((v_last - make_interval(months => 11 - g))::date order by g)
    into v_months from generate_series(0, 11) g;
  select max(invoice_date) into v_inv_to from public.sales_invoices;
  select min(order_date) into v_pap_from from public.sales_paper_orders();

  with vis as (
    select c.* from public.sales_customers c
    where v_scope = 'all' or (c.portfolio = 'rep' and c.salesperson_code = v_code)
  ),
  orders as (
    select distinct code, d from (
      select i.code, i.invoice_date as d from public.sales_invoices i
        where i.code in (select code from vis) and coalesce(i.untaxed, i.total, 0) > 0
      union all
      select o.code, o.order_date from public.sales_paper_orders() o
        where o.code in (select code from vis) and o.order_date <= v_today
    ) u
  ),
  last_order as (
    select code, max(d) as last_d, min(d) as first_d, count(*) as n_dates from orders group by code
  ),
  gaps as (
    select code, d - lag(d) over (partition by code order by d) as gap
    from orders where d >= v_today - 180
  ),
  rhythm as (
    select code, round(percentile_cont(0.5) within group (order by gap))::int as rhythm, count(*) as n_gaps
    from gaps where gap is not null group by code having count(*) >= 2
  ),
  rev as (
    select m.code,
           jsonb_agg(coalesce(s.amt, 0) order by m.month) as m12,
           sum(coalesce(s.amt, 0)) filter (where m.month > v_last - interval '3 months') as last3,
           sum(coalesce(s.amt, 0)) filter (where m.month <= v_last - interval '3 months'
                                             and m.month > v_last - interval '6 months') as prev3,
           sum(coalesce(s.amt, 0)) as total12,
           sum(coalesce(s.farm, 0)) as farm12,
           sum(coalesce(s.food, 0)) as food12,
           max(m.month) filter (where coalesce(s.amt, 0) > 0) as last_month,
           min(m.month) filter (where coalesce(s.amt, 0) > 0) as first_month
    from (select v.code, mm as month from vis v, unnest(v_months) mm) m
    left join (select code, month, sum(amount) as amt,
                      sum(amount) filter (where company = 'Prosun Farm') as farm,
                      sum(amount) filter (where company = 'Prosun Food') as food
               from public.sales_monthly group by code, month) s
      on s.code = m.code and s.month = m.month
    group by m.code
  ),
  first_ever as (
    select code, min(month) as first_month from public.sales_monthly where amount > 0 group by code
  ),
  postponed as (
    select o.code, count(distinct h.paper_id) as n
    from public.weighing_postponements h
    join public.sales_paper_orders() o on o.paper_id = h.paper_id
    where h.created_at >= now() - interval '30 days'
    group by o.code
  ),
  calls as (
    select distinct on (code) code, called_at, outcome, note, pr.full_name as by_name
    from public.sales_calls k left join public.profiles pr on pr.id = k.called_by
    order by code, called_at desc
  ),
  base as (
    select v.*, lo.last_d, lo.first_d, lo.n_dates, rh.rhythm,
           (v_today - lo.last_d) as days_missing,
           r.m12, coalesce(r.last3, 0) as last3, coalesce(r.prev3, 0) as prev3,
           coalesce(r.total12, 0) as total12, coalesce(r.farm12, 0) as farm12, coalesce(r.food12, 0) as food12,
           r.last_month, fe.first_month,
           coalesce(pp.n, 0) as postponed30,
           k.called_at, k.outcome, k.note as call_note, k.by_name as call_by,
           -- a lower bound when only the month is known
           case when lo.last_d is null and r.last_month is not null
                then v_today - (r.last_month + interval '1 month - 1 day')::date end as days_min
    from vis v
    left join last_order lo on lo.code = v.code
    left join rhythm rh on rh.code = v.code
    left join rev r on r.code = v.code
    left join first_ever fe on fe.code = v.code
    left join postponed pp on pp.code = v.code
    left join calls k on k.code = v.code
  ),
  judged as (
    select b.*,
      case
        when b.days_missing is not null and b.rhythm is not null and b.days_missing <= 120
             and b.days_missing >= greatest(ceil(b.rhythm * 1.5), b.rhythm + 2) then 'call_now'
        when b.days_missing is not null and b.rhythm is null and b.days_missing between 21 and 120
             and (b.last_d >= v_today - 180 or b.last3 > 0) then 'call_now'
        when b.days_missing is null and b.days_min is not null and b.days_min between 21 and 120 then 'call_now'
        when coalesce(b.days_missing, b.days_min) > 120 and b.total12 > 0 then 'lost'
        when b.prev3 >= 10000 and b.last3 < 0.6 * b.prev3 then 'at_risk'
        when b.postponed30 >= 2 then 'at_risk'
        when b.first_month is not null and b.first_month > v_months[1]
             and b.first_month >= date_trunc('month', v_today - 90)::date then 'new'
        when b.days_missing is not null or b.total12 > 0 then 'ok'
        else 'none'
      end as status
    from base b
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'code', j.code, 'name', j.name, 'odoo_name', j.odoo_name, 'notes', j.notes,
           'area', j.area, 'zone', j.zone, 'portfolio', j.portfolio,
           'salesperson', j.salesperson_code, 'odoo_salesperson', j.odoo_salesperson,
           'last_order', j.last_d, 'days_missing', j.days_missing, 'days_min', j.days_min,
           'last_month', j.last_month, 'rhythm', j.rhythm, 'n_dates', coalesce(j.n_dates, 0),
           'm12', j.m12, 'last3', round(j.last3, 2), 'prev3', round(j.prev3, 2),
           'total12', round(j.total12, 2), 'farm12', round(j.farm12, 2), 'food12', round(j.food12, 2),
           'postponed30', j.postponed30,
           'status', j.status,
           'drop_pct', case when j.prev3 > 0 then round(100 * (j.last3 - j.prev3) / j.prev3) end,
           'call', case when j.called_at is not null then jsonb_build_object(
                     'at', j.called_at, 'outcome', j.outcome, 'note', j.call_note, 'by', j.call_by) end)
         order by case j.status when 'call_now' then 0 when 'at_risk' then 1 when 'lost' then 2
                                when 'new' then 3 when 'ok' then 4 else 5 end,
                  j.total12 desc, j.name), '[]'::jsonb)
    into v_rows
  from judged j
  where j.portfolio <> 'house' or j.status <> 'none';

  with active as (
    select code from public.sales_monthly where amount <> 0
    union select code from public.sales_invoices where code is not null
    union select code from public.sales_paper_orders() where code is not null)
  select count(*) into v_hidden
  from public.sales_customers c
  where v_scope = 'all' and c.portfolio = 'house'
    and c.code not in (select code from active);

  return jsonb_build_object(
    'today', v_today,
    'scope', v_scope,
    'my_code', v_code,
    'months', to_jsonb(v_months),
    -- report months with no figure at all (Oct 2025 is missing from the 09-2026 report)
    'months_empty', (select coalesce(jsonb_agg(mm order by mm), '[]'::jsonb) from unnest(v_months) mm
                     where not exists (select 1 from public.sales_monthly s where s.month = mm)),
    'invoices_to', v_inv_to,
    'invoices_from', (select min(invoice_date) from public.sales_invoices),
    'papers_from', v_pap_from,
    'report_to', (select max(month) from public.sales_monthly),
    'hidden_inactive', v_hidden,
    'clients', v_rows,
    'loaded_at', now());
end;
$$;
revoke all on function public.sales_clients() from public, anon;
grant execute on function public.sales_clients() to authenticated, service_role;


-- ----------------------------------------------------------------------------
-- 7. sales_client_detail
-- ----------------------------------------------------------------------------
create or replace function public.sales_client_detail(p_code text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  c public.sales_customers;
begin
  if not public.sales_can_see(p_code) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  select * into c from public.sales_customers where code = p_code;
  if not found then raise exception 'unknown client %', p_code using errcode = 'P0002'; end if;

  return jsonb_build_object(
    'client', to_jsonb(c) - 'assigned_manually' - 'source',
    'can_assign', coalesce(public.current_role(), '') = 'admin',
    'names', (select coalesce(jsonb_agg(n.name order by n.name), '[]'::jsonb)
              from public.sales_customer_names n where n.code = p_code),
    'monthly', (select coalesce(jsonb_agg(jsonb_build_object('month', m.month, 'company', m.company, 'amount', m.amount)
                                         order by m.month, m.company), '[]'::jsonb)
                from public.sales_monthly m where m.code = p_code),
    'invoices', (select coalesce(jsonb_agg(x order by x->>'date' desc, x->>'number' desc), '[]'::jsonb) from (
                   select jsonb_build_object('company', i.company, 'number', i.number, 'date', i.invoice_date,
                                             'untaxed', i.untaxed, 'total', i.total, 'payment', i.payment_status) as x
                   from public.sales_invoices i where i.code = p_code
                   order by i.invoice_date desc limit 60) s),
    -- Working papers (orders) with the delivery team's status; no photo, no postponement reason.
    'orders', (select coalesce(jsonb_agg(x order by x->>'due_date' desc), '[]'::jsonb) from (
                 select (public.delivery_paper_json(p) - 'photo_path' - 'photo_deleted_at' - 'confirmed_by_name') as x
                 from public.sales_paper_orders() o
                 join public.weighing_papers p on p.id = o.paper_id
                 where o.code = p_code
                 order by o.order_date desc limit 40) s),
    'calls', (select coalesce(jsonb_agg(jsonb_build_object('at', k.called_at, 'outcome', k.outcome, 'note', k.note,
                                                           'by', pr.full_name) order by k.called_at desc), '[]'::jsonb)
              from (select * from public.sales_calls where code = p_code order by called_at desc limit 30) k
              left join public.profiles pr on pr.id = k.called_by));
end;
$$;
revoke all on function public.sales_client_detail(text) from public, anon;
grant execute on function public.sales_client_detail(text) to authenticated, service_role;


-- ----------------------------------------------------------------------------
-- 8. sales_deliveries — my clients' orders for one delivery day
-- ----------------------------------------------------------------------------
-- The delivery board's data (Migrations 029–035) for the clients this person
-- may see: orders due that day (produced or not yet), and orders that were
-- due that day and moved to another day — the new date, never the reason
-- (reasons stay with admin, middle office and the company director).
create or replace function public.sales_deliveries(p_date date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_scope text := public.sales_scope();
  orders  jsonb;
  moved   jsonb;
  unknown int;
begin
  if v_scope is null then raise exception 'not allowed' using errcode = '42501'; end if;
  if p_date is null then raise exception 'choose a day' using errcode = '22023'; end if;

  select coalesce(jsonb_agg(x order by x->>'client_name' nulls last, x->>'po_number'), '[]'::jsonb) into orders
  from (
    select (public.delivery_paper_json(p) - 'photo_path' - 'photo_deleted_at' - 'confirmed_by_name')
           || jsonb_build_object('code', o.code, 'client_name', c.name, 'salesperson', c.salesperson_code) as x
    from public.sales_paper_orders() o
    join public.weighing_papers p on p.id = o.paper_id
    join public.sales_customers c on c.code = o.code
    where o.order_date = p_date and public.sales_can_see(o.code)
  ) s;

  select coalesce(jsonb_agg(x order by x->>'client_name' nulls last), '[]'::jsonb) into moved
  from (
    select jsonb_build_object(
             'paper_id', h.paper_id, 'code', c.code, 'client_name', c.name, 'po_number', h.po_number,
             'company', h.company, 'new_date', coalesce(p.delivery_date, h.to_delivery_date),
             'kg_ordered', h.kg_ordered, 'moved_at', h.created_at) as x
    from (select distinct on (coalesce(wp.paper_id, wp.id)) wp.*
          from public.weighing_postponements wp
          where coalesce(wp.from_delivery_date, wp.from_work_date) = p_date
          order by coalesce(wp.paper_id, wp.id), wp.created_at desc) h
    left join public.weighing_papers p on p.id = h.paper_id
    join public.sales_customers c on c.code = public.sales_code_for_name(coalesce(p.customer_name, h.customer_name))
    where (p.id is null or coalesce(p.delivery_date, p.work_date) <> p_date)
      and public.sales_can_see(c.code)
    union all
    select jsonb_build_object('register_id', r.id, 'code', c.code, 'client_name', c.name, 'po_number', r.po_number,
                              'company', r.company, 'new_date', r.new_date, 'product', r.product,
                              'kg_ordered', r.quantity_kg, 'moved_at', r.created_at)
    from public.order_postponements r
    join public.sales_customers c on c.code = public.sales_code_for_name(r.customer_name)
    where r.original_date = p_date and public.sales_can_see(c.code)
  ) s;

  -- Papers of that day whose client could not be read (admin and sales director see the count).
  select count(*) into unknown from public.sales_paper_orders() o
  where o.order_date = p_date and o.code is null and v_scope = 'all';

  return jsonb_build_object('date', p_date, 'orders', orders, 'moved', moved,
                            'unmatched', unknown, 'loaded_at', now());
end;
$$;
revoke all on function public.sales_deliveries(date) from public, anon;
grant execute on function public.sales_deliveries(date) to authenticated, service_role;


-- ----------------------------------------------------------------------------
-- 9. Calls
-- ----------------------------------------------------------------------------
create or replace function public.sales_log_call(p_code text, p_outcome text, p_note text default null)
returns uuid
language plpgsql
volatile
security definer
set search_path = public
as $$
declare v uuid;
begin
  if not public.sales_can_see(p_code) then raise exception 'not allowed' using errcode = '42501'; end if;
  if p_outcome not in ('ordered', 'call_back', 'no_answer', 'no_need', 'problem') then
    raise exception 'unknown outcome' using errcode = '22023';
  end if;
  if p_outcome = 'problem' and nullif(btrim(coalesce(p_note, '')), '') is null then
    raise exception 'write what the problem is' using errcode = '22023';
  end if;
  insert into public.sales_calls (code, called_by, outcome, note)
  values (p_code, auth.uid(), p_outcome, nullif(btrim(coalesce(p_note, '')), ''))
  returning id into v;
  return v;
end;
$$;
revoke all on function public.sales_log_call(text, text, text) from public, anon;
grant execute on function public.sales_log_call(text, text, text) to authenticated, service_role;


-- ----------------------------------------------------------------------------
-- 10. Names on papers that match no client (admin, sales director)
-- ----------------------------------------------------------------------------
create or replace function public.sales_unmatched_names()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if coalesce(public.sales_scope(), '') <> 'all' then raise exception 'not allowed' using errcode = '42501'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('name', customer_name, 'papers', n, 'last', last_d)
                                    order by n desc, customer_name), '[]'::jsonb)
          from (select o.customer_name, count(*) as n, max(o.order_date) as last_d
                from public.sales_paper_orders() o
                where o.code is null and o.customer_name is not null
                group by o.customer_name) s);
end;
$$;

create or replace function public.sales_link_name(p_name text, p_code text)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
begin
  if coalesce(public.sales_scope(), '') <> 'all' then raise exception 'not allowed' using errcode = '42501'; end if;
  if not exists (select 1 from public.sales_customers where code = upper(btrim(p_code))) then
    raise exception 'unknown client code %', p_code using errcode = 'P0002';
  end if;
  if public.client_match_key(p_name) is null then raise exception 'empty name' using errcode = '22023'; end if;
  -- One name, one client: a name already linked elsewhere moves.
  delete from public.sales_customer_names
   where name_key = public.client_match_key(p_name) and code <> upper(btrim(p_code));
  insert into public.sales_customer_names (code, name, linked_by)
  values (upper(btrim(p_code)), btrim(p_name), auth.uid())
  on conflict (code, name) do nothing;
end;
$$;
revoke all on function public.sales_unmatched_names(), public.sales_link_name(text, text) from public, anon;
grant execute on function public.sales_unmatched_names(), public.sales_link_name(text, text) to authenticated, service_role;


-- ----------------------------------------------------------------------------
-- 11. Moving a client (admin)
-- ----------------------------------------------------------------------------
create or replace function public.sales_assign(p_code text, p_salesperson text, p_portfolio text)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
begin
  if coalesce(public.current_role(), '') <> 'admin' then raise exception 'not allowed' using errcode = '42501'; end if;
  if p_portfolio not in ('rep', 'not_transferred', 'house') then raise exception 'unknown portfolio' using errcode = '22023'; end if;
  if p_portfolio = 'rep' and not exists (select 1 from public.sales_reps where code = p_salesperson) then
    raise exception 'choose a salesperson' using errcode = '22023';
  end if;
  update public.sales_customers
     set portfolio = p_portfolio,
         salesperson_code = case when p_portfolio = 'rep' then p_salesperson end,
         assigned_manually = true, updated_at = now()
   where code = p_code;
  if not found then raise exception 'unknown client %', p_code using errcode = 'P0002'; end if;
end;
$$;
revoke all on function public.sales_assign(text, text, text) from public, anon;
grant execute on function public.sales_assign(text, text, text) to authenticated, service_role;


-- ----------------------------------------------------------------------------
-- 12. Loading a sales report (admin; scripts/import_sales_report.py builds it)
-- ----------------------------------------------------------------------------
-- p_data: {customers:[…], monthly:[{code, month, company, amount}],
--          months:[ISO months the report covers — replaced whole],
--          invoices:[{company, number, code, partner_name, date, untaxed, total,
--                     odoo_salesperson, payment_status}]}
create or replace function public.sales_import(p_data jsonb, p_source text default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  n_c int; n_m int; n_i int;
begin
  -- The SQL editor (no login) or admin.
  if auth.uid() is not null and coalesce(public.current_role(), '') <> 'admin' then
    raise exception 'not allowed' using errcode = '42501';
  end if;

  insert into public.sales_customers as c (code, name, report_name, notes, odoo_name, area, zone, city, phone, email,
                                           salesperson_code, portfolio, odoo_salesperson, source, updated_at)
  select upper(btrim(x->>'code')), coalesce(nullif(btrim(x->>'name'), ''), x->>'odoo_name', x->>'code'),
         x->>'report_name', x->>'notes', x->>'odoo_name', x->>'area', x->>'zone', x->>'city', x->>'phone', x->>'email',
         case when x->>'portfolio' = 'rep' then x->>'salesperson' end,
         coalesce(x->>'portfolio', 'house'), x->>'odoo_salesperson', p_source, now()
  from jsonb_array_elements(coalesce(p_data->'customers', '[]')) x
  where nullif(btrim(x->>'code'), '') is not null
  on conflict (code) do update set
    name = excluded.name,
    report_name = coalesce(excluded.report_name, c.report_name),
    notes = coalesce(excluded.notes, c.notes),
    odoo_name = coalesce(excluded.odoo_name, c.odoo_name),
    area = coalesce(excluded.area, c.area),
    zone = coalesce(excluded.zone, c.zone),
    city = coalesce(excluded.city, c.city),
    phone = coalesce(excluded.phone, c.phone),
    email = coalesce(excluded.email, c.email),
    salesperson_code = case when c.assigned_manually then c.salesperson_code else excluded.salesperson_code end,
    portfolio = case when c.assigned_manually then c.portfolio else excluded.portfolio end,
    odoo_salesperson = coalesce(excluded.odoo_salesperson, c.odoo_salesperson),
    source = excluded.source, updated_at = now();
  get diagnostics n_c = row_count;

  insert into public.sales_customer_names (code, name)
  select distinct upper(btrim(x->>'code')), btrim(nm)
  from jsonb_array_elements(coalesce(p_data->'customers', '[]')) x,
       lateral (values (x->>'name'), (x->>'odoo_name')) v(nm)
  where nullif(btrim(nm), '') is not null and nullif(btrim(x->>'code'), '') is not null
    and public.client_match_key(nm) is not null
  on conflict (code, name) do nothing;

  delete from public.sales_monthly
   where month in (select (m #>> '{}')::date from jsonb_array_elements(coalesce(p_data->'months', '[]')) m);
  insert into public.sales_monthly (code, month, company, amount, source)
  select upper(btrim(x->>'code')), (x->>'month')::date, x->>'company', sum((x->>'amount')::numeric), p_source
  from jsonb_array_elements(coalesce(p_data->'monthly', '[]')) x
  where exists (select 1 from public.sales_customers c where c.code = upper(btrim(x->>'code')))
  group by 1, 2, 3
  having sum((x->>'amount')::numeric) <> 0;
  get diagnostics n_m = row_count;

  insert into public.sales_invoices as i (company, number, code, partner_name, invoice_date, untaxed, total,
                                          odoo_salesperson, payment_status, source)
  select x->>'company', x->>'number',
         (select c.code from public.sales_customers c where c.code = upper(btrim(x->>'code'))),
         x->>'partner_name', (x->>'date')::date, (x->>'untaxed')::numeric, (x->>'total')::numeric,
         x->>'odoo_salesperson', x->>'payment_status', p_source
  from jsonb_array_elements(coalesce(p_data->'invoices', '[]')) x
  where nullif(x->>'number', '') is not null and nullif(x->>'date', '') is not null
  on conflict (company, number) do update set
    code = excluded.code, partner_name = excluded.partner_name, invoice_date = excluded.invoice_date,
    untaxed = excluded.untaxed, total = excluded.total, odoo_salesperson = excluded.odoo_salesperson,
    payment_status = excluded.payment_status, source = excluded.source;
  get diagnostics n_i = row_count;

  -- Names PACE customers already go by (same code): the middle office's spelling.
  insert into public.sales_customer_names (code, name)
  select pc.code, pc.name from public.pace_customers pc
  join public.sales_customers c on c.code = pc.code
  where pc.code is not null and public.client_match_key(pc.name) is not null
  on conflict (code, name) do nothing;

  return jsonb_build_object('customers', n_c, 'monthly_rows', n_m, 'invoices', n_i);
end;
$$;
revoke all on function public.sales_import(jsonb, text) from public, anon;
grant execute on function public.sales_import(jsonb, text) to authenticated, service_role;
