-- ============================================================================
-- Migration 029 — Delivery board (PACE › Delivery)
-- ============================================================================
-- Written 11 Nov 2026. Clément: an interface for the delivery team — which
-- order is finished, which one is pushed back (postponed), and so on — very
-- visual for them.
--
-- Where the information comes from
--   An order reaches the system when production photographs its working
--   paper (FM-SA-01) on the weighing screen. For one delivery day the board
--   shows every paper whose delivery date is that day:
--     - postponed to this day and not produced yet  → "To produce"
--     - photographed, weights being checked         → "Produced — checking"
--     - weights confirmed                           → "Ready to deliver"
--   then the delivery team's own marks (new here):
--     - out for delivery → delivered, or a problem (comment required)
--   and, separately, everything pushed away from this day: papers postponed
--   by production or by the middle office (Migrations 027, 028) and the
--   middle office register (order_postponements).
--   Orders still only in sale support's Excel file are not on the board until
--   their paper is photographed — the order book moves into PACE later.
--
-- What this migration adds
--   1. A new role, delivery. Sees only PROSUN PACE › Delivery. Nothing
--      existing is granted to it (every older policy names its roles).
--   2. delivery_marks — one row per paper: out / delivered / problem, for the
--      delivery date it was marked on. If the delivery is postponed after
--      that, the old mark no longer applies (the board compares the dates).
--      No direct table access: written through delivery_mark(), read through
--      delivery_board(). Every change is kept in activity_log.
--   3. delivery_board(day) — everything the board shows for one delivery day,
--      in one call. Reasons and comments of postponements are returned only
--      to admin and the middle office (Clément, 11 Nov: the others see the
--      dates, not the reasons) — the delivery team sees dates only.
--   4. delivery_mark(paper, status, note) — delivery and admin. A problem
--      needs a comment and rings the admin bell. status null = undo.
--
-- Who can do what
--   delivery_board: delivery, sale_support, admin (read).
--   delivery_mark:  delivery, admin.
--
-- Run order: after 028. Safe to re-run.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. The delivery role
-- ----------------------------------------------------------------------------
-- The role list is read from the constraint as it is in the database and
-- 'delivery' added, so a role added on the live project since 020 is kept.
do $$
declare
  def   text;
  roles text[];
begin
  select pg_get_constraintdef(oid) into def
  from pg_constraint
  where conrelid = 'public.profiles'::regclass and conname = 'profiles_role_check';

  select array_agg(m[1]) into roles
  from regexp_matches(coalesce(def, ''), '''([a-z_]+)''', 'g') as m;
  roles := coalesce(roles, array['admin', 'director', 'sales', 'sale_support', 'purchasing',
                                 'production', 'factory_admin', 'accounting']);
  if not ('delivery' = any(roles)) then
    roles := array_append(roles, 'delivery');
  end if;

  alter table public.profiles drop constraint if exists profiles_role_check;
  execute format('alter table public.profiles add constraint profiles_role_check check (role in (%s))',
                 (select string_agg(quote_literal(r), ', ') from unnest(roles) r));
end $$;

comment on constraint profiles_role_check on public.profiles is
  'admin = everything; director/sales = CRM; sale_support/purchasing/production '
  '= PACE; factory_admin = weighing photo screen only (Migration 018); '
  'accounting = confirmed weights and payables (Migrations 020, 025); '
  'delivery = delivery board only (Migration 029).';


-- ----------------------------------------------------------------------------
-- 2. The delivery team's marks
-- ----------------------------------------------------------------------------
create table if not exists public.delivery_marks (
  id             uuid primary key default gen_random_uuid(),
  paper_id       uuid not null unique references public.weighing_papers(id) on delete cascade,
  delivery_date  date not null,     -- the delivery day the mark was made for
  status         text not null check (status in ('out', 'delivered', 'problem')),
  note           text,
  marked_by      uuid references public.profiles(id),
  marked_at      timestamptz not null default now(),
  constraint delivery_marks_problem_note check (status <> 'problem' or length(trim(coalesce(note, ''))) > 0)
);

comment on table public.delivery_marks is
  'Delivery team marks per working paper: out for delivery, delivered, or problem (with comment). '
  'Written only by delivery_mark(); applies while the paper''s delivery date equals delivery_date. Migration 029.';

alter table public.delivery_marks enable row level security;
-- No policy for authenticated: no direct reads or writes. The functions below
-- run as owner and check the role themselves.
revoke all on public.delivery_marks from anon, authenticated;
grant all on public.delivery_marks to service_role;

drop trigger if exists delivery_marks_log_activity on public.delivery_marks;
create trigger delivery_marks_log_activity
  after insert or update or delete on public.delivery_marks
  for each row execute function public.log_weighing_activity();


