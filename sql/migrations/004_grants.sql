-- ============================================================================
-- Migration 004 — table privileges for the PACE tables
-- ============================================================================
-- Written 6 Sep 2026, after Jane hit "permission denied for table
-- order_products" the first time she opened the order screen in production.
--
-- Cause: migrations 001 and 002 created cut_yield_reference, order_products,
-- sale_orders and sale_order_lines with full RLS policies but no GRANTs. Row
-- Level Security decides WHICH ROWS a person may see; Postgres still requires
-- a baseline table privilege before it will run the query at all. Tables made
-- through the dashboard get that automatically — tables created from raw SQL,
-- as all of ours are, do not.
--
-- This is the third time the project has hit it (see "Bugs hit and fixed"
-- #1 and #8 in github-crm-feasibility.md: once for `authenticated` on the
-- original tables, once for `service_role` during the Odoo import). The
-- default privileges at the end are there so it is the last time.
--
-- Run order: after 003. Safe to re-run.
-- ============================================================================

-- The four tables added by 001/002. RLS still governs which rows each role
-- actually sees or changes — these grants only get the query past the door.
grant select, insert, update, delete on public.cut_yield_reference to authenticated;
grant select, insert, update, delete on public.order_products      to authenticated;
grant select, insert, update, delete on public.sale_orders         to authenticated;
grant select, insert, update, delete on public.sale_order_lines    to authenticated;

-- service_role bypasses RLS and is what the import/backup scripts use. Granted
-- explicitly for the same reason as above — this was Bug #8 during the Odoo
-- customer import, and the same trap applies to any future loader script.
grant select, insert, update, delete on public.cut_yield_reference to service_role;
grant select, insert, update, delete on public.order_products      to service_role;
grant select, insert, update, delete on public.sale_orders         to service_role;
grant select, insert, update, delete on public.sale_order_lines    to service_role;

-- anon is deliberately given nothing: these tables hold customer orders and
-- must never be readable without signing in.

-- Sequences: none of these tables use one (all keys are uuid defaults), so
-- there is nothing further to grant.

-- ----------------------------------------------------------------------------
-- Stop this recurring
-- ----------------------------------------------------------------------------
-- Applies to tables created in this schema FROM NOW ON by the role running
-- this statement — so the next migration that adds a table does not have to
-- remember, and nobody discovers it from a permission error in production.
alter default privileges in schema public
  grant select, insert, update, delete on tables to authenticated;
alter default privileges in schema public
  grant select, insert, update, delete on tables to service_role;

-- ============================================================================
-- Check afterwards, from the SQL Editor (this one needs no login, unlike the
-- role-gated views — it reads the catalogue, not the data):
--
--   select table_name, grantee, string_agg(privilege_type, ', ' order by privilege_type)
--   from information_schema.role_table_grants
--   where table_schema = 'public'
--     and table_name in ('cut_yield_reference','order_products','sale_orders','sale_order_lines')
--     and grantee in ('authenticated','service_role','anon')
--   group by table_name, grantee
--   order by table_name, grantee;
--
-- Expect four tables x two roles, each with DELETE, INSERT, SELECT, UPDATE,
-- and no rows at all for anon.
-- ============================================================================
