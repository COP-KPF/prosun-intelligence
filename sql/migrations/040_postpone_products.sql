-- ============================================================================
-- Migration 040 — Postpone one product (or part of it) from Confirmed weights
-- ============================================================================
-- Written 19 Nov 2026. Clément: in Middle office › Confirmed weights, the team
-- can postpone the whole order (028) — and now also only one product, or part
-- of its quantity.
--
-- Decisions (Clément, 19 Nov):
--   - The team chooses each time what happened to the product:
--       "later"      produced — its weights stay confirmed, only its delivery
--                    date moves;
--       "production" not produced — it goes back to production on a new day,
--                    as a postponed working paper (like 027).
--   - Whole product line, or part of its quantity (kg, pieces, packs …).
--   - Two deliveries, same PO: the rest of the order is delivered and
--     invoiced now; the moved product becomes its own working paper —
--     "part 2" (3, 4 … if moved again) — with its own delivery and invoice.
--
-- What happens
--   weighing_postpone_lines(paper, moves, mode, delivery date, production day,
--   reason, note) — middle office and admin, on a confirmed paper not yet
--   picked up by the delivery team:
--     - a new working paper "part N" (same PO, client, company, photo) holds
--       the moved products: confirmed (later) or postponed on the new
--       production day (production);
--     - the products leave the original paper (a part of a line: its ordered
--       quantity — and, when produced, its kg — are split between the two);
--     - the original paper stays confirmed; its confirmation time is renewed,
--       so accounting sees it changed (and gets the "weights changed after
--       invoice" bell if it was already invoiced) and the department checks
--       show "changed since checked";
--     - a postponement record on the new paper (reason, products moved), so
--       it is followed in Middle office › Postponed orders (035) like any
--       postponed order;
--     - admins get a bell.
--   Moving every product of the paper is refused: that is "Postpone" (028).
--
--   weighing_split_marks(papers): for Confirmed weights — which paper is a
--   part, and the parts of each order.
--
-- Also
--   - 035's list shows who moved it (middle office), the part number and the
--     products moved; the delivery board's cards show "part N" (033/034).
--   - weighing_link_postponed (027): a part sent back to production shares the
--     original's photo — linking its filled paper keeps that photo (the
--     browser deletes nothing) and the new photo keeps "part N".
--
-- Run order: after 035 (and 036–039). Safe to re-run.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Columns
-- ----------------------------------------------------------------------------
alter table public.weighing_papers
  add column if not exists split_from uuid references public.weighing_papers(id) on delete set null,
  add column if not exists split_part int;
create index if not exists weighing_papers_split_idx on public.weighing_papers (split_from) where split_from is not null;
comment on column public.weighing_papers.split_from is
  'Part of an order split in Confirmed weights: the original paper (part 1). Migration 040.';
comment on column public.weighing_papers.split_part is 'Part number (2, 3 …) of a split order. Migration 040.';

alter table public.weighing_postponements
  add column if not exists split_mode text,
  add column if not exists split_from uuid,
  add column if not exists lines_moved jsonb;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'weighing_postponements_split_mode_check') then
    alter table public.weighing_postponements add constraint weighing_postponements_split_mode_check
      check (split_mode is null or split_mode in ('later', 'production'));
  end if;
end $$;
comment on column public.weighing_postponements.split_mode is
  'Product postponed from Confirmed weights (040): later = produced, delivered later; production = back to production.';
comment on column public.weighing_postponements.lines_moved is
  'Products moved to this part (040): description, quantity, unit, whole line or part, kg moved.';


-- ----------------------------------------------------------------------------
-- 2. A confirmed paper's lines change only through the split below
-- ----------------------------------------------------------------------------
create or replace function public.weighing_lines_guard()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  st text;
begin
  select status into st from public.weighing_papers
  where id = coalesce(new.paper_id, old.paper_id);
  if st = 'confirmed' and coalesce(current_setting('prosun.splitting', true), '') <> 'on' then
    raise exception 'weighing paper % is confirmed — set it back to read before changing its lines',
      coalesce(new.paper_id, old.paper_id)
      using errcode = '42501';
  end if;
  -- a line moved to another paper: the paper it leaves is checked too
  if tg_op = 'UPDATE' and new.paper_id is distinct from old.paper_id then
    select status into st from public.weighing_papers where id = old.paper_id;
    if st = 'confirmed' and coalesce(current_setting('prosun.splitting', true), '') <> 'on' then
      raise exception 'weighing paper % is confirmed', old.paper_id using errcode = '42501';
    end if;
  end if;
  return coalesce(new, old);
end;
$$;


