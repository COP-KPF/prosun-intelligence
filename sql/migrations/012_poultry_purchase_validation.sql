-- ============================================================================
-- Migration 012 — poultry purchase validation (bird quantities sign-off)
-- ============================================================================
-- Written 6 Sep 2026. Clément, on the multi-cycle calculator: "id like to be
-- able to validate the purchasing bird quantities... a validation at an
-- Instant T by purchasing or me... an add on quantity amount [to cover] the
-- added on orders from the moment we've validate the quantities to the
-- moment the poultry arrives at the factory... this second number is
-- validated, it sends me a notification... to validate the total amount to
-- be ordered."
--
-- The calculator's numbers are live — they recompute every time the page
-- loads, from whatever orders exist right now. That's correct for "what does
-- the book say today", but wrong for "what did we actually decide to buy" —
-- that decision has to be a frozen fact, immune to a new order landing five
-- minutes later, because the whole point of the add-on step (see the process
-- doc's "add-on problem", 4 Sep) is to size a buffer for exactly those late
-- orders. So unlike the calculator itself or the order grid's "already
-- counted" star (both deliberately live-computed — see the app.js comments
-- above aggregatePoultryDemand and orderIsCalcCounted), this is a real
-- stored snapshot.
--
-- WORKFLOW
-- 1. Purchasing or Clément clicks "Validate" on a cycle's numbers: freezes
--    the current recommended-birds figure per bird line, and which orders
--    fed it, as of that instant.
-- 2. Purchasing or Clément sets one add-on (buffer) quantity for the whole
--    cycle — not per bird line — covering late orders between validation
--    and the birds' arrival at the factory. Clément, 6 Sep, on why it's one
--    number rather than per-species: "a number that covers the next two
--    days from the moment the quantity is locked."
-- 3. Setting the add-on emails clement@klongphaifarm.com (via the same
--    EmailJS mechanism the quotation flow already uses — see app.js).
-- 4. Only Clément can give final approval. Once approved, the row is locked
--    (Clément, 6 Sep: "Lock it once I approve") — any change needs a fresh
--    validation for the next occurrence of that cycle. Approval is what
--    should later gate generating the production sequencing sheet (process
--    doc, "End-of-day production sequencing sheet" — not built yet).
--
-- Run order: after 011. Safe to re-run (create table/policy/trigger all use
-- if-not-exists / or-replace guards).
-- ============================================================================

create table if not exists public.poultry_purchase_validations (
  calc_date        date primary key,
  delivery_dates   jsonb not null,          -- the dates this cycle covers, for display only
  status           text not null default 'quantities_validated'
                     check (status in ('quantities_validated', 'addon_set', 'approved')),

  -- Step 1: frozen at the moment of validation. [{species, variant, birds,
  -- bottleneck}, ...] — the same shape the calculator already renders, just
  -- no longer recomputed after this point.
  validated_lines  jsonb not null,
  order_ids        jsonb not null,          -- sale_orders.id values that fed this snapshot — drives the order-grid mark
  validated_by     uuid not null references public.profiles(id),
  validated_at     timestamptz not null default now(),

  -- Step 2: one buffer number for the whole cycle, not per bird line.
  addon_birds      integer check (addon_birds is null or addon_birds >= 0),
  addon_set_by     uuid references public.profiles(id),
  addon_set_at     timestamptz,

  -- Step 4: Clément only, enforced below by trigger, not just by RLS or the
  -- app hiding the button — see Migrations 004/005/010/011 for why that
  -- distinction has mattered every previous time in this project.
  approved         boolean not null default false,
  approved_by      uuid references public.profiles(id),
  approved_at      timestamptz,

  created_at       timestamptz not null default now()
);

comment on table public.poultry_purchase_validations is
  'One row per calculation cycle occurrence (calc_date) actually validated '
  'for purchase. A frozen snapshot, not a live view — see Migration 012 '
  'header. Drives the order grid''s "included in a validated purchase" mark '
  'via order_ids, separate from the always-live "already counted" star.';

