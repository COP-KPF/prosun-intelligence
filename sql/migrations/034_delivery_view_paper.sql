-- ============================================================================
-- Migration 034 — Delivery board: open the weighing paper
-- ============================================================================
-- Written 17 Nov 2026. Clément: in the delivery summary table, be able to
-- check the weighing paper as well.
--
-- Each row of the summary table gets a "View paper" button: the photographed
-- working paper (FM-SA-01) with its lines — product, ordered, actual kg — and
-- who confirmed the weights.
--
-- What it adds
--   1. The delivery team can open the photo of a CONFIRMED paper — the same
--      rule accounting, purchasing and the middle office already have
--      (Migrations 020, 022). Photos of papers still being checked stay with
--      the factory and admin. Photos are deleted after 4 weeks (Migration 018).
--   2. delivery_board(day) papers also carry photo_path, photo_deleted_at and
--      the name of who confirmed the weights (delivery_paper_json, 033).
--   Company director (032): unchanged — his company's confirmed papers.
--
-- Run order: after 033. Safe to re-run.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Photos of confirmed papers: the delivery team too
-- ----------------------------------------------------------------------------
drop policy if exists "weighing-photos: delivery sees confirmed" on storage.objects;
create policy "weighing-photos: delivery sees confirmed"
  on storage.objects for select to authenticated
  using (bucket_id = 'weighing-photos'
         and public.current_role() = 'delivery'
         and public.weighing_photo_is_confirmed(name));


-- ----------------------------------------------------------------------------
-- 2. One paper as the board shows it (033's version + the paper itself)
-- ----------------------------------------------------------------------------
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
    -- 034: the working paper itself — its photo (opened only where the storage
    -- rules allow: confirmed papers for the delivery team) and who confirmed it.
    'photo_path', p.photo_path,
    'photo_deleted_at', p.photo_deleted_at,
    'confirmed_by_name', (select pr.full_name from public.profiles pr where pr.id = p.confirmed_by),
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


-- Check (as a delivery login, in the app): Delivery › Delivery board › 📄 View
-- on a confirmed order shows the photo.
-- ============================================================================