-- The postponement bell (027/028) stays quiet for a product move: 040 sends
-- its own, naming the products. Accounting's "weights changed after invoice"
-- bell (030) says the products were moved.
create or replace function public.weighing_postponements_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
begin
  -- 040: a product moved from Confirmed weights sends its own bell, naming the products
  if new.split_mode is not null then
    return new;
  end if;
  if new.stage = 'delivery' then
    perform public.notify_admins('delivery_postponed',
      'Delivery postponed — ' || public.weighing_paper_label(new.po_number, new.customer_name),
      'Delivery ' || coalesce(to_char(new.from_delivery_date, 'DD Mon'), to_char(new.from_work_date, 'DD Mon'))
        || ' → ' || to_char(new.to_delivery_date, 'DD Mon')
        || ' (weights already confirmed). ' || public.postponement_reason_label(new.reason) || '.'
        || coalesce(' ' || new.note, ''),
      jsonb_build_object('postponement', to_jsonb(new)),
      new.paper_id, new.from_work_date);
  else
    perform public.notify_admins('paper_postponed',
      'Production postponed — ' || public.weighing_paper_label(new.po_number, new.customer_name),
      'Production ' || to_char(new.from_work_date, 'DD Mon') || ' → ' || to_char(new.to_work_date, 'DD Mon')
        || ' · delivery ' || coalesce(to_char(new.from_delivery_date, 'DD Mon'), '—') || ' → ' || to_char(new.to_delivery_date, 'DD Mon')
        || '. ' || public.postponement_reason_label(new.reason) || '.'
        || coalesce(' ' || new.note, ''),
      jsonb_build_object('postponement', to_jsonb(new)),
      new.paper_id, new.to_work_date);
  end if;
  return new;
end;
$function$;

create or replace function public.weighing_invoice_changed_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
declare
  inv public.weighing_invoices;
  who uuid := auth.uid();
  who_name text;
begin
  if new.status <> 'confirmed' or new.confirmed_at is not distinct from old.confirmed_at then
    return new;
  end if;
  select * into inv from public.weighing_invoices where paper_id = new.id;
  if not found or inv.confirmed_at_seen is not distinct from new.confirmed_at then
    return new;
  end if;
  select full_name into who_name from public.profiles where id = who;
  insert into public.notifications (recipient, kind, title, body, details, paper_id, work_date, actor, actor_name)
  select pr.id, 'invoice_weights_changed',
         'Weights changed after invoice — ' || public.weighing_paper_label(new.po_number, new.customer_name),
         case when coalesce(current_setting('prosun.splitting', true), '') = 'on'   -- 040
              then 'The middle office moved products of this paper to a later delivery after it was marked invoiced'
                   || coalesce(' (' || inv.invoice_no || ')', '') || '. The moved products have their own paper (part 2 …). Check the invoice in Odoo.'
              else 'The factory re-confirmed this paper after it was marked invoiced'
                   || coalesce(' (' || inv.invoice_no || ')', '') || '. Check the invoice in Odoo.' end,
         jsonb_build_object('invoice_no', inv.invoice_no, 'invoiced_at', inv.invoiced_at,
                            'delivery_date', coalesce(new.delivery_date, new.work_date)),
         new.id, new.work_date, who, who_name
  from public.profiles pr
  where pr.role = 'accounting' and pr.id is distinct from who;
  return new;
end;
$function$;


-- ----------------------------------------------------------------------------
-- 3. Postpone products
-- ----------------------------------------------------------------------------
create or replace function public.weighing_qty_text(q numeric, u text)
returns text
language sql
immutable
as $$
  select trim(to_char(q, 'FM999999990.###')) || ' '
         || case u when 'kg' then 'Kg' when 'g' then 'g' when 'pcs' then 'pcs' when 'pack' then 'pack'
                   when 'jar' then 'jar' else coalesce(u, '') end;
$$;

