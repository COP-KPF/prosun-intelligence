-- ============================================================================
-- Migration 014 — one work sheet generation record per company, not per order
-- ============================================================================
-- Written 7 Sep 2026, superseding part of Migration 013 before it was ever
-- run in production. Clément's question after seeing the "Set Company first"
-- gate: "what happens if one work paper has two company products? could it
-- be automatic?" — followed by the actual rule: "everything that is raw and
-- underoof is psfarm the rest is psfood."
--
-- That changes the shape of the feature. Company is no longer something
-- someone sets on the order before generating a sheet — it's derived per
-- PRODUCT LINE from that line's existing `type` (Raw/UnderRoof -> Prosun
-- Farm, everything else -> Prosun Food), entirely client-side, no schema
-- needed for the derivation itself. But an order can now need ZERO, ONE, or
-- TWO separate work sheet PDFs (one per company actually present among its
-- lines), so "generated" can no longer be a single flag on the order — it
-- has to be one record per (order, company).
--
-- Migration 013's two columns (sale_orders.work_sheet_generated_at/_by)
-- are left in place, just unused from here — dropping columns that may
-- already be live in production is a separate, deliberate decision, not
-- something to bundle into a same-day design change. If 013 was never run,
-- these columns simply never get created and nothing here depends on them.
--
-- sale_orders.entity is untouched and keeps its original job: which company
-- INVOICES the order in Odoo (Clément, order-entry form: "decided in Odoo").
-- That's a separate business decision from which company's letterhead a
-- given product line's work sheet uses, and the two can now legitimately
-- differ on a mixed order.
--
-- Run order: after 013 (doesn't matter whether 013 was ever executed).
-- Safe to re-run (create table / policies all use if-not-exists / drop-if-
-- exists guards).
-- ============================================================================

create table if not exists public.work_sheet_generations (
  order_id      uuid not null references public.sale_orders(id) on delete cascade,
  entity        text not null check (entity in ('Prosun Farm', 'Prosun Food')),
  generated_at  timestamptz not null default now(),
  generated_by  uuid not null references public.profiles(id),
  primary key (order_id, entity)
);

comment on table public.work_sheet_generations is
  'One row per (order, company) work sheet (ใบสั่งงาน) PDF actually '
  'generated from the Orders grid. An order with lines from only one '
  'company gets at most one row; a mixed order can get up to two — one per '
  'company, each PDF listing only that company''s lines. Not locked like '
  'poultry_purchase_validations (Migration 012) — regenerating just '
  'replaces the row''s generated_at/generated_by, since the order can '
  'still change afterwards (a line added, a quantity fixed).';

comment on column public.work_sheet_generations.entity is
  'Which company''s letterhead/lines this generation covers. Derived '
  'client-side from the order''s product lines (Clément, 7 Sep 2026: '
  '"everything that is raw and underoof is psfarm the rest is psfood") — '
  'not sale_orders.entity, which is a separate, manually-set field for '
  'which company invoices the order in Odoo.';

-- ----------------------------------------------------------------------------
-- Access: identical role set to sale_orders itself (Migration 001) — admin
-- full access, sale_support read/write (this is their screen), purchasing
-- and production read-only.
-- ----------------------------------------------------------------------------
alter table public.work_sheet_generations enable row level security;

drop policy if exists "work_sheet_generations: admin full access" on public.work_sheet_generations;
create policy "work_sheet_generations: admin full access"
  on public.work_sheet_generations for all
  using (public.current_role() = 'admin')
  with check (public.current_role() = 'admin');

drop policy if exists "work_sheet_generations: sale_support reads" on public.work_sheet_generations;
create policy "work_sheet_generations: sale_support reads"
  on public.work_sheet_generations for select
  using (public.current_role() = 'sale_support');
drop policy if exists "work_sheet_generations: sale_support inserts" on public.work_sheet_generations;
create policy "work_sheet_generations: sale_support inserts"
  on public.work_sheet_generations for insert
  with check (public.current_role() = 'sale_support');
drop policy if exists "work_sheet_generations: sale_support updates" on public.work_sheet_generations;
create policy "work_sheet_generations: sale_support updates"
  on public.work_sheet_generations for update
  using (public.current_role() = 'sale_support')
  with check (public.current_role() = 'sale_support');

drop policy if exists "work_sheet_generations: purchasing reads" on public.work_sheet_generations;
create policy "work_sheet_generations: purchasing reads"
  on public.work_sheet_generations for select
  using (public.current_role() = 'purchasing');
drop policy if exists "work_sheet_generations: production reads" on public.work_sheet_generations;
create policy "work_sheet_generations: production reads"
  on public.work_sheet_generations for select
  using (public.current_role() = 'production');

-- No delete policy — regenerating updates the existing row (upsert on the
-- order_id/entity primary key) rather than ever removing one.

grant select, insert, update on public.work_sheet_generations to authenticated;

-- ============================================================================
-- Check afterwards, in the SQL Editor:
--
--   select column_name from information_schema.columns
--   where table_name = 'work_sheet_generations';
--
--   select grantee, privilege_type from information_schema.table_privileges
--   where table_name = 'work_sheet_generations';
--   -- authenticated: SELECT/INSERT/UPDATE only. anon: no rows at all.
--
-- Then, simulating a signed-in sale_support session (see Migration 003's
-- note on simulating a role from the SQL Editor):
--
--   begin;
--   select set_config('request.jwt.claims', json_build_object('sub', id)::text, true)
--   from public.profiles where role = 'sale_support' limit 1;
--   insert into work_sheet_generations (order_id, entity, generated_by)
--   values ((select id from sale_orders limit 1), 'Prosun Farm',
--     (select id from profiles where role = 'sale_support' limit 1));
--   -- should succeed;
--   insert into work_sheet_generations (order_id, entity, generated_by)
--   values ((select id from sale_orders limit 1), 'Prosun Food',
--     (select id from profiles where role = 'sale_support' limit 1));
--   -- should also succeed — same order, the other company, no conflict;
--   rollback;
-- ============================================================================