-- ----------------------------------------------------------------------------
-- 3. The board for one delivery day
-- ----------------------------------------------------------------------------
create or replace function public.delivery_board(p_date date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  r        text := coalesce(public.current_role(), '');
  reasons  boolean;
  papers   jsonb;
  moved    jsonb;
  register jsonb;
begin
  if r not in ('delivery', 'sale_support', 'admin') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if p_date is null then
    raise exception 'choose a delivery day' using errcode = '22023';
  end if;
  reasons := r in ('sale_support', 'admin');

  -- Every paper delivering that day (no delivery date read yet: its weighing day).
  select coalesce(jsonb_agg(x order by x->>'customer_name' nulls last, x->>'po_number'), '[]'::jsonb)
    into papers
  from (
    select jsonb_build_object(
      'id', p.id,
      'status', p.status,
      'company', p.company,
      'po_number', p.po_number,
      'customer_name', p.customer_name,
      'delivery_date', p.delivery_date,
      'work_date', p.work_date,
      'confirmed_at', p.confirmed_at,
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
        select jsonb_build_object('status', m.status, 'note', m.note, 'marked_at', m.marked_at,
                                  'by', pr.full_name)
        from public.delivery_marks m
        left join public.profiles pr on pr.id = m.marked_by
        where m.paper_id = p.id and m.delivery_date = coalesce(p.delivery_date, p.work_date))
    ) as x
    from public.weighing_papers p
    where coalesce(p.delivery_date, p.work_date) = p_date
  ) s;

  -- Papers that were due that day and have been pushed to another day.
  select coalesce(jsonb_agg(x order by x->>'customer_name' nulls last), '[]'::jsonb)
    into moved
  from (
    select jsonb_build_object(
      'paper_id', h.paper_id,
      'customer_name', h.customer_name,
      'po_number', h.po_number,
      'company', h.company,
      'stage', h.stage,
      'new_date', coalesce(p.delivery_date, h.to_delivery_date),
      'paper_status', p.status,
      'kg_ordered', h.kg_ordered,
      'lines', h.lines,
      'reason', case when reasons then h.reason end,
      'note', case when reasons then h.note end,
      'moved_at', h.created_at
    ) as x
    from (
      select distinct on (coalesce(wp.paper_id, wp.id)) wp.*
      from public.weighing_postponements wp
      where coalesce(wp.from_delivery_date, wp.from_work_date) = p_date
      order by coalesce(wp.paper_id, wp.id), wp.created_at desc
    ) h
    left join public.weighing_papers p on p.id = h.paper_id
    -- Moved back to this day since: it is on the board itself.
    where p.id is null or coalesce(p.delivery_date, p.work_date) <> p_date
  ) s;

  -- The middle office register: postponed before the paper reached production.
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', o.id,
           'customer_name', o.customer_name,
           'po_number', o.po_number,
           'company', o.company,
           'product', o.product,
           'quantity_kg', o.quantity_kg,
           'new_date', o.new_date,
           'reason', case when reasons then o.reason end,
           'note', case when reasons then o.note end,
           'moved_at', o.created_at)
         order by o.customer_name), '[]'::jsonb)
    into register
  from public.order_postponements o
  where o.original_date = p_date;

  return jsonb_build_object(
    'date', p_date,
    'papers', papers,
    'moved', moved,
    'register', register,
    'reasons_visible', reasons,
    'can_mark', r in ('delivery', 'admin'),
    'loaded_at', now());
end;
$$;

comment on function public.delivery_board(date) is
  'Delivery board for one day: papers due (with lines, postponement origin and delivery mark), papers '
  'pushed away, middle office register. Reasons only for admin and sale_support. Migration 029.';

revoke all on function public.delivery_board(date) from public, anon;
grant execute on function public.delivery_board(date) to authenticated, service_role;


-- ----------------------------------------------------------------------------
-- 4. Marking an order: out / delivered / problem (null = undo)
-- ----------------------------------------------------------------------------
create or replace function public.delivery_mark(p_paper uuid, p_status text, p_note text default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  p    public.weighing_papers;
  day  date;
  note text := nullif(trim(coalesce(p_note, '')), '');
  rec  public.delivery_marks;
begin
  if coalesce(public.current_role(), '') not in ('delivery', 'admin') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  select * into p from public.weighing_papers where id = p_paper;
  if not found then
    raise exception 'paper not found' using errcode = '22023';
  end if;
  day := coalesce(p.delivery_date, p.work_date);

  if p_status is null then
    delete from public.delivery_marks where paper_id = p.id;
    return null;
  end if;

  if p_status not in ('out', 'delivered', 'problem') then
    raise exception 'unknown delivery status' using errcode = '22023';
  end if;
  -- A postponed paper has not been produced; one still being read has no
  -- client yet.
  if p.status not in ('read', 'failed', 'confirmed') then
    raise exception 'this order is not produced yet (status: %)', p.status using errcode = '22023';
  end if;
  if p_status = 'problem' and note is null then
    raise exception 'write what the problem is' using errcode = '22023';
  end if;

  insert into public.delivery_marks (paper_id, delivery_date, status, note, marked_by, marked_at)
  values (p.id, day, p_status, note, auth.uid(), now())
  on conflict (paper_id) do update
    set delivery_date = excluded.delivery_date, status = excluded.status, note = excluded.note,
        marked_by = excluded.marked_by, marked_at = excluded.marked_at
  returning * into rec;

  if p_status = 'problem' then
    perform public.notify_admins('delivery_problem',
      'Delivery problem — ' || public.weighing_paper_label(p.po_number, p.customer_name),
      'Delivery ' || to_char(day, 'DD Mon') || ': ' || note,
      jsonb_build_object('mark', to_jsonb(rec)),
      p.id, p.work_date);
  end if;

  return to_jsonb(rec);
end;
$$;

comment on function public.delivery_mark(uuid, text, text) is
  'Delivery team marks a paper out / delivered / problem (comment required; notifies admins), '
  'or clears the mark (status null). Delivery and admin. Migration 029.';

revoke all on function public.delivery_mark(uuid, text, text) from public, anon;
grant execute on function public.delivery_mark(uuid, text, text) to authenticated, service_role;


-- ============================================================================
-- After running — give the delivery team their accounts
-- ============================================================================
--   1. Authentication > Users > Add user: their email + a password.
--      A new login always starts as 'sales' (handle_new_user trigger).
--   2. Then, in the SQL Editor (one line per person):
--
--        update public.profiles p set role = 'delivery', full_name = 'ชื่อ'
--        from auth.users u where p.id = u.id and u.email = 'name@klongphaifarm.com';
--
-- Check:
--   select role, count(*) from public.profiles group by role;
-- ============================================================================
