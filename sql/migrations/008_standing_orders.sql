-- ============================================================================
-- Migration 008 — standing orders and unconfirmed quantities
-- ============================================================================
-- Written 6 Sep 2026, from two things found while parsing September's real
-- sheets ahead of the import.
--
-- 1. **71 restaurant lines carry a quantity of `x`** rather than a number —
--    27% of that channel's lines. Clément: *"it means that, we know the client
--    has a standing order, but we don't know the quantity of this week yet."*
--
-- 2. **84 lines carry an order date months before September** — back to
--    Oct 2025 — usually alongside `PO = Standing order`. Clément: *"its the
--    beggining of the standing order date."*
--
-- Both describe the same thing: a standing arrangement, not bad data. The
-- sheets have no way to say so, which is why it looks like an anomaly.
--
-- WHY THIS MATTERS BEYOND TIDINESS
-- The poultry calculator totals ordered quantities to decide how many birds to
-- slaughter. A line reading `x` has no number — but the customer *will* take
-- product. Treated as zero it silently under-counts, and the shortage only
-- appears on delivery day. So an unknown quantity has to be distinguishable
-- from both zero and from a blank someone forgot to fill in, and the
-- calculator must be able to report "N lines still unconfirmed" alongside its
-- figure rather than quietly presenting a number that is too low.
--
-- Run order: after 007. Safe to re-run.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Standing orders
-- ----------------------------------------------------------------------------
-- The date the arrangement began, which the team already tracks in the Date
-- column of the sheets. Its presence is what marks an order as standing — no
-- separate boolean to fall out of step with it.
alter table public.sale_orders add column if not exists standing_since date;

comment on column public.sale_orders.standing_since is
  'For a standing arrangement: the date it began, as recorded in the Date '
  'column of the source sheets. Null for a normal one-off order. The order''s '
  'own order_date remains the date this particular delivery was placed for.';


-- ----------------------------------------------------------------------------
-- 2. Quantities that are not yet known
-- ----------------------------------------------------------------------------
-- `quantity` stays null for these. The flag is what separates "the customer is
-- taking product, the amount is not settled" from "nobody filled this in" —
-- a distinction the calculator depends on and Jane needs for her follow-up.
alter table public.sale_order_lines
  add column if not exists quantity_tbc boolean not null default false;

comment on column public.sale_order_lines.quantity_tbc is
  'True when the line is a standing order whose quantity for this delivery is '
  'not yet confirmed — written as "x" in the source sheets. quantity is null '
  'in that case. The poultry calculator must count these as unknown, never as '
  'zero, and report them separately from its total.';

-- A line cannot both carry a quantity and claim it is unknown.
alter table public.sale_order_lines drop constraint if exists sale_order_lines_qty_tbc_check;
alter table public.sale_order_lines add constraint sale_order_lines_qty_tbc_check
  check (not (quantity_tbc and quantity is not null));

-- Finding these quickly is the point: "what still needs a number before
-- Tuesday's slaughter calculation" is a question asked several times a week.
create index if not exists sale_order_lines_tbc_idx
  on public.sale_order_lines (quantity_tbc) where quantity_tbc;


-- ----------------------------------------------------------------------------
-- 3. Products that are not on the list
-- ----------------------------------------------------------------------------
-- `product_id` alone assumes every product ordered is in the catalogue. Parsing
-- September showed 49 of 1,236 lines (4%) where it is not: 43 are shorthand the
-- team types instead of the dropdown text — "Chicken Breast อกไก่" where the
-- list offers "Chicken Breast อกไก่ติดหนัง" — and 6 are genuinely absent
-- (chicken skin, breakfast sausage, smoked chicken filet, a "Western Option").
--
-- Without somewhere to put the text, importing those lines would silently lose
-- what was ordered. Customers already have exactly this fallback
-- (pace_customer_id plus customer_name); products get the same, so a line can
-- always say what it was for even when it points at nothing.
alter table public.sale_order_lines add column if not exists product_name text;

