-- ============================================================================
-- Migration 035 — Postponed orders: follow each one until it is delivered
-- ============================================================================
-- Written 17 Nov 2026. Clément: when an order is postponed, how do I follow
-- it — how do I know it was produced, finished and is no longer postponed?
-- Design agreed on 17 Nov (compact list, Thai and English, nothing covering
-- other text).
--
-- One row per postponed ORDER (not per move), with where it is now:
--     waiting    postponed by production, not produced yet
--     checking   photographed, weights being checked (not confirmed yet)
--     no_paper   middle office register, no working paper with that PO yet
--     no_date    middle office register, no new delivery date yet
--     factory    produced (weights confirmed), waiting for pick-up
--     dispatch   picked up, at the dispatch center      (delivery board, 033)
--     out        on the road
--     problem    delivery problem
--     delivered  delivered                              -> closed
--     closed     closed by hand by the middle office    -> closed
--     untracked  produced before the delivery board started (delivery_from)
--     deleted    its working paper was deleted
-- "Late again": still open and its new delivery date has passed.
--
-- How the pieces join
--   - Production's and the middle office's moves (weighing_postponements) are
--     grouped by working paper: an order moved twice is ONE row, "2×".
--   - A register record (order_postponements) follows the working paper with
--     the same PO whose delivery date is the new date (or up to 14 days
--     later). Same company when both are known. If that paper was also moved
--     by production, the two are one order.
--   - Produced = the paper's weights are confirmed. Picked up, on the road and
--     delivered come from the delivery board's marks (029, 033).
--
-- Closing by hand
--   Until the delivery team uses the board, a produced order never gets its
--   "Delivered" mark. The middle office (and admin) can close an order by hand
--   — "Delivered / close" — and reopen it. Kept in postponement_closures.
--
-- Bell (admins): "Late again" once per order and delivery date, when the new
--   delivery date has passed and the order is still open. Checked when an
--   admin or the middle office opens PACE (and, optionally, every morning by
--   pg_cron — see the end of this file). Orders already late when this
--   migration runs are noted silently, so the first check does not ring for
--   old history.
--
-- Functions
--   postponed_orders_tracker(closed_days)   the list. admin, sale_support,
--       company director (his company, read-only). Reasons for those three.
--   postponed_order_timeline(paper, register)  one order, step by step.
--   postponement_close(paper, register, close, note)  close / reopen by hand.
--       sale_support, admin.
--   postponed_late_check()                  rings the bell for newly late orders.
--   management_postponed_open(company)      Management dashboard tiles.
--
-- Run order: after 034. Safe to re-run.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Closing an order by hand
-- ----------------------------------------------------------------------------
create table if not exists public.postponement_closures (
  id           uuid primary key default gen_random_uuid(),
  paper_id     uuid unique references public.weighing_papers(id) on delete cascade,
  register_id  uuid unique references public.order_postponements(id) on delete cascade,
  closed_at    timestamptz not null default now(),
  closed_by    uuid references public.profiles(id),
  note         text,
  constraint postponement_closures_one check (num_nonnulls(paper_id, register_id) = 1)
);

comment on table public.postponement_closures is
  'A postponed order closed by hand by the middle office (delivered without a delivery-board mark). '
  'Written only by postponement_close(). Migration 035.';

alter table public.postponement_closures enable row level security;
revoke all on public.postponement_closures from anon, authenticated;
grant all on public.postponement_closures to service_role;

drop trigger if exists postponement_closures_log_activity on public.postponement_closures;
create trigger postponement_closures_log_activity
  after insert or update or delete on public.postponement_closures
  for each row execute function public.log_weighing_activity();


-- "Late again" bells already sent (one per order and delivery date)
create table if not exists public.postponed_late_alerts (
  key        text not null,
  due_date   date not null,
  created_at timestamptz not null default now(),
  primary key (key, due_date)
);

alter table public.postponed_late_alerts enable row level security;
revoke all on public.postponed_late_alerts from anon, authenticated;
grant all on public.postponed_late_alerts to service_role;


-- The timeline reads the activity log by paper: two small indexes.
create index if not exists activity_log_record_idx on public.activity_log (table_name, record_id);
create index if not exists activity_log_delivery_paper_idx on public.activity_log ((details->>'paper_id'))
  where table_name = 'delivery_marks';


