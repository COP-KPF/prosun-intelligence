-- ============================================================================
-- Migration 027 — Postponing production, and so the delivery
-- ============================================================================
-- Written 10 Nov 2026. Clément: an option to postpone the production of an
-- order, and therefore its delivery — done by production on the weighing
-- screen, seen by the middle office (who can also record postponements the
-- factory never sees, such as a client asking to move a delivery), notified
-- to management in the bell, and shown on the Management dashboard.
--
-- 1. PRODUCTION — on the weighing screen
--    A working paper (FM-SA-01) that cannot be produced today is photographed
--    as usual; the AI reads its client, PO and products. Production then
--    presses "Postpone": new production day, new delivery date, reason.
--    The paper takes the status 'postponed' and moves to the new production
--    day's list (its work_date), with its new delivery date. Each move is
--    kept in weighing_postponements, so an order pushed twice shows twice.
--    On the new day the filled paper is photographed again with the phone;
--    the screen offers to link it to the postponed one (same PO): the history
--    moves to the new photo and the blank paper is removed — without a
--    "paper deleted" notification, since nothing was lost. Production can
--    also simply type the weights on the postponed paper and confirm it.
--
-- 2. MIDDLE OFFICE — PACE › Middle office › Postponed orders
--    Sees the factory's postponements (read-only) and keeps a register for
--    the others (client request, or an order moved before its paper reached
--    production): the date missed, the new date, the reason. This is the
--    register drafted on 2 Nov and parked until now (it was "Migration 025"
--    then; that number went to payables).
--
-- 3. MANAGEMENT
--    Every postponement — production's and the register's — notifies the
--    admins in the bell (Migration 021), as does any change to a register
--    record's dates or reason, or its deletion. management_postponements()
--    gives the dashboard its numbers.
--
-- Rules
--   - Only papers not yet confirmed can be postponed (a confirmed paper was
--     produced). Status 'postponed' can only be set through
--     weighing_postpone(), so every postponed paper has its history row.
--   - New production day: today or later, and different from the current
--     one. New delivery date: on or after the new production day.
--   - Reason 'other' needs a note.
--   - History rows are never edited or deleted by the app; they survive the
--     paper's deletion (the client, PO and dates are copied on the row).
--
-- Access
--   weighing_postponements: read by factory_admin, production, admin and
--     sale_support; written only by the two functions below.
--   order_postponements (register): sale_support and admin read, add and
--     correct; only admin deletes.
--   management_postponements(): admin only.
--
-- Run order: after 026. Safe to re-run.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. A paper can be 'postponed'
-- ----------------------------------------------------------------------------
do $$
declare c text;
begin
  for c in
    select con.conname from pg_constraint con
    where con.conrelid = 'public.weighing_papers'::regclass and con.contype = 'c'
      and pg_get_constraintdef(con.oid) ilike '%status%uploading%'
  loop
    execute format('alter table public.weighing_papers drop constraint %I', c);
  end loop;
end $$;

alter table public.weighing_papers add constraint weighing_papers_status_check
  check (status in ('uploading', 'queued', 'reading', 'read', 'failed', 'postponed', 'confirmed'));


-- ----------------------------------------------------------------------------
-- 2. Reasons (shared by production and the register)
-- ----------------------------------------------------------------------------
create or replace function public.postponement_reason_label(p_reason text)
returns text
language sql
immutable
as $$
  select case p_reason
    when 'production'   then 'Production not finished in time'
    when 'raw_material' then 'Birds or raw material short'
    when 'delivery'     then 'Delivery or logistics'
    when 'client'       then 'Client request'
    else 'Other' end;
$$;


-- ----------------------------------------------------------------------------
-- 3. Production's postponements: one row per move
-- ----------------------------------------------------------------------------
create table if not exists public.weighing_postponements (
  id                 uuid primary key default gen_random_uuid(),
  created_at         timestamptz not null default now(),
  created_by         uuid references public.profiles(id),
  paper_id           uuid references public.weighing_papers(id) on delete set null,
  customer_name      text,
  po_number          text,
  company            text,
  from_work_date     date not null,
  to_work_date       date not null,
  from_delivery_date date,
  to_delivery_date   date not null,
  reason             text not null check (reason in ('production', 'raw_material', 'delivery', 'client', 'other')),
  note               text,
  kg_ordered         numeric,        -- ordered kg on the paper at that moment (lines in kg or g)
  lines              int,
  constraint weighing_postponements_dates check (to_work_date <> from_work_date and to_delivery_date >= to_work_date),
  constraint weighing_postponements_other_note check (reason <> 'other' or length(trim(coalesce(note, ''))) > 0)
);