create or replace function public.weighing_postpone_lines(
  p_paper uuid, p_moves jsonb, p_mode text, p_delivery_date date,
  p_work_date date default null, p_reason text default null, p_note text default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  p        public.weighing_papers;
  today    date := (now() at time zone 'Asia/Bangkok')::date;
  cur      date;
  v_work   date;
  v_root   uuid;
  v_part   int;
  v_child  uuid := gen_random_uuid();
  m        jsonb;
  l        public.weighing_lines;
  q        numeric;
  k        numeric;
  whole    boolean;
  n_lines  int;
  n_whole  int := 0;
  n_new    int := 0;
  seen     uuid[] := '{}';
  moved    jsonb := '[]'::jsonb;
  kg_moved numeric := 0;
  v_note   text := nullif(trim(coalesce(p_note, '')), '');
  txt      text;
begin
  if coalesce(public.current_role(), '') not in ('sale_support', 'admin') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  select * into p from public.weighing_papers where id = p_paper for update;
  if not found then
    raise exception 'paper not found' using errcode = '22023';
  end if;
  if p.status <> 'confirmed' then
    raise exception 'only a confirmed paper''s products can be postponed here (status: %)', p.status using errcode = '22023';
  end if;
  if p_mode is null or p_mode not in ('later', 'production') then
    raise exception 'choose: produced — deliver later, or not produced — back to production' using errcode = '22023';
  end if;
  if p_reason is null or p_reason not in ('production', 'raw_material', 'delivery', 'client', 'other') then
    raise exception 'choose a reason' using errcode = '22023';
  end if;
  if p_reason = 'other' and v_note is null then
    raise exception 'add a comment when the reason is Other' using errcode = '22023';
  end if;
  cur := coalesce(p.delivery_date, p.work_date);
  if p_delivery_date is null or p_delivery_date <= cur then
    raise exception 'the new delivery date must be after the current one (%)', to_char(cur, 'DD Mon') using errcode = '22023';
  end if;
  if p_delivery_date < today then
    raise exception 'choose a delivery date from today on' using errcode = '22023';
  end if;
  if p_mode = 'production' then
    v_work := coalesce(p_work_date, p_delivery_date);
    if v_work < today then
      raise exception 'choose a production day from today on' using errcode = '22023';
    end if;
    if v_work = p.work_date then
      raise exception 'choose another production day than the paper''s (%)', to_char(p.work_date, 'DD Mon') using errcode = '22023';
    end if;
    if v_work > p_delivery_date then
      raise exception 'the delivery date must be on or after the production day' using errcode = '22023';
    end if;
  else
    v_work := p.work_date;
  end if;
  if exists (select 1 from public.delivery_marks dm
             where dm.paper_id = p.id and dm.status in ('dispatch', 'out', 'problem', 'delivered')
               and (dm.delivery_date = cur or dm.status in ('dispatch', 'out', 'problem'))) then
    raise exception 'this order was already picked up by the delivery team — its products cannot be split here' using errcode = '22023';
  end if;
  if p_moves is null or jsonb_typeof(p_moves) <> 'array' or jsonb_array_length(p_moves) = 0 then
    raise exception 'choose at least one product' using errcode = '22023';
  end if;
  select count(*) into n_lines from public.weighing_lines where paper_id = p.id;

  v_root := coalesce(p.split_from, p.id);
  select coalesce(max(x.split_part), 1) + 1 into v_part
  from public.weighing_papers x where x.split_from = v_root;

  perform set_config('prosun.splitting', 'on', true);
  perform set_config('prosun.postponing', 'on', true);

  -- the new paper: part N of the same order
  insert into public.weighing_papers
    (id, work_date, photo_path, status, uploaded_by, uploaded_at, read_at, read_model,
     company, po_number, customer_name, delivery_date, note,
     confirmed_by, confirmed_at, photo_deleted_at, split_from, split_part)
  values
    (v_child, v_work, p.photo_path, case p_mode when 'later' then 'confirmed' else 'postponed' end,
     p.uploaded_by, p.uploaded_at, p.read_at, p.read_model,
     p.company, p.po_number, p.customer_name, p_delivery_date,
     'Part ' || v_part || ' of ' || coalesce('PO ' || nullif(p.po_number, ''), 'the order')
       || ' — products moved from the paper of ' || to_char(cur, 'DD Mon') || '.',
     case p_mode when 'later' then p.confirmed_by end, case p_mode when 'later' then now() end,
     p.photo_deleted_at, v_root, v_part);

  for m in select * from jsonb_array_elements(p_moves) loop
    select * into l from public.weighing_lines
    where id = nullif(m->>'line_id', '')::uuid and paper_id = p.id for update;
    if not found then
      raise exception 'product not found on this paper' using errcode = '22023';
    end if;
    if l.id = any(seen) then
      raise exception 'the same product is chosen twice' using errcode = '22023';
    end if;
    seen := seen || l.id;
    q := nullif(m->>'qty', '')::numeric;
    whole := q is null or (l.ordered_qty is not null and q >= l.ordered_qty);
    if not whole then
      if l.ordered_qty is null or l.ordered_qty <= 0 then
        raise exception '"%" has no ordered quantity: move the whole product', l.description using errcode = '22023';
      end if;
      if q <= 0 then
        raise exception 'the quantity to move must be more than 0 (%)', l.description using errcode = '22023';
      end if;
    end if;

    n_new := n_new + 1;
    if whole then
      n_whole := n_whole + 1;
      k := case when p_mode = 'later' then l.actual_kg end;
      update public.weighing_lines
         set paper_id = v_child, line_no = n_new,
             actual_kg = case when p_mode = 'later' then actual_kg end,
             weights = case when p_mode = 'later' then weights else '{}'::numeric[] end,
             handwritten_text = case when p_mode = 'later' then handwritten_text end,
             flag_reason = null
       where id = l.id;
    else
      if p_mode = 'later' then
        if l.actual_kg is null or l.actual_kg <= 0 then
          raise exception '"%" has no weight to split: move the whole product', l.description using errcode = '22023';
        end if;
        k := coalesce(nullif(m->>'actual_kg', '')::numeric, round(l.actual_kg * q / l.ordered_qty, 2));
        if k <= 0 or k >= l.actual_kg then
          raise exception 'the kg moved for "%" must be more than 0 and less than its % kg', l.description, l.actual_kg
            using errcode = '22023';
        end if;
      else
        k := null;
      end if;
      insert into public.weighing_lines
        (paper_id, line_no, description, ordered_text, ordered_qty, ordered_unit, weights, actual_kg,
         confidence, checked, edited)
      values (v_child, n_new, l.description, public.weighing_qty_text(q, l.ordered_unit), q, l.ordered_unit,
              '{}'::numeric[], k, 'high', p_mode = 'later', false);
      update public.weighing_lines
         set ordered_qty = l.ordered_qty - q,
             ordered_text = public.weighing_qty_text(l.ordered_qty - q, l.ordered_unit),
             actual_kg = case when p_mode = 'later' then l.actual_kg - k else l.actual_kg end
       where id = l.id;
    end if;

    kg_moved := kg_moved + coalesce(case l.ordered_unit when 'kg' then coalesce(q, l.ordered_qty)
                                                        when 'g' then coalesce(q, l.ordered_qty) / 1000 end, 0);
    moved := moved || jsonb_build_object(
      'description', l.description, 'whole', whole,
      'qty', case when whole then l.ordered_qty else q end, 'unit', l.ordered_unit,
      'of_qty', l.ordered_qty, 'ordered_text', l.ordered_text, 'actual_kg', k);
  end loop;

  if n_whole >= n_lines then
    raise exception 'every product would move: use “Postpone” for the whole order' using errcode = '22023';
  end if;

  -- the original stays confirmed; a new confirmation time tells accounting
  -- and the department checks that it changed
  update public.weighing_papers set confirmed_at = now() where id = p.id;

  insert into public.weighing_postponements
    (created_by, paper_id, customer_name, po_number, company, stage, from_work_date, to_work_date,
     from_delivery_date, to_delivery_date, reason, note, kg_ordered, lines,
     split_mode, split_from, lines_moved)
  values (auth.uid(), v_child, p.customer_name, p.po_number, p.company,
          case p_mode when 'later' then 'delivery' else 'production' end,
          p.work_date, v_work, cur, p_delivery_date, p_reason, v_note, kg_moved, n_new,
          p_mode, p.id, moved);

  perform set_config('prosun.postponing', '', true);
  perform set_config('prosun.splitting', '', true);

  select string_agg(e->>'description' || ' ' ||
           case when (e->>'whole')::boolean then coalesce(e->>'ordered_text', '')
                else public.weighing_qty_text((e->>'qty')::numeric, e->>'unit') || ' of ' || coalesce(e->>'ordered_text', '') end,
           ', ')
    into txt
  from jsonb_array_elements(moved) e;

  perform public.notify_admins('product_postponed',
    'Product postponed — ' || public.weighing_paper_label(p.po_number, p.customer_name),
    txt || ' → part ' || v_part || ', delivery ' || to_char(p_delivery_date, 'DD Mon')
      || case p_mode when 'later' then ' (produced, delivered later)'
                     else ' (back to production on ' || to_char(v_work, 'DD Mon') || ')' end
      || '. ' || public.postponement_reason_label(p_reason) || '.'
      || coalesce(' ' || v_note, ''),
    jsonb_build_object('original_paper', p.id, 'part', v_part, 'mode', p_mode, 'lines', moved,
                       'from_date', cur, 'to_date', p_delivery_date, 'reason', p_reason, 'note', v_note),
    v_child, v_work);

  return jsonb_build_object('paper_id', v_child, 'part', v_part, 'original_paper', p.id,
                            'mode', p_mode, 'work_date', v_work, 'delivery_date', p_delivery_date,
                            'lines', moved);
end;
$$;

comment on function public.weighing_postpone_lines(uuid, jsonb, text, date, date, text, text) is
  'Middle office: postpones one or more products (or part of a quantity) of a confirmed paper — '
  'a new paper "part N" (same PO): produced and delivered later, or back to production. Migration 040.';

revoke all on function public.weighing_postpone_lines(uuid, jsonb, text, date, date, text, text) from public, anon;
grant execute on function public.weighing_postpone_lines(uuid, jsonb, text, date, date, text, text) to authenticated, service_role;


-- ----------------------------------------------------------------------------
-- 4. Parts of an order, for Confirmed weights
-- ----------------------------------------------------------------------------
create or replace function public.weighing_split_marks(p_papers uuid[])
returns table (paper_id uuid, root uuid, part int, family jsonb)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  r   text := coalesce(public.current_role(), '');
  why boolean := r in ('admin', 'sale_support', 'company_director');
  v_scope text := public.my_company_scope();
begin
  if r not in ('admin', 'sale_support', 'factory_admin', 'production', 'accounting', 'purchasing', 'company_director') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if coalesce(array_length(p_papers, 1), 0) > 500 then
    raise exception 'too many papers at once' using errcode = '22023';
  end if;
  return query
    select p.id, coalesce(p.split_from, p.id), coalesce(p.split_part, 1),
           (select coalesce(jsonb_agg(jsonb_build_object(
                     'paper_id', c.id, 'part', c.split_part, 'status', c.status,
                     'work_date', c.work_date, 'delivery_date', c.delivery_date,
                     'mode', h.split_mode, 'lines', h.lines_moved, 'from_paper', h.split_from,
                     'reason', case when why then h.reason end, 'note', case when why then h.note end,
                     'at', h.created_at)
                   order by c.split_part), '[]'::jsonb)
              from public.weighing_papers c
              left join lateral (
                select w.* from public.weighing_postponements w
                where w.paper_id = c.id and w.split_mode is not null
                order by w.created_at limit 1) h on true
             where c.split_from = coalesce(p.split_from, p.id))
    from public.weighing_papers p
    where p.id = any(p_papers)
      and (p.split_from is not null or exists (select 1 from public.weighing_papers c where c.split_from = p.id))
      and (r not in ('accounting', 'purchasing') or p.status = 'confirmed')
      and (v_scope is null or p.company = v_scope);
end;
$$;

comment on function public.weighing_split_marks(uuid[]) is
  'Confirmed weights: for each paper of a split order, its part number and all the parts (products moved, '
  'mode, delivery date; reason for admin, middle office, company director). Migration 040.';

revoke all on function public.weighing_split_marks(uuid[]) from public, anon;
grant execute on function public.weighing_split_marks(uuid[]) to authenticated, service_role;


-- ----------------------------------------------------------------------------
-- 5. A part sent back to production shares the original's photo: linking its
--    filled paper (027) keeps that photo, and the new photo keeps "part N".
-- ----------------------------------------------------------------------------
create or replace function public.weighing_link_postponed(p_postponed uuid, p_new uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  old_p public.weighing_papers;
  new_p public.weighing_papers;
begin
  if coalesce(public.current_role(), '') not in ('factory_admin', 'production', 'admin') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if p_postponed = p_new then
    raise exception 'choose two different papers' using errcode = '22023';
  end if;
  select * into old_p from public.weighing_papers where id = p_postponed for update;
  select * into new_p from public.weighing_papers where id = p_new for update;
  if old_p.id is null or new_p.id is null then
    raise exception 'paper not found' using errcode = '22023';
  end if;
  if old_p.status <> 'postponed' then
    raise exception 'the first paper is not postponed' using errcode = '22023';
  end if;
  if new_p.status in ('confirmed', 'postponed', 'uploading', 'queued', 'reading') then
    raise exception 'the new photo must be read and not yet confirmed (status: %)', new_p.status using errcode = '22023';
  end if;

  update public.weighing_postponements set paper_id = new_p.id where paper_id = old_p.id;
  if new_p.delivery_date is null or new_p.delivery_date < old_p.delivery_date then
    update public.weighing_papers set delivery_date = old_p.delivery_date where id = new_p.id;
  end if;
  if old_p.split_from is not null then
    update public.weighing_papers set split_from = old_p.split_from, split_part = old_p.split_part
    where id = new_p.id;
  end if;

  perform set_config('prosun.linking', 'on', true);
  delete from public.weighing_papers where id = old_p.id;
  perform set_config('prosun.linking', '', true);

  -- the browser removes this photo from storage — unless another paper (the
  -- original order of a part) still shows it
  if exists (select 1 from public.weighing_papers x where x.photo_path = old_p.photo_path) then
    return null;
  end if;
  return old_p.photo_path;
end;
$$;

-- ----------------------------------------------------------------------------
-- 6. Middle office › Postponed orders (035): products moved by the middle
--    office are "middle office"; each order shows its part number and the
--    products moved. (Same functions as 035, with these additions.)
-- ----------------------------------------------------------------------------
create or replace function public.postponed_orders_rows(p_scope text, p_closed_days int)
returns table (
  key text, paper_id uuid, register_ids uuid[],
  customer_name text, po_number text, company text,
  original_date date, due_date date, work_date date,
  times int, sources text[], last_source text,
  reason text, note text, moved_by uuid, moved_at timestamptz,
  kg_ordered numeric, kg_actual numeric,
  paper_status text, reopened boolean, uploaded_at timestamptz, confirmed_at timestamptz,
  mark_status text, mark_at timestamptz, mark_note text,
  closed_at timestamptz, closed_by uuid, close_note text,
  state text, is_open boolean, late boolean, days_late int, delay_days int)
language sql
stable
security definer
set search_path = public
as $$
with cfg as (
  select (now() at time zone 'Asia/Bangkok')::date as today,
         coalesce((select s.delivery_from from public.management_settings s where s.id = 1), date '2026-11-17') as dfrom
),
reg as (
  select o.*, mp.id as match_paper
  from public.order_postponements o
  left join lateral (
    select p.id
    from public.weighing_papers p
    where o.new_date is not null
      and nullif(trim(o.po_number), '') is not null
      and lower(trim(p.po_number)) = lower(trim(o.po_number))
      and coalesce(p.delivery_date, p.work_date) between o.new_date and o.new_date + 14
      and (o.company is null or p.company is null or p.company = o.company)
    order by coalesce(p.delivery_date, p.work_date) - o.new_date, p.uploaded_at desc
    limit 1) mp on true
),
ev as (
  select coalesce('p:' || h.paper_id::text, 'h:' || h.id::text) as key, h.paper_id,
         null::uuid as register_id,
         case when h.split_mode is not null or h.stage = 'delivery' then 'middle' else 'production' end as src,   -- 040: products moved by the middle office
         h.customer_name, h.po_number, h.company,
         coalesce(h.from_delivery_date, h.from_work_date) as orig, h.to_delivery_date as dest,
         h.reason, h.note, h.created_by, h.created_at, h.kg_ordered
  from public.weighing_postponements h
  union all
  select case when r.match_paper is not null then 'p:' || r.match_paper::text else 'r:' || r.id::text end,
         r.match_paper, r.id, 'register',
         r.customer_name, r.po_number, r.company,
         r.original_date, r.new_date, r.reason, r.note, r.created_by, r.created_at, r.quantity_kg
  from reg r
),
grp as (
  select e.key,
         (array_agg(e.paper_id) filter (where e.paper_id is not null))[1]         as paper_id,
         coalesce(array_agg(e.register_id) filter (where e.register_id is not null), '{}'::uuid[]) as register_ids,
         count(*)::int                                                             as times,
         array_agg(distinct e.src)                                                 as sources,
         (array_agg(e.src order by e.created_at desc))[1]                          as last_source,
         (array_agg(e.customer_name order by e.created_at desc))[1]                as customer_name,
         (array_agg(e.po_number order by e.created_at desc))[1]                    as po_number,
         (array_agg(e.company order by e.created_at desc))[1]                      as company,
         min(e.orig)                                                               as original_date,
         (array_agg(e.dest order by e.created_at desc))[1]                         as last_dest,
         (array_agg(e.reason order by e.created_at desc))[1]                       as reason,
         (array_agg(e.note order by e.created_at desc))[1]                         as note,
         (array_agg(e.created_by order by e.created_at desc))[1]                   as moved_by,
         max(e.created_at)                                                         as moved_at,
         (array_agg(e.kg_ordered order by e.created_at desc))[1]                   as kg_hist
  from ev e
  group by e.key
),
base as (
  select g.*,
         p.id as p_id, p.status as p_status, p.work_date as p_work_date,
         p.reopened_snapshot is not null and p.status in ('read', 'failed') as p_reopened,
         p.uploaded_at as p_uploaded_at, p.confirmed_at as p_confirmed_at,
         coalesce(p.company, g.company) as co,
         coalesce(nullif(p.customer_name, ''), g.customer_name) as cust,
         coalesce(nullif(p.po_number, ''), g.po_number) as po,
         case when p.id is not null then coalesce(p.delivery_date, p.work_date) else g.last_dest end as due,
         m.eff_status, m.marked_at, m.mnote,
         c.closed_at as c_at, c.closed_by as c_by, c.note as c_note,
         (select sum(case l.ordered_unit when 'kg' then l.ordered_qty when 'g' then l.ordered_qty / 1000 end)
            from public.weighing_lines l where l.paper_id = p.id) as kg_ord,
         (select sum(l.actual_kg) from public.weighing_lines l where l.paper_id = p.id) as kg_act
  from grp g
  left join public.weighing_papers p on p.id = g.paper_id
  left join lateral (
    select case when dm.delivery_date = coalesce(p.delivery_date, p.work_date) then dm.status else 'dispatch' end as eff_status,
           dm.marked_at,
           case when dm.delivery_date = coalesce(p.delivery_date, p.work_date) then dm.note end as mnote
    from public.delivery_marks dm
    where dm.paper_id = p.id
      and (dm.delivery_date = coalesce(p.delivery_date, p.work_date) or dm.status in ('dispatch', 'out', 'problem'))
  ) m on true
  left join public.postponement_closures c
    on (p.id is not null and c.paper_id = p.id)
    or (p.id is null and g.key like 'r:%' and c.register_id = g.register_ids[1])
),
st as (
  select b.*,
         case
           when b.key like 'h:%'                     then 'deleted'
           when b.eff_status = 'delivered'           then 'delivered'
           when b.c_at is not null                   then 'closed'
           when b.p_id is null                       then case when b.last_dest is null then 'no_date' else 'no_paper' end
           when b.eff_status in ('dispatch', 'out', 'problem') then b.eff_status
           when b.p_status = 'confirmed' and b.due < (select dfrom from cfg) then 'untracked'
           when b.p_status = 'confirmed'             then 'factory'
           when b.p_status = 'postponed'             then 'waiting'
           else 'checking'
         end as state
  from base b
)
select s.key, s.p_id, s.register_ids,
       s.cust, s.po, s.co,
       s.original_date, s.due, s.p_work_date,
       s.times, s.sources, s.last_source,
       s.reason, s.note, s.moved_by, s.moved_at,
       coalesce(s.kg_ord, s.kg_hist), s.kg_act,
       s.p_status, coalesce(s.p_reopened, false), s.p_uploaded_at, s.p_confirmed_at,
       s.eff_status, s.marked_at, s.mnote,
       s.c_at, s.c_by, s.c_note,
       s.state,
       s.state not in ('delivered', 'closed', 'untracked', 'deleted') as is_open,
       s.state not in ('delivered', 'closed', 'untracked', 'deleted') and s.due is not null and s.due < cfg.today as late,
       case when s.state not in ('delivered', 'closed', 'untracked', 'deleted') and s.due < cfg.today
            then cfg.today - s.due end as days_late,
       s.due - s.original_date as delay_days
from st s, cfg
where (p_scope is null or s.co = p_scope)
  and (s.state not in ('delivered', 'closed', 'untracked', 'deleted')
       or coalesce(case when s.state = 'delivered' then (s.marked_at at time zone 'Asia/Bangkok')::date end,
                   case when s.state = 'closed' then (s.c_at at time zone 'Asia/Bangkok')::date end,
                   s.due, cfg.today) >= cfg.today - greatest(coalesce(p_closed_days, 30), 0));
$$;


create or replace function public.postponed_order_json(r record, p_reasons boolean)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  return jsonb_build_object(
    'key', r.key, 'paper_id', r.paper_id, 'register_ids', to_jsonb(r.register_ids),
    'customer_name', r.customer_name, 'po_number', r.po_number, 'company', r.company,
    'original_date', r.original_date, 'due_date', r.due_date, 'work_date', r.work_date,
    'times', r.times, 'sources', to_jsonb(r.sources), 'last_source', r.last_source,
    -- 040: a part of an order split in Confirmed weights, and the products moved
    'part', (select wp.split_part from public.weighing_papers wp where wp.id = r.paper_id),
    'split_mode', (select h.split_mode from public.weighing_postponements h
                   where h.paper_id = r.paper_id and h.split_mode is not null order by h.created_at desc limit 1),
    'lines_moved', (select h.lines_moved from public.weighing_postponements h
                    where h.paper_id = r.paper_id and h.split_mode is not null order by h.created_at desc limit 1),
    'reason', case when p_reasons then r.reason end,
    'note', case when p_reasons then r.note end,
    'moved_by', (select pr.full_name from public.profiles pr where pr.id = r.moved_by),
    'moved_at', r.moved_at,
    'kg_ordered', r.kg_ordered, 'kg_actual', r.kg_actual,
    'paper_status', r.paper_status, 'reopened', r.reopened,
    'uploaded_at', r.uploaded_at, 'confirmed_at', r.confirmed_at,
    'mark_status', r.mark_status, 'mark_at', r.mark_at,
    'mark_note', case when p_reasons then r.mark_note end,
    'closed_at', r.closed_at,
    'closed_by', (select pr.full_name from public.profiles pr where pr.id = r.closed_by),
    'close_note', case when p_reasons then r.close_note end,
    'state', r.state, 'open', r.is_open, 'late', r.late,
    'days_late', r.days_late, 'delay_days', r.delay_days);
end;
$$;


create or replace function public.postponed_order_timeline(p_paper uuid default null, p_register uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  r       text := coalesce(public.current_role(), '');
  v_scope text := public.my_company_scope();
  x       record;
  pid     uuid;
  ev      jsonb := '[]'::jsonb;
begin
  if r not in ('admin', 'sale_support', 'company_director') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if p_paper is null and p_register is null then
    raise exception 'choose an order' using errcode = '22023';
  end if;

  select * into x
  from public.postponed_orders_rows(v_scope, 36500) o
  where (p_paper is not null and o.paper_id = p_paper)
     or (p_register is not null and p_register = any(o.register_ids))
  limit 1;
  if not found then
    raise exception 'order not found' using errcode = '22023';
  end if;
  pid := x.paper_id;

  -- Moves by production and from Confirmed weights
  select ev || coalesce(jsonb_agg(jsonb_build_object(
           'at', h.created_at, 'kind', 'moved', 'stage', h.stage,
           'from_work_date', h.from_work_date, 'to_work_date', h.to_work_date,
           'from_date', coalesce(h.from_delivery_date, h.from_work_date), 'to_date', h.to_delivery_date,
           'reason', h.reason, 'note', h.note,
           'split_mode', h.split_mode, 'lines', h.lines_moved,
           'by', (select pr.full_name from public.profiles pr where pr.id = h.created_by))), '[]'::jsonb)
    into ev
  from public.weighing_postponements h
  where pid is not null and h.paper_id = pid;

  -- Middle office register
  select ev || coalesce(jsonb_agg(jsonb_build_object(
           'at', o.created_at, 'kind', 'register',
           'from_date', o.original_date, 'to_date', o.new_date,
           'reason', o.reason, 'note', o.note,
           'by', (select pr.full_name from public.profiles pr where pr.id = o.created_by))), '[]'::jsonb)
    into ev
  from public.order_postponements o
  where o.id = any(x.register_ids);

  if pid is not null then
    -- Photographed
    select ev || jsonb_build_array(jsonb_build_object(
             'at', p.uploaded_at, 'kind', 'photographed',
             'by', (select pr.full_name from public.profiles pr where pr.id = p.uploaded_by)))
      into ev
    from public.weighing_papers p where p.id = pid;

    -- Weights confirmed (each confirmation) and reopened for correction
    select ev || coalesce(jsonb_agg(c.j), '[]'::jsonb) into ev
    from (
      select distinct on (a.details->>'confirmed_at')
             jsonb_build_object('at', (a.details->>'confirmed_at')::timestamptz, 'kind', 'confirmed',
               'by', (select pr.full_name from public.profiles pr where pr.id = (a.details->>'confirmed_by')::uuid)) as j
      from public.activity_log a
      where a.table_name = 'weighing_papers' and a.record_id = pid
        and a.details->>'status' = 'confirmed' and a.details->>'confirmed_at' is not null
      order by a.details->>'confirmed_at', a.id
    ) c;
    if x.confirmed_at is not null and not exists (
         select 1 from jsonb_array_elements(ev) e
         where e->>'kind' = 'confirmed' and (e->>'at')::timestamptz = x.confirmed_at) then
      ev := ev || jsonb_build_array(jsonb_build_object('at', x.confirmed_at, 'kind', 'confirmed', 'by', null));
    end if;
    select ev || coalesce(jsonb_agg(c.j), '[]'::jsonb) into ev
    from (
      select distinct on (a.details->>'reopened_at')
             jsonb_build_object('at', (a.details->>'reopened_at')::timestamptz, 'kind', 'reopened',
               'by', (select pr.full_name from public.profiles pr where pr.id = (a.details->>'reopened_by')::uuid)) as j
      from public.activity_log a
      where a.table_name = 'weighing_papers' and a.record_id = pid
        and a.details->>'reopened_at' is not null
      order by a.details->>'reopened_at', a.id
    ) c;

    -- Delivery board steps
    select ev || coalesce(jsonb_agg(c.j), '[]'::jsonb) into ev
    from (
      select distinct on (a.details->>'status', a.details->>'marked_at')
             jsonb_build_object('at', (a.details->>'marked_at')::timestamptz, 'kind', 'mark',
               'status', a.details->>'status', 'delivery_date', a.details->>'delivery_date',
               'note', case when a.details->>'status' = 'problem' then a.details->>'note' end,
               'by', (select pr.full_name from public.profiles pr where pr.id = (a.details->>'marked_by')::uuid)) as j
      from public.activity_log a
      where a.table_name = 'delivery_marks' and a.details->>'paper_id' = pid::text and a.action <> 'DELETE'
      order by a.details->>'status', a.details->>'marked_at', a.id
    ) c;
    select ev || coalesce(jsonb_agg(jsonb_build_object('at', a.changed_at, 'kind', 'mark_cleared',
             'by', (select pr.full_name from public.profiles pr where pr.id = a.user_id))), '[]'::jsonb)
      into ev
    from public.activity_log a
    where a.table_name = 'delivery_marks' and a.details->>'paper_id' = pid::text and a.action = 'DELETE';
  end if;

  -- Closed by hand
  if x.closed_at is not null then
    ev := ev || jsonb_build_array(jsonb_build_object('at', x.closed_at, 'kind', 'closed', 'note', x.close_note,
            'by', (select pr.full_name from public.profiles pr where pr.id = x.closed_by)));
  end if;

  -- Late again: the day after the new delivery date
  if x.late then
    ev := ev || jsonb_build_array(jsonb_build_object(
            'at', ((x.due_date + 1)::timestamp at time zone 'Asia/Bangkok'), 'kind', 'late', 'due_date', x.due_date));
  end if;

  -- (same moment: the natural order of the steps)
  select coalesce(jsonb_agg(e order by (e->>'at')::timestamptz,
           case coalesce(e->>'status', e->>'kind')
             when 'photographed' then 1 when 'confirmed' then 2 when 'moved' then 3 when 'register' then 3
             when 'reopened' then 4 when 'dispatch' then 5 when 'out' then 6 when 'problem' then 7
             when 'delivered' then 8 when 'mark_cleared' then 9 when 'closed' then 10 else 11 end), '[]'::jsonb) into ev
  from jsonb_array_elements(ev) e
  where e->>'at' is not null;

  return jsonb_build_object('order', public.postponed_order_json(x, true), 'events', ev);
end;
$$;


revoke all on function public.postponed_orders_rows(text, int) from public, anon, authenticated;
revoke all on function public.postponed_order_json(record, boolean) from public, anon, authenticated;
revoke all on function public.postponed_order_timeline(uuid, uuid) from public, anon;
grant execute on function public.postponed_order_timeline(uuid, uuid) to authenticated, service_role;


-- ----------------------------------------------------------------------------
-- 7. Delivery board cards (033/034): "part N" of an order
-- ----------------------------------------------------------------------------
create or replace function public.delivery_paper_json(p public.weighing_papers)
returns jsonb
language sql
stable
security definer
set search_path = public
as $function$
  select jsonb_build_object(
    'id', p.id,
    'status', p.status,
    'company', p.company,
    'po_number', p.po_number,
    'customer_name', p.customer_name,
    'delivery_date', p.delivery_date,
    'work_date', p.work_date,
    'due_date', coalesce(p.delivery_date, p.work_date),
    'confirmed_at', p.confirmed_at,
    -- 040: part N of an order split in Confirmed weights
    'part', p.split_part,
    'split_from', p.split_from,
    -- 034: the working paper itself — its photo (opened only where the storage
    -- rules allow: confirmed papers for the delivery team) and who confirmed it.
    'photo_path', p.photo_path,
    'photo_deleted_at', p.photo_deleted_at,
    'confirmed_by_name', (select pr.full_name from public.profiles pr where pr.id = p.confirmed_by),
    'reopened', p.reopened_snapshot is not null and p.status in ('read', 'failed'),
    'lines', coalesce((
      select jsonb_agg(jsonb_build_object(
               'line_no', l.line_no, 'description', l.description,
               'ordered_text', l.ordered_text, 'ordered_qty', l.ordered_qty,
               'ordered_unit', l.ordered_unit, 'actual_kg', l.actual_kg)
             order by l.line_no)
      from public.weighing_lines l where l.paper_id = p.id), '[]'::jsonb),
    -- First date this order was due, if it was ever postponed to here.
    'moved_from', (
      select coalesce(h.from_delivery_date, h.from_work_date)
      from public.weighing_postponements h
      where h.paper_id = p.id
      order by h.created_at
      limit 1),
    'mark', (
      select jsonb_build_object(
               'status', case when m.delivery_date = coalesce(p.delivery_date, p.work_date) then m.status else 'dispatch' end,
               'note', case when m.delivery_date = coalesce(p.delivery_date, p.work_date) then m.note end,
               'marked_at', m.marked_at,
               'by', pr.full_name,
               'carried', m.delivery_date <> coalesce(p.delivery_date, p.work_date))
      from public.delivery_marks m
      left join public.profiles pr on pr.id = m.marked_by
      where m.paper_id = p.id
        and (m.delivery_date = coalesce(p.delivery_date, p.work_date) or m.status in ('dispatch', 'out', 'problem'))),
    -- Accounting's invoice mark (Migration 030).
    'invoice', (
      select jsonb_build_object('invoice_no', i.invoice_no, 'invoiced_at', i.invoiced_at,
                                'by', pr.full_name,
                                'changed', p.status <> 'confirmed' or p.confirmed_at is distinct from i.confirmed_at_seen)
      from public.weighing_invoices i
      left join public.profiles pr on pr.id = i.invoiced_by
      where i.paper_id = p.id));
$function$;

revoke all on function public.delivery_paper_json(public.weighing_papers) from public, anon, authenticated;

-- ============================================================================
