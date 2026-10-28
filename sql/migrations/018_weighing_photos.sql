-- ============================================================================
-- Migration 018 — weighing photo app (production work interface)
-- ============================================================================
-- Written 13 Oct 2026.
--
-- The factory writes the actual weight of each line by hand in the empty
-- "kg." column of the FM-SA-01 working paper (ใบสั่งงาน). Today that number
-- only exists on paper. Khun Muay (factory admin) will photograph the filled
-- papers; an AI vision model reads each photo server side (Supabase edge
-- function `weighing`, so the API key never reaches a browser); she checks
-- every number against the photo and confirms. Result: one table per day,
-- exportable to Excel.
--
-- What this migration adds
--   1. A new role, factory_admin. Sees only the weighing screen — no CRM,
--      no order book, no prices. Nothing existing is granted to it.
--   2. weighing_capture_links — the QR code on the PC screen. Scanning it
--      opens the phone camera page for that day without logging in on the
--      phone. A link only lets the phone ADD photos (through the edge
--      function); it reads nothing. Expires at midnight Bangkok time and
--      can be replaced from the PC ("สร้างใหม่"), which revokes the old one.
--   3. weighing_papers — one row per photographed paper: the photo, what was
--      read from its printed part (company, PO no., customer, delivery date),
--      reading status, and who confirmed it when.
--   4. weighing_lines — one row per product line on the paper: ordered
--      quantity and unit as printed, every handwritten value read in the kg.
--      column (several are kept separately and summed), the actual kg, and
--      whether the person checked it against the photo.
--   5. A private storage bucket for the photos.
--   6. An audit trail (activity_log) on both tables, because these weights
--      feed invoicing: every edit, confirmation and deletion is recorded.
--
-- Access (v1): factory_admin and admin only. Sale support, purchasing,
-- production and the CRM side read nothing here. Widening read access later
-- (e.g. sale support for invoicing) is one extra policy per table.
--
-- Lock: once a paper is confirmed its lines cannot change. To correct one,
-- the paper is first set back to "read" ("แก้ไข" on the screen) — that step
-- is itself logged.
--
-- Photos are kept 4 weeks (free-plan storage), then deleted automatically by
-- the edge function; the numbers stay.
--
-- Run order: after 017. Safe to re-run. Staging first, then production.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. The factory_admin role
-- ----------------------------------------------------------------------------
alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check
  check (role in ('admin', 'director', 'sales', 'sale_support', 'purchasing',
                  'production', 'factory_admin'));

comment on constraint profiles_role_check on public.profiles is
  'admin = everything; director/sales = CRM; sale_support/purchasing/production '
  '= PACE; factory_admin = weighing photo screen only (Migration 018).';


-- ----------------------------------------------------------------------------
-- 2. Tables
-- ----------------------------------------------------------------------------
create table if not exists public.weighing_capture_links (
  token       uuid primary key default gen_random_uuid(),
  work_date   date not null,
  created_by  uuid not null references public.profiles(id),
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null,
  revoked     boolean not null default false
);

comment on table public.weighing_capture_links is
  'QR codes shown on the PC weighing screen. Each lets a phone add photos for '
  'one work day until expires_at, via the weighing edge function only.';

create table if not exists public.weighing_papers (
  id             uuid primary key default gen_random_uuid(),
  work_date      date not null default ((now() at time zone 'Asia/Bangkok')::date),
  photo_path     text not null,
  status         text not null default 'uploading'
                   check (status in ('uploading', 'queued', 'reading', 'read', 'failed', 'confirmed')),
  uploaded_by    uuid references public.profiles(id),
  capture_token  uuid references public.weighing_capture_links(token) on delete set null,
  uploaded_at    timestamptz not null default now(),

  -- What the reading returned, kept whole so a disputed number can be traced
  -- back to exactly what the model said.
  read_started_at timestamptz,
  read_at        timestamptz,
  read_model     text,
  read_error     text,
  read_result    jsonb,

  -- The printed part of the paper (editable on the check screen).
  company        text check (company in ('Prosun Farm', 'Prosun Food')),
  po_number      text,
  customer_name  text,
  delivery_date  date,
  note           text,

  confirmed_by   uuid references public.profiles(id),
  confirmed_at   timestamptz,
  updated_at     timestamptz not null default now()
);

create index if not exists weighing_papers_work_date_idx on public.weighing_papers (work_date);
create index if not exists weighing_papers_po_idx        on public.weighing_papers (po_number);

-- Photo clean-up (Clément, 13 Oct 2026: stay on the Supabase free plan, 1 GB
-- storage). At 50–70 papers a day the photos add ~0.5–0.7 GB a month, so the
-- `weighing` function deletes photos older than 4 weeks. The paper, its lines
-- and the confirmed weights are kept forever; only the picture goes, and this
-- column records when.
alter table public.weighing_papers add column if not exists photo_deleted_at timestamptz;

