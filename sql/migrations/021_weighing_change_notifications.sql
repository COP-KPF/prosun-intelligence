-- ============================================================================
-- Migration 021 — notify management when confirmed weights change
-- ============================================================================
-- Written 29 Oct 2026. Clément: changes to the weighing are made by the
-- production team only, and every change must send him a notification in his
-- interface. Agreed scope (29 Oct): normal checking before a paper is
-- confirmed stays silent (Khun Muay corrects the AI's numbers on 50–70 papers
-- a day); what notifies is
--   1. a CONFIRMED paper reopened for correction ("แก้ไข" on the weighing
--      screen) — it leaves the accounting table until confirmed again;
--   2. that paper confirmed again — with every weight BEFORE → AFTER, and the
--      printed fields (PO, customer, company, delivery date) that changed;
--   3. a confirmed paper's printed fields changed without reopening it;
--   4. ANY paper deleted — with what it contained.
-- Admin keeps full access to the weighing screen (Clément's choice); a change
-- made by an admin does not notify that same admin.
--
-- How
--   - weighing_papers gets reopened_snapshot / reopened_at / reopened_by: when
--     a confirmed paper is reopened, its confirmed state (fields + every line)
--     is copied there, so the re-confirmation can be compared with it.
--   - notifications: one row per recipient (every admin). Written only by the
--     database triggers below (security definer) — nobody can insert or fake
--     one from the app; a recipient can only read their own and mark them read.
--   - Live: the table is added to realtime, so the bell updates at once.
--
-- Run order: after 020. Safe to re-run.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Where the confirmed state is kept while a paper is reopened
-- ----------------------------------------------------------------------------
alter table public.weighing_papers add column if not exists reopened_snapshot jsonb;
alter table public.weighing_papers add column if not exists reopened_at timestamptz;
alter table public.weighing_papers add column if not exists reopened_by uuid references public.profiles(id);

comment on column public.weighing_papers.reopened_snapshot is
  'Set when a confirmed paper is reopened for correction: the confirmed fields '
  'and lines, compared with the new values when it is confirmed again (then '
  'cleared). Migration 021.';


-- ----------------------------------------------------------------------------
-- 2. Notifications
-- ----------------------------------------------------------------------------
create table if not exists public.notifications (
  id          uuid primary key default gen_random_uuid(),
  created_at  timestamptz not null default now(),
  recipient   uuid not null references public.profiles(id) on delete cascade,
  kind        text not null,      -- weighing_reopened | weighing_changed | weighing_reconfirmed | weighing_deleted
  title       text not null,
  body        text,
  details     jsonb,
  paper_id    uuid,               -- no foreign key: the paper may have been deleted
  work_date   date,
  actor       uuid,
  actor_name  text,
  read_at     timestamptz
);

create index if not exists notifications_recipient_idx on public.notifications (recipient, created_at desc);

comment on table public.notifications is
  'In-app notifications (bell in the header). Written by database triggers only. Migration 021.';

alter table public.notifications enable row level security;

drop policy if exists "notifications: read own" on public.notifications;
create policy "notifications: read own"
  on public.notifications for select to authenticated
  using (recipient = auth.uid());

drop policy if exists "notifications: mark own read" on public.notifications;
create policy "notifications: mark own read"
  on public.notifications for update to authenticated
  using (recipient = auth.uid())
  with check (recipient = auth.uid());

-- Explicit grants: read, and change read_at only. No insert, no delete.
revoke all on public.notifications from anon, authenticated;
grant select on public.notifications to authenticated;
grant update (read_at) on public.notifications to authenticated;
grant all on public.notifications to service_role;


-- ----------------------------------------------------------------------------
-- 3. Helpers (internal — not callable from the app)
-- ----------------------------------------------------------------------------
create or replace function public.weighing_paper_snapshot(p_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'company', p.company, 'po_number', p.po_number, 'customer_name', p.customer_name,
    'delivery_date', p.delivery_date, 'work_date', p.work_date, 'status', p.status,
    'confirmed_at', p.confirmed_at, 'confirmed_by', p.confirmed_by,
    'confirmed_by_name', (select full_name from public.profiles where id = p.confirmed_by),
    'lines', coalesce((
      select jsonb_agg(jsonb_build_object('line_no', l.line_no, 'description', l.description,
                                          'ordered_text', l.ordered_text, 'actual_kg', l.actual_kg)
                       order by l.line_no)
      from public.weighing_lines l where l.paper_id = p.id), '[]'::jsonb))
  from public.weighing_papers p where p.id = p_id;
$$;

-- "PO 69-131003 · Le Bua" — how a paper is named in a notification
create or replace function public.weighing_paper_label(p_po text, p_customer text)
returns text
language sql
immutable
as $$
  select coalesce(nullif(concat_ws(' · ', 'PO ' || nullif(p_po, ''), nullif(p_customer, '')), ''), 'paper without PO');
$$;

create or replace function public.weighing_fmt_kg(v numeric)
returns text
language sql
immutable
as $$
  select case when v is null then '—' else to_char(v, 'FM999990.00') end;
$$;

-- Line-by-line comparison of a snapshot with the paper's lines now. Lines are
-- matched by their number on the paper (a re-read renumbers from 1, so ids
-- would not survive it).
create or replace function public.weighing_lines_diff(p_before jsonb, p_paper uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with b as (
    select (e->>'line_no')::int as n, e->>'description' as d, (e->>'actual_kg')::numeric as kg
    from jsonb_array_elements(coalesce(p_before->'lines', '[]'::jsonb)) e
  ), a as (
    select line_no as n, description as d, actual_kg as kg
    from public.weighing_lines where paper_id = p_paper
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'line_no', coalesce(a.n, b.n),
           'description', coalesce(a.d, b.d),
           'description_before', case when a.n is not null and b.n is not null and a.d is distinct from b.d then b.d end,
           'before_kg', b.kg, 'after_kg', a.kg,
           'change', case when b.n is null then 'added' when a.n is null then 'removed' else 'changed' end)
         order by coalesce(a.n, b.n)), '[]'::jsonb)
  from b full join a on a.n = b.n
  where b.n is null or a.n is null or a.kg is distinct from b.kg or a.d is distinct from b.d;
