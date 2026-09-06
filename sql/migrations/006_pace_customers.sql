-- ============================================================================
-- Migration 006 — PACE owns its customers; CRM link removed
-- ============================================================================
-- Written 6 Sep 2026.
--
-- WHY
-- Migration 003 gave the PACE side a narrow view onto the CRM's clients table
-- so orders could link to real customer records. Reviewing the Supabase linter
-- warnings on those views, Clément decided against the link entirely:
-- "Id prefer if the PACE program is not linked to the CRM" — consistent with
-- how he framed the two systems from the start.
--
-- That is the cleaner position, and it removes a real awkwardness. The views
-- worked by running as their owner and so bypassing RLS on clients, which the
-- linter correctly flagged as CRITICAL. Testing showed the compensating
-- control held (no session, wrong role, and three different self-promotion
-- attempts all returned nothing), but the design still carried a maintenance
-- trap: any future RLS policy added to clients would silently not apply to the
-- view. Severing the link removes the trap rather than documenting it.
--
-- An attempted middle path is worth recording as a dead end: giving the views
-- a dedicated low-privilege owner with column-level grants. It does not work —
-- reading past RLS IS table ownership, so a restricted owner simply returns
-- zero rows.
--
-- WHAT REPLACES IT
-- PACE gets its own customer list. Not free text: names would fragment across
-- spellings and per-customer history would become unreliable. A table of the
-- 107 customers who actually appear in the four September order sheets — a far
-- more relevant set than the CRM's 3,833 — maintained by sale support.
--
-- Both flagged views are dropped. Nothing in PACE reads the CRM any more, and
-- neither remaining mechanism relies on SECURITY DEFINER: the customer list is
-- an ordinary table with ordinary RLS, and colleague names come from a plain
-- policy on profiles.
--
-- Also fixes a defect from 001: sale_support could update an order line but
-- not delete one, so a mistyped line could be blanked but not removed. That is
-- inconsistent rather than protective, and it blocked editing the grid in
-- place. Deletion is allowed here, with an audit trigger so removals are
-- recorded — the same trail sale_orders already has.
--
-- Run order: after 005. Safe to re-run.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. PACE's own customer list
-- ----------------------------------------------------------------------------
create table if not exists public.pace_customers (
  id            uuid primary key default gen_random_uuid(),
  channel       text not null check (channel in ('Restaurant', 'Department Store', 'Individual', 'Retail')),
  name          text not null,
  code          text,          -- CR010 / CS015 / CM2303. Restaurant kept it inside
                               -- the name in Excel ("Ledu (CR010)"); split out here.
  contact_name  text,          -- the chef, for restaurants
  phone         text,
  notes         text,
  active        boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

comment on table public.pace_customers is
  'Customers for the middle-office side. Deliberately separate from the CRM''s '
  'clients table: PACE and the CRM are two systems sharing one database '
  '(Clement, 6 Sep 2026). Seeded from the four September order workbooks.';

-- The same customer can appear on more than one channel and is a separate
-- entry each time, because the channels genuinely price and serve differently.
create unique index if not exists pace_customers_channel_name_key
  on public.pace_customers (channel, lower(name));

alter table public.pace_customers enable row level security;

drop policy if exists "pace_customers: admin manages" on public.pace_customers;
create policy "pace_customers: admin manages"
  on public.pace_customers for all to authenticated
  using (public.current_role() = 'admin')
  with check (public.current_role() = 'admin');

drop policy if exists "pace_customers: pace roles read" on public.pace_customers;
create policy "pace_customers: pace roles read"
  on public.pace_customers for select to authenticated
  using (public.current_role() in ('sale_support', 'purchasing', 'production'));

-- Sale support maintains the list, the same way they maintain the catalogue.
drop policy if exists "pace_customers: sale_support inserts" on public.pace_customers;
create policy "pace_customers: sale_support inserts"
  on public.pace_customers for insert to authenticated
  with check (public.current_role() = 'sale_support');

drop policy if exists "pace_customers: sale_support updates" on public.pace_customers;
create policy "pace_customers: sale_support updates"
  on public.pace_customers for update to authenticated
  using (public.current_role() = 'sale_support')
  with check (public.current_role() = 'sale_support');
-- No delete: a customer is retired by setting active = false, so their order
-- history keeps its reference.

drop trigger if exists pace_customers_set_updated_at on public.pace_customers;
create trigger pace_customers_set_updated_at
  before update on public.pace_customers
  for each row execute function public.set_updated_at();

grant select, insert, update, delete on public.pace_customers to authenticated;
grant select, insert, update, delete on public.pace_customers to service_role;


-- ----------------------------------------------------------------------------
-- 2. Seed: the 107 customers who actually appear in the September sheets
-- ----------------------------------------------------------------------------
insert into public.pace_customers (channel, name, code, contact_name, phone) values
  ('Restaurant', 'Yona Beach', 'CH143', null, null),
  ('Restaurant', 'Prosun Food', null, null, null),
  ('Restaurant', 'Ledu', 'CR010', null, null),
  ('Restaurant', 'Accidental Butcher', 'CB005', null, null),
  ('Restaurant', 'Valia Hotel Bangkok', 'CH144', null, null),
  ('Restaurant', 'Le Bua', 'CR109', null, null),
  ('Restaurant', 'The Food Education', 'CO045', null, null),
  ('Restaurant', 'Amba', 'CR506', null, null),
  ('Restaurant', 'Stay Phuket', 'CH075', null, null),
  ('Restaurant', 'Swag Food', 'CR1031', null, null),
  ('Restaurant', 'CRU', 'CR270', null, null),
  ('Restaurant', 'Sala Chaweng Samui', 'CH124', null, null),
  ('Restaurant', 'Siam Kempinski Hotel Bangkok', 'CH030', null, null),
  ('Restaurant', 'Easy health Thong Lo 8', 'CR223', null, null),
  ('Restaurant', 'Blue Alain Ducasse', 'CR242', null, null),
  ('Restaurant', 'Sindhorn Kempinski', 'CH080', null, null),
  ('Restaurant', 'Chef Pascual Franco', 'CM541', null, null),
  ('Restaurant', 'Paname', 'CR1068', null, null),
  ('Restaurant', 'Alpea', 'CR610', null, null),
  ('Restaurant', 'Pastel', 'CR666', null, null),
  ('Restaurant', 'Four Seasons BKK', 'CR236', null, null),
  ('Restaurant', 'ชินกู่ (CHINGU) / Dakjib', 'CR816', null, null),
  ('Restaurant', 'Man Ho', 'CH203', null, null),
  ('Restaurant', 'Banyantree BKK', 'CH048', null, null),
  ('Restaurant', 'Khun Maarten', 'CM2240', null, null),
  ('Restaurant', 'Kahavadi Chiang Rai', 'CH280', null, null),
  ('Restaurant', 'Skyview Hotel', 'CH058', null, null),
  ('Restaurant', 'Isabella', 'CR528', null, null),
  ('Restaurant', 'The Standard', 'CH121', null, null),
  ('Restaurant', 'Amari Watergate BKK', 'CH086', null, null),
  ('Restaurant', 'Como', 'CH060', null, null),
  ('Restaurant', 'FOX', 'CR1121', null, null),
  ('Restaurant', 'Brekkie Organic Cafe & Juice Bar', 'CR985', null, null),
  ('Restaurant', 'Tharn', 'CR1049', null, null),
  ('Restaurant', 'Sakkwa', 'CR1018', null, null),
  ('Restaurant', 'บ้านหลานยาย', 'CR484', null, null),
  ('Restaurant', 'Blue elephant', 'CR252', null, null),
  ('Restaurant', 'Somsak', 'CR1007', null, null),
  ('Restaurant', 'Cagette', 'CR033', null, null),
  ('Restaurant', 'Easy health', 'CR223', null, null),
  ('Restaurant', 'Le Cordon Bleu', 'CR190', null, null),
  ('Restaurant', 'Le bouchon', 'CR595', null, null),
  ('Restaurant', 'Amalur', 'CR311', null, null),
  ('Restaurant', 'No Name Noodle', 'CR814', null, null),
  ('Restaurant', 'Sababa', 'CR840', null, null),
  ('Restaurant', 'Khaan', 'CR789', null, null),
  ('Restaurant', 'St.regis', 'CH016', null, null),
  ('Restaurant', 'Suvana', 'CR744', null, null),
  ('Restaurant', 'Paleo Robbie', 'CB007', null, null),
  ('Restaurant', 'Lub d Bangkok Chinatown', 'CH248', null, null),
  ('Restaurant', 'Suhring', 'CR069', null, null),
  ('Restaurant', 'Marco restaurant', 'CR150', null, null),
  ('Restaurant', 'Healthy Pattaya', 'CR139', null, null),
  ('Restaurant', 'Bentley´s Bar and Restaurant', 'CR1105', null, null),
  ('Restaurant', 'The Glasshouse Pattaya', 'CR882', null, null),
  ('Restaurant', 'Rosewood Phuket', 'CH108', null, null),
  ('Restaurant', 'Four Seasons Samui', 'CH152', null, null),
  ('Restaurant', 'Playlys Bangkok', 'CR878', null, null),
  ('Restaurant', 'The Peninsula Bangkok', 'CH069', null, null),
  ('Restaurant', 'Anantara Golden Triangle Elephant Camp & Resort', 'CH208', null, null),
  ('Restaurant', 'Gaggan', 'CR263', null, null),
  ('Restaurant', 'Patara', 'CR229', null, null),
  ('Restaurant', 'Grand Hyatt', 'CH024', null, null),
  ('Restaurant', 'Baan Tepa', 'CR441', null, null),
  ('Restaurant', 'Brasserie 9', 'CR092', null, null),
  ('Restaurant', 'The Consul Club', 'CR1072', null, null),
  ('Restaurant', 'Savelberg', 'CR045', null, null),
  ('Restaurant', 'PRU', 'CH180', null, null),
  ('Department Store', 'เอ็มควอเทียร์', 'CS002', null, null),
  ('Department Store', 'เอ็มโพเรี่ยม', 'CS003', null, null),
  ('Department Store', 'Tops ชิดลม', 'CS015', null, null),
  ('Department Store', 'Villa Market หลังสวน', 'CS026', null, null),
  ('Department Store', 'Villa Market นางลิ้นจี่', 'CS019', null, null),
  ('Department Store', 'Villa Market สุขุมวิท 33 (สำนักงานใหญ่)', 'CS005', null, null),
  ('Department Store', 'Tops นางลิ้นจี่', 'CS020', null, null),
  ('Department Store', 'เอ็มโพเรียม', 'CS003', null, null),
  ('Individual', 'Varit Poshyananda', 'CM2303', null, null),
  ('Individual', 'Coco Tsai', 'CM2329', null, null),
  ('Individual', 'Fadoua Vandeplassche', 'CM2316', null, null),
  ('Individual', 'Chutimon Boonyang', 'CM2314', null, null),
  ('Individual', 'Khun Mattia Sindicic', 'CM2067', null, null),
  ('Individual', 'Sadia Piracha', 'CM1969', null, null),
  ('Individual', 'Sammie Ho Dumas', 'CM2124', null, null),
  ('Individual', 'Jodie Thomas', 'CM2331', null, null),
  ('Individual', 'Khun Julie Sarasin', 'CM071', null, null),
  ('Individual', 'Joseph Stark', 'CM352', null, null),
  ('Individual', 'Robert Zetterstrom', 'CM2262', null, null),
  ('Individual', 'คุณสุทธิพัณ พิศาลบุตร', 'CM2332', null, null),
  ('Individual', 'คุณพิพัฒน์นารี', 'CM2061', null, null),
  ('Individual', 'Ekaterina Stulova', 'CM2333', null, null),
  ('Individual', 'Chi Chi', 'CM2139', null, null),
  ('Individual', 'Zsofia Besenyi', 'CM2220', null, null),
  ('Individual', 'Stephanie lacroix', 'CM786', null, null),
  ('Individual', 'Khun Kay Sureerat', 'CM2334', null, null),
  ('Individual', 'Alexandre VIDAL-NAQUET', 'CM1377', null, null),
  ('Individual', 'Khun Mint', 'CM2335', null, null),
  ('Individual', 'Manuel Alessandro Collazo', 'CM2243', null, null),
  ('Individual', 'Titien Rico', 'CM798', null, null),
  ('Individual', 'Nopadol Limwatanakul', 'CM839', null, null),
  ('Individual', 'HIRMI UETANI', 'CM2286', null, null),
  ('Individual', 'บริษัท ทิสโก้ไฟแนนเชียลกรุ๊ป จำกัด (มหาชน)', 'CO091', null, null),
  ('Individual', 'Emmanuel', 'CM886', null, null),
  ('Retail', 'ออร์แกนิควิลเลจ', 'RT005', null, null),
  ('Retail', 'ริมปิงกาดฝรั่ง', 'CS031', null, null),
  ('Retail', 'ริมปิงนวรัฐ', 'CS034', null, null),
  ('Retail', 'Happy lyfe (หน้าร้าน)', 'CS030', null, null),
  ('Retail', 'บริษัท เดอะมอลล์ กรุ๊ป จำกัด สาขาที่ 00012', 'CS033', null, null)
on conflict do nothing;


-- ----------------------------------------------------------------------------
-- 3. Drop the CRM-facing views
-- ----------------------------------------------------------------------------
-- Both bypassed RLS on their underlying table by design. Nothing in PACE reads
-- the CRM any more, so they go rather than being documented around.
drop view if exists public.client_directory;
drop view if exists public.pace_users;

-- Colleague names for "entered by" now come from an ordinary RLS policy, which
-- is the right mechanism and keeps the CRM sales team out of the result.
drop policy if exists "profiles: pace roles read pace colleagues" on public.profiles;
create policy "profiles: pace roles read pace colleagues"
  on public.profiles for select to authenticated
  using (
    public.current_role() in ('admin', 'sale_support', 'purchasing', 'production')
    and role in ('admin', 'sale_support', 'purchasing', 'production')
  );


-- ----------------------------------------------------------------------------
-- 4. sale_orders points at PACE's customers, not the CRM's
-- ----------------------------------------------------------------------------
alter table public.sale_orders
  add column if not exists pace_customer_id uuid references public.pace_customers(id);

-- client_id is removed, but never at the cost of losing data. If any order has
-- one set, the migration stops and says so rather than dropping it silently.
do $$
declare linked int;
begin
  if exists (select 1 from information_schema.columns
             where table_schema='public' and table_name='sale_orders'
               and column_name='client_id') then
    select count(*) into linked from public.sale_orders where client_id is not null;
    if linked > 0 then
      raise exception
        'sale_orders has % row(s) with client_id set. Stopping so nothing is lost — '
        'map those to pace_customers first, then re-run.', linked;
    end if;
    alter table public.sale_orders drop constraint if exists sale_orders_client_or_customer_name;
    alter table public.sale_orders drop column client_id;
    alter table public.sale_orders
      add constraint sale_orders_customer_present
      check (pace_customer_id is not null or customer_name is not null);
  end if;
end $$;


-- ----------------------------------------------------------------------------
-- 5. Fix the line-delete defect from 001
-- ----------------------------------------------------------------------------
-- 001 let sale_support update a line but not delete one, so a mistyped line
-- could be emptied but not removed. Since update was already unrestricted,
-- withholding delete bought nothing — it just meant asking an admin to tidy up.
drop policy if exists "sale_order_lines: sale_support deletes" on public.sale_order_lines;
create policy "sale_order_lines: sale_support deletes"
  on public.sale_order_lines for delete to authenticated
  using (public.current_role() = 'sale_support');

-- With deletion allowed, removals need the same trail order headers already
-- have, so a line that disappears can still be accounted for.
create or replace function public.log_sale_order_line_activity()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.activity_log (table_name, record_id, user_id, action, details)
  values (
    'sale_order_lines',
    coalesce(new.id, old.id),
    auth.uid(),
    tg_op,
    case tg_op when 'DELETE' then to_jsonb(old) else to_jsonb(new) end
  );
  return coalesce(new, old);
end;
$$;

drop trigger if exists sale_order_lines_log_activity on public.sale_order_lines;
create trigger sale_order_lines_log_activity
  after insert or update or delete on public.sale_order_lines
  for each row execute function public.log_sale_order_line_activity();


-- ============================================================================
-- Check afterwards (needs a signed-in session for the RLS-gated parts):
--
--   select channel, count(*) from public.pace_customers group by channel order by 1;
--     -- Department Store 8, Individual 26, Restaurant 68, Retail 5
--
--   select count(*) from pg_views where schemaname='public'
--     and viewname in ('client_directory','pace_users');
--     -- 0: both views gone
--
-- Then in the app: the customer box on a new order should suggest names from
-- this list, and removing a product line should work without an admin.
-- ============================================================================