comment on table public.weighing_papers is
  'One photographed FM-SA-01 working paper. work_date = the day it was '
  'photographed (Bangkok); the day table on the weighing screen is one work_date.';

create table if not exists public.weighing_lines (
  id               uuid primary key default gen_random_uuid(),
  paper_id         uuid not null references public.weighing_papers(id) on delete cascade,
  line_no          int not null,
  description      text not null default '',
  ordered_text     text,               -- as printed, e.g. "12 ตัว", "5 Kg"
  ordered_qty      numeric,
  ordered_unit     text,               -- normalised: kg / pcs / pack / jar / g / other
  weights          numeric[] not null default '{}',  -- each handwritten value read
  handwritten_text text,               -- the kg. cell as read, e.g. "4.2 + 5.9"
  actual_kg        numeric,            -- what goes in the table (sum of weights, or as corrected)
  confidence       text check (confidence in ('high', 'medium', 'low')),
  flag_reason      text,               -- why the person must look at the photo; null = clear
  checked          boolean not null default false,
  edited           boolean not null default false,  -- changed by hand from what was read
  updated_at       timestamptz not null default now()
);

create index if not exists weighing_lines_paper_idx on public.weighing_lines (paper_id, line_no);

comment on column public.weighing_lines.weights is
  'Every value read in the kg. column for this line. Several values (per bag '
  'or tray) are kept separately; actual_kg is their sum unless corrected.';

drop trigger if exists weighing_papers_set_updated_at on public.weighing_papers;
create trigger weighing_papers_set_updated_at
  before update on public.weighing_papers
  for each row execute function public.set_updated_at();

drop trigger if exists weighing_lines_set_updated_at on public.weighing_lines;
create trigger weighing_lines_set_updated_at
  before update on public.weighing_lines
  for each row execute function public.set_updated_at();


-- ----------------------------------------------------------------------------
-- 3. Lock confirmed papers' lines, in the database
-- ----------------------------------------------------------------------------
-- RLS below already refuses line writes on a confirmed paper for signed-in
-- users. This trigger also covers the service role (the edge function), so a
-- late re-read can never overwrite numbers someone has confirmed.
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
  if st = 'confirmed' then
    raise exception 'weighing paper % is confirmed — set it back to read before changing its lines',
      coalesce(new.paper_id, old.paper_id)
      using errcode = '42501';
  end if;
  return coalesce(new, old);
end;
$$;

drop trigger if exists weighing_lines_guard on public.weighing_lines;
create trigger weighing_lines_guard
  before insert or update or delete on public.weighing_lines
  for each row execute function public.weighing_lines_guard();

-- Confirming stamps who and when from the session itself, so the record
-- cannot be confirmed in someone else's name.
create or replace function public.weighing_papers_confirm_stamp()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.status = 'confirmed' and old.status is distinct from 'confirmed' then
    if auth.uid() is not null then
      new.confirmed_by := auth.uid();
    end if;
    new.confirmed_at := now();
  elsif new.status <> 'confirmed' and old.status = 'confirmed' then
    new.confirmed_by := null;
    new.confirmed_at := null;
  end if;
  return new;
end;
$$;

drop trigger if exists weighing_papers_confirm_stamp on public.weighing_papers;
create trigger weighing_papers_confirm_stamp
  before update on public.weighing_papers
  for each row execute function public.weighing_papers_confirm_stamp();


-- ----------------------------------------------------------------------------
-- 4. Audit trail
-- ----------------------------------------------------------------------------
create or replace function public.log_weighing_activity()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.activity_log (table_name, record_id, user_id, action, details)
  values (
    tg_table_name,
    coalesce(new.id, old.id),
    auth.uid(),
    tg_op,
    case tg_op when 'DELETE' then to_jsonb(old) else to_jsonb(new) end
  );
  return coalesce(new, old);
end;
$$;

drop trigger if exists weighing_papers_log_activity on public.weighing_papers;
create trigger weighing_papers_log_activity
  after insert or update or delete on public.weighing_papers
  for each row execute function public.log_weighing_activity();

drop trigger if exists weighing_lines_log_activity on public.weighing_lines;
create trigger weighing_lines_log_activity
  after insert or update or delete on public.weighing_lines
  for each row execute function public.log_weighing_activity();


-- ----------------------------------------------------------------------------
-- 5. Row Level Security
-- ----------------------------------------------------------------------------
alter table public.weighing_capture_links enable row level security;
alter table public.weighing_papers        enable row level security;
alter table public.weighing_lines         enable row level security;

-- capture links: the creator manages their own; admin sees all.
drop policy if exists "weighing_capture_links: own" on public.weighing_capture_links;
create policy "weighing_capture_links: own"
  on public.weighing_capture_links for all
  using (public.current_role() in ('factory_admin', 'admin') and created_by = auth.uid())
  with check (public.current_role() in ('factory_admin', 'admin') and created_by = auth.uid());

