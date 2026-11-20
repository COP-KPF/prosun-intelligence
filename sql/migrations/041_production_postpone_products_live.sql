-- ============================================================================
-- Migration 041 — Production postpones products too; PACE updates live
-- ============================================================================
-- Written 20 Nov 2026. Clément: production can postpone orders "with the same
-- system as the middle office" — the whole order, one product or part of it —
-- and both sides see the other's changes live in PACE.
--
-- Decision (Clément, 20 Nov): it depends on the paper.
--   - Not confirmed yet (production is still weighing it): the product goes
--     back to production on a new day — a new paper "part 2" (same PO) waits
--     for production; the rest of the order stays on this paper.
--   - Confirmed: the same two choices as the middle office (040) — produced,
--     delivered later, or back to production.
--   The whole order is still "เลื่อนผลิต / Postpone" (027) on the weighing
--   screen and "Postpone" (028) in Confirmed weights.
--
-- Database
--   - weighing_postpone_lines (040) also for factory_admin and production,
--     on papers read / failed / postponed (back to production only) and on
--     confirmed papers (both choices). The middle office still works on
--     confirmed papers only. A paper still being read is refused. New
--     argument p_from ('weighing' | 'weights') tells whose move it is when an
--     admin does it; production's and the middle office's own moves are known
--     from their role. Unconfirmed papers keep their confirmation untouched.
--   - weighing_postponements.by_dept ('production' | 'middle'): who moved it;
--     Postponed orders (035) and its timeline use it.
--   - Live: pace_live, one row per subject ('orders' — working papers,
--     products, postponements, the register, delivery marks, invoices,
--     closures). Every change to those tables stamps it, and it is in the
--     realtime publication. It holds no order data, so every signed-in user may
--     read it: each screen (Weighing, Confirmed weights, Postponed orders,
--     Delivery board, the menu count) reloads its own data — through its own
--     permissions — the moment something changes, wherever it was changed.
--
-- Run order: after 040. Safe to re-run.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Who moved it
-- ----------------------------------------------------------------------------
alter table public.weighing_postponements add column if not exists by_dept text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'weighing_postponements_by_dept_check') then
    alter table public.weighing_postponements add constraint weighing_postponements_by_dept_check
      check (by_dept is null or by_dept in ('production', 'middle'));
  end if;
end $$;
comment on column public.weighing_postponements.by_dept is
  'Who moved it: production (weighing screen) or middle (Confirmed weights). Set from 041 on.';
-- Earlier rows: production's postponements (027) are production's, the rest the middle office's.
update public.weighing_postponements
   set by_dept = case when split_mode is null and stage = 'production' then 'production' else 'middle' end
 where by_dept is null;


