-- ============================================================================
-- Migration 032 — Company director: one company, read-only (Chef Julien,
-- director of Prosun Food)
-- ============================================================================
-- Written 13 Nov 2026. Clément: "I'd like to give Chef Julien access to only
-- Prosun Food stuff. Management dashboard etc. The idea is for him to help me
-- pilot PSFood as director of Prosun Food." Read-only (Clément's choice).
--
-- A new role, company_director, tied to one company (profiles.company_scope).
-- He sees, for that company only:
--   Management › Dashboard        management_dashboard()     (no CRM salesperson table:
--                                                              the CRM's clients carry no company)
--   Management › Summary          management_summary()       (revenue, kg, reasons)
--   Middle office › Postponed     weighing_postponements, order_postponements (read)
--   Delivery › Delivery board     delivery_board()           (with the reasons; no marks)
--   Accounting › Confirmed weights weighing_confirmed_lines(), weighing_unconfirmed_count(),
--                                 weighing_invoice_marks(), weighing_postponement_marks(),
--                                 and the photos of his company's confirmed papers
--
-- How the company is enforced
--   Every function above asks public.my_company_scope(): null for everyone
--   else (nothing changes for them), the company for a company director. His
--   company is applied inside the function whatever the screen sends; asking
--   for the other company is refused. The two postponement tables and the
--   photos get their own policies, limited to his company.
--
-- What he cannot do
--   Change anything. Every write path keeps its own role list, and none of
--   them names company_director: weighing_mark_checked (reader department),
--   weighing_mark_invoiced, weighing_postpone_delivery, delivery_mark, the
--   register's insert/update/delete policies, management_set_count_from,
--   management_set_client_zone, payables, orders, the calculator, the
--   weighing screen. He reads accounting's "checked" marks on Confirmed
--   weights; he does not make any.
--   Not reached at all: Orders, Poultry calculator, Weighing, Payables, the
--   CRM, the bell (notifications stay admin and accounting).
--
-- The functions below are the latest versions (024, 028, 030, 022, 031),
-- copied unchanged except for the lines marked "032".
--
-- Run order: after 031. Safe to re-run.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. The role and the company it is limited to
-- ----------------------------------------------------------------------------
-- The role list is read from the constraint as it is in the database and
-- 'company_director' added (same method as Migration 029).
do $$
declare
  def   text;
  roles text[];
begin
  select pg_get_constraintdef(oid) into def
  from pg_constraint
  where conrelid = 'public.profiles'::regclass and conname = 'profiles_role_check';

  select array_agg(m[1]) into roles
  from regexp_matches(coalesce(def, ''), '''([a-z_]+)''', 'g') as m;
  roles := coalesce(roles, array['admin', 'director', 'sales', 'sale_support', 'purchasing',
                                 'production', 'factory_admin', 'accounting', 'delivery']);
  if not ('company_director' = any(roles)) then
    roles := array_append(roles, 'company_director');
  end if;

  alter table public.profiles drop constraint if exists profiles_role_check;
  execute format('alter table public.profiles add constraint profiles_role_check check (role in (%s))',
                 (select string_agg(quote_literal(r), ', ') from unnest(roles) r));
end $$;

comment on constraint profiles_role_check on public.profiles is
  'admin = everything; director/sales = CRM; sale_support/purchasing/production '
  '= PACE; factory_admin = weighing photo screen only (Migration 018); '
  'accounting = confirmed weights and payables (Migrations 020, 025); '
  'delivery = delivery board only (Migration 029); '
  'company_director = Management, Postponed orders, Delivery board and Confirmed weights '
  'of the company in company_scope, read-only (Migration 032).';

alter table public.profiles add column if not exists company_scope text;

alter table public.profiles drop constraint if exists profiles_company_scope_check;
alter table public.profiles add constraint profiles_company_scope_check
  check (company_scope is null or company_scope in ('Prosun Farm', 'Prosun Food'));

-- A company director without a company would see nothing; refuse it outright.
alter table public.profiles drop constraint if exists profiles_company_director_scope;
alter table public.profiles add constraint profiles_company_director_scope
  check (role <> 'company_director' or company_scope is not null);

comment on column public.profiles.company_scope is
  'For role company_director: the one company this person sees (Prosun Farm or Prosun Food). '
  'Ignored for every other role. Set by admin in the SQL editor. Migration 032.';


-- ----------------------------------------------------------------------------
-- 2. Helpers
-- ----------------------------------------------------------------------------
-- The caller's company limit: the company for a company director, null for
-- everyone else. Read from the profile on every call, never from the screen.
create or replace function public.my_company_scope()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select case when p.role = 'company_director' then p.company_scope end
  from public.profiles p
  where p.id = auth.uid();
$$;

comment on function public.my_company_scope() is
  'The company a company director is limited to; null for every other role. Migration 032.';

revoke all on function public.my_company_scope() from public, anon;
grant execute on function public.my_company_scope() to authenticated, service_role;

-- The company filter of the Management functions for this caller: as asked
-- for everyone else; always his own company for a company director, and
-- asking for the other one is refused. Internal (called by the functions).
create or replace function public.management_company(p_company text)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_scope text := public.my_company_scope();
  v_co    text := nullif(p_company, 'all');
begin
  if v_scope is null then
    return v_co;
  end if;
  if v_co is not null and v_co <> v_scope then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  return v_scope;
end;
$$;

revoke all on function public.management_company(text) from public, anon, authenticated;


-- ----------------------------------------------------------------------------
-- 3. Management › Dashboard (Migration 024)
-- ----------------------------------------------------------------------------
create or replace function public.management_dashboard(p_from date, p_to date, p_company text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_today date := (now() at time zone 'Asia/Bangkok')::date;
  v_start date;
  v_from  date;
  v_trend date;
  v_co    text := public.management_company(p_company);   -- a company director always gets his own company (032)
  v_scope text := public.my_company_scope();
  v_out   jsonb;
begin
  if coalesce(public.current_role(), '') not in ('admin', 'company_director') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'choose a start and an end date' using errcode = '22023';
  end if;
  if p_to - p_from > 366 then
    raise exception 'choose a period of one year or less' using errcode = '22023';
  end if;
  if v_co is not null and v_co not in ('Prosun Farm', 'Prosun Food') then
    raise exception 'unknown company' using errcode = '22023';
  end if;

  select s.count_from into v_start from public.management_settings s where s.id = 1;
  v_from  := greatest(p_from, v_start);
  -- The charts show at least the last 14 days, so a one-day period still has a trend.
  v_trend := greatest(least(p_from, p_to - 13), v_start);

  with papers as (
    select p.* from public.weighing_papers p
    where p.work_date >= v_start and (v_co is null or p.company = v_co)
  ),
  period as (
    select * from papers where work_date between v_from and p_to
  ),
  period_lines as (
    select p.customer_name, l.actual_kg, l.ordered_qty, l.ordered_unit,
           case
             when l.actual_kg is null or coalesce(l.ordered_qty, 0) <= 0 then null
             when l.ordered_unit = 'kg' then l.ordered_qty
             when l.ordered_unit = 'g'  then l.ordered_qty / 1000
           end as ordered_kg
    from period p
    join public.weighing_lines l on l.paper_id = p.id
    where p.status = 'confirmed'
  ),
  graded as (
    select *, actual_kg - ordered_kg as diff_kg,
           case
             when ordered_kg is null then null
             when abs(actual_kg - ordered_kg) / ordered_kg <= 0.05 then 'ok'
             when actual_kg < ordered_kg then 'under'
             else 'over'
           end as grade
    from period_lines
  ),
  by_client as (
    select min(coalesce(nullif(trim(customer_name), ''), '—')) as client,
           count(*) filter (where grade is not null) as compared,
           count(*) filter (where grade = 'under') as under_lines,
           count(*) filter (where grade = 'over')  as over_lines,
           coalesce(sum(diff_kg) filter (where grade = 'under'), 0) as under_kg,
           coalesce(sum(diff_kg) filter (where grade = 'over'), 0)  as over_kg,
           coalesce(sum(diff_kg), 0) as net_kg
    from graded
    group by lower(coalesce(nullif(trim(customer_name), ''), '—'))
  ),
  acct as (
    select p.id, p.confirmed_at, c.checked_at,
           (c.paper_id is null or (c.confirmed_at_seen is not null and p.confirmed_at > c.confirmed_at_seen)) as waiting
    from papers p
    left join public.weighing_paper_checks c on c.paper_id = p.id and c.dept = 'accounting'
    where p.status = 'confirmed'
  ),
  open_papers as (
    select * from papers where status <> 'confirmed'
  ),
  sales as (
    select c.assigned_to, count(*) as clients,
           count(*) filter (where c.stage = 'won') as active,
           count(*) filter (where c.stage = 'at_risk') as at_risk,
           count(*) filter (where c.stage = 'dormant') as dormant,
           count(*) filter (where c.stage in ('lead', 'qualified', 'proposal')) as pipeline,
           count(*) filter (where c.stage = 'lost') as lost
    from public.clients c
    where v_scope is null      -- CRM clients carry no company: not shown to a company director (032)
    group by c.assigned_to
  )
  select jsonb_build_object(
    'today', v_today,
    'scope', v_scope,
    'count_from', v_start,
    'from', v_from,
    'to', p_to,
    'trend_from', v_trend,
    'papers', (select jsonb_build_object(
        'total',      count(*),
        'confirmed',  count(*) filter (where status = 'confirmed'),
        'to_check',   count(*) filter (where status = 'read'),
        'processing', count(*) filter (where status in ('uploading', 'queued', 'reading')),
        'failed',     count(*) filter (where status = 'failed'),
        'median_confirm_minutes', round((percentile_cont(0.5) within group (
            order by extract(epoch from confirmed_at - uploaded_at))
            filter (where status = 'confirmed' and reopened_at is null))::numeric / 60, 1)
      ) from period),
    'lines', (select jsonb_build_object(
        'total',    count(*),
        'compared', count(*) filter (where grade is not null),
        'under',    count(*) filter (where grade = 'under'),
        'over',     count(*) filter (where grade = 'over'),
        'kg',       coalesce(sum(actual_kg), 0),
        'under_kg', coalesce(sum(diff_kg) filter (where grade = 'under'), 0),
        'over_kg',  coalesce(sum(diff_kg) filter (where grade = 'over'), 0)
      ) from graded),
    'clients', coalesce((select jsonb_agg(to_jsonb(b) order by b.under_lines + b.over_lines desc, abs(b.net_kg) desc, b.client)
        from by_client b where b.under_lines + b.over_lines > 0), '[]'::jsonb),
    'clients_within', (select count(*) from by_client b where b.compared > 0 and b.under_lines + b.over_lines = 0),
    'open', jsonb_build_object(
        'earlier', (select count(*) from open_papers where work_date < v_today),
        'today',   (select count(*) from open_papers where work_date = v_today),
        'list', coalesce((select jsonb_agg(x order by x.work_date, x.uploaded_at) from (
            select id, work_date, uploaded_at, status, reopened_at, po_number, customer_name, company
            from open_papers where work_date < v_today
            order by work_date, uploaded_at limit 20) x), '[]'::jsonb)
      ),
    'accounting', (select jsonb_build_object(
        'waiting', count(*) filter (where waiting),
        'oldest',  min(confirmed_at) filter (where waiting),
        'median_hours', round((percentile_cont(0.5) within group (
            order by extract(epoch from checked_at - confirmed_at))
            filter (where not waiting
                    and (confirmed_at at time zone 'Asia/Bangkok')::date between v_from and p_to))::numeric / 3600, 1)
      ) from acct),
    'trend', (select jsonb_agg(jsonb_build_object(
        'day', d.day,
        'confirmed', coalesce(t.confirmed, 0),
        'open', coalesce(t.open, 0),
        'kg', coalesce(t.kg, 0)) order by d.day)
      from (select generate_series(v_trend, greatest(p_to, v_trend), interval '1 day')::date as day) d
      left join (
        select p.work_date,
               count(*) filter (where p.status = 'confirmed') as confirmed,
               count(*) filter (where p.status <> 'confirmed') as open,
               coalesce(sum((select sum(l.actual_kg) from public.weighing_lines l where l.paper_id = p.id))
                 filter (where p.status = 'confirmed'), 0) as kg
        from papers p group by p.work_date
      ) t on t.work_date = d.day),
    'sales', jsonb_build_object(
        'reps', coalesce((select jsonb_agg(jsonb_build_object(
              'name', coalesce(pr.full_name, '—'), 'role', pr.role,
              'clients', s.clients, 'active', s.active, 'at_risk', s.at_risk,
              'dormant', s.dormant, 'pipeline', s.pipeline, 'lost', s.lost
            ) order by s.at_risk desc, s.clients desc, pr.full_name)
            from sales s left join public.profiles pr on pr.id = s.assigned_to
            where s.assigned_to is not null), '[]'::jsonb),
        'unassigned', coalesce((select jsonb_build_object(
              'clients', s.clients, 'active', s.active, 'at_risk', s.at_risk,
              'dormant', s.dormant, 'pipeline', s.pipeline, 'lost', s.lost)
            from sales s where s.assigned_to is null),
            jsonb_build_object('clients', 0, 'active', 0, 'at_risk', 0, 'dormant', 0, 'pipeline', 0, 'lost', 0))
      )
  ) into v_out;

  return v_out;
end;
$$;

comment on function public.management_dashboard(date, date, text) is
  'Numbers for PACE › Management. Admin, and a company director for his company '
  '(no CRM salesperson table). Read-only. Migrations 024, 032.';


-- ----------------------------------------------------------------------------
-- 4. Management › Dashboard, postponed orders (Migration 028)
-- ----------------------------------------------------------------------------
create or replace function public.management_postponements(p_from date, p_to date, p_company text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_co    text := public.management_company(p_company);   -- a company director always gets his own company (032)
  v_scope text := public.my_company_scope();
  v_start date;
  v_out   jsonb;
begin
  if coalesce(public.current_role(), '') not in ('admin', 'company_director') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'choose a start and an end date' using errcode = '22023';
  end if;

  select s.count_from into v_start from public.management_settings s where s.id = 1;

  with rec as (
    select case w.stage when 'delivery' then 'middle_office' else 'production' end as source,
           w.customer_name, w.po_number, w.company,
           null::text as product, w.kg_ordered as quantity_kg,
           coalesce(w.from_delivery_date, w.from_work_date) as original_date,
           w.to_delivery_date as new_date, w.reason, w.note, w.created_at,
           w.to_delivery_date - coalesce(w.from_delivery_date, w.from_work_date) as delay_days
    from public.weighing_postponements w
    where (v_co is null or w.company = v_co)
    union all
    select 'middle_office', r.customer_name, r.po_number, r.company, r.product, r.quantity_kg,
           r.original_date, r.new_date, r.reason, r.note, r.created_at,
           r.new_date - r.original_date
    from public.order_postponements r
    where (v_co is null or r.company = v_co)
  ),
  period as (
    select * from rec where original_date between p_from and p_to
  ),
  by_client as (
    select min(trim(coalesce(customer_name, '—'))) as client, count(*) as times,
           count(*) filter (where reason = 'production') as production
    from period group by lower(trim(coalesce(customer_name, '—')))
  )
  select jsonb_build_object(
    'total',       (select count(*) from period),
    'by_factory',  (select count(*) from period where source = 'production'),
    'production',  (select count(*) from period where reason = 'production'),
    'our_side',    (select count(*) from period where reason <> 'client'),
    'kg',          (select coalesce(sum(quantity_kg), 0) from period),
    'avg_delay',   (select round(avg(delay_days), 1) from period),
    'no_new_date', (select count(*) from rec where new_date is null),
    'by_reason', coalesce((select jsonb_agg(x order by x.times desc, x.reason) from (
        select reason, count(*) as times, coalesce(sum(quantity_kg), 0) as kg,
               round(avg(delay_days), 1) as avg_delay
        from period group by reason) x), '[]'::jsonb),
    'repeat_clients', coalesce((select jsonb_agg(c order by c.times desc, c.client)
        from by_client c where c.times >= 2), '[]'::jsonb),
    'recent', coalesce((select jsonb_agg(x order by x.original_date desc, x.created_at desc) from (
        select source, customer_name, po_number, product, quantity_kg, original_date, new_date, reason, note, created_at
        from period order by original_date desc, created_at desc limit 8) x), '[]'::jsonb),
    'late_papers', (select count(*) from public.weighing_papers p
        where p.work_date > p.delivery_date
          and p.work_date >= v_start
          and p.work_date between p_from and p_to
          and not exists (select 1 from public.weighing_postponements w where w.paper_id = p.id)
          and (v_co is null or p.company = v_co))
  ) into v_out;

  return v_out;
end;
$$;

comment on function public.management_postponements(date, date, text) is
  'Postponed-order numbers for PACE › Management (production, Confirmed weights and the register). '
  'Admin, and a company director for his company. Migrations 027, 028, 032.';


-- ----------------------------------------------------------------------------
-- 5. Management › Summary (Migration 031)
-- ----------------------------------------------------------------------------
create or replace function public.management_summary(p_from date, p_to date, p_company text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_co    text := public.management_company(p_company);   -- a company director always gets his own company (032)
  v_scope text := public.my_company_scope();
  v_start date;
  v_from  date;
  v_out   jsonb;
begin
  if coalesce(public.current_role(), '') not in ('admin', 'company_director') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'choose a start and an end date' using errcode = '22023';
  end if;
  if p_to - p_from > 400 then
    raise exception 'choose a period of about one year or less' using errcode = '22023';
  end if;
  if v_co is not null and v_co not in ('Prosun Farm', 'Prosun Food') then
    raise exception 'unknown company' using errcode = '22023';
  end if;

  select s.count_from into v_start from public.management_settings s where s.id = 1;
  v_from := greatest(p_from, v_start);

  with raw as materialized (
    select p.id as paper_id, p.work_date, p.company, p.po_number,
           coalesce(nullif(trim(p.customer_name), ''), '—') as client,
           l.description, l.actual_kg, l.ordered_qty, l.ordered_unit,
           coalesce(p.po_number, '') ~* '^\s*UR' as ur
    from public.weighing_papers p
    join public.weighing_lines l on l.paper_id = p.id
    where p.status = 'confirmed'
      and p.work_date between v_from and p_to
      and (v_co is null or p.company = v_co)
  ),
  -- Papers repeat the same few hundred descriptions: match each one once.
  matched as materialized (
    select d.description, d.ur,
           public.price_list_match(d.description, case when d.ur then 'UR' end) as price_id
    from (select distinct description, ur from raw) d
  ),
  lines as (
    select r.*, m.price_id
    from raw r join matched m on m.description is not distinct from r.description and m.ur = r.ur
  ),
  priced as (
    select x.*,
           case
             when pl.unit = 'kg' then
               case when x.actual_kg > 0 then round(x.actual_kg * x.unit_price, 2) end
             when pl.unit = 'pce' then
               case when x.pieces > 0 then round(x.pieces * x.unit_price, 2) end
           end as revenue
    from (
      select l.*, pl.unit as price_unit, pl.name as price_name,
             coalesce(z.zone, 'bangkok') as zone,
             case
               when pl.unit = 'pce' and l.ordered_unit = 'pcs' and l.ordered_qty > 0 then l.ordered_qty
               when pl.unit = 'pce' and l.actual_kg > 0 and pl.piece_kg > 0 then round(l.actual_kg / pl.piece_kg)
             end as pieces,
             -- quantity tier: pieces when known (ordered in pieces), else none
             case
               when pl.bulk_min is not null
                    and (case when l.ordered_unit = 'pcs' then l.ordered_qty end) >= pl.bulk_min
                 then case when z.zone = 'upcountry' then coalesce(pl.bulk_up, pl.bulk_bkk) else pl.bulk_bkk end
               else case when z.zone = 'upcountry' then coalesce(pl.price_up, pl.price_bkk) else pl.price_bkk end
             end as unit_price
      from lines l
      left join public.price_list pl on pl.id = l.price_id
      left join public.client_price_zones z on z.client_key = lower(l.client)
    ) x
    left join public.price_list pl on pl.id = x.price_id
  ),
  papers_day as (
    select work_date, count(distinct paper_id) as papers
    from lines group by work_date
  ),
  days as (
    select work_date, sum(actual_kg) as kg, sum(revenue) as revenue
    from priced group by work_date
  ),
  months as (
    select date_trunc('month', d.work_date)::date as month,
           count(*) as days,
           sum(pd.papers) as papers,
           coalesce(sum(d.kg), 0) as kg,
           coalesce(sum(d.revenue), 0) as revenue
    from days d join papers_day pd using (work_date)
    group by 1
  ),
  month_priced as (
    select date_trunc('month', work_date)::date as month,
           coalesce(sum(actual_kg) filter (where revenue is not null), 0) as kg_priced
    from priced group by 1
  ),
  postp as (
    select coalesce(w.from_delivery_date, w.from_work_date) as original_date,
           w.reason, w.kg_ordered as kg,
           w.to_delivery_date - coalesce(w.from_delivery_date, w.from_work_date) as delay_days
    from public.weighing_postponements w
    where (v_co is null or w.company = v_co)
    union all
    select r.original_date, r.reason, r.quantity_kg, r.new_date - r.original_date
    from public.order_postponements r
    where (v_co is null or r.company = v_co)
  ),
  postp_period as (
    select * from postp where original_date between v_from and p_to
  ),
  postp_month as (
    select date_trunc('month', original_date)::date as month, count(*) as n,
           (array_agg(reason order by cnt desc, reason))[1] as top_reason
    from (select original_date, reason, count(*) over (partition by date_trunc('month', original_date), reason) as cnt
          from postp_period) s
    group by 1
  )
  select jsonb_build_object(
    'from', v_from, 'to', p_to, 'count_from', v_start, 'scope', v_scope,
    'totals', (select jsonb_build_object(
        'days',       (select count(*) from days),
        'papers',     (select coalesce(sum(papers), 0) from papers_day),
        'kg',         coalesce(sum(actual_kg), 0),
        'kg_priced',  coalesce(sum(actual_kg) filter (where revenue is not null), 0),
        'revenue',    coalesce(sum(revenue), 0),
        'lines',      count(*),
        'lines_priced', count(*) filter (where revenue is not null),
        'upcountry_revenue', coalesce(sum(revenue) filter (where zone = 'upcountry'), 0),
        'under_roof_revenue', coalesce(sum(revenue) filter (where price_id like 'ur\_%'), 0)
      ) from priced),
    'months', coalesce((select jsonb_agg(jsonb_build_object(
        'month', m.month, 'days', m.days, 'papers', m.papers, 'kg', m.kg,
        'kg_priced', coalesce(mp.kg_priced, 0), 'revenue', m.revenue,
        'postponed', coalesce(pm.n, 0), 'top_reason', pm.top_reason) order by m.month)
      from months m
      left join month_priced mp using (month)
      left join postp_month pm using (month)), '[]'::jsonb),
    'reasons', (select jsonb_build_object(
        'total', coalesce(sum(r.times), 0),
        'list', coalesce(jsonb_agg(r order by r.times desc, r.reason) filter (where r.reason is not null), '[]'::jsonb))
      from (select reason, count(*) as times, coalesce(sum(kg), 0) as kg, round(avg(delay_days), 1) as avg_delay
            from postp_period group by reason) r),
    'products', coalesce((select jsonb_agg(x order by x.revenue desc nulls last) from (
        select price_id as id, min(price_name) as name, min(price_unit) as unit,
               sum(actual_kg) as kg, sum(pieces) as pieces, count(*) as lines,
               sum(revenue) as revenue
        from priced where revenue is not null
        group by price_id order by sum(revenue) desc limit 20) x), '[]'::jsonb),
    'clients', coalesce((select jsonb_agg(x order by x.revenue desc nulls last) from (
        select min(client) as client, min(zone) as zone, sum(actual_kg) as kg,
               coalesce(sum(revenue), 0) as revenue,
               coalesce(sum(actual_kg) filter (where revenue is null), 0) as kg_unpriced
        from priced group by lower(client)
        order by coalesce(sum(revenue), 0) desc, sum(actual_kg) desc nulls last limit 25) x), '[]'::jsonb),
    'unpriced', coalesce((select jsonb_agg(x order by x.kg desc nulls last) from (
        select min(description) as description,
               min(price_name) as why,
               coalesce(sum(actual_kg), 0) as kg, count(*) as lines,
               min(ordered_unit) as unit
        from priced where revenue is null
        group by lower(trim(description)), price_id
        order by coalesce(sum(actual_kg), 0) desc limit 25) x), '[]'::jsonb),
    'zones', coalesce((select jsonb_agg(jsonb_build_object('client', client_name, 'zone', zone) order by client_name)
        from public.client_price_zones where zone = 'upcountry'
          -- a company director sees only the zones of his own company's clients (032)
          and (v_scope is null or client_key in (select lower(r.client) from raw r))), '[]'::jsonb),
    'price_list', (select jsonb_agg(jsonb_build_object(
        'name', name, 'code', code, 'unit', unit, 'bkk', price_bkk, 'up', price_up,
        'bulk_min', bulk_min, 'bulk_bkk', bulk_bkk, 'bulk_up', bulk_up, 'source', source) order by sort)
        from public.price_list where unit <> 'none' and id <> 'red_label_alt')
  ) into v_out;

  return v_out;
end;
$$;

comment on function public.management_summary(date, date, text) is
  'Management › Summary: kg per day and month, approximate gross revenue at list prices, '
  'postponement reasons. Admin, and a company director for his company. Read-only. Migrations 031, 032.';


-- ----------------------------------------------------------------------------
-- 6. Delivery board (Migration 030): his company, with the reasons, no marks
-- ----------------------------------------------------------------------------
create or replace function public.delivery_board(p_date date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  r        text := coalesce(public.current_role(), '');
  v_scope  text := public.my_company_scope();   -- company director: his company only (032)
  reasons  boolean;
  papers   jsonb;
  moved    jsonb;
  register jsonb;
begin
  if r not in ('delivery', 'sale_support', 'admin', 'company_director') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if p_date is null then
    raise exception 'choose a delivery day' using errcode = '22023';
  end if;
  reasons := r in ('sale_support', 'admin', 'company_director');

  -- Every paper delivering that day (no delivery date read yet: its weighing day).
  select coalesce(jsonb_agg(x order by x->>'customer_name' nulls last, x->>'po_number'), '[]'::jsonb)
    into papers
  from (
    select jsonb_build_object(
      'id', p.id,
      'status', p.status,
      'company', p.company,
      'po_number', p.po_number,
      'customer_name', p.customer_name,
      'delivery_date', p.delivery_date,
      'work_date', p.work_date,
      'confirmed_at', p.confirmed_at,
      'reopened', p.reopened_snapshot is not null and p.status in ('read', 'failed'),
      'lines', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'line_no', l.line_no, 'description', l.description,
                 'ordered_text', l.ordered_text, 'ordered_qty', l.ordered_qty,
                 'ordered_unit', l.ordered_unit, 'actual_kg', l.actual_kg)
               order by l.line_no)
        from public.weighing_lines l where l.paper_id = p.id), '[]'::jsonb),
      -- First date this order was due, if it was ever postponed to here.
      'moved_from', (
        select coalesce(h.from_delivery_date, h.from_work_date)
        from public.weighing_postponements h
        where h.paper_id = p.id
        order by h.created_at
        limit 1),
      'mark', (
        select jsonb_build_object('status', m.status, 'note', m.note, 'marked_at', m.marked_at,
                                  'by', pr.full_name)
        from public.delivery_marks m
        left join public.profiles pr on pr.id = m.marked_by
        where m.paper_id = p.id and m.delivery_date = coalesce(p.delivery_date, p.work_date)),
      -- Accounting's invoice mark (Migration 030). changed = the weights were
      -- reopened or re-confirmed after the invoice was marked.
      'invoice', (
        select jsonb_build_object('invoice_no', i.invoice_no, 'invoiced_at', i.invoiced_at,
                                  'by', pr.full_name,
                                  'changed', p.status <> 'confirmed' or p.confirmed_at is distinct from i.confirmed_at_seen)
        from public.weighing_invoices i
        left join public.profiles pr on pr.id = i.invoiced_by
        where i.paper_id = p.id)
    ) as x
    from public.weighing_papers p
    where coalesce(p.delivery_date, p.work_date) = p_date
      and (v_scope is null or p.company = v_scope)
  ) s;

  -- Papers that were due that day and have been pushed to another day.
  select coalesce(jsonb_agg(x order by x->>'customer_name' nulls last), '[]'::jsonb)
    into moved
  from (
    select jsonb_build_object(
      'paper_id', h.paper_id,
      'customer_name', h.customer_name,
      'po_number', h.po_number,
      'company', h.company,
      'stage', h.stage,
      'new_date', coalesce(p.delivery_date, h.to_delivery_date),
      'paper_status', p.status,
      'kg_ordered', h.kg_ordered,
      'lines', h.lines,
      'reason', case when reasons then h.reason end,
      'note', case when reasons then h.note end,
      'moved_at', h.created_at
    ) as x
    from (
      select distinct on (coalesce(wp.paper_id, wp.id)) wp.*
      from public.weighing_postponements wp
      where coalesce(wp.from_delivery_date, wp.from_work_date) = p_date
      order by coalesce(wp.paper_id, wp.id), wp.created_at desc
    ) h
    left join public.weighing_papers p on p.id = h.paper_id
    -- Moved back to this day since: it is on the board itself.
    where (p.id is null or coalesce(p.delivery_date, p.work_date) <> p_date)
      and (v_scope is null or coalesce(p.company, h.company) = v_scope)
  ) s;

  -- The middle office register: postponed before the paper reached production.
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', o.id,
           'customer_name', o.customer_name,
           'po_number', o.po_number,
           'company', o.company,
           'product', o.product,
           'quantity_kg', o.quantity_kg,
           'new_date', o.new_date,
           'reason', case when reasons then o.reason end,
           'note', case when reasons then o.note end,
           'moved_at', o.created_at)
         order by o.customer_name), '[]'::jsonb)
    into register
  from public.order_postponements o
  where o.original_date = p_date
    and (v_scope is null or o.company = v_scope);

  return jsonb_build_object(
    'date', p_date,
    'papers', papers,
    'moved', moved,
    'register', register,
    'reasons_visible', reasons,
    'scope', v_scope,
    'can_mark', r in ('delivery', 'admin'),
    'loaded_at', now());
