-- ============================================================================
-- Migration 033 — Delivery board follows the real flow:
--   factory → dispatch center → client
-- ============================================================================
-- Written 17 Nov 2026. Clément: a working paper confirmed means production has
-- produced the order and it is done. The order then waits at the factory to be
-- picked up; the delivery team picks it up by truck, brings it to the dispatch
-- center, and delivers it to the client.
--
-- The delivery team's steps are now:
--     (confirmed paper)  At the factory — waiting for pick-up
--     dispatch           Picked up — at the dispatch center
--     out                Out for delivery
--     delivered          Delivered            (problem: with a comment, as before)
--
-- What changes
--   1. delivery_marks.status also allows 'dispatch'.
--   2. A pick-up can be recorded only on a finished order (weights confirmed).
--      An order already picked up keeps moving even if its paper is reopened.
--   3. Postponing an order that is already at the dispatch center (or on the
--      road) does not lose it: on its new day it shows "at the dispatch
--      center". Before 033 the mark simply disappeared.
--   4. delivery_board(day) also returns "pickups": every finished order still
--      waiting at the factory, whatever its delivery day — production runs a day
--      or two before delivery, so the truck collects for several days at once.
--      Orders delivering before management_settings.delivery_from (new column,
--      default: the day this migration is run) are left out, so older papers
--      that were delivered before the board existed do not show as waiting.
--   5. delivery_mark_many(papers[], status) — "pick up all", "all out for
--      delivery": one call, all or nothing.
--   Company director (Migration 032): same scope as before (his company only,
--   read-only).
--
-- Run order: after 032. Safe to re-run.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Statuses
-- ----------------------------------------------------------------------------
alter table public.delivery_marks drop constraint if exists delivery_marks_status_check;
alter table public.delivery_marks add constraint delivery_marks_status_check
  check (status in ('dispatch', 'out', 'delivered', 'problem'));

comment on table public.delivery_marks is
  'Delivery team marks per working paper: dispatch (picked up, at the dispatch center), out, delivered, '
  'problem (with comment). Written only by delivery_mark(). Migrations 029, 033.';


-- ----------------------------------------------------------------------------
-- 2. From which delivery day the board counts (older papers are history)
-- ----------------------------------------------------------------------------
alter table public.management_settings
  add column if not exists delivery_from date not null default (now() at time zone 'Asia/Bangkok')::date;

comment on column public.management_settings.delivery_from is
  'Delivery board: orders delivering before this day are not listed as waiting for pick-up. Migration 033. '
  'Change in the SQL Editor: update public.management_settings set delivery_from = ''2026-11-18'' where id = 1;';


-- ----------------------------------------------------------------------------
-- 3. One paper, as the board shows it (used by delivery_board only)
-- ----------------------------------------------------------------------------
-- The mark: one made for the paper's current delivery day as recorded; one
-- made for an earlier day is kept as "dispatch" if the goods had left the
-- factory (postponed after pick-up), and dropped otherwise.
create or replace function public.delivery_paper_json(p public.weighing_papers)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'id', p.id,
    'status', p.status,
    'company', p.company,
    'po_number', p.po_number,
    'customer_name', p.customer_name,
    'delivery_date', p.delivery_date,
    'work_date', p.work_date,
    'due_date', coalesce(p.delivery_date, p.work_date),
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
      select jsonb_build_object(
               'status', case when m.delivery_date = coalesce(p.delivery_date, p.work_date) then m.status else 'dispatch' end,
               'note', case when m.delivery_date = coalesce(p.delivery_date, p.work_date) then m.note end,
               'marked_at', m.marked_at,
               'by', pr.full_name,
               'carried', m.delivery_date <> coalesce(p.delivery_date, p.work_date))
      from public.delivery_marks m
      left join public.profiles pr on pr.id = m.marked_by
      where m.paper_id = p.id
        and (m.delivery_date = coalesce(p.delivery_date, p.work_date) or m.status in ('dispatch', 'out', 'problem'))),
    -- Accounting's invoice mark (Migration 030).
    'invoice', (
      select jsonb_build_object('invoice_no', i.invoice_no, 'invoiced_at', i.invoiced_at,
                                'by', pr.full_name,
                                'changed', p.status <> 'confirmed' or p.confirmed_at is distinct from i.confirmed_at_seen)
      from public.weighing_invoices i
      left join public.profiles pr on pr.id = i.invoiced_by
      where i.paper_id = p.id));
$$;

revoke all on function public.delivery_paper_json(public.weighing_papers) from public, anon, authenticated;


