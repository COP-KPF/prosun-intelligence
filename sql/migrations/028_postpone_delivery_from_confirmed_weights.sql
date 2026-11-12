-- ============================================================================
-- Migration 028 — Middle office postpones a delivery from Confirmed weights
-- ============================================================================
-- Written 11 Nov 2026. Clément: the middle office should be able to click an
-- order directly in Confirmed weights and postpone it, with a reason that must
-- be chosen — no reason, no postponement — and a comment when the reason is
-- Other. Reasons, as he listed them: Lack from production, Not enough
-- product, Missed the delivery time, Other. "Client request" is kept as well,
-- so the dashboard can still tell our side from the client's.
--
-- A paper in Confirmed weights is already produced and weighed, so only its
-- delivery date moves: the paper stays confirmed, its weights are untouched
-- and it now appears under the new delivery date (for accounting too). The
-- move is kept in weighing_postponements with stage = 'delivery' (production's
-- own postponements are stage = 'production'), so it shows in Middle office ›
-- Postponed orders, rings the admin bell and counts on the dashboard as a
-- middle office postponement.
--
-- Rules
--   - Only a confirmed paper; sale_support or admin.
--   - New delivery date: later than the current one (or the weighing day if
--     the paper had none), and today or later.
--   - A reason is required (checked again here, whatever the screen does);
--     Other needs a comment.
--   - Migration 021's "Confirmed paper changed" bell is not sent for this
--     change: the postponement's own bell says it, with the reason.
--
-- Who sees what (Clément, 11 Nov): every department sees that an order was
-- postponed and its delivery dates ("postponed, delivery from … to …"); only
-- admin (Clément, Khun Jum) and the middle office see the reason and comment.
--
-- Run order: after 027. Safe to re-run.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Reason wording (Clément, 11 Nov) — the keys stay the same
-- ----------------------------------------------------------------------------
create or replace function public.postponement_reason_label(p_reason text)
returns text
language sql
immutable
as $$
  select case p_reason
    when 'production'   then 'Lack from production'
    when 'raw_material' then 'Not enough product'
    when 'delivery'     then 'Missed the delivery time'
    when 'client'       then 'Client request'
    else 'Other' end;
$$;


-- ----------------------------------------------------------------------------
-- 2. A history row is a production move or a delivery move
-- ----------------------------------------------------------------------------
alter table public.weighing_postponements
  add column if not exists stage text not null default 'production';

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'weighing_postponements_stage_check') then
    alter table public.weighing_postponements add constraint weighing_postponements_stage_check
      check (stage in ('production', 'delivery'));
  end if;
end $$;

alter table public.weighing_postponements drop constraint if exists weighing_postponements_dates;
alter table public.weighing_postponements add constraint weighing_postponements_dates check (
  (stage = 'production' and to_work_date <> from_work_date and to_delivery_date >= to_work_date)
  or
  (stage = 'delivery' and to_work_date = from_work_date
     and to_delivery_date > coalesce(from_delivery_date, from_work_date))
);

comment on column public.weighing_postponements.stage is
  'production = production postponed on the weighing screen (paper not yet confirmed); '
  'delivery = delivery of a confirmed paper postponed by the middle office from Confirmed weights. Migration 028.';


-- ----------------------------------------------------------------------------
-- 3. Postpone the delivery of a confirmed paper
-- ----------------------------------------------------------------------------
create or replace function public.weighing_postpone_delivery(p_paper uuid, p_delivery_date date,
                                                             p_reason text, p_note text default null)
returns public.weighing_postponements
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  p       public.weighing_papers;
  today   date := (now() at time zone 'Asia/Bangkok')::date;
  current date;
  kg      numeric;
  n       int;
  rec     public.weighing_postponements;
