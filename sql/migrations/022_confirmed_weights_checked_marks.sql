-- ============================================================================
-- Migration 022 — "checked" marks on the confirmed weights + middle office
-- ============================================================================
-- Written 30 Oct 2026. Clément:
--   1. In Confirmed weights, when accounting or purchasing staff click an
--      order, its line changes colour so the team sees what has already been
--      opened / checked.
--   2. The middle office (sale support) gets Confirmed weights too, with the
--      same marks.
--
-- Marks are shared inside a department and separate between departments:
-- when Ann (accounting) opens a paper, her accounting colleagues see it
-- checked — with her name and the time — and purchasing does not. If the
-- factory later reopens and re-confirms that paper (new weights), the mark
-- shows "changed since checked" until someone checks it again.
--
-- Nothing here changes a weight. The marks live in their own table, which is
-- reached only through the two functions below (role checked inside):
--   weighing_mark_checked(paper, dept, checked)
--   weighing_confirmed_lines(from, to, dept)  — the 020 summary + the marks
--
-- Run order: after 021. Safe to re-run.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. The marks
-- ----------------------------------------------------------------------------
create table if not exists public.weighing_paper_checks (
  paper_id            uuid not null references public.weighing_papers(id) on delete cascade,
  dept                text not null check (dept in ('middle_office', 'purchasing', 'accounting')),
  checked_by          uuid references public.profiles(id),
  checked_at          timestamptz not null default now(),
  confirmed_at_seen   timestamptz,     -- the paper's confirmation the mark refers to
  primary key (paper_id, dept)
);

comment on table public.weighing_paper_checks is
  'Per-department "already checked" marks on confirmed weighing papers (Confirmed '
  'weights screen). Reached only through weighing_mark_checked / '
  'weighing_confirmed_lines. Migration 022.';

alter table public.weighing_paper_checks enable row level security;
-- No policies: signed-in users cannot read or write the table directly.
revoke all on public.weighing_paper_checks from anon, authenticated;
grant all on public.weighing_paper_checks to service_role;


-- ----------------------------------------------------------------------------
-- 2. Which department a caller works for
-- ----------------------------------------------------------------------------
-- Staff always act for their own department; admin (who reaches the screen
-- from any of the three menus) acts for the one he opened it from.
create or replace function public.weighing_reader_dept(p_dept text)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  r text := coalesce(public.current_role(), '');
begin
  if r = 'accounting'   then return 'accounting'; end if;
  if r = 'purchasing'   then return 'purchasing'; end if;
  if r = 'sale_support' then return 'middle_office'; end if;
  if r = 'admin' then
    if p_dept in ('middle_office', 'purchasing', 'accounting') then return p_dept; end if;
    return 'accounting';
  end if;
  raise exception 'not allowed' using errcode = '42501';
end;
$$;

revoke all on function public.weighing_reader_dept(text) from public, anon, authenticated;


