-- ============================================================================
-- Special care clients — first list (sales team, 24 Nov 2026)
-- ============================================================================
-- Run in the LIVE project (klongphaifarm-crm, svbrujflslpkpiqmxolp) AFTER
-- Migration 043. Safe to run again: it updates the same rows.
-- Every client gets "No postpone" (the list is about postponed orders);
-- change any of them later in PACE › Management › Special care.
--
-- Client codes were matched to the names by Claude from the Sept 2026 sales
-- report. Not found, so NOT in this list (add them in PACE when you have the
-- code): Duet, Buenazo, Goat Beach Club Phuket.
-- The last query lists the clients whose working-paper name is not linked to
-- their code yet: their papers will not show the ⭐ until the name is linked
-- (Sales › Clients › names on working papers).
-- ============================================================================

with list (code, no_postpone, exact_quantity, priority_delivery, delivery_window, instructions) as (values
  -- Clément
  ('CH018',  true, false, false, null::text, 'Mandarin Oriental. Chef Emanuele Bergamo (Italian, Ciao Terrazza) 082 218 0227.'),
  ('CR236',  true, false, false, null, 'Four Seasons Bangkok. Purchasing 065 518 2863.'),
  -- James: Red Label postponed before
  ('CH030',  true, false, false, null, 'Siam Kempinski. Red Label orders were postponed before: do not postpone again.'),
  ('CH080',  true, false, false, null, 'Sindhorn Kempinski. Red Label orders were postponed before: do not postpone again.'),
  ('CH052',  true, false, false, null, 'Sofitel Sukhumvit. Red Label orders were postponed before: do not postpone again.'),
  ('CH215',  true, false, false, null, 'Dusit Thani Bangkok. Red Label and turkey orders were postponed before: do not postpone again.'),
  -- James: turkey postponed, all hotels of the Dusit group
  ('CH135',  true, false, false, null, 'Dusit group. Turkey orders were postponed (needed from 18 Nov): do not postpone again.'),
  ('CH136',  true, false, false, null, 'Dusit group. Turkey orders were postponed (needed from 18 Nov): do not postpone again.'),
  ('CH145',  true, false, false, null, 'Dusit group. Turkey orders were postponed (needed from 18 Nov): do not postpone again.'),
  ('CH148',  true, false, false, null, 'Dusit group. Turkey orders were postponed (needed from 18 Nov): do not postpone again.'),
  ('CH173',  true, false, false, null, 'Dusit group. Turkey orders were postponed (needed from 18 Nov): do not postpone again.'),
  ('CH219',  true, false, false, null, 'Dusit group. Turkey orders were postponed (needed from 18 Nov): do not postpone again.'),
  ('CR1068', true, false, false, null, 'Dusit group. Turkey orders were postponed (needed from 18 Nov): do not postpone again.'),
  -- Chovie: Red Label postponed before
  ('CH005',  true, false, false, null, 'Anantara Siam. Red Label orders were postponed before: do not postpone again.'),
  ('CR033',  true, false, false, null, 'Cagette. Red Label orders were postponed before: do not postpone again.'),
  ('CR862',  true, false, false, null, 'Juksunchae (with ducks). Red Label orders were postponed before: do not postpone again.'),
  ('CH022',  true, false, false, null, 'Park Hyatt. Red Label orders were postponed before: do not postpone again.'),
  ('CR342',  true, false, false, null, 'Monkey Pod (Galanga). Red Label orders were postponed before: do not postpone again.'),
  ('CH070',  true, false, false, null, 'Centara Central World. Red Label orders were postponed before: do not postpone again.'),
  ('CH060',  true, false, false, null, 'COMO Metropolitan. Red Label orders were postponed before: do not postpone again.'),
  ('CR883',  true, false, false, null, 'Chikkin. Red Label orders were postponed before: do not postpone again.'),
  ('CR066',  true, false, false, null, 'El Gaucho (under roof price). Red Label orders were postponed before: do not postpone again.'),
  -- Pammy
  ('CR957',  true, false, false, null, 'Standing order every Monday and Thursday.'),
  ('CH180',  true, false, false, null, 'PRU Phuket. Standing order every Friday.'),
  ('CH143',  true, false, false, null, 'Yona Phuket. Standing order every Tuesday and Friday.'),
  ('CR311',  true, false, true,  'before 14:00', 'Deliver before 2 PM.'),
  ('CR1081', true, false, false, null, 'Egg price 3.5 baht.'),
  ('CR745',  true, false, false, null, 'Egg price 3.5 baht.'),
  ('CR387',  true, false, false, null, 'Egg price 3.5 baht.'),
  ('CR890',  true, false, false, null, 'Came back with a big order: handle with care.')
)
insert into public.client_special_care as s
  (code, active, no_postpone, exact_quantity, priority_delivery, delivery_window, instructions, updated_at)
select l.code, true, l.no_postpone, l.exact_quantity, l.priority_delivery, l.delivery_window, l.instructions, now()
  from list l
  join public.sales_customers c on c.code = l.code
on conflict (code) do update set
  active = true, no_postpone = excluded.no_postpone, exact_quantity = excluded.exact_quantity,
  priority_delivery = excluded.priority_delivery, delivery_window = excluded.delivery_window,
  instructions = excluded.instructions, updated_at = now(), removed_by = null, removed_at = null;

-- Check 1: the list as PACE has it (expect 30 rows)
select s.code, c.name, s.no_postpone, s.priority_delivery, s.delivery_window, s.instructions
  from public.client_special_care s join public.sales_customers c on c.code = s.code
 where s.active order by c.name;

-- Check 2: flagged clients with no working-paper name linked yet (their papers show no ⭐)
select s.code, c.name
  from public.client_special_care s join public.sales_customers c on c.code = s.code
 where s.active and not exists (select 1 from public.sales_customer_names n where n.code = s.code)
 order by c.name;
