-- ============================================================================
-- Migration 016 — simplified three-click purchase confirmation (7 Sep 2026)
-- ============================================================================
-- Clément, looking at the shipped Migration 012 panel: "before we move on,
-- please simplify the purchase interface. Id like something very easy to
-- read with the possibility to have the detail. And confirmation. it could
-- be a table which the two or three last columns are confirmation. With
-- Purchase manager to click, sale support manager and me at the end."
--
-- Two design forks were resolved with him before writing this:
--  - The add-on (buffer) step, previously its own separate action between
--    validating and approving, is now folded into purchasing's single
--    confirm click — one step instead of two.
--  - Sale support's confirmation means "I've looked at these frozen
--    quantities and they look right" — a read-and-agree checkpoint with no
--    editing power, not a statement that the order book itself is settled.
--
-- The new flow is three clicks, in order:
--   1. Purchasing (or admin) confirms the quantities AND sets the add-on
--      buffer in one action — same moment, same person, replacing the old
--      two-step validate-then-set-addon sequence.
--   2. Sale support (or admin) confirms the frozen numbers look right.
--   3. Admin gives final approval, which locks the row exactly as before.
--
-- This migration is purely additive — it does not touch or rename anything
-- Migration 012 created, so any cycle already sitting in production under
-- the old flow (status = 'quantities_validated' or 'addon_set') keeps
-- working: the app now derives which stage a row is at from which columns
-- are actually populated (validated_by, addon_birds, the new
-- ss_confirmed_by, approved) rather than from the `status` text column, so
-- no backfill or status rewrite is needed for existing rows. `status` is
-- still written on each step for a human skimming the table in the SQL
-- Editor, but nothing in the app reads it anymore.
--
-- Run order: after 015. Safe to re-run (add column/policy/trigger all use
-- if-not-exists / or-replace guards).
-- ============================================================================

alter table public.poultry_purchase_validations
  add column if not exists ss_confirmed_by uuid references public.profiles(id),
  add column if not exists ss_confirmed_at timestamptz;

comment on column public.poultry_purchase_validations.ss_confirmed_by is
  'Sale support (or admin) confirming the frozen quantities above look '
  'right — a read-and-agree checkpoint, no editing power. Sits between '
  'purchasing''s confirm+add-on step and Clément''s final approval. Added '
  'Migration 016, replacing the old validate -> set add-on -> approve '
  'sequence with confirm+add-on -> sale support confirm -> approve.';


-- ----------------------------------------------------------------------------
-- Access: sale_support now needs to write its own confirmation, alongside
-- purchasing/admin's existing ability to write the initial confirm+add-on.
-- The trigger below (not this policy) is what keeps sale_support from
-- writing anything other than its own two new columns.
-- ----------------------------------------------------------------------------
drop policy if exists "purchasing/admin update purchase validations" on public.poultry_purchase_validations;
drop policy if exists "pace roles update purchase validations" on public.poultry_purchase_validations;
create policy "pace roles update purchase validations"
  on public.poultry_purchase_validations
  for update
  using (public.current_role() in ('admin', 'purchasing', 'sale_support'))
  with check (public.current_role() in ('admin', 'purchasing', 'sale_support'));


-- ----------------------------------------------------------------------------
-- The lock, extended — enforced in the database, not just by which button
-- the UI happens to show. Builds on Migration 012's trigger rather than
-- replacing its intent: still locked solid once approved, still admin-only
-- to approve. New rules add the sale-support step and its column-scoping.
-- ----------------------------------------------------------------------------
create or replace function public.enforce_purchase_validation_lock()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  approving_now boolean := NEW.approved and not OLD.approved;
  ss_confirming_now boolean := (NEW.ss_confirmed_by is distinct from OLD.ss_confirmed_by)
                             or (NEW.ss_confirmed_at is distinct from OLD.ss_confirmed_at);
  changing_frozen_numbers boolean := (NEW.validated_lines is distinct from OLD.validated_lines)
                                   or (NEW.order_ids is distinct from OLD.order_ids)
                                   or (NEW.addon_birds is distinct from OLD.addon_birds);
