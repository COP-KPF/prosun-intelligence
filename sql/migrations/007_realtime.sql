-- ============================================================================
-- Migration 007 — live updates for the order book
-- ============================================================================
-- Written 6 Sep 2026.
--
-- Jane, Tod and Nam work the same order book. In Excel that means one person
-- has the file open and the others wait, or they each keep a copy and someone
-- reconciles later. The point of a shared database is that it need not work
-- that way — but the browser only knows what it fetched when the page loaded,
-- so without this a colleague's order stays invisible until someone reloads.
--
-- Supabase Realtime broadcasts row changes to subscribed clients over a
-- websocket. Tables have to be added to the publication explicitly; being in
-- `public` is not enough.
--
-- Row Level Security still applies: the websocket is authenticated with the
-- signed-in user's token, so a client is only sent changes to rows it would be
-- allowed to read anyway. A CRM sales rep subscribing to sale_orders receives
-- nothing, exactly as a query would return nothing.
--
-- Only the two order tables are published. The catalogue and customer list
-- change rarely and are read when a form opens, so streaming them would be
-- traffic for no benefit.
--
-- Run order: after 006. Safe to re-run.
-- ============================================================================

do $$
begin
  -- Supabase creates this publication as part of the project. Guarded so the
  -- migration is still safe to run against a database where it is absent.
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    raise notice 'supabase_realtime publication not found — skipping (is this a real Supabase project?)';
    return;
  end if;

  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'sale_orders'
  ) then
    alter publication supabase_realtime add table public.sale_orders;
    raise notice 'sale_orders added to realtime';
  else
    raise notice 'sale_orders already published';
  end if;

  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'sale_order_lines'
  ) then
    alter publication supabase_realtime add table public.sale_order_lines;
    raise notice 'sale_order_lines added to realtime';
  else
    raise notice 'sale_order_lines already published';
  end if;
end $$;

-- An UPDATE or DELETE only broadcasts the changed columns unless the table is
-- told to send the whole row. The order book needs the full row to know which
-- week and channel a change belongs to, so it can ignore changes the person is
-- not currently looking at.
alter table public.sale_orders      replica identity full;
alter table public.sale_order_lines replica identity full;

-- ============================================================================
-- Check afterwards, in the SQL Editor:
--
--   select tablename from pg_publication_tables
--   where pubname = 'supabase_realtime' and schemaname = 'public'
--   order by tablename;
--
-- Expect sale_orders and sale_order_lines in the list.
--
-- Then the real test: open the order book in two browser windows signed in as
-- two different people, save an order in one, and watch it appear in the other
-- without a reload.
-- ============================================================================