end;
$$;


-- ----------------------------------------------------------------------------
-- 7. Confirmed weights (Migration 022): his company, accounting's marks read-only
-- ----------------------------------------------------------------------------
create or replace function public.weighing_confirmed_lines(p_from date, p_to date, p_dept text)
returns table (
  paper_id          uuid,
  work_date         date,
  delivery_date     date,
  company           text,
  po_number         text,
  customer_name     text,
  confirmed_at      timestamptz,
  confirmed_by_name text,
  photo_path        text,
  photo_deleted_at  timestamptz,
  line_id           uuid,
  line_no           int,
  description       text,
  ordered_text      text,
  ordered_qty       numeric,
  ordered_unit      text,
  actual_kg         numeric,
  edited            boolean,
  dept              text,
  checked_at        timestamptz,
  checked_by_name   text,
  check_confirmed_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  -- A company director reads accounting's marks, read-only, and his company only (032).
  v_scope text := public.my_company_scope();
  d text := case when public.current_role() = 'company_director' then 'accounting'
                 else public.weighing_reader_dept(p_dept) end;
begin
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'choose a start and an end date' using errcode = '22023';
  end if;
  if p_to - p_from > 92 then
    raise exception 'choose a period of 3 months or less' using errcode = '22023';
  end if;

  return query
    select p.id, p.work_date, p.delivery_date, p.company, p.po_number, p.customer_name,
           p.confirmed_at, pr.full_name, p.photo_path, p.photo_deleted_at,
           l.id, l.line_no, l.description, l.ordered_text, l.ordered_qty, l.ordered_unit,
           l.actual_kg, l.edited,
           d, c.checked_at, cb.full_name, c.confirmed_at_seen
    from public.weighing_papers p
    join public.weighing_lines l on l.paper_id = p.id
    left join public.profiles pr on pr.id = p.confirmed_by
    left join public.weighing_paper_checks c on c.paper_id = p.id and c.dept = d
    left join public.profiles cb on cb.id = c.checked_by
    where p.status = 'confirmed'
      and coalesce(p.delivery_date, p.work_date) between p_from and p_to
      and (v_scope is null or p.company = v_scope)
    order by coalesce(p.delivery_date, p.work_date), p.company nulls last,
             p.customer_name nulls last, p.po_number nulls last, p.id, l.line_no;
end;
$$;

comment on function public.weighing_confirmed_lines(date, date, text) is
  'Confirmed weighing lines for a period, with the caller''s department "checked" '
  'marks. Accounting, purchasing, middle office (sale_support) and admin; a company '
  'director reads accounting''s marks for his company. Migrations 022, 032.';

create or replace function public.weighing_unconfirmed_count(p_from date, p_to date)
returns integer
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  n       integer;
  v_scope text := public.my_company_scope();   -- 032
begin
  if coalesce(public.current_role(), '') not in ('accounting', 'purchasing', 'sale_support', 'admin', 'company_director') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  select count(*) into n
  from public.weighing_papers p
  where p.status <> 'confirmed'
    and coalesce(p.delivery_date, p.work_date) between p_from and p_to
    and (v_scope is null or p.company = v_scope);
  return n;
end;
$$;

create or replace function public.weighing_invoice_marks(p_papers uuid[])
returns table (paper_id uuid, invoice_no text, invoiced_at timestamptz,
               invoiced_by_name text, changed boolean)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_scope text := public.my_company_scope();   -- 032
begin
  if coalesce(public.current_role(), '') not in ('accounting', 'admin', 'sale_support', 'purchasing', 'delivery', 'company_director') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  return query
    select i.paper_id, i.invoice_no, i.invoiced_at, pr.full_name,
           (p.status <> 'confirmed' or p.confirmed_at is distinct from i.confirmed_at_seen)
    from public.weighing_invoices i
    join public.weighing_papers p on p.id = i.paper_id
    left join public.profiles pr on pr.id = i.invoiced_by
    where i.paper_id = any(coalesce(p_papers, array[]::uuid[]))
      and (v_scope is null or p.company = v_scope);
end;
$$;

comment on function public.weighing_invoice_marks(uuid[]) is
  'Invoice marks of the given papers; changed = weights reopened / re-confirmed since the invoice. '
  'A company director gets his company''s papers only. Migrations 030, 032.';

create or replace function public.weighing_postponement_marks(p_papers uuid[] default null,
                                                              p_from_work_date date default null)
returns table (id uuid, paper_id uuid, stage text, from_work_date date, to_work_date date,
               from_delivery_date date, to_delivery_date date, created_at timestamptz,
               created_by uuid, customer_name text, po_number text, reason text, note text)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  r   text := coalesce(public.current_role(), '');
  why boolean := r in ('admin', 'sale_support', 'company_director');
  v_scope text := public.my_company_scope();
begin
  if r not in ('admin', 'sale_support', 'factory_admin', 'production', 'accounting', 'purchasing', 'company_director') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if coalesce(array_length(p_papers, 1), 0) > 500 then
    raise exception 'too many papers at once' using errcode = '22023';
  end if;
  return query
    select w.id, w.paper_id, w.stage, w.from_work_date, w.to_work_date,
           w.from_delivery_date, w.to_delivery_date, w.created_at, w.created_by,
           w.customer_name, w.po_number,
           case when why then w.reason end,
           case when why then w.note end
    from public.weighing_postponements w
    left join public.weighing_papers p on p.id = w.paper_id
    where ((p_papers is not null and w.paper_id = any(p_papers))
           or (p_from_work_date is not null and w.from_work_date = p_from_work_date))
      and (r not in ('accounting', 'purchasing') or p.status = 'confirmed')
      and (v_scope is null or coalesce(p.company, w.company) = v_scope)
    order by w.created_at;
end;
$$;

comment on function public.weighing_postponement_marks(uuid[], date) is
  'Postponement dates for the weighing screen and Confirmed weights. Reason and comment for '
  'admin, sale_support and a company director (his company only); accounting and purchasing '
  'see confirmed papers only. Migrations 028, 032.';

-- Photos of his company's confirmed papers. A separate policy: the existing
-- ones are untouched.
create or replace function public.weighing_photo_in_scope(p_path text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.weighing_papers
                 where photo_path = p_path and status = 'confirmed'
                   and company = public.my_company_scope());
$$;

revoke all on function public.weighing_photo_in_scope(text) from public, anon;
grant execute on function public.weighing_photo_in_scope(text) to authenticated, service_role;

drop policy if exists "weighing-photos: company director sees own company" on storage.objects;
create policy "weighing-photos: company director sees own company"
  on storage.objects for select to authenticated
  using (bucket_id = 'weighing-photos'
         and public.current_role() = 'company_director'
         and public.weighing_photo_in_scope(name));


-- ----------------------------------------------------------------------------
-- 8. Postponed orders (Migrations 027, 028): read his company's records
-- ----------------------------------------------------------------------------
-- Added next to the existing read policies (Postgres allows a row when any
-- policy allows it). Records with no company are not his.
drop policy if exists "weighing_postponements: company director reads own company" on public.weighing_postponements;
create policy "weighing_postponements: company director reads own company"
  on public.weighing_postponements for select to authenticated
  using (public.current_role() = 'company_director'
         and company = public.my_company_scope());

drop policy if exists "order_postponements: company director reads own company" on public.order_postponements;
create policy "order_postponements: company director reads own company"
  on public.order_postponements for select to authenticated
  using (public.current_role() = 'company_director'
         and company = public.my_company_scope());

-- "Recorded by": the names of the PACE colleagues who record postponements.
drop policy if exists "profiles: company director reads pace colleagues" on public.profiles;
create policy "profiles: company director reads pace colleagues"
  on public.profiles for select to authenticated
  using (public.current_role() = 'company_director'
         and role in ('admin', 'sale_support', 'purchasing', 'production', 'factory_admin'));


-- ----------------------------------------------------------------------------
-- 9. Execute rights (unchanged; repeated so this file stands alone)
-- ----------------------------------------------------------------------------
revoke all on function public.management_dashboard(date, date, text)       from public, anon;
revoke all on function public.management_postponements(date, date, text)   from public, anon;
revoke all on function public.management_summary(date, date, text)         from public, anon;
revoke all on function public.delivery_board(date)                         from public, anon;
revoke all on function public.weighing_confirmed_lines(date, date, text)   from public, anon;
revoke all on function public.weighing_unconfirmed_count(date, date)       from public, anon;
revoke all on function public.weighing_invoice_marks(uuid[])               from public, anon;
revoke all on function public.weighing_postponement_marks(uuid[], date)    from public, anon;
grant execute on function public.management_dashboard(date, date, text)     to authenticated, service_role;
grant execute on function public.management_postponements(date, date, text) to authenticated, service_role;
grant execute on function public.management_summary(date, date, text)       to authenticated, service_role;
grant execute on function public.delivery_board(date)                       to authenticated, service_role;
grant execute on function public.weighing_confirmed_lines(date, date, text) to authenticated, service_role;
grant execute on function public.weighing_unconfirmed_count(date, date)     to authenticated, service_role;
grant execute on function public.weighing_invoice_marks(uuid[])             to authenticated, service_role;
grant execute on function public.weighing_postponement_marks(uuid[], date)  to authenticated, service_role;


-- ============================================================================
-- After running — Chef Julien's account
-- ============================================================================
--   1. Authentication > Users > Add user: his email + a password (send it to
--      him privately). The trigger creates the profile as 'sales', which
--      sees nothing in the CRM until it is changed.
--   2. Then, in the SQL Editor (replace the email):
--
--        update public.profiles p
--           set role = 'company_director', company_scope = 'Prosun Food', full_name = 'Chef Julien'
--          from auth.users u
--         where p.id = u.id and u.email = 'julien@klongphaifarm.com';
--
--   3. Check (one row, company_director, Prosun Food):
--
--        select u.email, p.full_name, p.role, p.company_scope
--        from public.profiles p join auth.users u on u.id = p.id
--        where p.role = 'company_director';
--
-- To remove the access later: set his role back to 'sales' (company_scope is
-- then ignored), or delete the user in Authentication > Users.
-- ============================================================================