-- ----------------------------------------------------------------------------
-- 3. The summary, now also for the middle office, with the marks
-- ----------------------------------------------------------------------------
create or replace function public.weighing_confirmed_lines(p_from date, p_to date, p_dept text)
returns table (
  paper_id          uuid,
  work_date         date,
  delivery_date     date,
  company           text,
  po_number         text,
  customer_name     text,
  confirmed_at      timestamptz,
  confirmed_by_name text,
  photo_path        text,
  photo_deleted_at  timestamptz,
  line_id           uuid,
  line_no           int,
  description       text,
  ordered_text      text,
  ordered_qty       numeric,
  ordered_unit      text,
  actual_kg         numeric,
  edited            boolean,
  dept              text,
  checked_at        timestamptz,
  checked_by_name   text,
  check_confirmed_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  d text := public.weighing_reader_dept(p_dept);
begin
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'choose a start and an end date' using errcode = '22023';
  end if;
  if p_to - p_from > 92 then
    raise exception 'choose a period of 3 months or less' using errcode = '22023';
  end if;

  return query
    select p.id, p.work_date, p.delivery_date, p.company, p.po_number, p.customer_name,
           p.confirmed_at, pr.full_name, p.photo_path, p.photo_deleted_at,
           l.id, l.line_no, l.description, l.ordered_text, l.ordered_qty, l.ordered_unit,
           l.actual_kg, l.edited,
           d, c.checked_at, cb.full_name, c.confirmed_at_seen
    from public.weighing_papers p
    join public.weighing_lines l on l.paper_id = p.id
    left join public.profiles pr on pr.id = p.confirmed_by
    left join public.weighing_paper_checks c on c.paper_id = p.id and c.dept = d
    left join public.profiles cb on cb.id = c.checked_by
    where p.status = 'confirmed'
      and coalesce(p.delivery_date, p.work_date) between p_from and p_to
    order by coalesce(p.delivery_date, p.work_date), p.company nulls last,
             p.customer_name nulls last, p.po_number nulls last, p.id, l.line_no;
end;
$$;

comment on function public.weighing_confirmed_lines(date, date, text) is
  'Confirmed weighing lines for a period, with the caller''s department "checked" '
  'marks. Accounting, purchasing, middle office (sale_support) and admin. Migration 022.';

-- The 020 version (no department) stays for any browser still on the old
-- page until it reloads; it now also admits the middle office.
create or replace function public.weighing_confirmed_lines(p_from date, p_to date)
returns table (
  paper_id uuid, work_date date, delivery_date date, company text, po_number text,
  customer_name text, confirmed_at timestamptz, confirmed_by_name text, photo_path text,
  photo_deleted_at timestamptz, line_id uuid, line_no int, description text,
  ordered_text text, ordered_qty numeric, ordered_unit text, actual_kg numeric, edited boolean
)
language sql
stable
security definer
set search_path = public
as $$
  select x.paper_id, x.work_date, x.delivery_date, x.company, x.po_number, x.customer_name,
         x.confirmed_at, x.confirmed_by_name, x.photo_path, x.photo_deleted_at, x.line_id,
         x.line_no, x.description, x.ordered_text, x.ordered_qty, x.ordered_unit, x.actual_kg, x.edited
  from public.weighing_confirmed_lines(p_from, p_to, null) x;
$$;

create or replace function public.weighing_unconfirmed_count(p_from date, p_to date)
returns integer
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  n integer;
begin
  if coalesce(public.current_role(), '') not in ('accounting', 'purchasing', 'sale_support', 'admin') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  select count(*) into n
  from public.weighing_papers p
  where p.status <> 'confirmed'
    and coalesce(p.delivery_date, p.work_date) between p_from and p_to;
  return n;
end;
$$;


-- ----------------------------------------------------------------------------
-- 4. Marking a paper checked (or unchecked)
-- ----------------------------------------------------------------------------
create or replace function public.weighing_mark_checked(p_paper uuid, p_dept text, p_checked boolean)
returns table (dept text, checked_at timestamptz, checked_by_name text, check_confirmed_at timestamptz)
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  d text := public.weighing_reader_dept(p_dept);
  conf timestamptz;
begin
  select p.confirmed_at into conf from public.weighing_papers p
  where p.id = p_paper and p.status = 'confirmed';
  if not found then
    raise exception 'this paper is not confirmed (any more)' using errcode = '22023';
  end if;

  if p_checked then
    insert into public.weighing_paper_checks (paper_id, dept, checked_by, checked_at, confirmed_at_seen)
    values (p_paper, d, auth.uid(), now(), conf)
    on conflict on constraint weighing_paper_checks_pkey do update
      set checked_by = excluded.checked_by, checked_at = excluded.checked_at,
          confirmed_at_seen = excluded.confirmed_at_seen;
  else
    delete from public.weighing_paper_checks c where c.paper_id = p_paper and c.dept = d;
  end if;

  return query
    select d, c.checked_at, pr.full_name, c.confirmed_at_seen
    from (select 1) one
    left join public.weighing_paper_checks c on c.paper_id = p_paper and c.dept = d
    left join public.profiles pr on pr.id = c.checked_by;
end;
$$;

comment on function public.weighing_mark_checked(uuid, text, boolean) is
  'Marks a confirmed paper as checked (or not) for the caller''s department. Migration 022.';

revoke all on function public.weighing_confirmed_lines(date, date, text) from public, anon;
revoke all on function public.weighing_confirmed_lines(date, date)       from public, anon;
revoke all on function public.weighing_unconfirmed_count(date, date)     from public, anon;
revoke all on function public.weighing_mark_checked(uuid, text, boolean) from public, anon;
grant execute on function public.weighing_confirmed_lines(date, date, text) to authenticated, service_role;
grant execute on function public.weighing_confirmed_lines(date, date)       to authenticated, service_role;
grant execute on function public.weighing_unconfirmed_count(date, date)     to authenticated, service_role;
grant execute on function public.weighing_mark_checked(uuid, text, boolean) to authenticated, service_role;


-- ----------------------------------------------------------------------------
-- 5. Photos of confirmed papers: middle office too
-- ----------------------------------------------------------------------------
drop policy if exists "weighing-photos: readers see confirmed" on storage.objects;
create policy "weighing-photos: readers see confirmed"
  on storage.objects for select to authenticated
  using (bucket_id = 'weighing-photos'
         and public.current_role() in ('accounting', 'purchasing', 'sale_support')
         and public.weighing_photo_is_confirmed(name));
