-- ============================================================================
-- Migration 010 - the CRM and PACE stop overlapping
-- ============================================================================
-- Written 6 Sep 2026. Clement: *"id like only the sales to have access to the
-- CRM and the Sales support team only has access to the PACE Program."*
--
-- WHAT WAS ALREADY RIGHT
-- The order tables, the customer directory and the client list were already
-- separated. A sale support account reads nothing from `clients`; a sales rep
-- reads nothing from `sale_orders`, `sale_order_lines` or `pace_customers`.
-- The app also routes by role - sale support never sees a client list, a sales
-- rep never sees an order book - but that is only the screen. What follows is
-- the database, which is what actually decides.
--
-- WHAT WAS NOT
-- Two PACE tables carried a policy written before PACE existed as its own
-- system, back when everyone was expected to read a shared catalogue:
--
--   order_products      - the 518-product catalogue
--   cut_yield_reference - how much of each cut comes off a bird
--
-- Both named 'sales' and 'director' among the roles allowed to read them. So a
-- sales rep, signed in to the CRM, could query PACE's catalogue and yield
-- table from the browser console. Not customer data - but cut yields describe
-- how the margin is built, and neither table is theirs.
--
-- This is the same class of mistake as the anon grants found on 4 Sep: a
-- permission that was reasonable when it was written and stopped being
-- reasonable when the system around it changed. It does not announce itself,
-- because nothing breaks.
--
-- The CRM has its own separate `products` table for quotations. It does not
-- read order_products, so nothing on the sales side loses anything here.
--
-- Run order: after 009. Safe to re-run. Staging first, then production.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. The product catalogue belongs to PACE
-- ----------------------------------------------------------------------------
-- Both names are dropped first: the old one because it is being replaced, the
-- new one so this file can be run twice without erroring.
drop policy if exists "order_products: all roles read" on public.order_products;
drop policy if exists "order_products: pace roles read" on public.order_products;

create policy "order_products: pace roles read"
  on public.order_products for select
  using (public.current_role() = any (array[
    'admin', 'sale_support', 'purchasing', 'production'
  ]));

comment on table public.order_products is
  'PACE order catalogue, per channel. Readable by the middle office and '
  'purchasing only - the CRM has its own `products` table for quotations, and '
  'a sales rep has no reason to read this one.';


-- ----------------------------------------------------------------------------
-- 2. So does the yield reference
-- ----------------------------------------------------------------------------
-- Production reads it because it is their own data. Purchasing reads it
-- because the whole point of the poultry calculator is to turn ordered cuts
-- into a number of birds to buy.
drop policy if exists "cut_yield_reference: all roles read" on public.cut_yield_reference;
drop policy if exists "cut_yield_reference: pace roles read" on public.cut_yield_reference;

create policy "cut_yield_reference: pace roles read"
  on public.cut_yield_reference for select
  using (public.current_role() = any (array[
    'admin', 'sale_support', 'purchasing', 'production'
  ]));

comment on table public.cut_yield_reference is
  'How much of each cut comes off a bird. Middle office, purchasing and '
  'production only - it describes how the margin is built.';


-- ============================================================================
-- 3. Then check the whole picture
-- ============================================================================
-- This lists every table in the database with the roles its policies actually
-- name. Read it as the answer to "who can reach what", not as decoration -
-- there are tables on production this file has never seen, and if any of them
-- says OPEN TO EVERYONE, or names a role that should not be there, that is the
-- next thing to fix.
--
-- What to expect:
--   * every row should say "protected" in the second column
--   * CRM tables (clients, products, quotations, quotation_lines, activity_log)
--     should name only admin, sales and director
--   * PACE tables (sale_orders, sale_order_lines, order_products,
--     pace_customers, cut_yield_reference) should name only admin,
--     sale_support, purchasing and production
--   * profiles is shared on purpose - both sides need to show a colleague's
--     name - and each side only sees its own people
select c.relname                        as table_name,
       case when c.relrowsecurity then 'protected'
            else 'OPEN TO EVERYONE' end as row_security,
       coalesce((
         select string_agg(distinct m[1], ', ' order by m[1])
         from pg_policy p,
              lateral regexp_matches(
                coalesce(pg_get_expr(p.polqual, p.polrelid), '') || ' ' ||
                coalesce(pg_get_expr(p.polwithcheck, p.polrelid), ''),
                '''(admin|sales|director|sale_support|purchasing|production)''', 'g') as m
         where p.polrelid = c.oid
       ), '(no policy - unreachable except by admin keys)') as roles_that_can_reach_it
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind = 'r'
order by c.relrowsecurity, c.relname;

-- ============================================================================
-- Send me the table this returns. It is the first full picture of who can
-- reach what, and six of the tables on production have never been visible from
-- my side.
-- ============================================================================
