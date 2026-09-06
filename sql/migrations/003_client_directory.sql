-- ============================================================================
-- Migration 003 — customer directory for the PACE side
-- ============================================================================
-- Written 6 Sep 2026.
--
-- Context: Clément's framing (6 Sep 2026) is that these are two separate
-- systems sharing one database — "Sales rep are in the CRM but the PACE
-- intelligence system is only for middle office and purchasing". Sale support
-- and purchasing therefore get no access to the CRM's clients table, and
-- indeed have none today: the policies on public.clients are admin-full,
-- sales-own, director-leads-only, so RLS returns zero rows for sale_support.
--
-- The problem that creates: sale_orders.client_id could never be populated by
-- the people actually entering orders, so every order would carry a free-text
-- customer name. Order data and CRM data could then never be joined ("what did
-- Tops Chidlom order this year"), and the same customer would drift across
-- several spellings. Connecting those two sides is the point of the system.
--
-- The fix: a narrow, read-only customer directory exposing ONLY the fields
-- needed to identify and deliver to a customer. No deal_value, no notes, no
-- stage, no pipeline — those stay inside the CRM.
--
-- Note this is genuinely column-restricted, unlike the director_leads view.
-- director_leads uses security_invoker = true, so it relies on the front-end
-- simply never requesting deal_value (the "known limitation" in README.md).
-- This view instead runs as its owner and selects only safe columns, so the
-- commercial fields are structurally unreachable through it — not merely
-- un-requested. Access is gated inside the view body, the same pattern as
-- public.admin_last_logins().
--
-- Run order: after 002. Safe to re-run.
-- ============================================================================

create or replace view public.client_directory
with (security_invoker = false) as
  select c.id,
         c.name,
         c.contact_name,
         c.phone,
         c.segment,
         c.delivery_area,
         c.archived
  from public.clients c
  where public.current_role() in ('admin', 'sale_support', 'purchasing')
    and not c.archived;

comment on view public.client_directory is
  'Read-only customer lookup for the PACE side (sale support, purchasing). '
  'Deliberately excludes deal_value, notes, stage and assigned_to — the '
  'commercial CRM fields. Runs as owner with the role check in the body, so '
  'the excluded columns are unreachable rather than merely un-requested.';

grant select on public.client_directory to authenticated;


-- ----------------------------------------------------------------------------
-- Sale support needs to resolve its own colleagues' names to show who entered
-- an order. profiles today is "read own row" plus "admin reads everyone", so
-- an order list would show blank authors for everyone but yourself. This adds
-- read access to the PACE roles for the two harmless columns only.
-- ----------------------------------------------------------------------------
create or replace view public.pace_users
with (security_invoker = false) as
  select p.id, p.full_name, p.role
  from public.profiles p
  where public.current_role() in ('admin', 'sale_support', 'purchasing')
    and p.role in ('admin', 'sale_support', 'purchasing', 'production');

comment on view public.pace_users is
  'Name lookup for order authorship on the PACE side. Exposes only id, '
  'full_name and role, and only for PACE-side accounts — the CRM sales team '
  'is not listed.';

grant select on public.pace_users to authenticated;



-- ----------------------------------------------------------------------------
-- Narrow cleanup permission, so a half-saved order can't strand
-- ----------------------------------------------------------------------------
-- Saving an order is two writes: the header into sale_orders, then its lines
-- into sale_order_lines. PostgREST has no cross-request transaction, so if the
-- second write fails the header is already committed — and sale_support has no
-- delete policy (deliberately, per 001), leaving an order with no lines that
-- only an admin could remove.
--
-- Rather than granting delete outright, this permits exactly the cleanup case:
-- an order the person entered themselves, that still has no lines on it. Once
-- a single line exists the order can never be deleted by sale support again,
-- so the original "no deleting orders" intent holds.

drop policy if exists "sale_orders: sale_support deletes own empty" on public.sale_orders;
create policy "sale_orders: sale_support deletes own empty"
  on public.sale_orders for delete to authenticated
  using (
    public.current_role() = 'sale_support'
    and created_by = auth.uid()
    and not exists (
      select 1 from public.sale_order_lines l where l.order_id = sale_orders.id
    )
  );


-- ============================================================================
-- Done. After running this, sale support can pick a real customer when
-- entering an order, so sale_orders.client_id links properly to the CRM
-- record while the commercial fields stay on the CRM side.
--
-- Still open: customer_code (CS015 / CM2303) is not yet reconciled against
-- the CRM clients table's Odoo reference codes, so B2C customers who exist
-- only in the Excel sheets will still be entered by name until that mapping
-- is done.
-- ============================================================================
