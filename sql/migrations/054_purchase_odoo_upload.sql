-- ============================================================================
-- Migration 054 — Purchases: the cost side of the ratio comes from Odoo
-- ============================================================================
-- Written 27 Nov 2026. Clément: the purchasing team exports the purchase table
-- from Odoo (Purchase Analysis, pivot by product category and PO, month to
-- date, one file per company) and uploads it daily into PACE, so the
-- revenue / cost ratio follows Odoo. "Let's proceed step by step: the most
-- important is to see the ratio revenue/cost, and keep the ratio at 50 %."
--
-- What the file holds (Pivot_Purchase_Analysis_Prosun_Farm / _Prosum_Food):
--   group rows   "All"             → everything that is not saleable
--                "All / Saleable"  → the goods bought to sell (birds …)
--   PO rows      "PO26110038 (Chicken on 18/11/26)": count, untaxed, total
--   (product rows when a PO is expanded: not used)
-- There is no date column: the date is read from the PO description, the
-- last d/m/yy in it ("on 23/11/26", "On 9/11/26", "on19/11/26", "11/06/26").
-- Clément: it is the ORDER date. Arrival = order date + 2 days (Mon → Wed,
-- Wed → Fri, Sat → Mon) unless the purchasing team sets it in PACE.
--
-- What counts in the ratio (step 1, Clément 27 Nov 2026):
--   goods    the PO's "Saleable" amount, untaxed
--   freight  the same PO's non-saleable amount (the transport / delivery line
--            of a bird PO)
--   not yet  POs with only non-saleable lines (packaging, consumables,
--            maintenance, ingredients) — kept, shown, not in the ratio.
-- A PO is not counted until it has a date: none in the text, or a date more
-- than 15 days outside the month of its PO number (e.g. a seasonal order
-- placed weeks ahead) → the purchasing team sets the order / arrival date.
--
-- Uploads: a PO is matched on (company, PO number, group). The same PO in a
-- later file updates its amounts; nothing is counted twice. A PO missing from
-- a later file is not deleted — it is listed as "not in the latest file".
-- Each upload records whether the file is complete: the PO rows must add up
-- to the group totals of the pivot (the files of 27 Nov did not: in Odoo,
-- "Expand all" before downloading).
--
-- Who: purchase_access (Clément, Khun Jum, the purchasing manager). The
-- Orders & arrivals tab stays for following quantities; its prices no longer
-- feed the ratio.
--
-- Run order: after 053. Safe to re-run.
-- ============================================================================

create table if not exists public.purchase_odoo_uploads (
  id                 uuid primary key default gen_random_uuid(),
  company            text not null check (company in ('Prosun Farm', 'Prosun Food')),
  file_name          text,
  uploaded_by        uuid references public.profiles(id),
  uploaded_at        timestamptz not null default now(),
  po_rows            int not null default 0,
  saleable_file      numeric,      -- the pivot's group total
  saleable_rows      numeric,      -- the sum of its PO rows
  other_file         numeric,
  other_rows         numeric,
  complete           boolean not null default false,
  new_rows           int not null default 0,
  changed_rows       int not null default 0
);

create table if not exists public.purchase_odoo_lines (
  company      text not null check (company in ('Prosun Farm', 'Prosun Food')),
  po_number    text not null check (po_number ~ '^PO\d{6,}$'),
  grp          text not null check (grp in ('saleable', 'other')),
  description  text,
  lines_count  int,
  untaxed      numeric not null default 0,
  total        numeric,
  first_upload uuid references public.purchase_odoo_uploads(id),
  last_upload  uuid references public.purchase_odoo_uploads(id),
  updated_at   timestamptz not null default now(),
  primary key (company, po_number, grp)
);

-- Dates set by the purchasing team, kept across uploads.
create table if not exists public.purchase_odoo_po (
  id           uuid not null default gen_random_uuid() unique,   -- for activity_log
  company      text not null check (company in ('Prosun Farm', 'Prosun Food')),
  po_number    text not null,
  order_date   date,
  arrival_date date,
  note         text,
  set_by       uuid references public.profiles(id),
  set_at       timestamptz not null default now(),
  primary key (company, po_number)
);

