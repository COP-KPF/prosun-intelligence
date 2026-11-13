-- ============================================================================
-- Migration 030 — "Invoiced" marks (accounting) + invoice status on the
--                 delivery board
-- ============================================================================
-- Written 13 Nov 2026. Clément: the delivery team needs to see which order is
-- finished, how many kg, and whether accounting has already generated the
-- invoice.
--
-- Accounting issues invoices in Odoo from the Confirmed weights screen
-- (Migration 020). Until now nothing recorded that the invoice exists — the
-- "checked" marks of Migration 022 only say someone opened the paper. This
-- migration adds an explicit mark, set by accounting on Confirmed weights:
--     🧾 Invoiced  (+ the Odoo invoice number, optional)
-- and shows it on every card of the delivery board.
--
-- If the factory reopens or re-confirms a paper after it was invoiced, the
-- mark shows "weights changed after invoice" (on both screens) and accounting
-- gets a bell, so a corrected invoice / credit note is not missed.
--
-- What it adds
--   1. weighing_invoices — one row per paper; no direct table access; every
--      change kept in activity_log.
--   2. weighing_mark_invoiced(paper, invoiced, invoice_no) — accounting, admin.
--      Marking needs a confirmed paper; unmarking is always possible.
--   3. weighing_invoice_marks(papers[]) — read by accounting, admin, middle
--      office, purchasing, delivery (the screens that show the mark).
--   4. delivery_board(day) — now also returns each paper's invoice mark.
--   5. Trigger: weights re-confirmed after the invoice → bell for accounting
--      (kind invoice_weights_changed).
--
-- Run order: after 029. Safe to re-run.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. The marks
-- ----------------------------------------------------------------------------
create table if not exists public.weighing_invoices (
  id                 uuid primary key default gen_random_uuid(),
  paper_id           uuid not null unique references public.weighing_papers(id) on delete cascade,
  invoice_no         text,            -- Odoo invoice number, optional
  invoiced_by        uuid references public.profiles(id),
  invoiced_at        timestamptz not null default now(),
  confirmed_at_seen  timestamptz      -- the paper's confirmation the invoice was made from
);

comment on table public.weighing_invoices is
  'Accounting''s "invoiced" mark per confirmed weighing paper (+ optional Odoo invoice number). '
  'Written only by weighing_mark_invoiced(); read through weighing_invoice_marks() and delivery_board(). Migration 030.';

alter table public.weighing_invoices enable row level security;
revoke all on public.weighing_invoices from anon, authenticated;
grant all on public.weighing_invoices to service_role;

drop trigger if exists weighing_invoices_log_activity on public.weighing_invoices;
create trigger weighing_invoices_log_activity
  after insert or update or delete on public.weighing_invoices
  for each row execute function public.log_weighing_activity();