-- ----------------------------------------------------------------------------
-- 2. Every postponed order and where it is now (internal)
-- ----------------------------------------------------------------------------
create or replace function public.postponed_orders_rows(p_scope text, p_closed_days int)
returns table (
  key text, paper_id uuid, register_ids uuid[],
  customer_name text, po_number text, company text,
  original_date date, due_date date, work_date date,
  times int, sources text[], last_source text,
  reason text, note text, moved_by uuid, moved_at timestamptz,
  kg_ordered numeric, kg_actual numeric,
  paper_status text, reopened boolean, uploaded_at timestamptz, confirmed_at timestamptz,
  mark_status text, mark_at timestamptz, mark_note text,
  closed_at timestamptz, closed_by uuid, close_note text,
  state text, is_open boolean, late boolean, days_late int, delay_days int)
language sql
stable
security definer
set search_path = public
as $$
with cfg as (
  select (now() at time zone 'Asia/Bangkok')::date as today,
         coalesce((select s.delivery_from from public.management_settings s where s.id = 1), date '2026-11-17') as dfrom
),
reg as (
  select o.*, mp.id as match_paper
  from public.order_postponements o
  left join lateral (
    select p.id
    from public.weighing_papers p
    where o.new_date is not null
      and nullif(trim(o.po_number), '') is not null
      and lower(trim(p.po_number)) = lower(trim(o.po_number))
      and coalesce(p.delivery_date, p.work_date) between o.new_date and o.new_date + 14
      and (o.company is null or p.company is null or p.company = o.company)
    order by coalesce(p.delivery_date, p.work_date) - o.new_date, p.uploaded_at desc
    limit 1) mp on true
),
ev as (
  select coalesce('p:' || h.paper_id::text, 'h:' || h.id::text) as key, h.paper_id,
         null::uuid as register_id,
         case h.stage when 'delivery' then 'middle' else 'production' end as src,
         h.customer_name, h.po_number, h.company,
         coalesce(h.from_delivery_date, h.from_work_date) as orig, h.to_delivery_date as dest,
         h.reason, h.note, h.created_by, h.created_at, h.kg_ordered
  from public.weighing_postponements h
  union all
  select case when r.match_paper is not null then 'p:' || r.match_paper::text else 'r:' || r.id::text end,
         r.match_paper, r.id, 'register',
         r.customer_name, r.po_number, r.company,
         r.original_date, r.new_date, r.reason, r.note, r.created_by, r.created_at, r.quantity_kg
  from reg r
),
grp as (
  select e.key,
         (array_agg(e.paper_id) filter (where e.paper_id is not null))[1]         as paper_id,
         coalesce(array_agg(e.register_id) filter (where e.register_id is not null), '{}'::uuid[]) as register_ids,
         count(*)::int                                                             as times,
         array_agg(distinct e.src)                                                 as sources,
         (array_agg(e.src order by e.created_at desc))[1]                          as last_source,
         (array_agg(e.customer_name order by e.created_at desc))[1]                as customer_name,
         (array_agg(e.po_number order by e.created_at desc))[1]                    as po_number,
         (array_agg(e.company order by e.created_at desc))[1]                      as company,
         min(e.orig)                                                               as original_date,
         (array_agg(e.dest order by e.created_at desc))[1]                         as last_dest,
         (array_agg(e.reason order by e.created_at desc))[1]                       as reason,
         (array_agg(e.note order by e.created_at desc))[1]                         as note,
         (array_agg(e.created_by order by e.created_at desc))[1]                   as moved_by,
         max(e.created_at)                                                         as moved_at,
         (array_agg(e.kg_ordered order by e.created_at desc))[1]                   as kg_hist
  from ev e
  group by e.key
),
base as (
  select g.*,
         p.id as p_id, p.status as p_status, p.work_date as p_work_date,
         p.reopened_snapshot is not null and p.status in ('read', 'failed') as p_reopened,
         p.uploaded_at as p_uploaded_at, p.confirmed_at as p_confirmed_at,
         coalesce(p.company, g.company) as co,
         coalesce(nullif(p.customer_name, ''), g.customer_name) as cust,
         coalesce(nullif(p.po_number, ''), g.po_number) as po,
         case when p.id is not null then coalesce(p.delivery_date, p.work_date) else g.last_dest end as due,
         m.eff_status, m.marked_at, m.mnote,
         c.closed_at as c_at, c.closed_by as c_by, c.note as c_note,
         (select sum(case l.ordered_unit when 'kg' then l.ordered_qty when 'g' then l.ordered_qty / 1000 end)
            from public.weighing_lines l where l.paper_id = p.id) as kg_ord,
         (select sum(l.actual_kg) from public.weighing_lines l where l.paper_id = p.id) as kg_act
  from grp g
  left join public.weighing_papers p on p.id = g.paper_id
  left join lateral (
    select case when dm.delivery_date = coalesce(p.delivery_date, p.work_date) then dm.status else 'dispatch' end as eff_status,
           dm.marked_at,
           case when dm.delivery_date = coalesce(p.delivery_date, p.work_date) then dm.note end as mnote
    from public.delivery_marks dm
    where dm.paper_id = p.id
      and (dm.delivery_date = coalesce(p.delivery_date, p.work_date) or dm.status in ('dispatch', 'out', 'problem'))
  ) m on true
  left join public.postponement_closures c
    on (p.id is not null and c.paper_id = p.id)
    or (p.id is null and g.key like 'r:%' and c.register_id = g.register_ids[1])
),
st as (
  select b.*,
         case
           when b.key like 'h:%'                     then 'deleted'
           when b.eff_status = 'delivered'           then 'delivered'
           when b.c_at is not null                   then 'closed'
           when b.p_id is null                       then case when b.last_dest is null then 'no_date' else 'no_paper' end
           when b.eff_status in ('dispatch', 'out', 'problem') then b.eff_status
           when b.p_status = 'confirmed' and b.due < (select dfrom from cfg) then 'untracked'
           when b.p_status = 'confirmed'             then 'factory'
           when b.p_status = 'postponed'             then 'waiting'
           else 'checking'
         end as state
  from base b
)
select s.key, s.p_id, s.register_ids,
       s.cust, s.po, s.co,
       s.original_date, s.due, s.p_work_date,
       s.times, s.sources, s.last_source,
       s.reason, s.note, s.moved_by, s.moved_at,
       coalesce(s.kg_ord, s.kg_hist), s.kg_act,
       s.p_status, coalesce(s.p_reopened, false), s.p_uploaded_at, s.p_confirmed_at,
       s.eff_status, s.marked_at, s.mnote,
       s.c_at, s.c_by, s.c_note,
       s.state,
       s.state not in ('delivered', 'closed', 'untracked', 'deleted') as is_open,
       s.state not in ('delivered', 'closed', 'untracked', 'deleted') and s.due is not null and s.due < cfg.today as late,
       case when s.state not in ('delivered', 'closed', 'untracked', 'deleted') and s.due < cfg.today
            then cfg.today - s.due end as days_late,
       s.due - s.original_date as delay_days
