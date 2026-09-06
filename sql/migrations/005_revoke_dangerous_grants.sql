-- ============================================================================
-- Migration 005 — remove TRUNCATE and anon access (SECURITY)
-- ============================================================================
-- Written 6 Sep 2026, immediately after checking the grants applied by 004 and
-- finding something worse than the problem 004 fixed.
--
-- WHAT WAS FOUND
-- The grant listing showed `anon` holding DELETE, INSERT, REFERENCES, SELECT,
-- TRIGGER, TRUNCATE and UPDATE on every PACE table — far more than 004
-- granted (004 gave nothing to anon). Those came from Supabase's project-level
-- default privileges, which grant ALL on new public tables to postgres, anon,
-- authenticated and service_role.
--
-- WHY IT MATTERS
-- `anon` is the role the publishable key uses. That key is deliberately public
-- — it sits in web/config.js and in the public GitHub repo — and that is safe
-- *because Row Level Security protects the data*. But RLS governs SELECT,
-- INSERT, UPDATE and DELETE only. **TRUNCATE is not subject to RLS.** A role
-- holding TRUNCATE can empty a table regardless of every policy on it.
--
-- Verified against a local replica with the grants set exactly as production
-- reported them: as `anon`, SELECT correctly returned 0 rows and DELETE
-- correctly affected 0 rows — and TRUNCATE then emptied both sale_orders and
-- the 518-row order_products catalogue. So the exposure was destruction of
-- data, not disclosure of it.
--
-- The same reasoning applies to `authenticated`: any signed-in account could
-- truncate these tables from the browser console, whatever its role.
--
-- WHAT THIS DOES
--   * anon           — loses every table privilege. The app never queries as
--                      anon; before sign-in it only talks to Supabase Auth.
--   * authenticated  — keeps SELECT/INSERT/UPDATE/DELETE, which RLS governs,
--                      and loses TRUNCATE, TRIGGER and REFERENCES, which it
--                      does not.
--   * service_role   — left alone. It is the admin key, already bypasses RLS
--                      by design, and is what the import/backup scripts use.
--                      It must never be exposed to a browser.
--
-- Applied to EVERY table in public, not just the PACE ones, because the same
-- default privileges applied when the CRM tables were created.
--
-- Run order: after 004. Safe to re-run. Run on staging first, then production.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. anon gets nothing
-- ----------------------------------------------------------------------------
revoke all on all tables in schema public from anon;
revoke all on all sequences in schema public from anon;
revoke all on all functions in schema public from anon;

-- and nothing on tables added later
alter default privileges in schema public revoke all on tables    from anon;
alter default privileges in schema public revoke all on sequences from anon;
alter default privileges in schema public revoke all on functions from anon;

-- ----------------------------------------------------------------------------
-- 2. authenticated keeps only what RLS can police
-- ----------------------------------------------------------------------------
revoke truncate, trigger, references on all tables in schema public from authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;

alter default privileges in schema public
  revoke truncate, trigger, references on tables from authenticated;
alter default privileges in schema public
  grant select, insert, update, delete on tables to authenticated;

-- ----------------------------------------------------------------------------
-- 3. The login screen still needs Auth, which is untouched
-- ----------------------------------------------------------------------------
-- Signing in goes through Supabase Auth (the auth schema and GoTrue), not
-- through any table in public, so removing anon's table privileges does not
-- affect it. Everything after sign-in runs as `authenticated`.
--
-- One function is deliberately left reachable by signed-in users:
grant execute on function public.admin_last_logins() to authenticated;
grant execute on function public.current_role()      to authenticated;

-- ============================================================================
-- Check afterwards, in the SQL Editor:
--
--   select grantee, privilege_type, count(*) as tables
--   from information_schema.role_table_grants
--   where table_schema = 'public' and grantee in ('anon','authenticated')
--   group by grantee, privilege_type order by grantee, privilege_type;
--
-- Expect NO rows for anon at all, and authenticated holding only DELETE,
-- INSERT, SELECT and UPDATE — no TRUNCATE, TRIGGER or REFERENCES.
--
-- Then confirm the app still works: sign in as Jane, open the order screen,
-- and check the product list loads and an order saves.
-- ============================================================================
