-- ============================================================================
-- Migration 026 — Clément can do every payables step (6 Nov 2026)
-- ============================================================================
-- Clément asked for all access in Payables: scan, edit, review, select,
-- approve and pay. Kept on purpose (his choice): nobody, including him, can
-- record the payment of a bill they approved themselves (payable_mark_paid,
-- Migration 025). Every step is still recorded under the person's name.
--
-- Adds can_scan to payable_permissions so scanning and checking bills is no
-- longer limited to the accounting role. Accounting users keep scanning as
-- before. Also redeploy the edge function `payables` (its new index.ts lets a
-- can_scan user upload).
--
-- Run order: after 025. Safe to re-run.
-- ============================================================================

alter table public.payable_permissions add column if not exists can_scan boolean not null default false;

update public.payable_permissions x
   set can_scan = true, can_review = true, can_select = true, can_approve = true, can_pay = true, updated_at = now()
  from auth.users u
 where u.id = x.user_id and lower(u.email) = 'clement@klongphaifarm.com';

create or replace function public.payable_can_scan()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.current_role() = 'accounting'
      or coalesce((select can_scan from public.payable_permissions where user_id = auth.uid()), false);
$$;
revoke all on function public.payable_can_scan() from public, anon, authenticated;
grant execute on function public.payable_can_scan() to authenticated, service_role;

create or replace function public.payable_my_permissions()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'read',    public.current_role() in ('accounting', 'admin'),
    'scan',    public.payable_can_scan(),
    'review',  public.payable_can('review'),
    'select',  public.payable_can('select'),
    'approve', public.payable_can('approve'),
    'pay',     public.payable_can('pay'),
    'me',      auth.uid());
$$;
revoke all on function public.payable_my_permissions() from public, anon;
grant execute on function public.payable_my_permissions() to authenticated;

drop policy if exists "payable_capture_links: own" on public.payable_capture_links;
create policy "payable_capture_links: own"
  on public.payable_capture_links for all to authenticated
  using (public.payable_can_scan() and created_by = auth.uid())
  with check (public.payable_can_scan() and created_by = auth.uid());

drop policy if exists "payables: accounting edits" on public.payables;
create policy "payables: accounting edits"
  on public.payables for update to authenticated
  using (public.payable_can_scan() and status in ('read', 'failed', 'returned'))
  with check (public.payable_can_scan() and status in ('read', 'failed', 'returned'));

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
  if not public.payable_can_scan() then
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
          or (public.payable_can_scan() and b.status in ('uploading', 'queued', 'reading', 'read', 'failed', 'returned'))) then
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

revoke all on function public.payable_submit(uuid, text) from public, anon;
grant execute on function public.payable_submit(uuid, text) to authenticated;
revoke all on function public.payable_void(uuid, text) from public, anon;
grant execute on function public.payable_void(uuid, text) to authenticated;

-- Check after running: Clément should show true in every column
select p.full_name, x.can_scan, x.can_review, x.can_select, x.can_approve, x.can_pay
from public.payable_permissions x
join public.profiles p on p.id = x.user_id
order by p.full_name;