begin
  if OLD.approved then
    raise exception 'This cycle''s purchase validation is approved and locked — start a fresh validation instead of editing it.';
  end if;

  -- Final approval: admin only, and only once sale support has confirmed —
  -- enforces the three-click order itself, not just each individual step.
  if approving_now then
    if public.current_role() <> 'admin' then
      raise exception 'Only admin can give final approval on a purchase validation.';
    end if;
    if OLD.ss_confirmed_by is null then
      raise exception 'Sale support has not confirmed these quantities yet.';
    end if;
  end if;

  -- Sale support's confirm: sale_support or admin, first time only (touching
  -- either the "by" or the "at" column counts — a replay that only bumps
  -- the timestamp is still a second confirmation), and it may not travel
  -- alongside a change to the frozen numbers it is meant to be confirming.
  if ss_confirming_now then
    if OLD.ss_confirmed_by is not null then
      raise exception 'Sale support has already confirmed this cycle.';
    end if;
    if public.current_role() not in ('sale_support', 'admin') then
      raise exception 'Only sale support (or admin) can confirm these quantities.';
    end if;
    if changing_frozen_numbers then
      raise exception 'Sale support''s confirmation cannot also change the validated quantities.';
    end if;
  end if;

  -- Once sale support has confirmed, the frozen numbers are locked from
  -- further edits short of a fresh validation (a new row) — otherwise a
  -- later purchasing edit could silently invalidate a confirmation someone
  -- already gave.
  if OLD.ss_confirmed_by is not null
     and changing_frozen_numbers
     and public.current_role() <> 'admin' then
    raise exception 'Sale support already confirmed these quantities — start a fresh validation instead of editing it.';
  end if;

  return NEW;
end;
$$;

-- Trigger itself is unchanged (same function name, same before-update
-- attachment) — recreating it here only because the function body above
-- was replaced.
drop trigger if exists trg_lock_purchase_validation on public.poultry_purchase_validations;
create trigger trg_lock_purchase_validation
  before update on public.poultry_purchase_validations
  for each row execute function public.enforce_purchase_validation_lock();

-- ============================================================================
-- Check afterwards, in the SQL Editor:
--
--   select column_name from information_schema.columns
--   where table_name = 'poultry_purchase_validations'
--   order by ordinal_position;
--   -- should now include ss_confirmed_by, ss_confirmed_at
--
--   select grantee, privilege_type from information_schema.table_privileges
--   where table_name = 'poultry_purchase_validations';
--
-- Then, simulating each role in turn (see Migration 003's note on
-- simulating a signed-in session from the SQL Editor):
--
--   begin;
--   -- as purchasing: confirm + add-on together
--   select set_config('request.jwt.claims', json_build_object('sub', id)::text, true)
--   from public.profiles where role = 'purchasing' limit 1;
--   insert into poultry_purchase_validations (calc_date, delivery_dates,
--     validated_lines, order_ids, validated_by, addon_birds, addon_set_by)
--   values ('2026-09-14', '["2026-09-17","2026-09-18"]', '[]', '[]',
--     (select id from profiles where role = 'purchasing' limit 1), 5,
--     (select id from profiles where role = 'purchasing' limit 1));
--
--   -- as purchasing again: trying to set ss_confirmed_by should fail
--   update poultry_purchase_validations set ss_confirmed_by =
--     (select id from profiles where role = 'purchasing' limit 1)
--     where calc_date = '2026-09-14';  -- should fail, wrong role
--
--   -- as sale_support: confirming should succeed
--   select set_config('request.jwt.claims', json_build_object('sub', id)::text, true)
--   from public.profiles where role = 'sale_support' limit 1;
--   update poultry_purchase_validations set ss_confirmed_by =
--     (select id from profiles where role = 'sale_support' limit 1),
--     ss_confirmed_at = now()
--     where calc_date = '2026-09-14';  -- should succeed
--
--   -- as sale_support again: confirming twice should fail
--   update poultry_purchase_validations set ss_confirmed_at = now()
--     where calc_date = '2026-09-14';  -- should fail, already confirmed
--
--   -- as purchasing: approving should fail (wrong role)
--   select set_config('request.jwt.claims', json_build_object('sub', id)::text, true)
--   from public.profiles where role = 'purchasing' limit 1;
--   update poultry_purchase_validations set approved = true
--     where calc_date = '2026-09-14';  -- should fail
--
--   -- as admin: approving should succeed now that sale support confirmed
--   select set_config('request.jwt.claims', json_build_object('sub', id)::text, true)
--   from public.profiles where role = 'admin' limit 1;
--   update poultry_purchase_validations set approved = true, approved_by =
--     (select id from profiles where role = 'admin' limit 1), approved_at = now()
--     where calc_date = '2026-09-14';  -- should succeed
--   rollback;
-- ============================================================================