create index if not exists weighing_postponements_paper_idx on public.weighing_postponements (paper_id);
create index if not exists weighing_postponements_from_idx  on public.weighing_postponements (from_work_date);

comment on table public.weighing_postponements is
  'Each time production postpones a working paper: production day and delivery '
  'date before and after, reason. Written only by weighing_postpone(). Migration 027.';

alter table public.weighing_postponements enable row level security;

drop policy if exists "weighing_postponements: read" on public.weighing_postponements;
create policy "weighing_postponements: read"
  on public.weighing_postponements for select to authenticated
  using (public.current_role() in ('factory_admin', 'production', 'admin', 'sale_support'));

revoke all on public.weighing_postponements from anon, authenticated;
grant select on public.weighing_postponements to authenticated;
grant all on public.weighing_postponements to service_role;


-- 'postponed' only through weighing_postpone(): the function sets a flag for
-- its own transaction; a direct update without it is refused.
create or replace function public.weighing_papers_postpone_guard()
returns trigger
language plpgsql
as $$
begin
  if new.status = 'postponed' and old.status is distinct from 'postponed'
     and coalesce(current_setting('prosun.postponing', true), '') <> 'on' then
    raise exception 'a paper is postponed with the Postpone button (weighing_postpone)' using errcode = '42501';
  end if;
  return new;
end;
$$;

drop trigger if exists weighing_papers_postpone_guard on public.weighing_papers;
create trigger weighing_papers_postpone_guard
  before update on public.weighing_papers
  for each row execute function public.weighing_papers_postpone_guard();


create or replace function public.weighing_postpone(p_paper uuid, p_work_date date, p_delivery_date date,
                                                    p_reason text, p_note text default null)
returns public.weighing_postponements
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  p     public.weighing_papers;
  today date := (now() at time zone 'Asia/Bangkok')::date;
  kg    numeric;
  n     int;
  rec   public.weighing_postponements;
begin
  if coalesce(public.current_role(), '') not in ('factory_admin', 'production', 'admin') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  select * into p from public.weighing_papers where id = p_paper for update;
  if not found then
    raise exception 'paper not found' using errcode = '22023';
  end if;
  if p.status not in ('read', 'failed', 'postponed') then
    raise exception 'only a paper that is read and not confirmed can be postponed (status: %)', p.status using errcode = '22023';
  end if;
  if p_work_date is null or p_work_date < today then
    raise exception 'choose a production day from today on' using errcode = '22023';
  end if;
  if p_work_date = p.work_date then
    raise exception 'the new production day is the same as the current one' using errcode = '22023';
  end if;
  if p_delivery_date is null or p_delivery_date < p_work_date then
    raise exception 'the new delivery date must be on or after the new production day' using errcode = '22023';
  end if;
  if p_reason not in ('production', 'raw_material', 'delivery', 'client', 'other') then
    raise exception 'choose a reason' using errcode = '22023';
  end if;
  if p_reason = 'other' and length(trim(coalesce(p_note, ''))) = 0 then
    raise exception 'add a note when the reason is Other' using errcode = '22023';
  end if;

  select coalesce(sum(case l.ordered_unit when 'kg' then l.ordered_qty when 'g' then l.ordered_qty / 1000 end), 0),
         count(*)
    into kg, n
    from public.weighing_lines l where l.paper_id = p.id;

  insert into public.weighing_postponements
    (created_by, paper_id, customer_name, po_number, company, from_work_date, to_work_date,
     from_delivery_date, to_delivery_date, reason, note, kg_ordered, lines)
  values (auth.uid(), p.id, p.customer_name, p.po_number, p.company, p.work_date, p_work_date,
          p.delivery_date, p_delivery_date, p_reason, nullif(trim(coalesce(p_note, '')), ''), kg, n)
  returning * into rec;

  perform set_config('prosun.postponing', 'on', true);
  update public.weighing_papers
     set status = 'postponed', work_date = p_work_date, delivery_date = p_delivery_date
   where id = p.id;
  perform set_config('prosun.postponing', '', true);

  return rec;