drop policy if exists "weighing_capture_links: admin reads" on public.weighing_capture_links;
create policy "weighing_capture_links: admin reads"
  on public.weighing_capture_links for select
  using (public.current_role() = 'admin');

-- papers
drop policy if exists "weighing_papers: read" on public.weighing_papers;
create policy "weighing_papers: read"
  on public.weighing_papers for select
  using (public.current_role() in ('factory_admin', 'admin'));

drop policy if exists "weighing_papers: insert" on public.weighing_papers;
create policy "weighing_papers: insert"
  on public.weighing_papers for insert
  with check (public.current_role() in ('factory_admin', 'admin') and uploaded_by = auth.uid());

drop policy if exists "weighing_papers: update" on public.weighing_papers;
create policy "weighing_papers: update"
  on public.weighing_papers for update
  using (public.current_role() in ('factory_admin', 'admin'))
  with check (public.current_role() in ('factory_admin', 'admin'));

-- A wrong or duplicate photo can be removed until it is confirmed; after
-- that only admin can delete (it has fed a number someone may have used).
drop policy if exists "weighing_papers: delete" on public.weighing_papers;
create policy "weighing_papers: delete"
  on public.weighing_papers for delete
  using (public.current_role() = 'admin'
         or (public.current_role() = 'factory_admin' and status <> 'confirmed'));

-- lines
drop policy if exists "weighing_lines: read" on public.weighing_lines;
create policy "weighing_lines: read"
  on public.weighing_lines for select
  using (public.current_role() in ('factory_admin', 'admin'));

drop policy if exists "weighing_lines: write" on public.weighing_lines;
create policy "weighing_lines: write"
  on public.weighing_lines for all
  using (public.current_role() in ('factory_admin', 'admin'))
  with check (public.current_role() in ('factory_admin', 'admin'));

-- factory_admin needs to read its own profile row to sign in — that is the
-- existing "profiles: read own row" policy; nothing more is opened.


-- ----------------------------------------------------------------------------
-- 6. Grants (explicit, per the lesson of Migrations 004/005)
-- ----------------------------------------------------------------------------
grant select, insert, update, delete on public.weighing_capture_links to authenticated, service_role;
grant select, insert, update, delete on public.weighing_papers        to authenticated, service_role;
grant select, insert, update, delete on public.weighing_lines         to authenticated, service_role;
revoke all on public.weighing_capture_links from anon;
revoke all on public.weighing_papers        from anon;
revoke all on public.weighing_lines         from anon;


-- ----------------------------------------------------------------------------
-- 7. Photo storage — private bucket
-- ----------------------------------------------------------------------------
-- Photos are resized on the phone before upload (longest side 2000 px, JPEG),
-- so 10 MB is a generous ceiling. Path: <work_date>/<paper id>.jpg
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('weighing-photos', 'weighing-photos', false, 10485760,
        array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "weighing-photos: read" on storage.objects;
create policy "weighing-photos: read"
  on storage.objects for select to authenticated
  using (bucket_id = 'weighing-photos'
         and public.current_role() in ('factory_admin', 'admin'));

drop policy if exists "weighing-photos: upload" on storage.objects;
create policy "weighing-photos: upload"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'weighing-photos'
              and public.current_role() in ('factory_admin', 'admin'));

drop policy if exists "weighing-photos: delete" on storage.objects;
create policy "weighing-photos: delete"
  on storage.objects for delete to authenticated
  using (bucket_id = 'weighing-photos'
         and public.current_role() in ('factory_admin', 'admin'));


-- ----------------------------------------------------------------------------
-- 8. Live updates on the PC screen
-- ----------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    raise notice 'supabase_realtime publication not found — skipping';
    return;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime'
                 and schemaname = 'public' and tablename = 'weighing_papers') then
    alter publication supabase_realtime add table public.weighing_papers;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime'
                 and schemaname = 'public' and tablename = 'weighing_lines') then
    alter publication supabase_realtime add table public.weighing_lines;
  end if;
end $$;

alter table public.weighing_papers replica identity full;
alter table public.weighing_lines  replica identity full;


-- ============================================================================
-- After running — give Khun Muay her account
-- ============================================================================
--   1. Authentication > Users > Add user: her email + a password
--      (e.g. muay@klongphaifarm.com). The trigger creates her profile as 'sales'.
--   2. Then, in the SQL Editor:
--
--        update public.profiles p set role = 'factory_admin', full_name = 'คุณหมวย'
--        from auth.users u where p.id = u.id and u.email = 'muay@klongphaifarm.com';
--
-- Check:
--   select tablename from pg_publication_tables
--   where pubname = 'supabase_realtime' and tablename like 'weighing%';
--   -- expect weighing_papers, weighing_lines
--   select id, public from storage.buckets where id = 'weighing-photos';
--   -- expect public = false
-- ============================================================================