$$;

-- Printed fields that differ between a snapshot (or the old row) and now
create or replace function public.weighing_fields_diff(p_before jsonb, p_after jsonb)
returns jsonb
language sql
immutable
as $$
  select coalesce(jsonb_agg(jsonb_build_object('field', f, 'before', p_before->>f, 'after', p_after->>f)), '[]'::jsonb)
  from unnest(array['po_number', 'customer_name', 'company', 'delivery_date']) as f
  where (p_before->>f) is distinct from (p_after->>f);
$$;

-- One readable sentence for the notification list
create or replace function public.weighing_diff_text(p_lines jsonb, p_fields jsonb)
returns text
language sql
immutable
as $$
  select nullif(concat_ws('; ',
    (select string_agg(
       case e->>'change'
         when 'added'   then 'added: ' || coalesce(nullif(e->>'description', ''), 'line ' || (e->>'line_no')) || ' ' || public.weighing_fmt_kg((e->>'after_kg')::numeric) || ' kg'
         when 'removed' then 'removed: ' || coalesce(nullif(e->>'description', ''), 'line ' || (e->>'line_no')) || ' ' || public.weighing_fmt_kg((e->>'before_kg')::numeric) || ' kg'
         else coalesce(nullif(e->>'description', ''), 'line ' || (e->>'line_no')) || ' '
              || public.weighing_fmt_kg((e->>'before_kg')::numeric) || ' → ' || public.weighing_fmt_kg((e->>'after_kg')::numeric) || ' kg'
       end, '; ' order by (e->>'line_no')::int)
     from jsonb_array_elements(p_lines) e),
    (select string_agg(
       case e->>'field' when 'po_number' then 'PO' when 'customer_name' then 'customer'
                        when 'delivery_date' then 'delivery date' else e->>'field' end
       || ' ' || coalesce(e->>'before', '—') || ' → ' || coalesce(e->>'after', '—'), '; ')
     from jsonb_array_elements(p_fields) e)
  ), '');
$$;

-- Sends one notification to every admin except the person who made the change.
create or replace function public.notify_admins(p_kind text, p_title text, p_body text,
                                                p_details jsonb, p_paper uuid, p_work_date date)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  who uuid := auth.uid();
  who_name text;
begin
  select full_name into who_name from public.profiles where id = who;
  insert into public.notifications (recipient, kind, title, body, details, paper_id, work_date, actor, actor_name)
  select pr.id, p_kind, p_title, p_body, p_details, p_paper, p_work_date, who, who_name
  from public.profiles pr
  where pr.role = 'admin' and pr.id is distinct from who;
end;
$$;

revoke all on function public.weighing_paper_snapshot(uuid)            from public, anon, authenticated;
revoke all on function public.weighing_lines_diff(jsonb, uuid)         from public, anon, authenticated;
revoke all on function public.notify_admins(text, text, text, jsonb, uuid, date) from public, anon, authenticated;


-- ----------------------------------------------------------------------------
-- 4. Triggers on weighing_papers
-- ----------------------------------------------------------------------------
-- Before the row changes: keep the confirmed state when a paper is reopened;
-- clear it when the paper is confirmed again.
create or replace function public.weighing_papers_reopen_snapshot()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if old.status = 'confirmed' and new.status <> 'confirmed' then
    new.reopened_snapshot := public.weighing_paper_snapshot(old.id);
    new.reopened_at := now();
    new.reopened_by := auth.uid();
  elsif new.status = 'confirmed' and old.status <> 'confirmed' then
    new.reopened_snapshot := null;
    new.reopened_at := null;
    new.reopened_by := null;
  end if;
  return new;
end;
$$;

drop trigger if exists weighing_papers_reopen_snapshot on public.weighing_papers;
create trigger weighing_papers_reopen_snapshot
  before update on public.weighing_papers
  for each row execute function public.weighing_papers_reopen_snapshot();

-- After the row changed: tell management.
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

drop trigger if exists weighing_papers_notify_change on public.weighing_papers;
create trigger weighing_papers_notify_change
  after update on public.weighing_papers
  for each row execute function public.weighing_papers_notify_change();

-- Before a paper is deleted (its lines still exist at that moment): record
-- what it contained. If the delete fails, the notification is rolled back too.
create or replace function public.weighing_papers_notify_delete()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  snap jsonb := public.weighing_paper_snapshot(old.id);
  n int := jsonb_array_length(snap->'lines');
  total numeric;
  confirmed_before boolean := old.status = 'confirmed' or old.reopened_snapshot is not null;
begin
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

drop trigger if exists weighing_papers_notify_delete on public.weighing_papers;
create trigger weighing_papers_notify_delete
  before delete on public.weighing_papers
  for each row execute function public.weighing_papers_notify_delete();


-- ----------------------------------------------------------------------------
-- 5. Live updates for the bell
-- ----------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    raise notice 'supabase_realtime publication not found — skipping';
    return;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime'
                 and schemaname = 'public' and tablename = 'notifications') then
    alter publication supabase_realtime add table public.notifications;
  end if;
end $$;


-- ============================================================================
-- Check after running:
--   select count(*) from public.notifications;   -- 0 until something changes
-- ============================================================================