from st s, cfg
where (p_scope is null or s.co = p_scope)
  and (s.state not in ('delivered', 'closed', 'untracked', 'deleted')
       or coalesce(case when s.state = 'delivered' then (s.marked_at at time zone 'Asia/Bangkok')::date end,
                   case when s.state = 'closed' then (s.c_at at time zone 'Asia/Bangkok')::date end,
                   s.due, cfg.today) >= cfg.today - greatest(coalesce(p_closed_days, 30), 0));
$$;

comment on function public.postponed_orders_rows(text, int) is
  'Internal: every postponed order (grouped by working paper, register records joined by PO) and where '
  'it is now. Open orders always; closed ones from the last p_closed_days days. Migration 035.';

revoke all on function public.postponed_orders_rows(text, int) from public, anon, authenticated;
grant execute on function public.postponed_orders_rows(text, int) to service_role;


-- One row as the screen shows it. Reasons and comments only when allowed.
create or replace function public.postponed_order_json(r record, p_reasons boolean)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  return jsonb_build_object(
    'key', r.key, 'paper_id', r.paper_id, 'register_ids', to_jsonb(r.register_ids),
    'customer_name', r.customer_name, 'po_number', r.po_number, 'company', r.company,
    'original_date', r.original_date, 'due_date', r.due_date, 'work_date', r.work_date,
    'times', r.times, 'sources', to_jsonb(r.sources), 'last_source', r.last_source,
    'reason', case when p_reasons then r.reason end,
    'note', case when p_reasons then r.note end,
    'moved_by', (select pr.full_name from public.profiles pr where pr.id = r.moved_by),
    'moved_at', r.moved_at,
    'kg_ordered', r.kg_ordered, 'kg_actual', r.kg_actual,
    'paper_status', r.paper_status, 'reopened', r.reopened,
    'uploaded_at', r.uploaded_at, 'confirmed_at', r.confirmed_at,
    'mark_status', r.mark_status, 'mark_at', r.mark_at,
    'mark_note', case when p_reasons then r.mark_note end,
    'closed_at', r.closed_at,
    'closed_by', (select pr.full_name from public.profiles pr where pr.id = r.closed_by),
    'close_note', case when p_reasons then r.close_note end,
    'state', r.state, 'open', r.is_open, 'late', r.late,
    'days_late', r.days_late, 'delay_days', r.delay_days);