-- ----------------------------------------------------------------------------
-- 4. The board (032's version + pick-ups across days)
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
  pickups  jsonb;
  v_from   date;
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
    select public.delivery_paper_json(p) as x
    from public.weighing_papers p
    where coalesce(p.delivery_date, p.work_date) = p_date
      and (v_scope is null or p.company = v_scope)
  ) s;

  -- Every finished order (any delivery day from delivery_from on) still waiting
  -- at the factory: confirmed, no pick-up recorded yet. Migration 033.
  select coalesce(s.delivery_from, date '2026-11-17') into v_from from public.management_settings s where s.id = 1;
  select coalesce(jsonb_agg(x order by x->>'due_date', x->>'customer_name' nulls last, x->>'po_number'), '[]'::jsonb)
    into pickups
  from (
    select public.delivery_paper_json(p) as x
    from public.weighing_papers p
    where p.status = 'confirmed'
      and coalesce(p.delivery_date, p.work_date) >= v_from
      and (v_scope is null or p.company = v_scope)
      and not exists (select 1 from public.delivery_marks m where m.paper_id = p.id
                        and (m.delivery_date = coalesce(p.delivery_date, p.work_date)
                             or m.status in ('dispatch', 'out', 'problem')))
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
    'pickups', pickups,
    'delivery_from', v_from,
    'reasons_visible', reasons,
    'scope', v_scope,
    'can_mark', r in ('delivery', 'admin'),
    'loaded_at', now());
end;
$$;
comment on function public.delivery_board(date) is
  'Delivery board for one day (papers due, pushed away, register) plus every finished order still waiting '
  'at the factory (pickups). Reasons only for admin, sale_support, company director. Migrations 029, 030, 032, 033.';

revoke all on function public.delivery_board(date) from public, anon;
grant execute on function public.delivery_board(date) to authenticated, service_role;


-- ----------------------------------------------------------------------------
-- 5. Marking one order
-- ----------------------------------------------------------------------------
create or replace function public.delivery_mark(p_paper uuid, p_status text, p_note text default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  p    public.weighing_papers;
  day  date;
  note text := nullif(trim(coalesce(p_note, '')), '');
  rec  public.delivery_marks;
  had  boolean;
begin
  if coalesce(public.current_role(), '') not in ('delivery', 'admin') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  select * into p from public.weighing_papers where id = p_paper;
  if not found then
    raise exception 'paper not found' using errcode = '22023';
  end if;
  day := coalesce(p.delivery_date, p.work_date);

  if p_status is null then
    delete from public.delivery_marks where paper_id = p.id;
    return null;
  end if;

  if p_status not in ('dispatch', 'out', 'delivered', 'problem') then
    raise exception 'unknown delivery status' using errcode = '22023';
  end if;
  -- Only a finished order leaves the factory. One already picked up keeps
  -- moving even if the factory reopens its paper meanwhile.
  select exists (select 1 from public.delivery_marks m where m.paper_id = p.id) into had;
  if p.status <> 'confirmed' and not had then
    raise exception 'this order is not finished yet — its weights are not confirmed (status: %)', p.status
      using errcode = '22023';
  end if;
  if p_status = 'problem' and note is null then
    raise exception 'write what the problem is' using errcode = '22023';
  end if;

  insert into public.delivery_marks (paper_id, delivery_date, status, note, marked_by, marked_at)
  values (p.id, day, p_status, note, auth.uid(), now())
  on conflict (paper_id) do update
    set delivery_date = excluded.delivery_date, status = excluded.status, note = excluded.note,
        marked_by = excluded.marked_by, marked_at = excluded.marked_at
  returning * into rec;

  if p_status = 'problem' then
    perform public.notify_admins('delivery_problem',
      'Delivery problem — ' || public.weighing_paper_label(p.po_number, p.customer_name),
      'Delivery ' || to_char(day, 'DD Mon') || ': ' || note,
      jsonb_build_object('mark', to_jsonb(rec)),
      p.id, p.work_date);
  end if;

  return to_jsonb(rec);
end;
$$;

comment on function public.delivery_mark(uuid, text, text) is
  'Delivery team: dispatch (picked up) / out / delivered / problem (comment required; notifies admins), '
  'or clears the mark (status null). Delivery and admin. Migrations 029, 033.';

revoke all on function public.delivery_mark(uuid, text, text) from public, anon;
grant execute on function public.delivery_mark(uuid, text, text) to authenticated, service_role;


-- ----------------------------------------------------------------------------
-- 6. Marking several orders at once ("pick up all", "all out for delivery")
-- ----------------------------------------------------------------------------
create or replace function public.delivery_mark_many(p_papers uuid[], p_status text)
returns integer
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  id uuid;
  n  integer := 0;
begin
  if coalesce(public.current_role(), '') not in ('delivery', 'admin') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if p_status is null or p_status not in ('dispatch', 'out', 'delivered') then
    raise exception 'several orders at once: dispatch, out or delivered only' using errcode = '22023';
  end if;
  foreach id in array coalesce(p_papers, array[]::uuid[]) loop
    perform public.delivery_mark(id, p_status, null);   -- all or nothing
    n := n + 1;
  end loop;
  return n;
end;
$$;

comment on function public.delivery_mark_many(uuid[], text) is
  'Marks several papers dispatch / out / delivered in one go (all or nothing). Delivery and admin. Migration 033.';

revoke all on function public.delivery_mark_many(uuid[], text) from public, anon;
grant execute on function public.delivery_mark_many(uuid[], text) to authenticated, service_role;


-- Check:
--   select delivery_from from public.management_settings;   -- the day this ran
-- ============================================================================
