-- ============================================================================
-- Migration 019 — the weighing screen belongs to Production
-- ============================================================================
-- Written 28 Oct 2026. Clément reorganised PROSUN PACE by department: orders
-- for the middle office (sale support), the poultry calculator for purchasing,
-- the weighing for production. Migration 018 opened the weighing tables to
-- factory_admin (Khun Muay) and admin only; this adds the `production` role,
-- so a production account sees the same Production section. Nothing else
-- changes: sale support, purchasing and the CRM side still read nothing here.
--
-- Run order: after 018. Safe to re-run.
-- ============================================================================

-- capture links (QR codes): own rows
drop policy if exists "weighing_capture_links: own" on public.weighing_capture_links;
create policy "weighing_capture_links: own"
  on public.weighing_capture_links for all
  using (public.current_role() in ('factory_admin', 'production', 'admin') and created_by = auth.uid())
  with check (public.current_role() in ('factory_admin', 'production', 'admin') and created_by = auth.uid());

-- papers
drop policy if exists "weighing_papers: read" on public.weighing_papers;
create policy "weighing_papers: read"
  on public.weighing_papers for select
  using (public.current_role() in ('factory_admin', 'production', 'admin'));

drop policy if exists "weighing_papers: insert" on public.weighing_papers;
create policy "weighing_papers: insert"
  on public.weighing_papers for insert
  with check (public.current_role() in ('factory_admin', 'production', 'admin') and uploaded_by = auth.uid());

drop policy if exists "weighing_papers: update" on public.weighing_papers;
create policy "weighing_papers: update"
  on public.weighing_papers for update
  using (public.current_role() in ('factory_admin', 'production', 'admin'))
  with check (public.current_role() in ('factory_admin', 'production', 'admin'));

drop policy if exists "weighing_papers: delete" on public.weighing_papers;
create policy "weighing_papers: delete"
  on public.weighing_papers for delete
  using (public.current_role() = 'admin'
         or (public.current_role() in ('factory_admin', 'production') and status <> 'confirmed'));

-- lines
drop policy if exists "weighing_lines: read" on public.weighing_lines;
create policy "weighing_lines: read"
  on public.weighing_lines for select
  using (public.current_role() in ('factory_admin', 'production', 'admin'));

drop policy if exists "weighing_lines: write" on public.weighing_lines;
create policy "weighing_lines: write"
  on public.weighing_lines for all
  using (public.current_role() in ('factory_admin', 'production', 'admin'))
  with check (public.current_role() in ('factory_admin', 'production', 'admin'));

-- photos
drop policy if exists "weighing-photos: read" on storage.objects;
create policy "weighing-photos: read"
  on storage.objects for select to authenticated
  using (bucket_id = 'weighing-photos'
         and public.current_role() in ('factory_admin', 'production', 'admin'));

drop policy if exists "weighing-photos: upload" on storage.objects;
create policy "weighing-photos: upload"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'weighing-photos'
              and public.current_role() in ('factory_admin', 'production', 'admin'));

drop policy if exists "weighing-photos: delete" on storage.objects;
create policy "weighing-photos: delete"
  on storage.objects for delete to authenticated
  using (bucket_id = 'weighing-photos'
         and public.current_role() in ('factory_admin', 'production', 'admin'));