end;
$$;

comment on function public.weighing_postpone(uuid, date, date, text, text) is
  'Postpones a working paper not yet confirmed: new production day (work_date) and delivery date, '
  'with the reason. Production and admin. Migration 027.';


-- Link the filled paper photographed on the new day to the postponed one: the
-- history follows the new photo, the new photo keeps the postponed delivery
-- date (the printed one is the old date), and the blank paper is removed.
create or replace function public.weighing_link_postponed(p_postponed uuid, p_new uuid)
returns text
language plpgsql
volatile
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

  perform set_config('prosun.linking', 'on', true);
  delete from public.weighing_papers where id = old_p.id;
  perform set_config('prosun.linking', '', true);

  return old_p.photo_path;     -- the browser removes this photo from storage
end;
$$;

comment on function public.weighing_link_postponed(uuid, uuid) is
  'Moves a postponed paper''s history to the photo of the produced paper and removes the '
  'postponed one. Returns its photo path. Migration 027.';

revoke all on function public.weighing_postpone(uuid, date, date, text, text) from public, anon;
revoke all on function public.weighing_link_postponed(uuid, uuid)            from public, anon;
grant execute on function public.weighing_postpone(uuid, date, date, text, text) to authenticated, service_role;
grant execute on function public.weighing_link_postponed(uuid, uuid)            to authenticated, service_role;


