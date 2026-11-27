-- ============================================================================
-- Migration 053 — Postponed orders: open the working paper (27 Nov 2026)
-- ============================================================================
-- Clément, 27 Nov: in Middle office › Postponed orders, "I'd like to be able to
-- click and directly see the workpaper for the postponed ones."
--
-- The list gets a 📄 button on every order that has a working paper; it opens
-- the same pop-up as the delivery board (Migration 034): the photographed
-- paper and its lines (ordered, actual kg), who confirmed the weights.
--
-- Until now the middle office could open the photo of a CONFIRMED paper only
-- (Migration 022). A postponed order waiting for production has no confirmed
-- paper yet, so this adds:
--   1. weighing_photo_is_postponed(path) + storage rule "weighing-photos:
--      middle office sees postponed": the middle office may open the photo of
--      any paper that was postponed (itself, or the paper it was split from in
--      Migrations 040/041), or that a register postponement points to (same PO).
--      The company director: the same, for his company only.
--   2. postponed_order_paper(paper) → the paper as on the delivery board
--      (delivery_paper_json) + customer_po (052) + photo_ok (can this person
--      open the photo). Admin: any paper. Middle office and company director:
--      only papers on their Postponed orders list (company director: his
--      company only, as everywhere).
--
-- Run after 052. Safe to run twice.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Photos of postponed papers: middle office
-- ----------------------------------------------------------------------------
create or replace function public.weighing_photo_is_postponed(p_path text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.weighing_papers p
    where p.photo_path = p_path
      and (
        exists (select 1 from public.weighing_postponements h
                where h.paper_id = p.id or (p.split_from is not null and h.paper_id = p.split_from))
        or exists (select 1 from public.order_postponements r
                   where r.po_number is not null and p.po_number is not null
                     and upper(trim(r.po_number)) = upper(trim(p.po_number))
                     and (r.company is null or p.company is null or r.company = p.company))));
$$;

comment on function public.weighing_photo_is_postponed(text) is
  'True when a working-paper photo belongs to a paper that was postponed (or split from one), or that a register postponement points to by PO. Used by the storage rule for the middle office. Migration 053.';

revoke all on function public.weighing_photo_is_postponed(text) from public, anon;
grant execute on function public.weighing_photo_is_postponed(text) to authenticated, service_role;

drop policy if exists "weighing-photos: middle office sees postponed" on storage.objects;
create policy "weighing-photos: middle office sees postponed"
  on storage.objects for select to authenticated
  using (bucket_id = 'weighing-photos'
         and public.current_role() = 'sale_support'
         and public.weighing_photo_is_postponed(name));


-- Company director (Migration 032 lets him open his company's CONFIRMED
-- papers): also his company's postponed ones.
create or replace function public.weighing_photo_postponed_in_scope(p_path text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.weighing_photo_is_postponed(p_path)
     and exists (select 1 from public.weighing_papers
                 where photo_path = p_path and company = public.my_company_scope());
$$;

revoke all on function public.weighing_photo_postponed_in_scope(text) from public, anon;
grant execute on function public.weighing_photo_postponed_in_scope(text) to authenticated, service_role;

drop policy if exists "weighing-photos: company director sees own postponed" on storage.objects;
create policy "weighing-photos: company director sees own postponed"
  on storage.objects for select to authenticated
  using (bucket_id = 'weighing-photos'
         and public.current_role() = 'company_director'
         and public.weighing_photo_postponed_in_scope(name));


-- ----------------------------------------------------------------------------
-- 2. One paper of the Postponed orders list
-- ----------------------------------------------------------------------------
create or replace function public.postponed_order_paper(p_paper uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  r       text := coalesce(public.current_role(), '');
  v_scope text := public.my_company_scope();
  p       public.weighing_papers;
  v_photo boolean;
begin
  if r not in ('admin', 'sale_support', 'company_director') then
    raise exception 'not allowed' using errcode = '42501';
  end if;

  select * into p from public.weighing_papers where id = p_paper;
  if not found then
    return null;
  end if;

  -- Only papers on the person's Postponed orders list (admin: any).
  if r <> 'admin' and not exists (
       select 1 from public.postponed_orders_rows(v_scope, 36500) o where o.paper_id = p_paper) then
    raise exception 'not allowed' using errcode = '42501';
  end if;

  v_photo := p.photo_path is not null and p.photo_deleted_at is null and (
               r = 'admin'
            or (r = 'sale_support' and (p.status = 'confirmed' or public.weighing_photo_is_postponed(p.photo_path)))
            or (r = 'company_director' and (public.weighing_photo_in_scope(p.photo_path)
                                            or public.weighing_photo_postponed_in_scope(p.photo_path))));

  return public.delivery_paper_json(p)
      || jsonb_build_object('customer_po', p.customer_po, 'photo_ok', v_photo);
end;
$$;

comment on function public.postponed_order_paper(uuid) is
  'Postponed orders: one working paper for the pop-up (photo path, lines, who confirmed, customer PO, photo_ok). Admin any paper; middle office and company director only papers on their list. Migration 053.';

revoke all on function public.postponed_order_paper(uuid) from public, anon;
grant execute on function public.postponed_order_paper(uuid) to authenticated, service_role;


-- Check (as the middle office, with a paper id from the list):
--   select public.postponed_order_paper('<paper id>')->>'photo_ok';
-- ============================================================================