comment on column public.sale_order_lines.product_name is
  'What was written for the product, kept whether or not product_id resolved. '
  'Mirrors customer_name alongside pace_customer_id: the record stays truthful '
  'when the catalogue has no match, and the unmatched ones can be found and '
  'either corrected or added to the catalogue later.';

-- A line has to identify its product one way or the other.
alter table public.sale_order_lines drop constraint if exists sale_order_lines_product_present;
alter table public.sale_order_lines add constraint sale_order_lines_product_present
  check (product_id is not null or product_name is not null or type is not null);


-- ----------------------------------------------------------------------------
-- 4. Which company invoices is not PACE's to decide
-- ----------------------------------------------------------------------------
-- sale_orders.entity was carried over from the CRM's quotation flow, where the
-- rep genuinely does choose the issuing company. Order capture is different.
-- Clément, 6 Sep 2026: *"the invoice is generated by the odoo system."*
--
-- None of the four order sheets records an entity, because sale support never
-- decides it — Odoo does, downstream. Requiring it here would make them guess
-- at something another system owns, and a guess that disagrees with Odoo is
-- worse than no answer at all. This is the two-sources-of-truth risk already
-- flagged on 4 Sep, appearing in a small concrete form.
--
-- So entity becomes optional: recorded when it is genuinely known, left empty
-- when it is Odoo's to determine. The check constraint still applies to any
-- value that IS set, so nothing invalid gets through.
alter table public.sale_orders alter column entity drop not null;

comment on column public.sale_orders.entity is
  'Issuing company, when known. Optional by design: invoices are generated in '
  'Odoo, which is where the Farm/Food decision actually lives. PACE captures '
  'the order; it does not assert who bills for it.';


-- ----------------------------------------------------------------------------
-- 5. A view for the question the team actually asks
-- ----------------------------------------------------------------------------
-- Ordinary view over tables the caller already has RLS on — security_invoker
-- is true, so it inherits those policies rather than bypassing them. A CRM
-- sales rep querying it gets nothing, exactly as they would from the tables.
create or replace view public.pending_quantities
with (security_invoker = true) as
  select o.id            as order_id,
         o.channel,
         o.customer_name,
         o.customer_code,
         o.delivery_date,
         o.standing_since,
         l.id            as line_id,
         l.type,
         p.name          as product,
         l.unit,
         l.description
  from public.sale_order_lines l
  join public.sale_orders o on o.id = l.order_id
  left join public.order_products p on p.id = l.product_id
  where l.quantity_tbc;

comment on view public.pending_quantities is
  'Standing-order lines whose quantity for this delivery is still unknown. '
  'These must be settled before a slaughter calculation can be trusted.';

grant select on public.pending_quantities to authenticated;


-- ----------------------------------------------------------------------------
-- 6. Lines whose product is not on the list
-- ----------------------------------------------------------------------------
-- Either the name needs correcting to match the catalogue, or the product
-- genuinely belongs on it. Both are sale support's to resolve, and neither is
-- visible unless something surfaces them.
create or replace view public.unmatched_products
with (security_invoker = true) as
  select o.channel,
         l.product_name,
         l.type,
         count(*)                      as line_count,
         min(o.delivery_date)          as first_seen,
         max(o.delivery_date)          as last_seen
  from public.sale_order_lines l
  join public.sale_orders o on o.id = l.order_id
  where l.product_id is null and l.product_name is not null
  group by o.channel, l.product_name, l.type;

comment on view public.unmatched_products is
  'Products written on an order that do not match the channel catalogue — '
  'usually shorthand for an existing item, occasionally a product that should '
  'be added. Grouped so the common ones stand out.';

grant select on public.unmatched_products to authenticated;

-- ============================================================================
-- Check afterwards, in the SQL Editor:
--
--   select column_name from information_schema.columns
--   where table_name = 'sale_orders' and column_name = 'standing_since';
--
--   select column_name from information_schema.columns
--   where table_name = 'sale_order_lines' and column_name = 'quantity_tbc';
--
-- Both should return one row. The view returns nothing until orders exist.
-- ============================================================================