-- ----------------------------------------------------------------------------
-- 2. Marking (accounting, admin)
-- ----------------------------------------------------------------------------
create or replace function public.weighing_mark_invoiced(p_paper uuid, p_invoiced boolean, p_invoice_no text default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  p   public.weighing_papers;
  rec public.weighing_invoices;
  nm  text;
begin
  if coalesce(public.current_role(), '') not in ('accounting', 'admin') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  select * into p from public.weighing_papers where id = p_paper;
  if not found then
    raise exception 'paper not found' using errcode = '22023';
  end if;

  if not coalesce(p_invoiced, false) then
    delete from public.weighing_invoices where paper_id = p.id;
    return null;
  end if;

  if p.status <> 'confirmed' then
    raise exception 'the weights of this paper are not confirmed (status: %)', p.status using errcode = '22023';
  end if;

  insert into public.weighing_invoices (paper_id, invoice_no, invoiced_by, invoiced_at, confirmed_at_seen)
  values (p.id, nullif(trim(coalesce(p_invoice_no, '')), ''), auth.uid(), now(), p.confirmed_at)
  on conflict (paper_id) do update
    set invoice_no = excluded.invoice_no, invoiced_by = excluded.invoiced_by,
        invoiced_at = excluded.invoiced_at, confirmed_at_seen = excluded.confirmed_at_seen
  returning * into rec;

  select full_name into nm from public.profiles where id = rec.invoiced_by;
  return jsonb_build_object('paper_id', rec.paper_id, 'invoice_no', rec.invoice_no,
                            'invoiced_at', rec.invoiced_at, 'invoiced_by_name', nm, 'changed', false);
end;
$$;

comment on function public.weighing_mark_invoiced(uuid, boolean, text) is
  'Accounting marks a confirmed paper as invoiced (optional Odoo invoice number), or clears the mark. '
  'Accounting and admin. Migration 030.';

revoke all on function public.weighing_mark_invoiced(uuid, boolean, text) from public, anon;
grant execute on function public.weighing_mark_invoiced(uuid, boolean, text) to authenticated, service_role;


-- ----------------------------------------------------------------------------
-- 3. Reading the marks of the papers on screen
-- ----------------------------------------------------------------------------
create or replace function public.weighing_invoice_marks(p_papers uuid[])
returns table (paper_id uuid, invoice_no text, invoiced_at timestamptz,
               invoiced_by_name text, changed boolean)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if coalesce(public.current_role(), '') not in ('accounting', 'admin', 'sale_support', 'purchasing', 'delivery') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  return query
    select i.paper_id, i.invoice_no, i.invoiced_at, pr.full_name,
           (p.status <> 'confirmed' or p.confirmed_at is distinct from i.confirmed_at_seen)
    from public.weighing_invoices i
    join public.weighing_papers p on p.id = i.paper_id
    left join public.profiles pr on pr.id = i.invoiced_by
    where i.paper_id = any(coalesce(p_papers, array[]::uuid[]));
end;
$$;

comment on function public.weighing_invoice_marks(uuid[]) is
  'Invoice marks of the given papers; changed = weights reopened / re-confirmed since the invoice. Migration 030.';

revoke all on function public.weighing_invoice_marks(uuid[]) from public, anon;
grant execute on function public.weighing_invoice_marks(uuid[]) to authenticated, service_role;


-- ----------------------------------------------------------------------------
-- 4. Delivery board, now with the invoice mark of each paper
--    (same as Migration 029 otherwise)
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
  reasons  boolean;
  papers   jsonb;
  moved    jsonb;
  register jsonb;
begin
  if r not in ('delivery', 'sale_support', 'admin') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if p_date is null then
    raise exception 'choose a delivery day' using errcode = '22023';
  end if;
  reasons := r in ('sale_support', 'admin');

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
    where p.id is null or coalesce(p.delivery_date, p.work_date) <> p_date
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
  where o.original_date = p_date;

  return jsonb_build_object(
    'date', p_date,
    'papers', papers,
    'moved', moved,
    'register', register,
    'reasons_visible', reasons,
    'can_mark', r in ('delivery', 'admin'),
    'loaded_at', now());
end;
$$;

-- ----------------------------------------------------------------------------
-- 5. Weights re-confirmed after the invoice → bell for accounting
-- ----------------------------------------------------------------------------
create or replace function public.weighing_invoice_changed_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  inv public.weighing_invoices;
  who uuid := auth.uid();
  who_name text;
begin
  if new.status <> 'confirmed' or new.confirmed_at is not distinct from old.confirmed_at then
    return new;
  end if;
  select * into inv from public.weighing_invoices where paper_id = new.id;
  if not found or inv.confirmed_at_seen is not distinct from new.confirmed_at then
    return new;
  end if;
  select full_name into who_name from public.profiles where id = who;
  insert into public.notifications (recipient, kind, title, body, details, paper_id, work_date, actor, actor_name)
  select pr.id, 'invoice_weights_changed',
         'Weights changed after invoice — ' || public.weighing_paper_label(new.po_number, new.customer_name),
         'The factory re-confirmed this paper after it was marked invoiced'
           || coalesce(' (' || inv.invoice_no || ')', '') || '. Check the invoice in Odoo.',
         jsonb_build_object('invoice_no', inv.invoice_no, 'invoiced_at', inv.invoiced_at,
                            'delivery_date', coalesce(new.delivery_date, new.work_date)),
         new.id, new.work_date, who, who_name
  from public.profiles pr
  where pr.role = 'accounting' and pr.id is distinct from who;
  return new;
end;
$$;

revoke all on function public.weighing_invoice_changed_notify() from public, anon, authenticated;

drop trigger if exists weighing_papers_invoice_changed on public.weighing_papers;
create trigger weighing_papers_invoice_changed
  after update of status, confirmed_at on public.weighing_papers
  for each row execute function public.weighing_invoice_changed_notify();


-- Check:
--   select count(*) from public.weighing_invoices;     -- 0 right after running
-- ============================================================================
