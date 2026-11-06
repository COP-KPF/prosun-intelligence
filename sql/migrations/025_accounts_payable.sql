-- ============================================================================
-- Migration 025 — accounts payable: scan, review, select, approve, pay
-- ============================================================================
-- Written 6 Nov 2026. Clément: accounting scans each bill so it is online at
-- once; Khun Ann reviews; Khun Kirana selects the payments she would like to
-- make; Clément gives the last approval before payment; Khun Kirana pays and
-- records it. A summary shows what is owed to whom.
--
--   read        accounting checks what was read from the scan
--   submitted   waiting for Khun Ann's review
--   reviewed    can be selected for payment
--   proposed    selected by Khun Kirana, waiting for Clément
--   approved    Clément approved, waiting for payment
--   paid        Khun Kirana recorded the payment
--   returned    sent back to accounting with a comment
--   void        cancelled with a reason (never deleted)
--
-- Controls, all enforced here rather than on the screen:
--   * Who may do what comes from payable_permissions, not from profiles.role.
--     Khun Kirana and Clément are both 'admin', so a role could not separate
--     selecting and paying from approving. Nobody can change that table from
--     the app — only from the Supabase SQL editor.
--   * Status moves only through the functions below, and only along the
--     transitions allowed by payables_guard (which also binds the edge
--     function's service role).
--   * Amounts, supplier and references are locked from submission onward.
--     Correcting one means returning the bill to accounting, which cancels
--     any review, selection or approval: it goes through every step again.
--   * The person who approved a bill cannot record its payment.
--   * The approval checks the total the approver saw, so a stale screen cannot
--     approve a different amount.
--   * The same document number cannot be submitted twice for one company.
--   * Rows are never deleted; every step is in payable_events and activity_log.
--
-- Scans are kept (no automatic deletion, unlike the weighing photos): these
-- are accounting records. They use the same 1 GB free-plan storage.
--
-- Run order: after 024. Safe to re-run.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Permissions
-- ----------------------------------------------------------------------------
create table if not exists public.payable_permissions (
  user_id     uuid primary key references public.profiles(id) on delete cascade,
  can_review  boolean not null default false,
  can_select  boolean not null default false,
  can_approve boolean not null default false,
  can_pay     boolean not null default false,
  updated_at  timestamptz not null default now()
);

comment on table public.payable_permissions is
  'Who may review, select, approve and pay payables. Changed only from the '
  'Supabase SQL editor; no one can reach it from the app. Migration 025.';

alter table public.payable_permissions enable row level security;
revoke all on public.payable_permissions from public, anon, authenticated;
grant all on public.payable_permissions to service_role;

insert into public.payable_permissions (user_id, can_review, can_select, can_approve, can_pay)
select u.id,
       lower(u.email) = 'ann@klongphaifarm.com',
       lower(u.email) = 'kirana@klongphaifarm.com',
       lower(u.email) = 'clement@klongphaifarm.com',
       lower(u.email) = 'kirana@klongphaifarm.com'
from auth.users u
join public.profiles p on p.id = u.id
where lower(u.email) in ('ann@klongphaifarm.com', 'kirana@klongphaifarm.com', 'clement@klongphaifarm.com')
on conflict (user_id) do nothing;

create or replace function public.payable_can(p_what text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((
    select case p_what
             when 'review'  then can_review
             when 'select'  then can_select
             when 'approve' then can_approve
             when 'pay'     then can_pay
             else false end
    from public.payable_permissions where user_id = auth.uid()), false);
$$;
revoke all on function public.payable_can(text) from public, anon, authenticated;
grant execute on function public.payable_can(text) to authenticated, service_role;

create or replace function public.payable_my_permissions()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'read',    public.current_role() in ('accounting', 'admin'),
    'scan',    public.current_role() = 'accounting',
    'review',  public.payable_can('review'),
    'select',  public.payable_can('select'),
    'approve', public.payable_can('approve'),
    'pay',     public.payable_can('pay'));
$$;
revoke all on function public.payable_my_permissions() from public, anon;
grant execute on function public.payable_my_permissions() to authenticated;


-- ----------------------------------------------------------------------------
-- 2. Tables
-- ----------------------------------------------------------------------------
create table if not exists public.payable_capture_links (
  token       uuid primary key default gen_random_uuid(),
  created_by  uuid not null references public.profiles(id),
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null,
  revoked     boolean not null default false
);

comment on table public.payable_capture_links is
  'QR codes on the accounting screen. Each lets a phone add scans until '
  'expires_at, through the payables edge function only. It reads nothing back.';

create table if not exists public.payables (
  id              uuid primary key default gen_random_uuid(),
  status          text not null default 'uploading'
                    check (status in ('uploading', 'queued', 'reading', 'read', 'failed', 'submitted',
                                      'reviewed', 'proposed', 'approved', 'paid', 'returned', 'void')),

  -- The scan
  file_path       text not null,
  file_type       text not null default 'image/jpeg',
  uploaded_at     timestamptz not null default now(),
  uploaded_by     uuid references public.profiles(id),
  capture_token   uuid references public.payable_capture_links(token) on delete set null,

  -- The reading, kept whole so a number can be traced to what the model said
  read_started_at timestamptz,
  read_at         timestamptz,
  read_model      text,
  read_error      text,
  read_result     jsonb,

  -- The bill. company is the Prosun company paying; vendor is the party paid.
  company         text check (company in ('Prosun Farm', 'Prosun Food')),
  document_no     text,
  no_document_reason text,
  po_number       text,
  vendor_code     text,
  vendor_name     text,
  reference       text,
  bill_date       date,
  due_date        date,
  lines           jsonb not null default '[]'::jsonb check (jsonb_typeof(lines) = 'array'),
  vat_amount      numeric(14,2),
  wht_amount      numeric(14,2),
  deposit_amount  numeric(14,2),
  net_amount      numeric(14,2),
  note            text,

  -- The workflow; written only by the functions below
  submitted_by    uuid references public.profiles(id),
  submitted_at    timestamptz,
  reviewed_by     uuid references public.profiles(id),
  reviewed_at     timestamptz,
  proposed_by     uuid references public.profiles(id),
  proposed_at     timestamptz,
  planned_pay_date date,
  approved_by     uuid references public.profiles(id),
  approved_at     timestamptz,
  approved_amount numeric(14,2),
  paid_by         uuid references public.profiles(id),
  paid_at         timestamptz,
  paid_date       date,
  paid_reference  text,
  last_comment    text,
  updated_at      timestamptz not null default now()
);

create index if not exists payables_status_idx on public.payables (status);
create index if not exists payables_po_idx     on public.payables (po_number);
create index if not exists payables_vendor_idx on public.payables (vendor_name);
create index if not exists payables_due_idx    on public.payables (due_date);

-- Once a bill has left accounting its number is taken. Scans still being
-- checked may repeat: the screen warns, and a duplicate is refused on submit.
create unique index if not exists payables_document_unique
  on public.payables (company, upper(btrim(document_no)))
  where document_no is not null and btrim(document_no) <> ''
    and status in ('submitted', 'reviewed', 'proposed', 'approved', 'paid');

comment on table public.payables is
  'One scanned supplier bill and its way to payment. Never deleted. Migration 025.';

create table if not exists public.payable_events (
  id          bigint generated always as identity primary key,
  payable_id  uuid not null references public.payables(id),
  at          timestamptz not null default now(),
  actor       uuid,
  actor_name  text,
  action      text not null,
  from_status text,
  to_status   text,
  comment     text,
  net_amount  numeric(14,2)
);
create index if not exists payable_events_bill_idx on public.payable_events (payable_id, at);

comment on table public.payable_events is
  'The history of each bill: who moved it, when, at what amount, with what '
  'comment. Written only by the functions below; nobody can change it.';

-- Payment terms remembered per supplier, to propose the due date on later bills.
create table if not exists public.payable_suppliers (
  supplier_key text primary key,
  vendor_name  text,
  terms_days   int,
  updated_at   timestamptz not null default now()
);


-- ----------------------------------------------------------------------------
-- 3. The guard: allowed status moves and the lock on the bill's content
-- ----------------------------------------------------------------------------
create or replace function public.payables_guard()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  editable constant text[] := array['uploading', 'queued', 'reading', 'read', 'failed', 'returned'];
  allowed text[];
begin
  if tg_op = 'DELETE' then
    raise exception 'payables are never deleted — void the bill with a reason' using errcode = '42501';
  end if;

  if new.status is distinct from old.status then
    allowed := case old.status
      when 'uploading' then array['queued', 'failed', 'void']
      when 'queued'    then array['reading', 'failed', 'void']
      when 'reading'   then array['read', 'failed', 'void']
      when 'read'      then array['reading', 'submitted', 'void']
      when 'failed'    then array['reading', 'submitted', 'void']
      when 'returned'  then array['submitted', 'void']
      when 'submitted' then array['reviewed', 'returned', 'void']
      when 'reviewed'  then array['proposed', 'returned', 'void']
      when 'proposed'  then array['approved', 'reviewed', 'returned', 'void']
      when 'approved'  then array['paid', 'reviewed', 'returned', 'void']
      when 'paid'      then array['approved']
      else array[]::text[] end;
    if not new.status = any(allowed) then
      raise exception 'a bill cannot go from % to %', old.status, new.status using errcode = '42501';
    end if;
  end if;

  if not old.status = any(editable) and (
       new.company            is distinct from old.company
    or new.document_no        is distinct from old.document_no
    or new.no_document_reason is distinct from old.no_document_reason
    or new.po_number          is distinct from old.po_number
    or new.vendor_code        is distinct from old.vendor_code
    or new.vendor_name        is distinct from old.vendor_name
    or new.reference          is distinct from old.reference
    or new.bill_date          is distinct from old.bill_date
    or new.due_date           is distinct from old.due_date
    or new.lines              is distinct from old.lines
    or new.vat_amount         is distinct from old.vat_amount
    or new.wht_amount         is distinct from old.wht_amount
    or new.deposit_amount     is distinct from old.deposit_amount
    or new.net_amount         is distinct from old.net_amount
    or new.file_path          is distinct from old.file_path) then
    raise exception 'this bill is locked — return it to accounting to change it' using errcode = '42501';
  end if;

  -- Leaving a step cancels what that step and the later ones recorded.
  if new.status in ('returned', 'void') and old.status in ('reviewed', 'proposed', 'approved', 'submitted') then
    new.reviewed_by := null; new.reviewed_at := null;
  end if;
  if new.status in ('reviewed', 'returned', 'void') and old.status in ('proposed', 'approved') then
    new.proposed_by := null; new.proposed_at := null; new.planned_pay_date := null;
  end if;
  if old.status = 'approved' and new.status in ('reviewed', 'returned', 'void') then
    new.approved_by := null; new.approved_at := null; new.approved_amount := null;
  end if;
  if old.status = 'paid' and new.status = 'approved' then
    new.paid_by := null; new.paid_at := null; new.paid_date := null; new.paid_reference := null;
  end if;
  return new;
end;
$$;

drop trigger if exists payables_guard on public.payables;
create trigger payables_guard
  before update or delete on public.payables
  for each row execute function public.payables_guard();

drop trigger if exists payables_set_updated_at on public.payables;
create trigger payables_set_updated_at
  before update on public.payables
  for each row execute function public.set_updated_at();

create or replace function public.payable_events_guard()
returns trigger
language plpgsql
as $$
begin
  raise exception 'the payable history cannot be changed' using errcode = '42501';
end;
$$;
drop trigger if exists payable_events_guard on public.payable_events;
create trigger payable_events_guard
  before update or delete on public.payable_events
  for each row execute function public.payable_events_guard();

-- Same audit trail as the weighing papers (Migration 018).
drop trigger if exists payables_log_activity on public.payables;
create trigger payables_log_activity
  after insert or update on public.payables
  for each row execute function public.log_weighing_activity();


-- ----------------------------------------------------------------------------
-- 4. Row Level Security and grants
-- ----------------------------------------------------------------------------
alter table public.payable_capture_links enable row level security;
alter table public.payables              enable row level security;
alter table public.payable_events        enable row level security;
alter table public.payable_suppliers     enable row level security;

drop policy if exists "payable_capture_links: own" on public.payable_capture_links;
create policy "payable_capture_links: own"
  on public.payable_capture_links for all to authenticated
  using (public.current_role() = 'accounting' and created_by = auth.uid())
  with check (public.current_role() = 'accounting' and created_by = auth.uid());

drop policy if exists "payables: read" on public.payables;
create policy "payables: read"
  on public.payables for select to authenticated
  using (public.current_role() in ('accounting', 'admin'));

-- Only accounting edits, only before submission, only the columns granted below.
drop policy if exists "payables: accounting edits" on public.payables;
create policy "payables: accounting edits"
  on public.payables for update to authenticated
  using (public.current_role() = 'accounting' and status in ('read', 'failed', 'returned'))
  with check (public.current_role() = 'accounting' and status in ('read', 'failed', 'returned'));

drop policy if exists "payable_events: read" on public.payable_events;
create policy "payable_events: read"
  on public.payable_events for select to authenticated
  using (public.current_role() in ('accounting', 'admin'));

drop policy if exists "payable_suppliers: read" on public.payable_suppliers;
create policy "payable_suppliers: read"
  on public.payable_suppliers for select to authenticated
  using (public.current_role() in ('accounting', 'admin'));

revoke all on public.payable_capture_links, public.payables, public.payable_events, public.payable_suppliers
  from public, anon, authenticated;
grant select, insert, update on public.payable_capture_links to authenticated;
grant select on public.payables, public.payable_events, public.payable_suppliers to authenticated;
grant update (company, document_no, no_document_reason, po_number, vendor_code, vendor_name,
              reference, bill_date, due_date, lines, vat_amount, wht_amount, deposit_amount,
              net_amount, note)
  on public.payables to authenticated;
grant all on public.payable_capture_links, public.payables, public.payable_events, public.payable_suppliers
  to service_role;


-- ----------------------------------------------------------------------------
-- 5. Internal helpers (not callable from the app)
-- ----------------------------------------------------------------------------
create or replace function public.payable_move(p_bill public.payables, p_to text, p_action text, p_comment text)
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
  update public.payables
     set status = p_to,
         last_comment = coalesce(nullif(btrim(p_comment), ''), case when p_to in ('returned', 'void') then last_comment end)
   where id = p_bill.id;
  insert into public.payable_events (payable_id, actor, actor_name, action, from_status, to_status, comment, net_amount)
  values (p_bill.id, who, who_name, p_action, p_bill.status, p_to, nullif(btrim(p_comment), ''), p_bill.net_amount);
end;
$$;

create or replace function public.payable_notify(p_to uuid[], p_kind text, p_title text, p_body text, p_details jsonb)
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
  insert into public.notifications (recipient, kind, title, body, details, actor, actor_name)
  select distinct r, p_kind, p_title, p_body, p_details, who, who_name
  from unnest(p_to) r
  where r is not null and r is distinct from who;
end;
$$;

create or replace function public.payable_people(p_what text)
returns uuid[]
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(array_agg(user_id), '{}') from public.payable_permissions
  where case p_what when 'review' then can_review when 'select' then can_select
                    when 'approve' then can_approve when 'pay' then can_pay else false end;
$$;

create or replace function public.payable_money(p numeric)
returns text
language sql
immutable
as $$ select to_char(coalesce(p, 0), 'FM999,999,999,990.00') || ' THB'; $$;

create or replace function public.payable_label(p public.payables)
returns text
language sql
stable
as $$ select coalesce(nullif(btrim(p.document_no), ''), 'No document no.') || ' · ' ||
             coalesce(p.vendor_name, 'unknown supplier') || ' · ' || public.payable_money(p.net_amount); $$;

revoke all on function public.payable_move(public.payables, text, text, text) from public, anon, authenticated;
revoke all on function public.payable_notify(uuid[], text, text, text, jsonb) from public, anon, authenticated;
revoke all on function public.payable_people(text) from public, anon, authenticated;


-- ----------------------------------------------------------------------------
-- 6. The steps
-- ----------------------------------------------------------------------------

-- Accounting: checked against the scan, send to Khun Ann.
create or replace function public.payable_submit(p_id uuid, p_comment text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.payables;
  total numeric;
  key text;
begin
  if public.current_role() is distinct from 'accounting' then
    raise exception 'only accounting can submit a bill' using errcode = '42501';
  end if;
  select * into b from public.payables where id = p_id for update;
  if not found then raise exception 'bill not found'; end if;
  if b.status not in ('read', 'failed', 'returned') then
    raise exception 'this bill has already been submitted' using errcode = '42501';
  end if;
  if b.company is null then raise exception 'choose the company'; end if;
  if nullif(btrim(b.vendor_name), '') is null then raise exception 'enter the supplier'; end if;
  if b.bill_date is null then raise exception 'enter the bill date'; end if;
  if b.due_date is null then raise exception 'enter the due date'; end if;
  if b.net_amount is null then raise exception 'enter the net amount to pay'; end if;
  if nullif(btrim(b.document_no), '') is null and nullif(btrim(b.no_document_reason), '') is null then
    raise exception 'enter the document number, or the reason there is none';
  end if;

  select coalesce(sum((l->>'amount')::numeric), 0) into total from jsonb_array_elements(b.lines) l;
  if abs(total + coalesce(b.vat_amount, 0) - coalesce(b.wht_amount, 0) - b.net_amount) > 0.05
     and nullif(btrim(p_comment), '') is null then
    raise exception 'the lines do not add up to the net amount — correct them, or add a comment explaining why';
  end if;

  begin
    update public.payables set submitted_by = auth.uid(), submitted_at = now() where id = p_id;
    perform public.payable_move(b, 'submitted', 'submitted', p_comment);
  exception when unique_violation then
    raise exception 'document % has already been submitted for %', b.document_no, b.company;
  end;

  key := upper(btrim(coalesce(nullif(b.vendor_code, ''), b.vendor_name)));
  insert into public.payable_suppliers (supplier_key, vendor_name, terms_days)
  values (key, b.vendor_name, b.due_date - b.bill_date)
  on conflict (supplier_key) do update
    set vendor_name = excluded.vendor_name, terms_days = excluded.terms_days, updated_at = now();
end;
$$;

-- Khun Ann: reviewed, can now be selected for payment.
create or replace function public.payable_review(p_ids uuid[], p_comment text default null)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.payables;
  i uuid;
  n int := 0;
begin
  if not public.payable_can('review') then
    raise exception 'you cannot review bills' using errcode = '42501';
  end if;
  foreach i in array p_ids loop
    select * into b from public.payables where id = i for update;
    if not found or b.status <> 'submitted' then
      raise exception 'a bill has already moved on — refresh the list' using errcode = '42501';
    end if;
    update public.payables set reviewed_by = auth.uid(), reviewed_at = now() where id = i;
    perform public.payable_move(b, 'reviewed', 'reviewed', p_comment);
    n := n + 1;
  end loop;
  return n;
end;
$$;

-- Back to accounting with a comment. Cancels review, selection and approval.
create or replace function public.payable_return(p_id uuid, p_comment text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.payables;
begin
  if not (public.payable_can('review') or public.payable_can('approve')) then
    raise exception 'you cannot return bills' using errcode = '42501';
  end if;
  if nullif(btrim(p_comment), '') is null then raise exception 'a comment is required'; end if;
  select * into b from public.payables where id = p_id for update;
  if not found or b.status not in ('submitted', 'reviewed', 'proposed', 'approved') then
    raise exception 'this bill cannot be returned now — refresh the list' using errcode = '42501';
  end if;
  perform public.payable_move(b, 'returned', 'returned', p_comment);
  perform public.payable_notify(array[b.submitted_by] || public.payable_people('review')
      || case when b.status in ('proposed', 'approved') then public.payable_people('select') else '{}'::uuid[] end
      || case when b.status = 'approved' then public.payable_people('approve') || public.payable_people('pay') else '{}'::uuid[] end,
    'payable_returned', 'Bill returned to accounting: ' || public.payable_label(b), p_comment,
    jsonb_build_object('ids', jsonb_build_array(p_id), 'was', b.status));
end;
$$;

-- Khun Kirana: the payments she proposes for a date. Clément can add one too.
create or replace function public.payable_propose(p_ids uuid[], p_date date, p_comment text default null)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.payables;
  i uuid;
  n int := 0;
  total numeric := 0;
begin
  if not (public.payable_can('select') or public.payable_can('approve')) then
    raise exception 'you cannot select payments' using errcode = '42501';
  end if;
  if p_date is null then raise exception 'choose the payment date'; end if;
  foreach i in array p_ids loop
    select * into b from public.payables where id = i for update;
    if not found or b.status <> 'reviewed' then
      raise exception 'a bill has already moved on — refresh the list' using errcode = '42501';
    end if;
    update public.payables set proposed_by = auth.uid(), proposed_at = now(), planned_pay_date = p_date where id = i;
    perform public.payable_move(b, 'proposed', 'proposed', p_comment);
    n := n + 1;
    total := total + b.net_amount;
  end loop;
  if n > 0 then
    perform public.payable_notify(public.payable_people('approve'), 'payable_proposed',
      n || case when n = 1 then ' payment' else ' payments' end || ' waiting for your approval: ' || public.payable_money(total),
      'Planned for ' || to_char(p_date, 'DD Mon YYYY') || coalesce(' · ' || nullif(btrim(p_comment), ''), ''),
      jsonb_build_object('ids', to_jsonb(p_ids), 'total', total));
  end if;
  return n;
end;
$$;

-- Khun Kirana takes a bill out of her selection before it is decided.
create or replace function public.payable_unpropose(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.payables;
begin
  if not public.payable_can('select') then
    raise exception 'you cannot change the selection' using errcode = '42501';
  end if;
  select * into b from public.payables where id = p_id for update;
  if not found or b.status <> 'proposed' then
    raise exception 'this bill is no longer waiting for approval — refresh the list' using errcode = '42501';
  end if;
  perform public.payable_move(b, 'reviewed', 'removed from selection', null);
end;
$$;

-- Clément: the last step before payment. p_total is the total he saw.
create or replace function public.payable_approve(p_ids uuid[], p_total numeric, p_comment text default null)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.payables;
  i uuid;
  n int := 0;
  total numeric := 0;
begin
  if not public.payable_can('approve') then
    raise exception 'you cannot approve payments' using errcode = '42501';
  end if;
  foreach i in array p_ids loop
    select * into b from public.payables where id = i for update;
    if not found or b.status <> 'proposed' then
      raise exception 'a bill has already moved on — refresh the list' using errcode = '42501';
    end if;
    total := total + b.net_amount;
    update public.payables
       set approved_by = auth.uid(), approved_at = now(), approved_amount = b.net_amount
     where id = i;
    perform public.payable_move(b, 'approved', 'approved', p_comment);
    n := n + 1;
  end loop;
  if abs(total - coalesce(p_total, -1)) > 0.005 then
    raise exception 'the total changed since the screen was loaded — refresh and check again' using errcode = '42501';
  end if;
  if n > 0 then
    perform public.payable_notify(public.payable_people('pay'), 'payable_approved',
      n || case when n = 1 then ' payment' else ' payments' end || ' approved: ' || public.payable_money(total),
      nullif(btrim(p_comment), ''), jsonb_build_object('ids', to_jsonb(p_ids), 'total', total));
  end if;
  return n;
end;
$$;

-- Clément: not now. Back to the bills that can be selected, with his reason.
create or replace function public.payable_hold(p_ids uuid[], p_comment text)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.payables;
  i uuid;
  n int := 0;
  total numeric := 0;
begin
  if not public.payable_can('approve') then
    raise exception 'you cannot hold payments' using errcode = '42501';
  end if;
  if nullif(btrim(p_comment), '') is null then raise exception 'a comment is required'; end if;
  foreach i in array p_ids loop
    select * into b from public.payables where id = i for update;
    if not found or b.status not in ('proposed', 'approved') then
      raise exception 'a bill has already moved on — refresh the list' using errcode = '42501';
    end if;
    perform public.payable_move(b, 'reviewed', 'held by approver', p_comment);
    n := n + 1;
    total := total + b.net_amount;
  end loop;
  if n > 0 then
    perform public.payable_notify(public.payable_people('select'), 'payable_held',
      n || case when n = 1 then ' payment' else ' payments' end || ' not approved for now: ' || public.payable_money(total),
      p_comment, jsonb_build_object('ids', to_jsonb(p_ids), 'total', total));
  end if;
  return n;
end;
$$;

-- Khun Kirana: paid through the bank; this records it. One bank transfer can
-- cover several bills, so several can share a reference.
create or replace function public.payable_mark_paid(p_ids uuid[], p_date date, p_reference text)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.payables;
  i uuid;
  n int := 0;
begin
  if not public.payable_can('pay') then
    raise exception 'you cannot record payments' using errcode = '42501';
  end if;
  if p_date is null then raise exception 'enter the payment date'; end if;
  if p_date > (now() at time zone 'Asia/Bangkok')::date then
    raise exception 'the payment date cannot be in the future';
  end if;
  if nullif(btrim(p_reference), '') is null then raise exception 'enter the bank reference'; end if;
  foreach i in array p_ids loop
    select * into b from public.payables where id = i for update;
    if not found or b.status <> 'approved' then
      raise exception 'a bill is not approved — refresh the list' using errcode = '42501';
    end if;
    if b.approved_by = auth.uid() then
      raise exception 'the person who approved a bill cannot record its payment' using errcode = '42501';
    end if;
    if b.approved_amount is distinct from b.net_amount then
      raise exception 'the amount differs from the approved amount' using errcode = '42501';
    end if;
    update public.payables
       set paid_by = auth.uid(), paid_at = now(), paid_date = p_date, paid_reference = btrim(p_reference)
     where id = i;
    perform public.payable_move(b, 'paid', 'paid', 'Bank reference ' || btrim(p_reference));
    n := n + 1;
  end loop;
  return n;
end;
$$;

-- Correcting a payment recorded by mistake. The approver is told.
create or replace function public.payable_undo_paid(p_id uuid, p_comment text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.payables;
begin
  if not public.payable_can('pay') then
    raise exception 'you cannot change payments' using errcode = '42501';
  end if;
  if nullif(btrim(p_comment), '') is null then raise exception 'a comment is required'; end if;
  select * into b from public.payables where id = p_id for update;
  if not found or b.status <> 'paid' then
    raise exception 'this bill is not paid' using errcode = '42501';
  end if;
  perform public.payable_move(b, 'approved', 'payment record cancelled', p_comment);
  perform public.payable_notify(public.payable_people('approve'), 'payable_undo',
    'Payment record cancelled: ' || public.payable_label(b), p_comment,
    jsonb_build_object('ids', jsonb_build_array(p_id), 'reference', b.paid_reference));
end;
$$;

-- Cancel a bill with a reason: wrong scan, duplicate, bill withdrawn. Accounting
-- for its own drafts; Khun Ann or the approver at any point before payment.
create or replace function public.payable_void(p_id uuid, p_comment text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.payables;
begin
  if nullif(btrim(p_comment), '') is null then raise exception 'a reason is required'; end if;
  select * into b from public.payables where id = p_id for update;
  if not found then raise exception 'bill not found'; end if;
  if b.status in ('paid', 'void') then
    raise exception 'this bill cannot be voided' using errcode = '42501';
  end if;
  if not (public.payable_can('review') or public.payable_can('approve')
          or (public.current_role() = 'accounting' and b.status in ('uploading', 'queued', 'reading', 'read', 'failed', 'returned'))) then
    raise exception 'you cannot void this bill' using errcode = '42501';
  end if;
  perform public.payable_move(b, 'void', 'voided', p_comment);
  if b.status in ('reviewed', 'proposed', 'approved') then
    perform public.payable_notify(public.payable_people('approve') || public.payable_people('select'),
      'payable_voided', 'Bill voided: ' || public.payable_label(b), p_comment,
      jsonb_build_object('ids', jsonb_build_array(p_id), 'was', b.status));
  end if;
end;
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'public.payable_submit(uuid, text)', 'public.payable_review(uuid[], text)',
    'public.payable_return(uuid, text)', 'public.payable_propose(uuid[], date, text)',
    'public.payable_unpropose(uuid)', 'public.payable_approve(uuid[], numeric, text)',
    'public.payable_hold(uuid[], text)', 'public.payable_mark_paid(uuid[], date, text)',
    'public.payable_undo_paid(uuid, text)', 'public.payable_void(uuid, text)']
  loop
    execute 'revoke all on function ' || f || ' from public, anon';
    execute 'grant execute on function ' || f || ' to authenticated';
  end loop;
end $$;


-- ----------------------------------------------------------------------------
-- 7. Scan storage — private bucket, nothing deleted automatically
-- ----------------------------------------------------------------------------
-- Uploads go through one-time signed URLs from the edge function, so no upload
-- or delete policy exists for signed-in users.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('payable-documents', 'payable-documents', false, 15728640,
        array['image/jpeg', 'application/pdf'])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "payable-documents: read" on storage.objects;
create policy "payable-documents: read"
  on storage.objects for select to authenticated
  using (bucket_id = 'payable-documents'
         and public.current_role() in ('accounting', 'admin'));


-- ----------------------------------------------------------------------------
-- 8. Check after running: this should list Ann, Kirana and Clément
-- ----------------------------------------------------------------------------
select p.full_name, x.can_review, x.can_select, x.can_approve, x.can_pay
from public.payable_permissions x
join public.profiles p on p.id = x.user_id
order by p.full_name;