-- Migration 021's "paper deleted" notification, now quiet when the deletion
-- is the link above (the paper's content lives on in the new photo).
create or replace function public.weighing_papers_notify_delete()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  snap jsonb;
  n int;
  total numeric;
  confirmed_before boolean := old.status = 'confirmed' or old.reopened_snapshot is not null;
begin
  if coalesce(current_setting('prosun.linking', true), '') = 'on' then
    return old;
  end if;
  snap := public.weighing_paper_snapshot(old.id);
  n := jsonb_array_length(snap->'lines');
  select sum((e->>'actual_kg')::numeric) into total from jsonb_array_elements(snap->'lines') e;
  perform public.notify_admins('weighing_deleted',
    case when confirmed_before then 'Confirmed paper deleted — ' else 'Paper deleted — ' end
      || public.weighing_paper_label(old.po_number, old.customer_name),
    case when old.status = 'confirmed' then 'Was confirmed' || coalesce(' by ' || (snap->>'confirmed_by_name'), '') || '. '
         when old.reopened_snapshot is not null then 'Had been confirmed, reopened for correction, then deleted. '
         else 'Not yet confirmed (status: ' || old.status || '). ' end
      || n || case when n = 1 then ' line' else ' lines' end
      || coalesce(', ' || public.weighing_fmt_kg(total) || ' kg in total', '') || '.',
    jsonb_build_object('deleted', snap, 'confirmed_before', old.reopened_snapshot),
    old.id, old.work_date);
  return old;
end;
$$;


-- Bell: every production postponement
create or replace function public.weighing_postponements_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.notify_admins('paper_postponed',
    'Production postponed — ' || public.weighing_paper_label(new.po_number, new.customer_name),
    'Production ' || to_char(new.from_work_date, 'DD Mon') || ' → ' || to_char(new.to_work_date, 'DD Mon')
      || ' · delivery ' || coalesce(to_char(new.from_delivery_date, 'DD Mon'), '—') || ' → ' || to_char(new.to_delivery_date, 'DD Mon')
      || '. ' || public.postponement_reason_label(new.reason) || '.'
      || coalesce(' ' || new.note, ''),
    jsonb_build_object('postponement', to_jsonb(new)),
    new.paper_id, new.to_work_date);
  return new;
end;
$$;

drop trigger if exists weighing_postponements_notify on public.weighing_postponements;
create trigger weighing_postponements_notify
  after insert on public.weighing_postponements
  for each row execute function public.weighing_postponements_notify();

drop trigger if exists weighing_postponements_log_activity on public.weighing_postponements;
create trigger weighing_postponements_log_activity
  after insert or update or delete on public.weighing_postponements
  for each row execute function public.log_weighing_activity();


-- ----------------------------------------------------------------------------
-- 4. The middle office register (the 2 Nov design)
-- ----------------------------------------------------------------------------
create table if not exists public.order_postponements (
  id             uuid primary key default gen_random_uuid(),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  created_by     uuid references public.profiles(id),
  customer_name  text not null check (length(trim(customer_name)) > 0),
  po_number      text,
  company        text check (company in ('Prosun Farm', 'Prosun Food')),
  product        text,
  quantity_kg    numeric check (quantity_kg is null or quantity_kg >= 0),
  original_date  date not null,
  new_date       date,            -- empty = no new date agreed yet
  reason         text not null check (reason in ('production', 'raw_material', 'delivery', 'client', 'other')),
  note           text,
  constraint order_postponements_later check (new_date is null or new_date > original_date),
  constraint order_postponements_other_note check (reason <> 'other' or length(trim(coalesce(note, ''))) > 0)
);

create index if not exists order_postponements_original_idx on public.order_postponements (original_date);

comment on table public.order_postponements is
  'Middle office register: a client order''s delivery date pushed back outside the factory''s '
  'own postponement (client request, order moved before its paper reached production). Migration 027.';

-- Who recorded it comes from the session, never from the form.
create or replace function public.order_postponements_stamp()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    new.created_by := auth.uid();
    new.created_at := now();
  else
    new.created_by := old.created_by;
    new.created_at := old.created_at;
  end if;
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists order_postponements_stamp on public.order_postponements;
create trigger order_postponements_stamp
  before insert or update on public.order_postponements
  for each row execute function public.order_postponements_stamp();

drop trigger if exists order_postponements_log_activity on public.order_postponements;
create trigger order_postponements_log_activity
  after insert or update or delete on public.order_postponements
  for each row execute function public.log_weighing_activity();

alter table public.order_postponements enable row level security;

drop policy if exists "order_postponements: read" on public.order_postponements;
create policy "order_postponements: read"
  on public.order_postponements for select to authenticated
  using (public.current_role() in ('sale_support', 'admin'));

drop policy if exists "order_postponements: add" on public.order_postponements;
create policy "order_postponements: add"
  on public.order_postponements for insert to authenticated
  with check (public.current_role() in ('sale_support', 'admin'));

drop policy if exists "order_postponements: correct" on public.order_postponements;
create policy "order_postponements: correct"
  on public.order_postponements for update to authenticated
  using (public.current_role() in ('sale_support', 'admin'))
  with check (public.current_role() in ('sale_support', 'admin'));

drop policy if exists "order_postponements: admin deletes" on public.order_postponements;
create policy "order_postponements: admin deletes"
  on public.order_postponements for delete to authenticated
  using (public.current_role() = 'admin');

revoke all on public.order_postponements from anon, authenticated;
grant select, insert, update, delete on public.order_postponements to authenticated;
grant all on public.order_postponements to service_role;

create or replace function public.order_postponements_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  rec public.order_postponements := case when tg_op = 'DELETE' then old else new end;
  dates text := to_char(rec.original_date, 'DD Mon') || ' → '
    || coalesce(to_char(rec.new_date, 'DD Mon'), 'no new date yet');
  label text := trim(rec.customer_name) || coalesce(' (' || nullif(trim(rec.po_number), '') || ')', '');
begin
  if tg_op = 'INSERT' then
    perform public.notify_admins('order_postponed', 'Order postponed — ' || label,
      'Delivery ' || dates || '. ' || public.postponement_reason_label(new.reason) || '.'
        || coalesce(' ' || nullif(trim(new.note), ''), ''),
      null, null, null);
  elsif tg_op = 'DELETE' then
    perform public.notify_admins('order_postponed_changed', 'Postponement deleted — ' || label,
      'Delivery ' || dates || '. ' || public.postponement_reason_label(old.reason) || '.',
      null, null, null);
  elsif new.original_date is distinct from old.original_date
     or new.new_date is distinct from old.new_date
     or new.reason is distinct from old.reason then
    perform public.notify_admins('order_postponed_changed', 'Postponement changed — ' || label,
      'Was: ' || to_char(old.original_date, 'DD Mon') || ' → '
        || coalesce(to_char(old.new_date, 'DD Mon'), 'no new date yet') || ', '
        || public.postponement_reason_label(old.reason)
        || '. Now: ' || dates || ', ' || public.postponement_reason_label(new.reason) || '.',
      null, null, null);
  end if;
  return rec;
end;
$$;

drop trigger if exists order_postponements_notify on public.order_postponements;
create trigger order_postponements_notify
  after insert or update or delete on public.order_postponements
  for each row execute function public.order_postponements_notify();

revoke all on function public.order_postponements_notify()      from public, anon, authenticated;
revoke all on function public.order_postponements_stamp()       from public, anon, authenticated;
revoke all on function public.weighing_postponements_notify()   from public, anon, authenticated;


-- ----------------------------------------------------------------------------
-- 5. The dashboard's numbers
-- ----------------------------------------------------------------------------
-- Both sources together. A postponement counts on the delivery date it
-- missed (production: the paper's delivery date before the move, or its
-- production day if it had none). "No new date yet" exists only in the
-- register and is today's state, whatever the period. With a company
-- selected, records with no company are left out.
create or replace function public.management_postponements(p_from date, p_to date, p_company text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_co    text := nullif(p_company, 'all');
  v_start date;
  v_out   jsonb;
begin
  if coalesce(public.current_role(), '') <> 'admin' then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'choose a start and an end date' using errcode = '22023';
  end if;

  select s.count_from into v_start from public.management_settings s where s.id = 1;

  with rec as (
    select 'production'::text as source, w.customer_name, w.po_number, w.company,
           null::text as product, w.kg_ordered as quantity_kg,
           coalesce(w.from_delivery_date, w.from_work_date) as original_date,
           w.to_delivery_date as new_date, w.reason, w.note, w.created_at,
           w.to_delivery_date - coalesce(w.from_delivery_date, w.from_work_date) as delay_days
    from public.weighing_postponements w
    where (v_co is null or w.company = v_co)
    union all
    select 'middle_office', r.customer_name, r.po_number, r.company, r.product, r.quantity_kg,
           r.original_date, r.new_date, r.reason, r.note, r.created_at,
           r.new_date - r.original_date
    from public.order_postponements r
    where (v_co is null or r.company = v_co)
  ),
  period as (
    select * from rec where original_date between p_from and p_to
  ),
  by_client as (
    select min(trim(coalesce(customer_name, '—'))) as client, count(*) as times,
           count(*) filter (where reason = 'production') as production
    from period group by lower(trim(coalesce(customer_name, '—')))
  )
  select jsonb_build_object(
    'total',       (select count(*) from period),
    'by_factory',  (select count(*) from period where source = 'production'),
    'production',  (select count(*) from period where reason = 'production'),
    'our_side',    (select count(*) from period where reason <> 'client'),
    'kg',          (select coalesce(sum(quantity_kg), 0) from period),
    'avg_delay',   (select round(avg(delay_days), 1) from period),
    'no_new_date', (select count(*) from rec where new_date is null),
    'by_reason', coalesce((select jsonb_agg(x order by x.times desc, x.reason) from (
        select reason, count(*) as times, coalesce(sum(quantity_kg), 0) as kg,
               round(avg(delay_days), 1) as avg_delay
        from period group by reason) x), '[]'::jsonb),
    'repeat_clients', coalesce((select jsonb_agg(c order by c.times desc, c.client)
        from by_client c where c.times >= 2), '[]'::jsonb),
    'recent', coalesce((select jsonb_agg(x order by x.original_date desc, x.created_at desc) from (
        select source, customer_name, po_number, product, quantity_kg, original_date, new_date, reason, note, created_at
        from period order by original_date desc, created_at desc limit 8) x), '[]'::jsonb),
    'late_papers', (select count(*) from public.weighing_papers p
        where p.work_date > p.delivery_date
          and p.work_date >= v_start
          and p.work_date between p_from and p_to
          and not exists (select 1 from public.weighing_postponements w where w.paper_id = p.id)
          and (v_co is null or p.company = v_co))
  ) into v_out;

  return v_out;
end;
$$;

comment on function public.management_postponements(date, date, text) is
  'Postponed-order numbers for PACE › Management (production and middle office). Admin only. Migration 027.';

revoke all on function public.management_postponements(date, date, text) from public, anon;
grant execute on function public.management_postponements(date, date, text) to authenticated, service_role;