comment on table public.purchase_odoo_lines is
  'Odoo purchase analysis, one row per company / PO / group (saleable or other), '
  'from the daily month-to-date upload. Migration 054.';

alter table public.purchase_odoo_uploads enable row level security;
alter table public.purchase_odoo_lines   enable row level security;
alter table public.purchase_odoo_po      enable row level security;
drop policy if exists "purchase_odoo_uploads: read" on public.purchase_odoo_uploads;
create policy "purchase_odoo_uploads: read" on public.purchase_odoo_uploads for select to authenticated using (public.purchase_can());
drop policy if exists "purchase_odoo_lines: read" on public.purchase_odoo_lines;
create policy "purchase_odoo_lines: read" on public.purchase_odoo_lines for select to authenticated using (public.purchase_can());
drop policy if exists "purchase_odoo_po: read" on public.purchase_odoo_po;
create policy "purchase_odoo_po: read" on public.purchase_odoo_po for select to authenticated using (public.purchase_can());
revoke all on public.purchase_odoo_uploads, public.purchase_odoo_lines, public.purchase_odoo_po from public, anon, authenticated;
grant select on public.purchase_odoo_uploads, public.purchase_odoo_lines, public.purchase_odoo_po to authenticated;
grant all on public.purchase_odoo_uploads, public.purchase_odoo_lines, public.purchase_odoo_po to service_role;

drop trigger if exists purchase_odoo_po_log_activity on public.purchase_odoo_po;
create trigger purchase_odoo_po_log_activity
  after insert or update or delete on public.purchase_odoo_po
  for each row execute function public.log_weighing_activity();


-- ----------------------------------------------------------------------------
-- Dates
-- ----------------------------------------------------------------------------
-- The last d/m/yy (or d/m/yyyy) written in a description; null if none or not a real date.
create or replace function public.purchase_odoo_text_date(p_text text)
returns date
language plpgsql
immutable
as $$
declare m text[]; v date; y int;
begin
  for m in select regexp_matches(coalesce(p_text, ''), '(\d{1,2})\s*/\s*(\d{1,2})\s*/\s*(\d{4}|\d{2})(?!\d)', 'g') loop
    y := m[3]::int; if y < 100 then y := 2000 + y; end if;
    begin
      v := make_date(y, m[2]::int, m[1]::int);
    exception when others then
      v := null;
    end;
  end loop;
  return v;
end $$;

-- First day of the month in the PO number: PO26110048 → 2026-11-01.
create or replace function public.purchase_odoo_po_month(p_po text)
returns date
language sql
immutable
as $$
  select case when p_po ~ '^PO\d{4}' and substr(p_po, 5, 2)::int between 1 and 12
              then make_date(2000 + substr(p_po, 3, 2)::int, substr(p_po, 5, 2)::int, 1) end;
$$;

-- One row per company / PO: goods, freight, dates and why it is (not) counted.
create or replace view public.purchase_odoo_costs
with (security_invoker = true) as
with po as (
  select l.company, l.po_number,
         max(l.description) filter (where l.grp = 'saleable') as d_sale,
         max(l.description) filter (where l.grp = 'other')    as d_other,
         coalesce(sum(l.untaxed) filter (where l.grp = 'saleable'), 0) as sale,
         coalesce(sum(l.untaxed) filter (where l.grp = 'other'), 0)    as other,
         bool_or(l.grp = 'saleable') as has_sale
  from public.purchase_odoo_lines l
  group by l.company, l.po_number
),
d as (
  select po.*, coalesce(po.d_sale, po.d_other) as description,
         public.purchase_odoo_text_date(coalesce(po.d_sale, po.d_other)) as text_date,
         public.purchase_odoo_po_month(po.po_number) as po_month,
         s.order_date as set_order, s.arrival_date as set_arrival, s.note
  from po
  left join public.purchase_odoo_po s on s.company = po.company and s.po_number = po.po_number
),
e as (
  select d.*,
         coalesce(d.set_order, case when d.text_date between d.po_month - 15 and (d.po_month + interval '1 month')::date + 14
                                    then d.text_date end) as order_day,
         case when d.text_date is null then 'none'
              when d.text_date between d.po_month - 15 and (d.po_month + interval '1 month')::date + 14 then 'text'
              else 'far' end as text_state
  from d
)
select e.company, e.po_number, e.description, e.text_date, e.text_state, e.po_month,
       e.set_order, e.set_arrival, e.note,
       e.order_day,
       coalesce(e.set_arrival, e.order_day + 2) as arrival_day,
       case when e.has_sale then e.sale else 0 end as goods,
       case when e.has_sale then e.other else 0 end as freight,
       case when e.has_sale then 0 else e.other end as not_counted_other,
       e.has_sale,
       (e.has_sale and coalesce(e.set_arrival, e.order_day + 2) is not null) as counted,
       (e.has_sale and coalesce(e.set_arrival, e.order_day + 2) is null) as needs_date,
       (select max(u.uploaded_at) from public.purchase_odoo_lines l2 join public.purchase_odoo_uploads u on u.id = l2.last_upload
         where l2.company = e.company and l2.po_number = e.po_number) as last_seen,
       not exists (select 1 from public.purchase_odoo_lines l3
                    where l3.company = e.company and l3.po_number = e.po_number
                      and l3.last_upload = (select u2.id from public.purchase_odoo_uploads u2 where u2.company = e.company
                                            order by u2.uploaded_at desc limit 1)) as missing_in_latest
