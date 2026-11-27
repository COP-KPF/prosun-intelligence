-- ============================================================================
-- Migration 052 — Customer PO number on the working paper
-- ============================================================================
-- Written 27 Nov 2026. Clément: each working paper printed by sale support
-- carries two numbers — Prosun's own PO ("PO. NO. :" top right, e.g.
-- 69-271102) and, in the "ส่ง :" box under the client's name, the client's own
-- PO number (e.g. POASIA-H102-00093733). The client's number is wanted in a
-- separate column.
--
--   - weighing_papers.customer_po: filled by the AI reading (edge function
--     `smart-api`, redeployed with this migration) and correctable by the
--     factory on the check screen, like the other printed fields.
--   - Confirmed weights (accounting, purchasing, middle office, admin, company
--     director): weighing_confirmed_lines() now returns customer_po.
--
-- Papers read before this migration have no customer PO (the reading did not
-- look for it); it can be typed on the check screen while a paper is not yet
-- confirmed.
--
-- Run order: after 051, BEFORE redeploying the edge function. Safe to re-run.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. The column
-- ----------------------------------------------------------------------------
alter table public.weighing_papers add column if not exists customer_po text;

comment on column public.weighing_papers.customer_po is
  'The client''s own purchase order number, printed in the "ส่ง :" box under the client name '
  '(po_number is Prosun''s own number). Read by the AI, correctable at the factory. Migration 052.';


-- ----------------------------------------------------------------------------
-- 2. Confirmed weights: same function as Migration 032, plus customer_po
-- ----------------------------------------------------------------------------
-- The returned columns change, so the function is dropped and created again
-- (the 2-argument version of Migration 022 reads it by column name and keeps
-- working).
drop function if exists public.weighing_confirmed_lines(date, date, text);

create function public.weighing_confirmed_lines(p_from date, p_to date, p_dept text)
returns table (
  paper_id          uuid,
  work_date         date,
  delivery_date     date,
  company           text,
  po_number         text,
  customer_po       text,
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
    select p.id, p.work_date, p.delivery_date, p.company, p.po_number, p.customer_po, p.customer_name,
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
  'marks and the client''s PO number. Accounting, purchasing, middle office (sale_support) '
  'and admin; a company director reads accounting''s marks for his company. Migrations 022, 032, 052.';

revoke all on function public.weighing_confirmed_lines(date, date, text) from public, anon;
grant execute on function public.weighing_confirmed_lines(date, date, text) to authenticated, service_role;
