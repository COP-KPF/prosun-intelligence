-- ============================================================================
-- Migration 013 — work sheet (ใบสั่งงาน) generation tracking
-- ============================================================================
-- Written 7 Sep 2026. This started life as an idea for a *grouped*, cross-
-- order production sequencing sheet (the 5 Sep process doc's design), but
-- once shown a draft Clément redirected it: "Id like to be one by one, not
-- grouped... the work sheet corresponds exactly to the client order with
-- the description the SS team wrote." So this migration is much smaller
-- than 012 — it just adds the tracking columns needed for item 2 of the
-- original target-system design: PACE auto-generating the same per-order
-- work sheet (ใบสั่งงาน, form FM-SA-01) sale support currently builds by hand
-- in Excel, one PDF per order, from real order data instead of retyping it.
--
-- Two things Clément asked for alongside the PDF itself:
-- 1. Two letterheads (his words: "psfarm and psfood"), matching the order's
--    own `entity` field (Migration 001/002, already captured at order
--    entry) — no new column needed for that.
-- 2. A "Work sheet generated" flag per order, visible on the Orders grid.
--
-- Deliberately NOT locked the way Migration 012's purchase validation is.
-- An order can still change after its work sheet is generated (a client
-- adds a line, a quantity gets corrected), and the team should be able to
-- regenerate freely — this is an operational convenience flag, not a
-- sign-off record. No trigger, no separate table: two columns on the
-- existing sale_orders row, updated in place each time the sheet is
-- (re)generated.
--
-- No new RLS policy needed either: sale_support and admin already have
-- UPDATE on sale_orders (Migration 001), which covers writing these two
-- columns; every PACE role already has read access to sale_orders, which
-- covers seeing the flag.
--
-- Run order: after 012. Safe to re-run (add column if-not-exists guards).
-- ============================================================================

alter table public.sale_orders
  add column if not exists work_sheet_generated_at timestamptz,
  add column if not exists work_sheet_generated_by uuid references public.profiles(id);

comment on column public.sale_orders.work_sheet_generated_at is
  'When the ใบสั่งงาน (per-order work sheet) PDF was last generated for this '
  'order, from the Orders grid''s "Work sheet" column. Not locked like '
  'Migration 012''s purchase validation — an order can change after its '
  'sheet is generated, and the team regenerates as needed.';

comment on column public.sale_orders.work_sheet_generated_by is
  'profiles.id of whoever last generated this order''s work sheet PDF.';

-- ============================================================================
-- Check afterwards, in the SQL Editor:
--
--   select column_name from information_schema.columns
--   where table_name = 'sale_orders'
--   and column_name like 'work_sheet%';
--   -- should list both new columns.
--
-- No RLS/grant changes to verify — this migration reuses sale_orders'
-- existing policies from Migration 001.
-- ============================================================================
