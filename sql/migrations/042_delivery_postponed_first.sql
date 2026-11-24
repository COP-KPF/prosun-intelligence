-- ============================================================================
-- Migration 042 — Delivery board: postponed orders first (24 Nov 2026)
-- ============================================================================
-- Clément, 23 Nov: "the delivery team must update the table each time the
-- product arrives or departs to go see the client. However, I'd like a better
-- focus on the postponed orders."
--
-- The delivery board shows one day at a time. A postponed order whose new
-- delivery day has passed without a "Delivered" mark is on no day the team
-- looks at, so it stays open ("Late again") in Postponed orders.
--
-- This adds one read function for a new section 0 on the delivery board:
-- every postponed order not yet delivered, all days together — late first,
-- then due today, then coming days, then the ones still waiting for
-- production. Same rules as Postponed orders (Migration 035/041), so an order
-- leaves the list exactly when it closes there.
--
--   delivery_postponed_open() → { today, can_mark, reasons, delivered_today, rows[] }
--
-- Who: delivery and admin (with the step buttons), middle office and company
-- director (read-only; company director: his company only). Reasons for the
-- postponement are left out for the delivery team, as on the delivery board.
-- Marks use the existing delivery_mark(paper, status, note) — nothing new to
-- write.
--
-- Run after 041. Safe to run twice.
-- ============================================================================

create or replace function public.delivery_postponed_open()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  r        text := coalesce(public.current_role(), '');
  v_scope  text := public.my_company_scope();
  reasons  boolean;
  v_today  date := (now() at time zone 'Asia/Bangkok')::date;
  v_rows   jsonb;
  v_done   int;
begin
  if r not in ('delivery', 'sale_support', 'admin', 'company_director') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  reasons := r in ('sale_support', 'admin', 'company_director');

  select coalesce(jsonb_agg(s.x order by s.grp, s.due nulls last, s.cust nulls last, s.po), '[]'::jsonb)
    into v_rows
  from (
    select
      jsonb_build_object(
        'key',          o.key,
        'paper_id',     o.paper_id,
        'customer_name', o.customer_name,
        'po_number',    o.po_number,
        'company',      o.company,
        'part',         p.split_part,
        'original_date', o.original_date,
        'due_date',     o.due_date,
        'work_date',    o.work_date,
        'state',        o.state,
        'group',        case when o.state in ('waiting', 'checking', 'no_paper', 'no_date') then 'waiting'
                             when o.late then 'late'
                             when o.due_date = v_today then 'today'
                             else 'coming' end,
        'late',         o.late,
        'days_late',    o.days_late,
        'times',        o.times,
        'source',       o.last_source,
        'reason',       case when reasons then o.reason end,
        'paper_status', o.paper_status,
        'confirmed_at', o.confirmed_at,
        'mark_status',  o.mark_status,
        'mark_at',      o.mark_at,
        'mark_note',    o.mark_note,
        'kg_ordered',   o.kg_ordered,
        'kg_actual',    o.kg_actual,
        'can_mark',     o.paper_id is not null and o.state in ('factory', 'dispatch', 'out', 'problem')
      ) as x,
      case when o.state in ('waiting', 'checking', 'no_paper', 'no_date') then 3
           when o.late then 0
           when o.due_date = v_today then 1
           else 2 end as grp,
      o.due_date as due, o.customer_name as cust, o.po_number as po
    from public.postponed_orders_rows(v_scope, 0) o
    left join public.weighing_papers p on p.id = o.paper_id
    where o.is_open
  ) s;

  select count(*)::int into v_done
  from public.postponed_orders_rows(v_scope, 0) o
  where o.state = 'delivered'
    and (o.mark_at at time zone 'Asia/Bangkok')::date = v_today;

  return jsonb_build_object(
    'today',           v_today,
    'can_mark',        r in ('delivery', 'admin'),
    'reasons',         reasons,
    'delivered_today', v_done,
    'rows',            v_rows);
end;
$$;

comment on function public.delivery_postponed_open() is
  'Delivery board section 0: every postponed order not yet delivered, all days (late, today, coming, waiting production). Delivery/admin mark with delivery_mark; middle office and company director read-only. Migration 042.';

revoke all on function public.delivery_postponed_open() from public, anon;
grant execute on function public.delivery_postponed_open() to authenticated, service_role;


-- Check:
--   select jsonb_array_length(public.delivery_postponed_open()->'rows');   -- as an admin
-- ============================================================================