end;
$$;

revoke all on function public.postponed_order_json(record, boolean) from public, anon, authenticated;


-- ----------------------------------------------------------------------------
-- 3. The list (Middle office › Postponed orders)
-- ----------------------------------------------------------------------------
create or replace function public.postponed_orders_tracker(p_closed_days int default 30)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  r       text := coalesce(public.current_role(), '');
  v_scope text := public.my_company_scope();
  v_days  int  := least(greatest(coalesce(p_closed_days, 30), 0), 366);
  orders  jsonb;
begin
  if r not in ('admin', 'sale_support', 'company_director') then
    raise exception 'not allowed' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(public.postponed_order_json(x, true)
           order by x.is_open desc, x.late desc, x.days_late desc nulls last, x.due_date nulls first,
                    x.mark_at desc nulls last, x.customer_name), '[]'::jsonb)
    into orders
  from public.postponed_orders_rows(v_scope, v_days) x;

  return jsonb_build_object(
    'today', (now() at time zone 'Asia/Bangkok')::date,
    'delivery_from', (select s.delivery_from from public.management_settings s where s.id = 1),
    'closed_days', v_days,
    'scope', v_scope,
    'can_edit', r in ('admin', 'sale_support'),
    'can_delete', r = 'admin',
    'orders', orders,
    'loaded_at', now());
end;
$$;

comment on function public.postponed_orders_tracker(int) is
  'Postponed orders and where each one is now (waiting, produced, picked up, on the road, delivered, '
  'late again). Admin, sale_support, company director (his company). Migration 035.';

revoke all on function public.postponed_orders_tracker(int) from public, anon;
grant execute on function public.postponed_orders_tracker(int) to authenticated, service_role;


