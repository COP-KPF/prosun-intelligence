-- ============================================================================
-- Migration 017 — manual work-sheet company selection, per order (11 Sep 2026)
-- ============================================================================
-- Jane (sale support manager), in written feedback to Clément: "we want to
-- manually select which company Prosun Farm/Food for each work order."
--
-- Migration 014 (7 Sep 2026) made the PSFarm/PSFood work-sheet buttons
-- appear automatically, computed live from each order line's own product
-- type (Raw/UnderRoof -> Prosun Farm, everything else -> Prosun Food). That
-- was the right call at the time (Clément's own rule, applied exactly), but
-- Jane's team wants direct control over which button(s) show on a given
-- order rather than relying on the automatic read of the line types.
-- Confirmed with Clément: manual selection replaces the automatic detection
-- entirely, rather than merely overriding it case by case.
--
-- What this does NOT change: which PRODUCTS print on which company's PDF.
-- buildWorkSheetDoc() in app.js still filters an order's lines by
-- lineCompany(type) (Raw/UnderRoof -> Farm, else -> Food) when building the
-- actual sheet content -- that is a statement about which factory
-- physically handles a given product, which hasn't changed. This migration
-- only changes which button(s) appear on an order in the first place, and
-- the existing "no <Company> lines to put on a work sheet" guard in
-- handleGenerateWorkSheet() still catches a manual selection that doesn't
-- match what's actually on the order.
--
-- Purely additive: two new boolean columns on sale_orders, backfilled from
-- exactly the same Raw/UnderRoof rule Migration 014's client-side detection
-- already used, so no order's visible work-sheet button disappears the
-- moment this migration runs. From this point on the two columns are the
-- only source of truth for which button(s) show -- app.js no longer
-- recomputes them from the lines, so editing an order's lines afterward
-- never silently changes which button(s) appear; that now only changes via
-- the "Work sheet company" checkboxes in the Edit panel.
--
-- No RLS/grant changes: sale_support and admin already have UPDATE on
-- sale_orders (Migration 001), which covers writing these two columns; every
-- PACE role already reads sale_orders, which covers seeing them.
--
-- Run order: after 016. Safe to re-run (add-column guards, and the backfill
-- is deterministic from the same lines every time).
-- ============================================================================

alter table public.sale_orders
  add column if not exists ws_company_farm boolean not null default false,
  add column if not exists ws_company_food boolean not null default false;

comment on column public.sale_orders.ws_company_farm is
  'Whether this order needs a Prosun Farm (PSFarm) work sheet. Manually set '
  'by sale support in the Edit panel (Migration 017) -- no longer derived '
  'automatically from the order''s product lines. Backfilled once, at '
  'migration time, from the same Raw/UnderRoof rule Migration 014 used, so '
  'existing orders keep showing the button they already had.';
comment on column public.sale_orders.ws_company_food is
  'Whether this order needs a Prosun Food (PSFood) work sheet. See '
  'ws_company_farm.';

update public.sale_orders o set
  ws_company_farm = exists (
    select 1 from public.sale_order_lines l
    where l.order_id = o.id and l.type in ('Raw', 'UnderRoof')
  ),
  ws_company_food = exists (
    select 1 from public.sale_order_lines l
    where l.order_id = o.id and l.type not in ('Raw', 'UnderRoof')
  )
where true;

-- ============================================================================
-- Check afterwards, in the SQL Editor:
--
--   select ws_company_farm, ws_company_food, count(*)
--   from public.sale_orders group by 1, 2;
--   -- every existing order should land in the same Farm/Food/both bucket
--   -- its PSFarm/PSFood buttons already showed before this migration ran.
-- ============================================================================
