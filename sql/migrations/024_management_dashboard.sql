-- ============================================================================
-- Migration 024 — Management dashboard (PACE › Management)
-- ============================================================================
-- Written 2 Nov 2026. Clément: a management dashboard to follow the activity
-- and pilot the company. First version, from data already in the system:
--   papers photographed / confirmed and kg confirmed per day; papers still
--   unconfirmed; lines under or over the ordered quantity, by client; time from
--   confirmation to the accounting check; clients per salesperson, at-risk
--   clients, clients with no salesperson.
--
-- Revenue is deliberately absent: order lines and weighing lines carry no
-- price yet. "Papers issued" is absent too: sale support works in the Excel
-- macro until the move to PACE (around Jan 2027), so this version counts the
-- papers photographed.
--
-- Rules behind the numbers
--   - A paper belongs to the day it was photographed (work_date), the same day
--     as the weighing screen's day table.
--   - Weights count only on confirmed papers.
--   - Under / over: only lines ordered in kg or g can be compared with actual
--     kg, and the tolerance is the weighing screen's ±5% (WEIGH_TOLERANCE in
--     weighing.js). Lines ordered in pieces, packs or jars are counted apart.
--   - Waiting for accounting: confirmed, and either never checked by accounting
--     or re-confirmed at the factory after the check. This is the "checked" mark
--     of Migration 022, not proof that an Odoo invoice exists.
--   - Salesperson figures come from the CRM's clients table as it stands today;
--     they do not follow the period or company filters.
--
-- count_from: papers before this date (team testing) are left out of every
-- weighing figure. Clément: 2 Nov 2026 is the first real day. Admin can change it
-- on the dashboard.
--
-- Access: admin only, role checked inside the functions. The settings table has
-- no policies, so it is reached only through them. Nothing here changes a
-- weight or a client.
--
-- Run order: after 023. Safe to re-run.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Settings
-- ----------------------------------------------------------------------------
create table if not exists public.management_settings (
  id          int primary key default 1 check (id = 1),
  count_from  date not null default date '2026-11-02',
  updated_by  uuid references public.profiles(id),
  updated_at  timestamptz not null default now()
);

insert into public.management_settings (id) values (1) on conflict (id) do nothing;

comment on table public.management_settings is
  'One row. count_from: the first day the Management dashboard counts weighing '
  'papers (earlier ones were team testing). Migration 024.';

alter table public.management_settings enable row level security;
revoke all on public.management_settings from anon, authenticated;
grant all on public.management_settings to service_role;


-- ----------------------------------------------------------------------------
-- 2. The dashboard's numbers
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
  v_co    text := nullif(p_company, 'all');
  v_out   jsonb;
begin
  if coalesce(public.current_role(), '') <> 'admin' then
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
    group by c.assigned_to
  )
  select jsonb_build_object(
    'today', v_today,
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
  'Numbers for PACE › Management. Admin only; read-only. Migration 024.';


-- ----------------------------------------------------------------------------
-- 3. Changing the first counted day
-- ----------------------------------------------------------------------------
create or replace function public.management_set_count_from(p_date date)
returns date
language plpgsql
volatile
security definer
set search_path = public
as $$
begin
  if coalesce(public.current_role(), '') <> 'admin' then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if p_date is null or p_date > (now() at time zone 'Asia/Bangkok')::date then
    raise exception 'choose a date that is not in the future' using errcode = '22023';
  end if;
  update public.management_settings
     set count_from = p_date, updated_by = auth.uid(), updated_at = now()
   where id = 1;
  return p_date;
end;
$$;

comment on function public.management_set_count_from(date) is
  'Sets the first day the Management dashboard counts weighing papers. Admin only. Migration 024.';

revoke all on function public.management_dashboard(date, date, text) from public, anon;
revoke all on function public.management_set_count_from(date)        from public, anon;
grant execute on function public.management_dashboard(date, date, text) to authenticated, service_role;
grant execute on function public.management_set_count_from(date)        to authenticated, service_role;
