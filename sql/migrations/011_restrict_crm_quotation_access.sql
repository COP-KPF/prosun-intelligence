-- ============================================================================
-- Migration 011 - close the CRM side of the same gap Migration 010 closed
-- ============================================================================
-- Written 6 Sep 2026, found while verifying 010's who-can-reach-what table on
-- production. Three tables I had never seen before this - `products`,
-- `quotations`, `quotation_lines` - turned up policies that check row
-- ownership or an `active` flag, but never the signed-in user's app role.
--
--   products: everyone reads active, admin reads all
--     using ( (active = true) OR (current_role() = 'admin') )
--
--   quotations: owner creates own          with check (created_by = auth.uid())
--   quotations: owner reads own            using       (created_by = auth.uid())
--
--   quotation_lines: owner inserts via parent quotation
--   quotation_lines: owner via parent quotation
--     both just check that the parent quotation belongs to auth.uid(), with no
--     role check at all.
--
-- None of these ask "is this account sales, or director, or admin". They ask
-- "is this row active" or "does this row belong to me" - which is true for
-- ANY signed-in account, including sale_support, purchasing or a production
-- account once one exists. The screen never shows Jane a quote button, but
-- the screen is not what decides; a direct request to the same endpoint the
-- app itself uses would succeed today. This is the same shape of gap Migration
-- 010 closed on the PACE side, just facing the other way.
--
-- The `active = true` structure on products and the ownership structure on
-- quotations/quotation_lines are both kept exactly as they are - a sales rep
-- should still only see active products and only their own quotations, a
-- director the same. What changes is which roles reach that logic at all.
--
-- WHO STAYS IN, AND WHY
-- The "generate quote" button is not gated by role in the app - it appears
-- for any open, non-archived client record (see openEditModal in app.js).
-- Since a director can open a lead-stage client, the quote flow is reachable
-- from their screen too, not just a sales rep's. So this keeps the same three
-- roles that already share `clients`: admin, sales, director.
--
-- `quote_counters` carries no policies at all, on purpose - the app never
-- queries it directly (see `next_quote_number` in app.js, called as an RPC).
-- Left untouched here; worth confirming separately that the underlying
-- function is SECURITY DEFINER, since if it were not, quote numbering would
-- already be broken for everyone rather than working today.
--
-- Run order: after 010. Safe to re-run. Staging first, then production - and
-- staging does not currently have these four tables at all, so this migration
-- cannot be tested there until staging is brought in line with production.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. products - active rows readable by admin, sales, director only
-- ----------------------------------------------------------------------------
drop policy if exists "products: everyone reads active, admin reads all" on public.products;
drop policy if exists "products: crm roles read" on public.products;

create policy "products: crm roles read"
  on public.products for select
  using (
    public.current_role() = 'admin'
    or (public.current_role() in ('sales', 'director') and active = true)
  );

comment on table public.products is
  'CRM price list for quotations. Readable by admin (all rows) and sales / '
  'director (active rows only) - not by sale_support, purchasing or '
  'production, who have no reason to see CRM pricing.';


-- ----------------------------------------------------------------------------
-- 2. quotations - ownership still required, and now the role too
-- ----------------------------------------------------------------------------
drop policy if exists "quotations: owner creates own" on public.quotations;
drop policy if exists "quotations: sales/director create own" on public.quotations;

create policy "quotations: sales/director create own"
  on public.quotations for insert
  with check (
    created_by = auth.uid()
    and public.current_role() in ('sales', 'director')
  );

drop policy if exists "quotations: owner reads own" on public.quotations;
drop policy if exists "quotations: sales/director read own" on public.quotations;

create policy "quotations: sales/director read own"
  on public.quotations for select
  using (
    created_by = auth.uid()
    and public.current_role() in ('sales', 'director')
  );

comment on table public.quotations is
  'One row per quotation sent to a client. A sales rep or director reads and '
  'creates only their own; admin reads everything (see "quotations: admin '
  'full access"). Ownership alone was not enough - a sale_support or '
  'purchasing account has no legitimate quotation of its own, but ownership '
  'checks do not know that on their own.';


-- ----------------------------------------------------------------------------
-- 3. quotation_lines - same fix, one level down
-- ----------------------------------------------------------------------------
drop policy if exists "quotation_lines: owner inserts via parent quotation" on public.quotation_lines;
drop policy if exists "quotation_lines: sales/director insert via parent quotation" on public.quotation_lines;

create policy "quotation_lines: sales/director insert via parent quotation"
  on public.quotation_lines for insert
  with check (
    public.current_role() in ('sales', 'director')
    and exists (
      select 1 from public.quotations q
      where q.id = quotation_lines.quotation_id
        and q.created_by = auth.uid()
    )
  );

drop policy if exists "quotation_lines: owner via parent quotation" on public.quotation_lines;
drop policy if exists "quotation_lines: sales/director via parent quotation" on public.quotation_lines;

create policy "quotation_lines: sales/director via parent quotation"
  on public.quotation_lines for select
  using (
    public.current_role() in ('sales', 'director')
    and exists (
      select 1 from public.quotations q
      where q.id = quotation_lines.quotation_id
        and q.created_by = auth.uid()
    )
  );

comment on table public.quotation_lines is
  'Line items on a quotation. Reachable only through a parent quotation owned '
  'by the same sales/director account - matches the fix on `quotations`.';


-- ============================================================================
-- 4. Check afterwards
-- ============================================================================
-- Every policy touched here should now name a role explicitly. This lists all
-- policies on the four tables involved so the change can be read directly
-- rather than taken on trust.
select tablename, policyname, cmd, qual, with_check
from pg_policies
where schemaname = 'public'
  and tablename in ('products', 'quotations', 'quotation_lines', 'quote_counters')
order by tablename, policyname;

-- ============================================================================
-- Then the real test, signed in as each role:
--   * sales / director - product picker still loads, own quotations still
--     open, creating a new one still works
--   * sale_support / purchasing - neither ever sees this screen, so nothing
--     to check there by hand; the point of this migration is that even a
--     direct request from one of those accounts would now be refused
--   * admin - the products admin page still lists every product, active or not
-- ============================================================================