from e;
revoke all on public.purchase_odoo_costs from public, anon, authenticated;
grant select on public.purchase_odoo_costs to authenticated;
grant all on public.purchase_odoo_costs to service_role;


-- ----------------------------------------------------------------------------
-- Upload. p = { company, file_name, dry_run,
--               rows: [{ po, grp: "saleable"|"other", description, lines, untaxed, total }],
--               file: { saleable, other } }   -- the pivot's group totals
-- dry_run = true answers what the upload would do and changes nothing.
-- ----------------------------------------------------------------------------
create or replace function public.purchase_odoo_import(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_co    text := p->>'company';
  v_dry   boolean := coalesce((p->>'dry_run')::boolean, false);
  v_id    uuid;
  r       jsonb;
  n_new   int := 0; n_chg int := 0; n_same int := 0;
  s_rows  numeric := 0; o_rows numeric := 0;
  s_file  numeric := nullif(p->'file'->>'saleable', '')::numeric;
  o_file  numeric := nullif(p->'file'->>'other', '')::numeric;
  v_cur   public.purchase_odoo_lines;
  v_pos   jsonb := '[]'::jsonb;
  v_complete boolean;
begin
  perform public.purchase_check();
  if v_co not in ('Prosun Farm', 'Prosun Food') then
    raise exception 'purchases: choose the company of this file' using errcode = '22023';
  end if;
  if jsonb_typeof(p->'rows') is distinct from 'array' or jsonb_array_length(p->'rows') = 0 then
    raise exception 'purchases: no purchase order found in this file' using errcode = '22023';
  end if;

  create temporary table if not exists pg_temp.odoo_in (po text, grp text, description text, lines int, untaxed numeric, total numeric) on commit drop;
  truncate pg_temp.odoo_in;
  for r in select * from jsonb_array_elements(p->'rows') loop
    if coalesce(r->>'po', '') !~ '^PO\d{6,}$' or coalesce(r->>'grp', '') not in ('saleable', 'other') then
      raise exception 'purchases: unreadable row: %', left(coalesce(r->>'po', '') || ' ' || coalesce(r->>'description', ''), 80) using errcode = '22023';
    end if;
    insert into pg_temp.odoo_in values (r->>'po', r->>'grp', r->>'description', nullif(r->>'lines', '')::int,
                                        coalesce(nullif(r->>'untaxed', '')::numeric, 0), nullif(r->>'total', '')::numeric);
  end loop;
  -- the same PO twice in one group (should not happen): keep the sum
  create temporary table if not exists pg_temp.odoo_rows on commit drop as select * from pg_temp.odoo_in limit 0;
  truncate pg_temp.odoo_rows;
  insert into pg_temp.odoo_rows
  select po, grp, max(description), sum(lines)::int, sum(untaxed), sum(total) from pg_temp.odoo_in group by po, grp;

  select coalesce(sum(untaxed) filter (where grp = 'saleable'), 0), coalesce(sum(untaxed) filter (where grp = 'other'), 0)
    into s_rows, o_rows from pg_temp.odoo_rows;
  v_complete := (s_file is null or abs(s_file - s_rows) < 1) and (o_file is null or abs(o_file - o_rows) < 1);

  select count(*) filter (where l.po_number is null),
         count(*) filter (where l.po_number is not null and (l.untaxed <> i.untaxed or l.description is distinct from i.description)),
         count(*) filter (where l.po_number is not null and l.untaxed = i.untaxed and l.description is not distinct from i.description)
    into n_new, n_chg, n_same
  from pg_temp.odoo_rows i
  left join public.purchase_odoo_lines l on l.company = v_co and l.po_number = i.po and l.grp = i.grp;

  -- What each PO in the file becomes (dates, counted or not).
  select coalesce(jsonb_agg(jsonb_build_object(
           'po', x.po, 'description', x.description, 'goods', x.goods, 'freight', x.freight, 'other', x.other_only,
           'text_date', x.text_date, 'order_day', x.order_day, 'arrival_day', x.arrival_day,
           'state', case when not x.has_sale then 'not_counted'
                         when x.arrival_day is null then (case when x.text_date is null then 'no_date' else 'far_date' end)
                         else 'counted' end,
           'is_new', x.is_new) order by x.po desc), '[]'::jsonb)
    into v_pos
  from (
    select i.po,
           coalesce(max(i.description) filter (where i.grp = 'saleable'), max(i.description)) as description,
           bool_or(i.grp = 'saleable') as has_sale,
           case when bool_or(i.grp = 'saleable') then coalesce(sum(i.untaxed) filter (where i.grp = 'saleable'), 0) else 0 end as goods,
           case when bool_or(i.grp = 'saleable') then coalesce(sum(i.untaxed) filter (where i.grp = 'other'), 0) else 0 end as freight,
           case when bool_or(i.grp = 'saleable') then 0 else coalesce(sum(i.untaxed), 0) end as other_only,
           public.purchase_odoo_text_date(coalesce(max(i.description) filter (where i.grp = 'saleable'), max(i.description))) as text_date,
           coalesce(max(s.order_date),
                    case when public.purchase_odoo_text_date(coalesce(max(i.description) filter (where i.grp = 'saleable'), max(i.description)))
                              between public.purchase_odoo_po_month(i.po) - 15 and (public.purchase_odoo_po_month(i.po) + interval '1 month')::date + 14
                         then public.purchase_odoo_text_date(coalesce(max(i.description) filter (where i.grp = 'saleable'), max(i.description))) end) as order_day,
           null::date as arrival_day,
           not exists (select 1 from public.purchase_odoo_lines l where l.company = v_co and l.po_number = i.po) as is_new,
           max(s.arrival_date) as set_arrival
    from pg_temp.odoo_rows i
    left join public.purchase_odoo_po s on s.company = v_co and s.po_number = i.po
    group by i.po
  ) x0
  cross join lateral (select x0.*, coalesce(x0.set_arrival, x0.order_day + 2) as arrival_day2) y
  cross join lateral (select y.po, y.description, y.has_sale, y.goods, y.freight, y.other_only, y.text_date, y.order_day,
                             y.arrival_day2 as arrival_day, y.is_new) x;

  if v_dry then
    return jsonb_build_object('dry_run', true, 'company', v_co, 'new', n_new, 'changed', n_chg, 'unchanged', n_same,
                              'complete', v_complete, 'saleable_file', s_file, 'saleable_rows', s_rows,
                              'other_file', o_file, 'other_rows', o_rows, 'pos', v_pos);
  end if;

  insert into public.purchase_odoo_uploads (company, file_name, uploaded_by, uploaded_at, po_rows, saleable_file, saleable_rows,
                                            other_file, other_rows, complete, new_rows, changed_rows)
  values (v_co, nullif(p->>'file_name', ''), auth.uid(), clock_timestamp(), (select count(*) from pg_temp.odoo_rows), s_file, s_rows,
          o_file, o_rows, v_complete, n_new, n_chg)
  returning id into v_id;

  insert into public.purchase_odoo_lines (company, po_number, grp, description, lines_count, untaxed, total, first_upload, last_upload, updated_at)
  select v_co, i.po, i.grp, i.description, i.lines, i.untaxed, i.total, v_id, v_id, now()
  from pg_temp.odoo_rows i
  on conflict (company, po_number, grp) do update
     set description = excluded.description, lines_count = excluded.lines_count, untaxed = excluded.untaxed,
         total = excluded.total, last_upload = excluded.last_upload,
         updated_at = case when purchase_odoo_lines.untaxed <> excluded.untaxed
                             or purchase_odoo_lines.description is distinct from excluded.description
                           then now() else purchase_odoo_lines.updated_at end;

  return jsonb_build_object('dry_run', false, 'upload_id', v_id, 'company', v_co, 'new', n_new, 'changed', n_chg, 'unchanged', n_same,
                            'complete', v_complete, 'saleable_file', s_file, 'saleable_rows', s_rows,
                            'other_file', o_file, 'other_rows', o_rows, 'pos', v_pos);
end $$;

-- The purchasing team sets a PO's order date and/or arrival date (null clears it).
create or replace function public.purchase_odoo_set_dates(p_company text, p_po text, p_order date, p_arrival date, p_note text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.purchase_check();
  if not exists (select 1 from public.purchase_odoo_lines where company = p_company and po_number = p_po) then
    raise exception 'purchases: % is not in the Odoo uploads of %', p_po, p_company using errcode = 'P0002';
  end if;
  if p_order is not null and p_arrival is not null and p_arrival < p_order then
    raise exception 'purchases: the arrival cannot be before the order' using errcode = '22023';
  end if;
  if p_order is null and p_arrival is null and nullif(trim(p_note), '') is null then
    delete from public.purchase_odoo_po where company = p_company and po_number = p_po;
  else
    insert into public.purchase_odoo_po (company, po_number, order_date, arrival_date, note, set_by, set_at)
    values (p_company, p_po, p_order, p_arrival, nullif(trim(p_note), ''), auth.uid(), now())
    on conflict (company, po_number) do update
      set order_date = excluded.order_date, arrival_date = excluded.arrival_date, note = excluded.note,
          set_by = excluded.set_by, set_at = excluded.set_at;
  end if;
end $$;

-- Last upload per company, and what is waiting for a date.
create or replace function public.purchase_odoo_status(p_co text default null)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'uploads', coalesce((select jsonb_agg(jsonb_build_object('company', u.company, 'at', u.uploaded_at, 'complete', u.complete,
                                                             'saleable_file', u.saleable_file, 'saleable_rows', u.saleable_rows,
                                                             'other_file', u.other_file, 'other_rows', u.other_rows))
                         from (select distinct on (company) * from public.purchase_odoo_uploads
                               where p_co is null or company = p_co order by company, uploaded_at desc) u), '[]'::jsonb),
    'waiting_count', (select count(*) from public.purchase_odoo_costs c where c.needs_date and (p_co is null or c.company = p_co)),
    'waiting_amount', (select coalesce(sum(c.goods + c.freight), 0) from public.purchase_odoo_costs c where c.needs_date and (p_co is null or c.company = p_co)));
$$;
revoke all on function public.purchase_odoo_status(text) from public, anon, authenticated;
grant execute on function public.purchase_odoo_status(text) to service_role;

-- The upload page: every PO of the period (by order or arrival day), the ones
-- waiting for a date, the last uploads.
create or replace function public.purchase_odoo_board(p_from date, p_to date, p_company text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare v_co text := nullif(nullif(p_company, ''), 'all');
begin
  perform public.purchase_check();
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 120 then
    raise exception 'purchases: choose a period of four months or less' using errcode = '22023';
  end if;
  return jsonb_build_object(
    'pos', coalesce((select jsonb_agg(jsonb_build_object(
              'company', c.company, 'po', c.po_number, 'description', c.description, 'text_date', c.text_date, 'text_state', c.text_state,
              'order_day', c.order_day, 'arrival_day', c.arrival_day, 'set_order', c.set_order, 'set_arrival', c.set_arrival, 'note', c.note,
              'goods', c.goods, 'freight', c.freight, 'other', c.not_counted_other, 'counted', c.counted, 'needs_date', c.needs_date,
              'missing_in_latest', c.missing_in_latest, 'last_seen', c.last_seen)
              order by c.needs_date desc, coalesce(c.arrival_day, c.po_month) desc, c.po_number desc)
            from public.purchase_odoo_costs c
            where (v_co is null or c.company = v_co)
              and (c.needs_date or coalesce(c.arrival_day, c.order_day, c.po_month) between p_from and p_to)), '[]'::jsonb),
    'uploads', coalesce((select jsonb_agg(x order by x->>'at' desc) from (
              select jsonb_build_object('company', u.company, 'file_name', u.file_name, 'at', u.uploaded_at,
                                        'by', (select full_name from public.profiles where id = u.uploaded_by),
                                        'po_rows', u.po_rows, 'complete', u.complete, 'new', u.new_rows, 'changed', u.changed_rows,
                                        'saleable_file', u.saleable_file, 'saleable_rows', u.saleable_rows,
                                        'other_file', u.other_file, 'other_rows', u.other_rows) as x
              from public.purchase_odoo_uploads u where v_co is null or u.company = v_co
              order by u.uploaded_at desc limit 12) z), '[]'::jsonb));
end $$;

revoke all on function public.purchase_odoo_import(jsonb) from public, anon;
revoke all on function public.purchase_odoo_set_dates(text, text, date, date, text) from public, anon;
revoke all on function public.purchase_odoo_board(date, date, text) from public, anon;
grant execute on function public.purchase_odoo_import(jsonb) to authenticated, service_role;
grant execute on function public.purchase_odoo_set_dates(text, text, date, date, text) to authenticated, service_role;
grant execute on function public.purchase_odoo_board(date, date, text) to authenticated, service_role;


-- ----------------------------------------------------------------------------
-- The ratio now takes its cost from Odoo (replaces 047's versions).
-- ----------------------------------------------------------------------------
create or replace function public.purchase_ratio_days(p_from date, p_to date, p_co text)
returns table (day date, company text, rev numeric, kg numeric, kg_priced numeric, papers bigint,
               cost numeric, freight numeric, est boolean, birds_ordered numeric, birds_received numeric,
               kg_bought numeric, no_price bigint, orders bigint)
language sql
stable
security definer
set search_path = public
as $$
  with raw as materialized (
    select p.id as paper_id, p.work_date as day, p.company,
           coalesce(nullif(trim(p.customer_name), ''), '—') as client,
           l.description, l.actual_kg, l.ordered_qty, l.ordered_unit,
           coalesce(p.po_number, '') ~* '^\s*UR' as ur
    from public.weighing_papers p
    join public.weighing_lines l on l.paper_id = p.id
    where p.status = 'confirmed'
      and p.work_date between p_from and p_to
      and (p_co is null or p.company = p_co)
  ),
  matched as materialized (
    select d.description, d.ur,
           public.price_list_match(d.description, case when d.ur then 'UR' end) as price_id
    from (select distinct description, ur from raw) d
  ),
  priced as (
    select x.*,
           case
             when x.price_unit = 'kg' then
               case when x.actual_kg > 0 then round(x.actual_kg * x.unit_price, 2) end
             when x.price_unit = 'pce' then
               case when x.pieces > 0 then round(x.pieces * x.unit_price, 2) end
           end as revenue
    from (
      select r.*, pl.unit as price_unit,
             case
               when r.ordered_unit = 'pcs' and r.ordered_qty > 0 then r.ordered_qty
               when pl.unit = 'pce' and r.actual_kg > 0 and pl.piece_kg > 0 then round(r.actual_kg / pl.piece_kg)
             end as pieces,
             case
               when pl.bulk_min is not null
                    and (case when r.ordered_unit = 'pcs' then r.ordered_qty end) >= pl.bulk_min
                 then case when z.zone = 'upcountry' then coalesce(pl.bulk_up, pl.bulk_bkk) else pl.bulk_bkk end
               else case when z.zone = 'upcountry' then coalesce(pl.price_up, pl.price_bkk) else pl.price_bkk end
             end as unit_price
      from raw r
      join matched m on m.description is not distinct from r.description and m.ur = r.ur
      left join public.price_list pl on pl.id = m.price_id
      left join public.client_price_zones z on z.client_key = lower(r.client)
    ) x
  ),
  rev as (
    select day, company,
           round(coalesce(sum(revenue), 0), 2) as rev,
           round(coalesce(sum(actual_kg), 0), 2) as kg,
           round(coalesce(sum(actual_kg) filter (where revenue is not null), 0), 2) as kg_priced,
           count(distinct paper_id) as papers
    from priced group by day, company
  ),
  -- Cost: Odoo purchase orders (Migration 054), by arrival day. Only the POs
  -- that are counted (saleable goods with a date). Birds ordered / received
  -- still come from Orders & arrivals when it is used.
  oc as (
    select c.arrival_day as day, c.company,
           round(sum(c.goods), 2) as cost, round(sum(c.freight), 2) as freight,
           bool_or(c.arrival_day > (now() at time zone 'Asia/Bangkok')::date) as est,
           count(*) as orders
    from public.purchase_odoo_costs c
    where c.counted and c.arrival_day between p_from and p_to
      and (p_co is null or c.company = p_co)
    group by c.arrival_day, c.company
  ),
  ob as (
    select coalesce(o.arrived_on, o.arrival_date) as day, o.company,
           coalesce(sum(l.ordered_qty) filter (where i.unit = 'bird'), 0) as birds_ordered,
           coalesce(sum(l.received_qty) filter (where i.unit = 'bird' and o.status = 'received'), 0) as birds_received
    from public.purchase_orders o
    join public.purchase_order_lines l on l.order_id = o.id
    join public.purchase_items i on i.id = l.item_id
    where o.status <> 'cancelled'
      and coalesce(o.arrived_on, o.arrival_date) between p_from and p_to
      and (p_co is null or o.company = p_co)
    group by 1, 2
  ),
  pur as (
    select coalesce(c.day, b.day) as day, coalesce(c.company, b.company) as company,
           coalesce(c.cost, 0) as cost, coalesce(c.freight, 0) as freight, coalesce(c.est, false) as est,
           coalesce(b.birds_ordered, 0) as birds_ordered, coalesce(b.birds_received, 0) as birds_received,
           0::numeric as kg_bought, 0::bigint as no_price, coalesce(c.orders, 0) as orders
    from oc c full join ob b on b.day = c.day and b.company = c.company
  )
  select coalesce(r.day, p.day), coalesce(r.company, p.company),
         coalesce(r.rev, 0), coalesce(r.kg, 0), coalesce(r.kg_priced, 0), coalesce(r.papers, 0),
         coalesce(p.cost, 0), coalesce(p.freight, 0), coalesce(p.est, false),
         coalesce(p.birds_ordered, 0), coalesce(p.birds_received, 0), coalesce(p.kg_bought, 0),
         coalesce(p.no_price, 0), coalesce(p.orders, 0)
  from rev r
  full join pur p on p.day = r.day and p.company = r.company;
$$;

create or replace function public.purchase_ratio(p_from date, p_to date, p_company text default null,
                                                 p_group text default 'cycle')
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_co    text := nullif(nullif(p_company, ''), 'all');
  v_grp   text := coalesce(nullif(p_group, ''), 'cycle');
  v_start date;
  v_first date;
  v_eff   date;
  v_today date := (now() at time zone 'Asia/Bangkok')::date;
  v_cut   date;   -- first day of the arrival cycle in progress: totals stop the day before
  v_head  jsonb;
  v_out   jsonb;
begin
  perform public.purchase_check();
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'purchases: choose a start and an end date' using errcode = '22023';
  end if;
  if p_to - p_from > 400 then
    raise exception 'purchases: choose a period of about a year or less' using errcode = '22023';
  end if;
  if v_co is not null and v_co not in ('Prosun Farm', 'Prosun Food') then
    raise exception 'purchases: unknown company' using errcode = '22023';
  end if;
  if v_grp not in ('cycle', 'week', 'month') then
    raise exception 'purchases: group by cycle, week or month' using errcode = '22023';
  end if;

  select s.count_from into v_start from public.management_settings s where s.id = 1;
  -- The ratio starts when both sides are counted: the first counted working
  -- paper day (count_from) and the first Odoo purchase counted.
  -- First purchase = first arrival of a counted Odoo PO (Migration 054).
  select min(c.arrival_day) into v_first
  from public.purchase_odoo_costs c
  where c.counted and (v_co is null or c.company = v_co);
  v_eff := greatest(p_from, coalesce(v_start, p_from), coalesce(v_first, p_from));
  v_cut := v_today - (case extract(dow from v_today)::int when 0 then 2 when 2 then 1 when 4 then 1 when 6 then 1 else 0 end);

  v_head := jsonb_build_object('from', p_from, 'to', p_to, 'company', coalesce(v_co, 'all'), 'count_from', v_start,
                               'first_purchase', v_first, 'from_effective', v_eff,
                               'complete_before', v_cut,
                               'full', public.purchase_sees_revenue(),
                               'odoo', public.purchase_odoo_status(v_co));

  if public.purchase_sees_revenue() then
    select v_head || jsonb_build_object(
      'revenue', coalesce((select jsonb_agg(jsonb_build_array(d.day, d.company, d.rev, d.kg, d.kg_priced, d.papers) order by d.day, d.company)
                           from public.purchase_ratio_days(v_eff, p_to, v_co) d where d.papers > 0), '[]'::jsonb),
      'purchases', coalesce((select jsonb_agg(jsonb_build_array(d.day, d.company, d.cost, d.freight, d.est, d.birds_ordered,
                                                                d.birds_received, d.kg_bought, d.no_price, d.orders) order by d.day, d.company)
                             from public.purchase_ratio_days(v_eff, p_to, v_co) d where d.orders > 0), '[]'::jsonb),
      'invoiced', coalesce((select jsonb_agg(jsonb_build_array(a.month, a.company, a.amount, a.days_counted) order by a.month, a.company)
                            from public.sales_actuals a
                            where a.month between date_trunc('month', p_from)::date and p_to
                              and (v_co is null or a.company = v_co)), '[]'::jsonb))
      into v_out;
    return v_out;
  end if;

  -- Ratio only.
  with d as (select * from public.purchase_ratio_days(v_eff, p_to, v_co)),
  k as (
    select case v_grp
             when 'month' then date_trunc('month', d.day)::date
             when 'week'  then date_trunc('week', d.day)::date
             else d.day - (case extract(dow from d.day)::int when 0 then 2 when 2 then 1 when 4 then 1 when 6 then 1 else 0 end)
           end as key, d.*
    from d
  ),
  g as (
    select key, sum(rev) as rev, sum(cost + freight) as total, bool_or(est) as est,
           sum(birds_ordered) as bo, sum(birds_received) as br, sum(orders) as orders
    from k group by key
  ),
  t as (   -- totals: completed cycles only (the cycle in production would swing them)
    select sum(rev) as rev, sum(cost + freight) as total, bool_or(est) as est,
           sum(birds_ordered) as bo, sum(birds_received) as br, sum(orders) as orders
    from d where d.day < v_cut
  )
  select v_head || jsonb_build_object(
    'groups', coalesce((select jsonb_agg(jsonb_build_array(
                 g.key,
                 case when g.rev > 0 then round(g.total / g.rev * 100, 1) end,
                 g.est, g.bo, g.br, g.orders,
                 (case v_grp
                    when 'month' then (g.key + interval '1 month' - interval '1 day')::date
                    when 'week'  then g.key + 6
                    else g.key + (case extract(dow from g.key)::int when 5 then 2 else 1 end)
                  end) >= v_today) order by g.key) from g), '[]'::jsonb),
    'total', (select jsonb_build_array(
                case when t.rev > 0 then round(t.total / t.rev * 100, 1) end,
                coalesce(t.est, false), coalesce(t.bo, 0), coalesce(t.br, 0), coalesce(t.orders, 0))
              from t))
  into v_out;
  return v_out;
end $$;


revoke all on function public.purchase_ratio_days(date, date, text) from public, anon, authenticated;
grant execute on function public.purchase_ratio_days(date, date, text) to service_role;
revoke all on function public.purchase_ratio(date, date, text, text) from public, anon;
grant execute on function public.purchase_ratio(date, date, text, text) to authenticated, service_role;

-- 2FA (Migration 050): the new tables get the "code required" policy too.
select public.mfa_gate_tables();