-- ----------------------------------------------------------------------------
-- 2. Postpone products — production too (040's function, extended)
-- ----------------------------------------------------------------------------
drop function if exists public.weighing_postpone_lines(uuid, jsonb, text, date, date, text, text);

create or replace function public.weighing_postpone_lines(
  p_paper uuid, p_moves jsonb, p_mode text, p_delivery_date date,
  p_work_date date default null, p_reason text default null, p_note text default null,
  p_from text default null)
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
  v_role   text := coalesce(public.current_role(), '');
  v_dept   text;
  v_conf   boolean;
begin
  if v_role not in ('sale_support', 'admin', 'factory_admin', 'production') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  select * into p from public.weighing_papers where id = p_paper for update;
  if not found then
    raise exception 'paper not found' using errcode = '22023';
  end if;
  v_conf := p.status = 'confirmed';
  if v_role = 'sale_support' and not v_conf then
    raise exception 'the middle office postpones products of confirmed papers only (status: %)', p.status using errcode = '22023';
  end if;
  if not v_conf and p.status not in ('read', 'failed', 'postponed') then
    raise exception 'this paper is still being read — wait until its products show (status: %)', p.status using errcode = '22023';
  end if;
  -- who moved it: production (weighing screen) or the middle office (Confirmed weights)
  v_dept := case when v_role in ('factory_admin', 'production') then 'production'
                 when v_role = 'sale_support' then 'middle'
                 when p_from = 'weighing' then 'production' else 'middle' end;
  if p_mode is null or p_mode not in ('later', 'production') then
    raise exception 'choose: produced — deliver later, or not produced — back to production' using errcode = '22023';
  end if;
  if not v_conf and p_mode = 'later' then
    raise exception 'the weights are not confirmed yet: these products can only go back to production' using errcode = '22023';
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
  if v_conf then
    update public.weighing_papers set confirmed_at = now() where id = p.id;
  end if;

  insert into public.weighing_postponements
    (created_by, paper_id, customer_name, po_number, company, stage, from_work_date, to_work_date,
     from_delivery_date, to_delivery_date, reason, note, kg_ordered, lines,
     split_mode, split_from, lines_moved, by_dept)
  values (auth.uid(), v_child, p.customer_name, p.po_number, p.company,
          case p_mode when 'later' then 'delivery' else 'production' end,
          p.work_date, v_work, cur, p_delivery_date, p_reason, v_note, kg_moved, n_new,
          p_mode, p.id, moved, v_dept);

  perform set_config('prosun.postponing', '', true);
  perform set_config('prosun.splitting', '', true);

  select string_agg(e->>'description' || ' ' ||
           case when (e->>'whole')::boolean then coalesce(e->>'ordered_text', '')
                else public.weighing_qty_text((e->>'qty')::numeric, e->>'unit') || ' of ' || coalesce(e->>'ordered_text', '') end,
           ', ')
    into txt
  from jsonb_array_elements(moved) e;

  perform public.notify_admins('product_postponed',
    'Product postponed by ' || case v_dept when 'production' then 'production' else 'the middle office' end
      || ' — ' || public.weighing_paper_label(p.po_number, p.customer_name),
    txt || ' → part ' || v_part || ', delivery ' || to_char(p_delivery_date, 'DD Mon')
      || case p_mode when 'later' then ' (produced, delivered later)'
                     else ' (back to production on ' || to_char(v_work, 'DD Mon') || ')' end
      || '. ' || public.postponement_reason_label(p_reason) || '.'
      || coalesce(' ' || v_note, ''),
    jsonb_build_object('original_paper', p.id, 'part', v_part, 'mode', p_mode, 'lines', moved, 'by_dept', v_dept,
                       'from_date', cur, 'to_date', p_delivery_date, 'reason', p_reason, 'note', v_note),
    v_child, v_work);

  return jsonb_build_object('paper_id', v_child, 'part', v_part, 'original_paper', p.id,
                            'mode', p_mode, 'work_date', v_work, 'delivery_date', p_delivery_date,
                            'lines', moved, 'by_dept', v_dept);
end;
$$;


comment on function public.weighing_postpone_lines(uuid, jsonb, text, date, date, text, text, text) is
  'Postpones one or more products (or part of a quantity) of a paper — a new paper "part N" (same PO). '
  'Production (weighing screen): unconfirmed papers back to production; confirmed papers like the middle office. '
  'Middle office (Confirmed weights): confirmed papers — produced and delivered later, or back to production. Migrations 040, 041.';

revoke all on function public.weighing_postpone_lines(uuid, jsonb, text, date, date, text, text, text) from public, anon;
grant execute on function public.weighing_postpone_lines(uuid, jsonb, text, date, date, text, text, text) to authenticated, service_role;


-- ----------------------------------------------------------------------------
-- 3. Postponed orders (035/040): who moved it comes from by_dept
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
         coalesce(h.by_dept, case when h.split_mode is not null or h.stage = 'delivery' then 'middle' else 'production' end) as src,   -- 041: who moved it
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
           'split_mode', h.split_mode, 'lines', h.lines_moved, 'by_dept', h.by_dept,
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
revoke all on function public.postponed_order_timeline(uuid, uuid) from public, anon;
grant execute on function public.postponed_order_timeline(uuid, uuid) to authenticated, service_role;


-- ----------------------------------------------------------------------------
-- 4. Live: one stamp per subject, published to realtime
-- ----------------------------------------------------------------------------
create table if not exists public.pace_live (
  topic      text primary key,
  changed_at timestamptz not null default now(),
  seq        bigint not null default 0
);
comment on table public.pace_live is
  'Live updates (041): a stamp per subject, renewed by every change. No order data — screens reload their own data '
  'through their own permissions when it changes.';
insert into public.pace_live (topic) values ('orders') on conflict do nothing;

alter table public.pace_live enable row level security;
drop policy if exists pace_live_read on public.pace_live;
create policy pace_live_read on public.pace_live for select to authenticated using (true);
revoke all on public.pace_live from anon, authenticated;
grant select on public.pace_live to authenticated;
grant all on public.pace_live to service_role;

create or replace function public.pace_live_touch()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.pace_live set changed_at = now(), seq = seq + 1 where topic = tg_argv[0];
  return null;
end;
$$;
revoke all on function public.pace_live_touch() from public, anon, authenticated;

do $$
declare
  t text;
begin
  foreach t in array array['weighing_papers', 'weighing_lines', 'weighing_postponements', 'order_postponements',
                           'delivery_marks', 'weighing_invoices', 'postponement_closures', 'weighing_paper_checks'] loop
    if to_regclass('public.' || t) is not null then
      execute format('drop trigger if exists %I on public.%I', t || '_pace_live', t);
      execute format('create trigger %I after insert or update or delete on public.%I '
                     'for each statement execute function public.pace_live_touch(%L)', t || '_pace_live', t, 'orders');
    end if;
  end loop;
end $$;

do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    raise notice 'supabase_realtime publication not found — skipping';
    return;
  end if;
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'pace_live') then
    alter publication supabase_realtime add table public.pace_live;
  end if;
end $$;

-- ============================================================================
