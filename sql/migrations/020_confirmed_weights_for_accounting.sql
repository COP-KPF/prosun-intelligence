-- ============================================================================
-- Migration 020 — confirmed weights for accounting and purchasing
-- ============================================================================
-- Written 28 Oct 2026. Clément: accounting needs the confirmed actual weights
-- to issue the invoices in Odoo, and purchasing needs them as well.
--
-- What this migration adds
--   1. A new role, accounting. Sees only PROSUN PACE › Accounting ›
--      Confirmed weights — no CRM, no order book, no calculator, no prices.
--      Nothing existing is granted to it (every older policy names its roles).
--   2. weighing_confirmed_lines(from, to) — the summary table: every line of
--      every CONFIRMED working paper whose delivery date (or, when the paper
--      has none, its weighing day) falls in the period, with who confirmed it
--      and when. Read-only, for accounting, purchasing and admin.
--   3. weighing_unconfirmed_count(from, to) — how many papers in the same
--      period are still at the factory (being read or checked), so the
--      reader knows the table is not complete yet.
--   4. The paper photo of a confirmed paper can be opened by the same roles
--      (evidence if a customer disputes a weight). Photos are deleted after
--      4 weeks (Migration 018); the numbers stay.
--
-- Why functions rather than opening the tables: readers get exactly the
-- confirmed lines and the columns needed for invoicing — never a paper that
-- is still being checked, never the raw AI output — and the confirmer's name
-- without opening the profiles table to them. Nobody here can change a
-- weight: correcting one stays with the factory (Migration 018 lock).
--
-- Run order: after 019. Safe to re-run.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. The accounting role
-- ----------------------------------------------------------------------------
alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check
  check (role in ('admin', 'director', 'sales', 'sale_support', 'purchasing',
                  'production', 'factory_admin', 'accounting'));

comment on constraint profiles_role_check on public.profiles is
  'admin = everything; director/sales = CRM; sale_support/purchasing/production '
  '= PACE; factory_admin = weighing photo screen only (Migration 018); '
  'accounting = confirmed weights only (Migration 020).';


-- ----------------------------------------------------------------------------
-- 2. The summary table
-- ----------------------------------------------------------------------------
create or replace function public.weighing_confirmed_lines(p_from date, p_to date)
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
  edited            boolean
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if coalesce(public.current_role(), '') not in ('accounting', 'purchasing', 'admin') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
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
           l.actual_kg, l.edited
    from public.weighing_papers p
    join public.weighing_lines l on l.paper_id = p.id
    left join public.profiles pr on pr.id = p.confirmed_by
    where p.status = 'confirmed'
      and coalesce(p.delivery_date, p.work_date) between p_from and p_to
    order by coalesce(p.delivery_date, p.work_date), p.company nulls last,
             p.customer_name nulls last, p.po_number nulls last, p.id, l.line_no;
end;
$$;

comment on function public.weighing_confirmed_lines(date, date) is
  'Confirmed weighing lines for a period (delivery date, else weighing day). '
  'Read-only summary for accounting (Odoo invoicing), purchasing and admin. Migration 020.';

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
  if coalesce(public.current_role(), '') not in ('accounting', 'purchasing', 'admin') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  select count(*) into n
  from public.weighing_papers p
  where p.status <> 'confirmed'
    and coalesce(p.delivery_date, p.work_date) between p_from and p_to;
  return n;
end;
$$;

comment on function public.weighing_unconfirmed_count(date, date) is
  'Papers in the period not yet confirmed at the factory (not in the summary yet). Migration 020.';

-- Explicit grants (Migrations 004/005): signed-in users may call; the role
-- check inside decides. Never anon.
revoke all on function public.weighing_confirmed_lines(date, date)  from public, anon;
revoke all on function public.weighing_unconfirmed_count(date, date) from public, anon;
grant execute on function public.weighing_confirmed_lines(date, date)  to authenticated, service_role;
grant execute on function public.weighing_unconfirmed_count(date, date) to authenticated, service_role;


-- ----------------------------------------------------------------------------
-- 3. Photos of confirmed papers
-- ----------------------------------------------------------------------------
create or replace function public.weighing_photo_is_confirmed(p_path text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.weighing_papers
                 where photo_path = p_path and status = 'confirmed');
$$;

revoke all on function public.weighing_photo_is_confirmed(text) from public, anon;
grant execute on function public.weighing_photo_is_confirmed(text) to authenticated, service_role;

drop policy if exists "weighing-photos: readers see confirmed" on storage.objects;
create policy "weighing-photos: readers see confirmed"
  on storage.objects for select to authenticated
  using (bucket_id = 'weighing-photos'
         and public.current_role() in ('accounting', 'purchasing')
         and public.weighing_photo_is_confirmed(name));


-- ============================================================================
-- After running — give accounting their accounts
-- ============================================================================
--   1. Authentication > Users > Add user: their email + a password.
--      The trigger creates the profile as 'sales'.
--   2. Then, in the SQL Editor (one line per person):
--
--        update public.profiles p set role = 'accounting', full_name = 'ชื่อ'
--        from auth.users u where p.id = u.id and u.email = 'name@klongphaifarm.com';
--
--   Purchasing staff keep their 'purchasing' role — nothing to change.
--
-- Check:
--   select role, count(*) from public.profiles group by role;
-- ============================================================================