begin
  if coalesce(public.current_role(), '') not in ('sale_support', 'admin') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  select * into p from public.weighing_papers where id = p_paper for update;
  if not found then
    raise exception 'paper not found' using errcode = '22023';
  end if;
  if p.status <> 'confirmed' then
    raise exception 'only a confirmed paper''s delivery can be postponed here (status: %)', p.status using errcode = '22023';
  end if;
  if p_reason is null or p_reason not in ('production', 'raw_material', 'delivery', 'client', 'other') then
    raise exception 'choose a reason' using errcode = '22023';
  end if;
  if p_reason = 'other' and length(trim(coalesce(p_note, ''))) = 0 then
    raise exception 'add a comment when the reason is Other' using errcode = '22023';
  end if;
  current := coalesce(p.delivery_date, p.work_date);
  if p_delivery_date is null or p_delivery_date <= current then
    raise exception 'the new delivery date must be after the current one (%)', to_char(current, 'DD Mon') using errcode = '22023';
  end if;
  if p_delivery_date < today then
    raise exception 'choose a delivery date from today on' using errcode = '22023';
  end if;

  select coalesce(sum(case l.ordered_unit when 'kg' then l.ordered_qty when 'g' then l.ordered_qty / 1000 end), 0),
         count(*)
    into kg, n
    from public.weighing_lines l where l.paper_id = p.id;

  insert into public.weighing_postponements
    (created_by, paper_id, customer_name, po_number, company, stage, from_work_date, to_work_date,
     from_delivery_date, to_delivery_date, reason, note, kg_ordered, lines)
  values (auth.uid(), p.id, p.customer_name, p.po_number, p.company, 'delivery', p.work_date, p.work_date,
          p.delivery_date, p_delivery_date, p_reason, nullif(trim(coalesce(p_note, '')), ''), kg, n)
  returning * into rec;

  perform set_config('prosun.postponing', 'on', true);
  update public.weighing_papers set delivery_date = p_delivery_date where id = p.id;
  perform set_config('prosun.postponing', '', true);

  return rec;
end;
$$;

comment on function public.weighing_postpone_delivery(uuid, date, text, text) is
  'Postpones the delivery of a confirmed paper (Confirmed weights › Postpone): new delivery date and '
  'required reason. Middle office and admin. Migration 028.';

revoke all on function public.weighing_postpone_delivery(uuid, date, text, text) from public, anon;
grant execute on function public.weighing_postpone_delivery(uuid, date, text, text) to authenticated, service_role;


-- ----------------------------------------------------------------------------
-- 4. Migration 021's change bell: quiet during a postponement
-- ----------------------------------------------------------------------------
-- Same function as in 021, with one line added at the top.
create or replace function public.weighing_papers_notify_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  label text := public.weighing_paper_label(new.po_number, new.customer_name);
  lines jsonb;
  fields jsonb;
  summary text;
begin
  -- 0. a postponement (027 / 028) sends its own bell, with the reason
  if coalesce(current_setting('prosun.postponing', true), '') = 'on' then
    return null;
  end if;

  -- 1. a confirmed paper reopened for correction
  if old.status = 'confirmed' and new.status <> 'confirmed' then
    perform public.notify_admins('weighing_reopened',
      'Confirmed paper reopened for correction — ' || label,
      'Confirmed ' || to_char(old.confirmed_at at time zone 'Asia/Bangkok', 'DD/MM HH24:MI')
        || coalesce(' by ' || (select full_name from public.profiles where id = old.confirmed_by), '')
        || '. It is out of the accounting table until it is confirmed again.',
      jsonb_build_object('confirmed', new.reopened_snapshot),
      new.id, new.work_date);

  -- 2. confirmed again after a reopen: what changed
  elsif new.status = 'confirmed' and old.status <> 'confirmed' and old.reopened_snapshot is not null then
    lines  := public.weighing_lines_diff(old.reopened_snapshot, new.id);
    fields := public.weighing_fields_diff(old.reopened_snapshot,
                jsonb_build_object('po_number', new.po_number, 'customer_name', new.customer_name,
                                   'company', new.company, 'delivery_date', new.delivery_date));
    summary := public.weighing_diff_text(lines, fields);
    if summary is null then
      perform public.notify_admins('weighing_reconfirmed',
        'Re-confirmed without changes — ' || label,
        'The weights are the same as before the correction.',
        jsonb_build_object('before', old.reopened_snapshot, 'lines', lines, 'fields', fields),
        new.id, new.work_date);
    else
      perform public.notify_admins('weighing_changed',
        'Confirmed weights changed — ' || label,
        summary,
        jsonb_build_object('before', old.reopened_snapshot, 'after', public.weighing_paper_snapshot(new.id),
                           'lines', lines, 'fields', fields),
        new.id, new.work_date);
    end if;

  -- 3. printed fields of a confirmed paper changed without reopening it
  elsif old.status = 'confirmed' and new.status = 'confirmed' then
    fields := public.weighing_fields_diff(
                jsonb_build_object('po_number', old.po_number, 'customer_name', old.customer_name,
                                   'company', old.company, 'delivery_date', old.delivery_date),
                jsonb_build_object('po_number', new.po_number, 'customer_name', new.customer_name,
                                   'company', new.company, 'delivery_date', new.delivery_date));
    if jsonb_array_length(fields) > 0 then
      perform public.notify_admins('weighing_changed',
        'Confirmed paper changed — ' || label,
        public.weighing_diff_text('[]'::jsonb, fields),
        jsonb_build_object('lines', '[]'::jsonb, 'fields', fields),
        new.id, new.work_date);
    end if;
  end if;
  return null;