comment on column public.poultry_purchase_validations.order_ids is
  'sale_orders.id values whose lines fed this cycle''s validated bird count. '
  'An order placed after validated_at is never in this list, even if its '
  'delivery date falls inside the cycle''s window — that''s the point: it is '
  'exactly what the add-on buffer in step 2 exists to cover.';

comment on column public.poultry_purchase_validations.addon_birds is
  'One buffer number for the whole cycle (not per bird line) — Clément, '
  '6 Sep 2026: sized to cover the gap between validation and the birds '
  'arriving at the factory, not tied to any one species.';


-- ----------------------------------------------------------------------------
-- Access: same two roles as everywhere else purchase quantities appear —
-- purchasing and admin can validate and set the add-on; every PACE role can
-- read, matching the calculator itself (visible to sale_support, purchasing,
-- production, admin). Final approval is restricted further, below.
-- ----------------------------------------------------------------------------
alter table public.poultry_purchase_validations enable row level security;

drop policy if exists "pace roles read purchase validations" on public.poultry_purchase_validations;
create policy "pace roles read purchase validations"
  on public.poultry_purchase_validations
  for select
  using (public.current_role() in ('admin', 'purchasing', 'sale_support', 'production'));

drop policy if exists "purchasing/admin create purchase validations" on public.poultry_purchase_validations;
create policy "purchasing/admin create purchase validations"
  on public.poultry_purchase_validations
  for insert
  with check (public.current_role() in ('admin', 'purchasing'));

drop policy if exists "purchasing/admin update purchase validations" on public.poultry_purchase_validations;
create policy "purchasing/admin update purchase validations"
  on public.poultry_purchase_validations
  for update
  using (public.current_role() in ('admin', 'purchasing'))
  with check (public.current_role() in ('admin', 'purchasing'));

-- No delete policy at all — nobody deletes a validated purchase through the
-- app. If one genuinely needs undoing, that's a deliberate SQL Editor action,
-- same as every other exceptional fix in this project.

grant select, insert, update on public.poultry_purchase_validations to authenticated;


-- ----------------------------------------------------------------------------
-- The lock: enforced in the database, not just hidden in the UI.
-- ----------------------------------------------------------------------------
create or replace function public.enforce_purchase_validation_lock()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if OLD.approved then
    raise exception 'This cycle''s purchase validation is approved and locked — start a fresh validation instead of editing it.';
  end if;
  if NEW.approved and not OLD.approved and public.current_role() <> 'admin' then
    raise exception 'Only admin can give final approval on a purchase validation.';
  end if;
  return NEW;
end;
$$;

drop trigger if exists trg_lock_purchase_validation on public.poultry_purchase_validations;
create trigger trg_lock_purchase_validation
  before update on public.poultry_purchase_validations
  for each row execute function public.enforce_purchase_validation_lock();

-- ============================================================================
-- Check afterwards, in the SQL Editor:
--
--   select column_name from information_schema.columns
--   where table_name = 'poultry_purchase_validations';
--
--   select grantee, privilege_type from information_schema.table_privileges
--   where table_name = 'poultry_purchase_validations';
--   -- authenticated: SELECT/INSERT/UPDATE only. anon: no rows at all.
--
-- Then, simulating a signed-in session (see Migration 003's note on
-- simulating a role from the SQL Editor):
--
--   begin;
--   select set_config('request.jwt.claims', json_build_object('sub', id)::text, true)
--   from public.profiles where role = 'purchasing' limit 1;
--   insert into poultry_purchase_validations (calc_date, delivery_dates,
--     validated_lines, order_ids, validated_by)
--   values ('2026-09-07', '["2026-09-10","2026-09-11"]', '[]', '[]',
--     (select id from profiles where role = 'purchasing' limit 1));
--   update poultry_purchase_validations set approved = true
--     where calc_date = '2026-09-07';
--   -- should fail with the "Only admin" exception here as purchasing;
--   rollback;
--
--   -- Then repeat as admin — the same update should succeed, and a second
--   -- update afterwards (even as admin) should fail with the "locked" error.
-- ============================================================================