-- ----------------------------------------------------------------------------
-- 4. One order, step by step
-- ----------------------------------------------------------------------------
create or replace function public.postponed_order_timeline(p_paper uuid default null, p_register uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  r       text := coalesce(public.current_role(), '');
  v_scope text := public.my_company_scope();
  x       record;
  pid     uuid;
  ev      jsonb := '[]'::jsonb;
begin
  if r not in ('admin', 'sale_support', 'company_director') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if p_paper is null and p_register is null then
    raise exception 'choose an order' using errcode = '22023';
  end if;

  select * into x
  from public.postponed_orders_rows(v_scope, 36500) o
  where (p_paper is not null and o.paper_id = p_paper)
     or (p_register is not null and p_register = any(o.register_ids))
  limit 1;
  if not found then
    raise exception 'order not found' using errcode = '22023';
  end if;
  pid := x.paper_id;

  -- Moves by production and from Confirmed weights
  select ev || coalesce(jsonb_agg(jsonb_build_object(
           'at', h.created_at, 'kind', 'moved', 'stage', h.stage,
           'from_work_date', h.from_work_date, 'to_work_date', h.to_work_date,
           'from_date', coalesce(h.from_delivery_date, h.from_work_date), 'to_date', h.to_delivery_date,
           'reason', h.reason, 'note', h.note,
           'by', (select pr.full_name from public.profiles pr where pr.id = h.created_by))), '[]'::jsonb)
    into ev
  from public.weighing_postponements h
  where pid is not null and h.paper_id = pid;

  -- Middle office register
  select ev || coalesce(jsonb_agg(jsonb_build_object(
           'at', o.created_at, 'kind', 'register',
           'from_date', o.original_date, 'to_date', o.new_date,
           'reason', o.reason, 'note', o.note,
           'by', (select pr.full_name from public.profiles pr where pr.id = o.created_by))), '[]'::jsonb)
    into ev
  from public.order_postponements o
  where o.id = any(x.register_ids);

  if pid is not null then
    -- Photographed
    select ev || jsonb_build_array(jsonb_build_object(
             'at', p.uploaded_at, 'kind', 'photographed',
             'by', (select pr.full_name from public.profiles pr where pr.id = p.uploaded_by)))
      into ev
    from public.weighing_papers p where p.id = pid;

    -- Weights confirmed (each confirmation) and reopened for correction
    select ev || coalesce(jsonb_agg(c.j), '[]'::jsonb) into ev
    from (
      select distinct on (a.details->>'confirmed_at')
             jsonb_build_object('at', (a.details->>'confirmed_at')::timestamptz, 'kind', 'confirmed',
               'by', (select pr.full_name from public.profiles pr where pr.id = (a.details->>'confirmed_by')::uuid)) as j
      from public.activity_log a
      where a.table_name = 'weighing_papers' and a.record_id = pid
        and a.details->>'status' = 'confirmed' and a.details->>'confirmed_at' is not null
      order by a.details->>'confirmed_at', a.id
    ) c;
    if x.confirmed_at is not null and not exists (
         select 1 from jsonb_array_elements(ev) e
         where e->>'kind' = 'confirmed' and (e->>'at')::timestamptz = x.confirmed_at) then
      ev := ev || jsonb_build_array(jsonb_build_object('at', x.confirmed_at, 'kind', 'confirmed', 'by', null));
    end if;
    select ev || coalesce(jsonb_agg(c.j), '[]'::jsonb) into ev
    from (
      select distinct on (a.details->>'reopened_at')
             jsonb_build_object('at', (a.details->>'reopened_at')::timestamptz, 'kind', 'reopened',
               'by', (select pr.full_name from public.profiles pr where pr.id = (a.details->>'reopened_by')::uuid)) as j
      from public.activity_log a
      where a.table_name = 'weighing_papers' and a.record_id = pid
        and a.details->>'reopened_at' is not null
      order by a.details->>'reopened_at', a.id
    ) c;

    -- Delivery board steps
    select ev || coalesce(jsonb_agg(c.j), '[]'::jsonb) into ev
    from (
      select distinct on (a.details->>'status', a.details->>'marked_at')
             jsonb_build_object('at', (a.details->>'marked_at')::timestamptz, 'kind', 'mark',
               'status', a.details->>'status', 'delivery_date', a.details->>'delivery_date',
               'note', case when a.details->>'status' = 'problem' then a.details->>'note' end,
               'by', (select pr.full_name from public.profiles pr where pr.id = (a.details->>'marked_by')::uuid)) as j
      from public.activity_log a
      where a.table_name = 'delivery_marks' and a.details->>'paper_id' = pid::text and a.action <> 'DELETE'
      order by a.details->>'status', a.details->>'marked_at', a.id
    ) c;
    select ev || coalesce(jsonb_agg(jsonb_build_object('at', a.changed_at, 'kind', 'mark_cleared',
             'by', (select pr.full_name from public.profiles pr where pr.id = a.user_id))), '[]'::jsonb)
      into ev
    from public.activity_log a
    where a.table_name = 'delivery_marks' and a.details->>'paper_id' = pid::text and a.action = 'DELETE';
  end if;

  -- Closed by hand
  if x.closed_at is not null then
    ev := ev || jsonb_build_array(jsonb_build_object('at', x.closed_at, 'kind', 'closed', 'note', x.close_note,
            'by', (select pr.full_name from public.profiles pr where pr.id = x.closed_by)));
  end if;

  -- Late again: the day after the new delivery date
  if x.late then
    ev := ev || jsonb_build_array(jsonb_build_object(
            'at', ((x.due_date + 1)::timestamp at time zone 'Asia/Bangkok'), 'kind', 'late', 'due_date', x.due_date));
  end if;

  -- (same moment: the natural order of the steps)
  select coalesce(jsonb_agg(e order by (e->>'at')::timestamptz,
           case coalesce(e->>'status', e->>'kind')
             when 'photographed' then 1 when 'confirmed' then 2 when 'moved' then 3 when 'register' then 3
             when 'reopened' then 4 when 'dispatch' then 5 when 'out' then 6 when 'problem' then 7
             when 'delivered' then 8 when 'mark_cleared' then 9 when 'closed' then 10 else 11 end), '[]'::jsonb) into ev
  from jsonb_array_elements(ev) e
  where e->>'at' is not null;

  return jsonb_build_object('order', public.postponed_order_json(x, true), 'events', ev);
end;
$$;

comment on function public.postponed_order_timeline(uuid, uuid) is
  'One postponed order step by step: moves, register, photo, confirmation, pick-up, on the road, '
  'delivered, closed by hand, late again. Admin, sale_support, company director. Migration 035.';

revoke all on function public.postponed_order_timeline(uuid, uuid) from public, anon;
grant execute on function public.postponed_order_timeline(uuid, uuid) to authenticated, service_role;


-- ----------------------------------------------------------------------------
-- 5. Close by hand / reopen
-- ----------------------------------------------------------------------------
create or replace function public.postponement_close(p_paper uuid, p_register uuid, p_close boolean,
                                                     p_note text default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  x record;
begin
  if coalesce(public.current_role(), '') not in ('sale_support', 'admin') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if num_nonnulls(p_paper, p_register) <> 1 then
    raise exception 'choose one order' using errcode = '22023';
  end if;

  select * into x
  from public.postponed_orders_rows(null, 36500) o
  where (p_paper is not null and o.paper_id = p_paper)
     or (p_register is not null and o.paper_id is null and p_register = any(o.register_ids))
  limit 1;
  if not found then
    raise exception 'order not found' using errcode = '22023';
  end if;

  if coalesce(p_close, true) then
    if x.state = 'delivered' then
      raise exception 'this order is already delivered on the delivery board' using errcode = '22023';
    end if;
    insert into public.postponement_closures (paper_id, register_id, closed_by, note)
    values (x.paper_id, case when x.paper_id is null then x.register_ids[1] end, auth.uid(),
            nullif(trim(coalesce(p_note, '')), ''))
    on conflict do nothing;
  else
    delete from public.postponement_closures c
    where (x.paper_id is not null and c.paper_id = x.paper_id)
       or (x.paper_id is null and c.register_id = x.register_ids[1]);
  end if;

  select * into x
  from public.postponed_orders_rows(null, 36500) o
  where o.key = x.key;
  return public.postponed_order_json(x, true);
end;
$$;

comment on function public.postponement_close(uuid, uuid, boolean, text) is
  'Middle office: closes a postponed order by hand (delivered without a delivery-board mark), or reopens it. '
  'Migration 035.';

revoke all on function public.postponement_close(uuid, uuid, boolean, text) from public, anon;
grant execute on function public.postponement_close(uuid, uuid, boolean, text) to authenticated, service_role;


-- ----------------------------------------------------------------------------
-- 6. Bell: "Late again"
-- ----------------------------------------------------------------------------
create or replace function public.postponed_state_label(p_state text)
returns text
language sql
immutable
as $$
  select case p_state
    when 'waiting'  then 'not produced yet'
    when 'checking' then 'weights being checked'
    when 'no_paper' then 'no working paper yet'
    when 'no_date'  then 'no new date yet'
    when 'factory'  then 'produced, waiting at the factory'
    when 'dispatch' then 'at the dispatch center'
    when 'out'      then 'on the road'
    when 'problem'  then 'delivery problem'
    else p_state end;
$$;

create or replace function public.postponed_late_check()
returns integer
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  x record;
  n integer := 0;
begin
  -- From the app (admin, middle office, company director) or a scheduled job (no user).
  if auth.uid() is not null
     and coalesce(public.current_role(), '') not in ('admin', 'sale_support', 'company_director') then
    raise exception 'not allowed' using errcode = '42501';
  end if;

  for x in select * from public.postponed_orders_rows(null, 0) o where o.late loop
    insert into public.postponed_late_alerts (key, due_date) values (x.key, x.due_date)
    on conflict do nothing;
    if found then
      insert into public.notifications (recipient, kind, title, body, details, paper_id, work_date, actor, actor_name)
      select pr.id, 'postponed_late',
             'Late again — ' || public.weighing_paper_label(x.po_number, x.customer_name),
             'New delivery date ' || to_char(x.due_date, 'DD Mon') || ' has passed (first planned '
               || to_char(x.original_date, 'DD Mon') || ', postponed ' || x.times
               || case when x.times = 1 then ' time' else ' times' end || '). Now: '
               || public.postponed_state_label(x.state) || '.',
             jsonb_build_object('key', x.key, 'state', x.state, 'due_date', x.due_date,
                                'original_date', x.original_date, 'register_ids', to_jsonb(x.register_ids)),
             x.paper_id, x.work_date, null, 'PACE'
      from public.profiles pr
      where pr.role = 'admin';
      n := n + 1;
    end if;
  end loop;
  return n;
end;
$$;

comment on function public.postponed_late_check() is
  'Rings the admins'' bell once for each postponed order whose new delivery date has passed while it is '
  'still open. Called by the app when PACE opens; can also run from pg_cron. Migration 035.';

revoke all on function public.postponed_late_check() from public, anon;
grant execute on function public.postponed_late_check() to authenticated, service_role;


-- ----------------------------------------------------------------------------
-- 7. Management dashboard: open vs closed
-- ----------------------------------------------------------------------------
create or replace function public.management_postponed_open(p_company text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_co  text := public.management_company(p_company);   -- a company director gets his own company (032)
  v_out jsonb;
begin
  if coalesce(public.current_role(), '') not in ('admin', 'company_director') then
    raise exception 'not allowed' using errcode = '42501';
  end if;

  with o as (select * from public.postponed_orders_rows(v_co, 30))
  select jsonb_build_object(
    'open',      (select count(*) from o where is_open),
    'waiting',   (select count(*) from o where is_open and state in ('waiting', 'checking', 'no_paper', 'no_date')),
    'produced',  (select count(*) from o where is_open and state in ('factory', 'dispatch', 'out', 'problem')),
    'late',      (select count(*) from o where late),
    'twice',     (select count(*) from o where is_open and times >= 2),
    'closed',    (select count(*) from o where state in ('delivered', 'closed')),
    'closed_avg_delay', (select round(avg(delay_days), 1) from o where state in ('delivered', 'closed')),
    'oldest', coalesce((select jsonb_agg(public.postponed_order_json(y, true)
                 order by y.late desc, y.days_late desc nulls last, y.due_date nulls first)
               from (select * from o where is_open
                     order by late desc, days_late desc nulls last, due_date nulls first limit 8) y), '[]'::jsonb)
  ) into v_out;
  return v_out;
end;
$$;

comment on function public.management_postponed_open(text) is
  'Management dashboard: postponed orders still open, late again, postponed more than once, closed in the '
  'last 30 days, oldest open. Admin, company director (his company). Migration 035.';

revoke all on function public.management_postponed_open(text) from public, anon;
grant execute on function public.management_postponed_open(text) to authenticated, service_role;


-- ----------------------------------------------------------------------------
-- 8. Orders already late today are history: note them without ringing.
-- ----------------------------------------------------------------------------
insert into public.postponed_late_alerts (key, due_date)
select o.key, o.due_date from public.postponed_orders_rows(null, 0) o where o.late
on conflict do nothing;


-- Optional, every morning at 07:00 Bangkok (00:00 UTC), if pg_cron is enabled
-- (Supabase › Database › Extensions › pg_cron):
--   select cron.schedule('postponed-late-check', '0 0 * * *', $$select public.postponed_late_check()$$);
--
-- Check:
--   select jsonb_array_length(public.postponed_orders_tracker(30)->'orders');   -- as admin, in the app
-- ============================================================================