end;
$$;


-- ----------------------------------------------------------------------------
-- 5. Bell: production moves and delivery moves
-- ----------------------------------------------------------------------------
create or replace function public.weighing_postponements_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
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
$$;

revoke all on function public.weighing_postponements_notify() from public, anon, authenticated;


-- ----------------------------------------------------------------------------
-- 6. Dashboard: a delivery move counts as a middle office postponement
-- ----------------------------------------------------------------------------
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
    select case w.stage when 'delivery' then 'middle_office' else 'production' end as source,
           w.customer_name, w.po_number, w.company,
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
  'Postponed-order numbers for PACE › Management (production, Confirmed weights and the register). '
  'Admin only. Migrations 027, 028.';

revoke all on function public.management_postponements(date, date, text) from public, anon;
grant execute on function public.management_postponements(date, date, text) to authenticated, service_role;


-- ----------------------------------------------------------------------------
-- 7. Who sees what (Clément, 11 Nov): every department sees that an order was
--    postponed — "postponed, delivery from … to …" — but only admin (Clément,
--    Khun Jum) and the middle office see the reason and the comment.
-- ----------------------------------------------------------------------------
-- The history table itself is now read only by admin and the middle office.
drop policy if exists "weighing_postponements: read" on public.weighing_postponements;
create policy "weighing_postponements: read"
  on public.weighing_postponements for select to authenticated
  using (public.current_role() in ('admin', 'sale_support'));

-- Everyone else gets the dates through this function; reason and comment come
-- back empty unless the caller is admin or middle office. Accounting and
-- purchasing see only confirmed papers (the ones in their Confirmed weights).
-- p_papers: history of these papers; p_from_work_date: papers postponed away
-- from that production day (the weighing screen's "Postponed from this day").
create or replace function public.weighing_postponement_marks(p_papers uuid[] default null,
                                                              p_from_work_date date default null)
returns table (id uuid, paper_id uuid, stage text, from_work_date date, to_work_date date,
               from_delivery_date date, to_delivery_date date, created_at timestamptz,
               created_by uuid, customer_name text, po_number text, reason text, note text)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  r   text := coalesce(public.current_role(), '');
  why boolean := r in ('admin', 'sale_support');
begin
  if r not in ('admin', 'sale_support', 'factory_admin', 'production', 'accounting', 'purchasing') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if coalesce(array_length(p_papers, 1), 0) > 500 then
    raise exception 'too many papers at once' using errcode = '22023';
  end if;
  return query
    select w.id, w.paper_id, w.stage, w.from_work_date, w.to_work_date,
           w.from_delivery_date, w.to_delivery_date, w.created_at, w.created_by,
           w.customer_name, w.po_number,
           case when why then w.reason end,
           case when why then w.note end
    from public.weighing_postponements w
    left join public.weighing_papers p on p.id = w.paper_id
    where ((p_papers is not null and w.paper_id = any(p_papers))
           or (p_from_work_date is not null and w.from_work_date = p_from_work_date))
      and (r not in ('accounting', 'purchasing') or p.status = 'confirmed')
    order by w.created_at;
end;
$$;

comment on function public.weighing_postponement_marks(uuid[], date) is
  'Postponement dates for the weighing screen and Confirmed weights. Reason and comment only for '
  'admin and sale_support; accounting and purchasing see confirmed papers only. Migration 028.';

revoke all on function public.weighing_postponement_marks(uuid[], date) from public, anon;
grant execute on function public.weighing_postponement_marks(uuid[], date) to authenticated, service_role;
