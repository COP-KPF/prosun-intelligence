-- ============================================================================
-- Migration 031 — Management summary: kg per day and per month, postponement
-- reasons, approximate gross revenue (PACE › Management › Summary)
-- ============================================================================
-- Written 13 Nov 2026. Clément: a section or another window in the
-- management dashboard summarising the average kilos per day and per month,
-- the top reasons for postponement, and an approximate gross revenue from the
-- price list he sent (hotel / restaurant price list valid 16.04.2026, Bangkok
-- and up-country).
--
-- Approximate gross revenue = confirmed weights × list price.
--   - Confirmed papers only, on the day photographed (work_date), from the
--     dashboard's count_from (Migration 024).
--   - Price per line: the paper's product description (as sale support typed
--     it, read by the AI) is matched by keywords to the price list below.
--     The product named first in the description wins, so a cutting note
--     further along ("ตัดหัว ตัดขา" on a whole chicken) does not change it.
--     Prepared products are recognised wherever the word appears.
--   - Papers whose PO starts with UR, or whose description says Under Roof,
--     use the Under Roof price list (valid 01.07.2025, same price everywhere);
--     a product that is not on it falls back to the hotel / restaurant list.
--   - Priced per kg: actual kg × price. Priced per piece (baby and spring
--     chicken, pigeon, eggs): the ordered pieces when ordered in pieces, else
--     actual kg ÷ the typical piece weight.
--   - Quantity tiers: special poultry 11 pieces or more, eggs over 90.
--   - Zone: Bangkok unless the client is marked up-country (admin, on the
--     Summary page). Items with no up-country price use the Bangkok price.
--   - List prices: discounts (clients above 100 kg a month) are not taken
--     off, and department store / retail / individual orders are priced at the
--     hotel / restaurant list. Prepared products (Prosun Food: confit,
--     terrines, sausages, sous-vide…) and client-specific products are not on
--     the list: they are counted in kg and shown as "not priced".
--   This is an estimate for piloting, not accounting. Odoo invoices are the
--   real revenue.
--
-- Postponement reasons: production's postponements (weighing_postponements,
-- Migrations 027/028) and the middle office's register (order_postponements),
-- counted on the delivery date missed — the same rule as the dashboard.
--
-- Access: admin only (Clément, Khun Jum). Price list and zones are read and
-- changed only through the functions below.
--
-- Run order: after 030. Safe to re-run (the price list is reloaded).
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Price list
-- ----------------------------------------------------------------------------
create table if not exists public.price_list (
  id          text primary key,
  sort        int  not null,
  tier        int  not null default 1,         -- 0 not priced (guard), 1 item, 2 generic whole bird
  family      text not null check (family in ('chicken', 'duck', 'special', 'egg', 'guard')),
  under_roof  boolean not null default false,
  name        text not null,
  code        text,
  unit        text not null check (unit in ('kg', 'pce', 'none')),
  price_bkk   numeric,
  price_up    numeric,                         -- null: use the Bangkok price
  bulk_min    numeric,                         -- pieces from which the bulk price applies
  bulk_bkk    numeric,
  bulk_up     numeric,
  piece_kg    numeric,                         -- typical piece weight, to count pieces from kg
  key         text not null,                   -- keyword(s); the earliest one in the description ranks
  pattern     text,                            -- extra condition (regex), null = key only
  exclude     text,                            -- regex that rules the row out
  source      text not null
);

comment on table public.price_list is
  'Prices used by the Management summary to estimate gross revenue from confirmed '
  'weights. Hotel / restaurant list 16.04.2026 (Bangkok, up-country) and Under Roof '
  'list 01.07.2025. Migration 031.';

alter table public.price_list enable row level security;
revoke all on public.price_list from anon, authenticated;
grant all on public.price_list to service_role;

delete from public.price_list;

-- key: the product's words; the one found first in a description decides.
-- pattern: an extra condition; exclude: words that rule the row out.
insert into public.price_list
  (id, sort, tier, family, under_roof, name, code, unit, price_bkk, price_up, bulk_min, bulk_bkk, bulk_up, piece_kg, key, pattern, exclude, source)
values
-- Not priced: prepared products and items not on the lists ----------------------
('prepared', 1, 0, 'guard', false, 'Prepared products (not on the price list)', null, 'none', null, null, null, null, null, null,
  'confit|กงฟี|rillette|ขาไก่บด|ขาเป็ดบด|terrine|เทอร์รีน|mousse|มูส|sausage|ไส้กรอก|chipolata|knack|sous ?vide|ซูวี|duck fat|น้ำมันเป็ด|foie|ฟัวกราส|smoked|รมควัน|lasagn|coq|shepherd|\mpies?\M|stuffed|ยัดไส้|cooked|western|\moption\M|frozen', null, null, 'guard'),
('chicken_skin', 2, 0, 'guard', false, 'Chicken skin (not on the price list)', null, 'none', null, null, null, null, null, null,
  'chicken skin|หนังไก่', null, null, 'guard'),
('green_parts', 3, 0, 'guard', false, 'Green Label parts (not on the price list)', null, 'none', null, null, null, null, null, null,
  'green label|ไก่โคราช', '(breast|อก|\mlegs?\M|ขา|wing|ปีก|thigh|สะโพก|drum|น่อง|supreme)', null, 'guard'),

-- Under Roof (hotel / restaurant, valid 01.07.2025, no zone) --------------------
('ur_breast_noskin', 10, 1, 'chicken', true, 'Breast without skin Under Roof', null, 'kg', 177.00, null, null, null, null, null,
  'breast|อก', '(without|skinless|no skin|ลอก)', 'duck|เป็ด|egg|ไข่', 'Under Roof 01.07.2025'),
('ur_breast', 11, 1, 'chicken', true, 'Breast with skin Under Roof', null, 'kg', 170.00, null, null, null, null, null,
  'breast|อก', null, 'duck|เป็ด|egg|ไข่', 'Under Roof 01.07.2025'),
('ur_mid_wing', 12, 1, 'chicken', true, 'Middle wing Under Roof', null, 'kg', 304.80, null, null, null, null, null,
  'middle wing|mid wing|ปีกกลาง', null, 'duck|เป็ด', 'Under Roof 01.07.2025'),
('ur_top_wing', 13, 1, 'chicken', true, 'Top wing Under Roof', null, 'kg', 198.12, null, null, null, null, null,
  'top wing|ปีกบน|drumette', null, 'duck|เป็ด', 'Under Roof 01.07.2025'),
('ur_wing', 14, 1, 'chicken', true, 'Full wing Under Roof', null, 'kg', 222.25, null, null, null, null, null,
  'wing|ปีก', null, 'duck|เป็ด', 'Under Roof 01.07.2025'),
('ur_feet', 15, 1, 'chicken', true, 'Chicken feet Under Roof', null, 'kg', 241.30, null, null, null, null, null,
  'feet|ตีน', null, 'duck|เป็ด', 'Under Roof 01.07.2025'),
('ur_drum', 16, 1, 'chicken', true, 'Drumstick Under Roof', null, 'kg', 177.80, null, null, null, null, null,
  'drum|น่อง', null, 'duck|เป็ด', 'Under Roof 01.07.2025'),
('ur_thigh', 17, 1, 'chicken', true, 'Thigh Under Roof', null, 'kg', 154.94, null, null, null, null, null,
  'thigh|สะโพก', null, 'duck|เป็ด', 'Under Roof 01.07.2025'),
('ur_leg', 18, 1, 'chicken', true, 'Leg Under Roof', null, 'kg', 187.96, null, null, null, null, null,
  '\mlegs?\M|ขา', null, 'duck|เป็ด', 'Under Roof 01.07.2025'),
('ur_whole_small', 19, 2, 'chicken', true, 'Chicken Under Roof 1.0-1.1 kg', null, 'kg', 184.15, null, null, null, null, null,
  'whole|ยกตัว|ทั้งตัว|chicken under ?roof|ไก่ใต้หลังคา', '(\m1\.0\M|\m1\.1\M)', 'duck|เป็ด|egg|ไข่|liver|ตับ|gizzard|กึ๋น|heart|หัวใจ|neck|คอไก่|carcass|โครง', 'Under Roof 01.07.2025'),
('ur_whole', 20, 2, 'chicken', true, 'Chicken Under Roof 1.4-1.6 kg', null, 'kg', 167.64, null, null, null, null, null,
  'whole|ยกตัว|ทั้งตัว|chicken under ?roof|ไก่ใต้หลังคา', null, 'duck|เป็ด|egg|ไข่|liver|ตับ|gizzard|กึ๋น|heart|หัวใจ|neck|คอไก่|carcass|โครง', 'Under Roof 01.07.2025'),

-- Eggs ---------------------------------------------------------------------------
('duck_egg', 30, 1, 'egg', false, 'Duck eggs size 0', '80-2000-000000', 'pce', 14, 14, null, null, null, 0.08,
  'egg|ไข่', '(duck|เป็ด)', null, 'H/R 16.04.2026'),
('chicken_egg', 31, 1, 'egg', false, 'Eggs', '80-1000-000000', 'pce', 7.5, 7.5, 91, 7.0, 7.0, 0.06,
  'egg|ไข่', null, null, 'H/R 16.04.2026'),

-- Duck ---------------------------------------------------------------------------
('gsd_filet_m', 100, 1, 'duck', false, 'Golden Signature Duck male filet', null, 'kg', 900, 920, null, null, null, null,
  'fil+et|breast|อก|magret', '(golden|gsd)(?=.*)', null, 'H/R 16.04.2026'),
('gsd_filet_f', 101, 1, 'duck', false, 'Golden Signature Duck female filet', null, 'kg', 820, 840, null, null, null, null,
  'fil+et|breast|อก|magret', '(golden|gsd)', null, 'H/R 16.04.2026'),
('gsd_leg_m', 102, 1, 'duck', false, 'Golden Signature Duck male leg', null, 'kg', 643, 663, null, null, null, null,
  '\mlegs?\M|ขา|cuisse', '(golden|gsd)', null, 'H/R 16.04.2026'),
('gsd_leg_f', 103, 1, 'duck', false, 'Golden Signature Duck female leg', null, 'kg', 586, 606, null, null, null, null,
  '\mlegs?\M|ขา|cuisse', '(golden|gsd)', null, 'H/R 16.04.2026'),
('gsd_crown_m', 104, 1, 'duck', false, 'Golden Signature Duck male crown', null, 'kg', 920, null, null, null, null, null,
  'crown', '(golden|gsd)', null, 'H/R 16.04.2026'),
('gsd_crown_f', 105, 1, 'duck', false, 'Golden Signature Duck female crown', null, 'kg', 840, null, null, null, null, null,
  'crown', '(golden|gsd)', null, 'H/R 16.04.2026'),
('gsd_whole_m', 106, 2, 'duck', false, 'Golden Signature Duck male', null, 'kg', 420, 440, null, null, null, null,
  'golden|gsd', null, 'fil+et|breast|magret|\mlegs?\M|cuisse|crown', 'H/R 16.04.2026'),
('gsd_whole_f', 107, 2, 'duck', false, 'Golden Signature Duck female', null, 'kg', 400, 420, null, null, null, null,
  'golden|gsd', null, 'fil+et|breast|magret|\mlegs?\M|cuisse|crown', 'H/R 16.04.2026'),
('duck_aig', 110, 1, 'duck', false, 'Duck aiguillettes / filets', '20-D250-212KFR', 'kg', 350, 370, null, null, null, null,
  'aiguillette|สันใน', '(duck|เป็ด)', null, 'H/R 16.04.2026'),
('duck_liver', 111, 1, 'duck', false, 'Duck liver', '20-D250-204KFR', 'kg', 259, 279, null, null, null, null,
  'liver|ตับ', '(duck|เป็ด)', null, 'H/R 16.04.2026'),
('duck_gizzard', 112, 1, 'duck', false, 'Duck gizzard', '20-D250-207KFR', 'kg', 259, 279, null, null, null, null,
  'gizzard|กึ๋น', '(duck|เป็ด)', null, 'H/R 16.04.2026'),
('duck_carcass', 113, 1, 'duck', false, 'Duck carcass', '20-B250-207KFR', 'kg', 76, 96, null, null, null, null,
  'carcass|โครง', '(duck|เป็ด)', null, 'H/R 16.04.2026'),
('duck_wing', 114, 1, 'duck', false, 'Duck wings + manchon', '20-D250-225KFR', 'kg', 231, 251, null, null, null, null,
  'wing|ปีก|manchon', '(duck|เป็ด)', null, 'H/R 16.04.2026'),
('duck_crown', 115, 1, 'duck', false, 'Moscovy / Barbary duck crown', null, 'kg', 766, null, null, null, null, null,
  'crown', '(duck|เป็ด)', null, 'H/R 16.04.2026'),
('duck_filet', 116, 1, 'duck', false, 'Moscovy / Barbary duck filet', '20-C180-202KFR', 'kg', 746, 766, null, null, null, null,
  'fil+et|breast|อก|magret', '(duck|เป็ด)', null, 'H/R 16.04.2026'),
('duck_leg', 117, 1, 'duck', false, 'Moscovy / Barbary duck leg', '20-C180-203KFR', 'kg', 533, 553, null, null, null, null,
  '\mlegs?\M|ขา|cuisse', '(duck|เป็ด)', null, 'H/R 16.04.2026'),
('duck_whole_m', 118, 2, 'duck', false, 'Moscovy / Barbary duck male', '20-B250-100KFR', 'kg', 340, 360, null, null, null, null,
  'whole|ทั้งตัว|เป็ดตัว|barbary|บาร์บารี|moscovy|muscovy', '(duck|เป็ด)', null, 'H/R 16.04.2026'),
('duck_whole_f', 119, 2, 'duck', false, 'Moscovy / Barbary duck female', '20-C180-100KFR', 'kg', 320, 340, null, null, null, null,
  'whole|ทั้งตัว|เป็ดตัว|barbary|บาร์บารี|moscovy|muscovy', '(duck|เป็ด)', null, 'H/R 16.04.2026'),

-- Special poultry --------------------------------------------------------------------
('capon', 200, 1, 'special', false, 'Capon 3-4 kg', null, 'kg', 520, 540, 11, 508, 528, null,
  'capon|คาปอง', null, null, 'H/R 16.04.2026'),
('quail_big', 201, 1, 'special', false, 'Quails 190-250 g', null, 'kg', 426, 446, null, null, null, null,
  'quail|นกกระทา', '(\m19\d|\m2[0-5]\d|161|large|ใหญ่)', null, 'H/R 16.04.2026'),
('quail', 202, 1, 'special', false, 'Quails 130-160 g', null, 'kg', 335, 355, null, null, null, null,
  'quail|นกกระทา', null, null, 'H/R 16.04.2026'),
('pigeon_400', 203, 1, 'special', false, 'Pigeon 400+ g', null, 'pce', 680, 680, 11, 639, 659, 0.42,
  'pigeon|นกพิราบ', '(400 ?\+|\+ ?400|4[0-9]{2} ?-)', null, 'H/R 16.04.2026'),
('pigeon_350', 204, 1, 'special', false, 'Pigeon 350-400 g', null, 'pce', 630, 630, 11, 589, 609, 0.38,
  'pigeon|นกพิราบ', '(350 ?- ?400)', null, 'H/R 16.04.2026'),
('pigeon', 205, 1, 'special', false, 'Pigeon 300-350 g', null, 'pce', 550, 550, 11, 508, 528, 0.33,
  'pigeon|นกพิราบ', null, null, 'H/R 16.04.2026'),
('turkey', 206, 1, 'special', false, 'Turkey', null, 'kg', 517, 537, 11, 497, 517, null,
  'turkey|ไก่งวง|dinde', null, null, 'H/R 16.04.2026'),
('rabbit', 207, 1, 'special', false, 'Rabbit 1.1-1.4 kg', null, 'kg', 490, 490, 11, 467, 487, null,
  'rabbit|กระต่าย|lapin', null, null, 'H/R 16.04.2026'),

-- Chicken (hotel / restaurant, Red Label unless named) -------------------------------
('yellow', 300, 1, 'chicken', false, 'Yellow chicken 1.8-2.0 kg', null, 'kg', 558, 578, null, null, null, null,
  'yellow|ตะเภา', null, 'duck|เป็ด|egg|ไข่', 'H/R 16.04.2026'),
('poularde', 301, 1, 'chicken', false, 'Poularde 1.8-2.2 kg', null, 'kg', 376, 396, null, null, null, null,
  'poularde|พูลาร์ด', null, 'duck|เป็ด|egg|ไข่', 'H/R 16.04.2026'),
('green_label', 302, 1, 'chicken', false, 'Chicken Green Label 1.7-1.8 kg', '01-2170-100KFR', 'kg', 298, 318, null, null, null, null,
  'green label|ไก่โคราช', null, 'duck|เป็ด|egg|ไข่', 'H/R 16.04.2026'),
('spring', 303, 1, 'chicken', false, 'Spring chicken 400-600 g', '01-3170-100PFR', 'pce', 228, 248, null, null, null, 0.5,
  'spring|สปริง', null, 'duck|เป็ด|egg|ไข่', 'H/R 16.04.2026'),
('baby', 304, 1, 'chicken', false, 'Baby chicken 600-800 g', '01-3070-100PFR', 'pce', 178, 198, null, null, null, 0.7,
  'baby|เบบี้', null, 'duck|เป็ด|egg|ไข่', 'H/R 16.04.2026'),
('klong_phai', 305, 1, 'chicken', false, 'Klong Phai chicken 1-1.2 kg', null, 'kg', 200, 220, null, null, null, null,
  'klong ?phai|คลองไผ่', null, 'duck|เป็ด|egg|ไข่', 'H/R 16.04.2026'),
('feet', 310, 1, 'chicken', false, 'Chicken feet Red Label', '01-1110-207KER', 'kg', 183, 203, null, null, null, null,
  'feet|ตีน', null, 'duck|เป็ด', 'H/R 16.04.2026'),
('neck', 311, 1, 'chicken', false, 'Chicken neck Red Label', '01-1110-205KFR', 'kg', 46, 66, null, null, null, null,
  'neck|คอไก่', null, 'duck|เป็ด', 'H/R 16.04.2026'),
('liver', 312, 1, 'chicken', false, 'Chicken liver Red Label', '01-1110-209KFR', 'kg', 167, 187, null, null, null, null,
  'liver|ตับ', null, 'duck|เป็ด', 'H/R 16.04.2026'),
('gizzard', 313, 1, 'chicken', false, 'Chicken gizzard Red Label', '01-1110-208KFR', 'kg', 167, 187, null, null, null, null,
  'gizzard|กึ๋น', null, 'duck|เป็ด', 'H/R 16.04.2026'),
('heart', 314, 1, 'chicken', false, 'Chicken heart Red Label', '01-1110-210KFR', 'kg', 157, 177, null, null, null, null,
  'heart|หัวใจ', null, 'duck|เป็ด', 'H/R 16.04.2026'),
('carcass', 315, 1, 'chicken', false, 'Chicken carcass', '01-1110-212KFR', 'kg', 46, 66, null, null, null, null,
  'carcass|โครง', null, 'duck|เป็ด', 'H/R 16.04.2026'),
('oyster', 316, 1, 'chicken', false, 'Chicken oyster (sot-l''y-laisse)', '01-1110-217KFR', 'kg', 259, 279, null, null, null, null,
  'oyster|sot.?l.?y|saut', null, 'duck|เป็ด', 'H/R 16.04.2026'),
('supreme', 317, 1, 'chicken', false, 'Supreme Red Label', '01-1110-221KFR', 'kg', 354, 374, null, null, null, null,
  'supreme|suprême|พิเศษ', null, 'duck|เป็ด', 'H/R 16.04.2026'),
('breast', 318, 1, 'chicken', false, 'Breasts Red Label', '01-1110-201KFR', 'kg', 342, 362, null, null, null, null,
  'breast|อก', null, 'duck|เป็ด', 'H/R 16.04.2026'),
('drumstick', 319, 1, 'chicken', false, 'Drumstick Red Label', '01-1110-224KFR', 'kg', 294, 314, null, null, null, null,
  'drum|น่อง', null, 'duck|เป็ด', 'H/R 16.04.2026'),
('thigh', 320, 1, 'chicken', false, 'Leg thigh Red Label', '01-1110-223KFR', 'kg', 294, 314, null, null, null, null,
  'thigh|สะโพก', null, 'duck|เป็ด', 'H/R 16.04.2026'),
('leg', 321, 1, 'chicken', false, 'Leg Red Label', '01-1110-202PFR', 'kg', 283, 303, null, null, null, null,
  '\mlegs?\M|ขา', null, 'duck|เป็ด', 'H/R 16.04.2026'),
('wing', 322, 1, 'chicken', false, 'Wing Red Label', '01-1110-203KFR', 'kg', 162, 182, null, null, null, null,
  'wing|ปีก', null, 'duck|เป็ด', 'H/R 16.04.2026'),
('red_label', 330, 2, 'chicken', false, 'Chicken Red Label 1.4-1.5 kg', '01-1110-100KFR', 'kg', 222, 242, null, null, null, null,
  'red label chicken|ไก่ตองหนึ่ง|whole chicken|ไก่ทั้งตัว|ยกตัว', null, 'duck|เป็ด|egg|ไข่', 'H/R 16.04.2026'),
('red_label_alt', 331, 2, 'chicken', false, 'Chicken Red Label 1.4-1.5 kg', '01-1110-100KFR', 'kg', 222, 242, null, null, null, null,
  'chicken red label', null, 'duck|เป็ด|egg|ไข่|breast|อก|\mlegs?\M|ขา|wing|ปีก|thigh|สะโพก|drum|น่อง|supreme|พิเศษ|liver|ตับ|gizzard|กึ๋น|heart|หัวใจ|feet|ตีน|neck|carcass|oyster', 'H/R 16.04.2026');

-- The first GSD male rows must also say male: patterns written above as the
-- brand only, the sex is added here so the list stays readable.
update public.price_list set pattern = '^(?=.*(golden|gsd))(?=.*(\mmales?\M|ตัวผู้))' where id in ('gsd_filet_m', 'gsd_leg_m', 'gsd_crown_m', 'gsd_whole_m');
update public.price_list set pattern = '^(?=.*(duck|เป็ด))(?=.*(\mmales?\M|ตัวผู้))'   where id = 'duck_whole_m';


-- ----------------------------------------------------------------------------
-- 2. Client zone (Bangkok unless marked up-country)
-- ----------------------------------------------------------------------------
create table if not exists public.client_price_zones (
  client_key  text primary key,                -- lower(trim(customer name on the paper))
  client_name text not null,
  zone        text not null check (zone in ('bangkok', 'upcountry')),
  updated_by  uuid references public.profiles(id),
  updated_at  timestamptz not null default now()
);

comment on table public.client_price_zones is
  'Clients priced at the up-country list in the Management summary. Migration 031.';

alter table public.client_price_zones enable row level security;
revoke all on public.client_price_zones from anon, authenticated;
grant all on public.client_price_zones to service_role;


-- ----------------------------------------------------------------------------
-- 3. Price of one line
-- ----------------------------------------------------------------------------
-- Returns the matched price-list row id (null = no match). Internal helper.
create or replace function public.price_list_match(p_description text, p_po text)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  t   text := lower(coalesce(p_description, ''));
  ur  boolean := coalesce(p_po, '') ~* '^\s*UR' or t ~ 'under ?roof|ใต้หลังคา';
  hit text;
begin
  if t = '' then return null; end if;
  -- On an Under Roof paper, a product missing from the Under Roof list falls
  -- back to the hotel / restaurant list (second pass, ur = false).
  for pass in 1..2 loop
    select pl.id into hit
    from public.price_list pl
    where t ~ pl.key
      and (pl.pattern is null or t ~ pl.pattern)
      and (pl.exclude is null or t !~ pl.exclude)
      and (pl.under_roof = ur or (not pl.under_roof and (not ur or pl.family <> 'chicken')))
    order by (pl.tier = 0) desc, regexp_instr(t, pl.key), pl.tier, pl.sort
    limit 1;
    exit when hit is not null or not ur;
    ur := false;
  end loop;
  return hit;
end;
$$;

revoke all on function public.price_list_match(text, text) from public, anon, authenticated;


-- ----------------------------------------------------------------------------
-- 4. The summary's numbers
-- ----------------------------------------------------------------------------
create or replace function public.management_summary(p_from date, p_to date, p_company text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_co    text := nullif(p_company, 'all');
  v_start date;
  v_from  date;
  v_out   jsonb;
begin
  if coalesce(public.current_role(), '') <> 'admin' then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_to < p_from then
    raise exception 'choose a start and an end date' using errcode = '22023';
  end if;
  if p_to - p_from > 400 then
    raise exception 'choose a period of about one year or less' using errcode = '22023';
  end if;
  if v_co is not null and v_co not in ('Prosun Farm', 'Prosun Food') then
    raise exception 'unknown company' using errcode = '22023';
  end if;

  select s.count_from into v_start from public.management_settings s where s.id = 1;
  v_from := greatest(p_from, v_start);

  with raw as materialized (
    select p.id as paper_id, p.work_date, p.company, p.po_number,
           coalesce(nullif(trim(p.customer_name), ''), '—') as client,
           l.description, l.actual_kg, l.ordered_qty, l.ordered_unit,
           coalesce(p.po_number, '') ~* '^\s*UR' as ur
    from public.weighing_papers p
    join public.weighing_lines l on l.paper_id = p.id
    where p.status = 'confirmed'
      and p.work_date between v_from and p_to
      and (v_co is null or p.company = v_co)
  ),
  -- Papers repeat the same few hundred descriptions: match each one once.
  matched as materialized (
    select d.description, d.ur,
           public.price_list_match(d.description, case when d.ur then 'UR' end) as price_id
    from (select distinct description, ur from raw) d
  ),
  lines as (
    select r.*, m.price_id
    from raw r join matched m on m.description is not distinct from r.description and m.ur = r.ur
  ),
  priced as (
    select x.*,
           case
             when pl.unit = 'kg' then
               case when x.actual_kg > 0 then round(x.actual_kg * x.unit_price, 2) end
             when pl.unit = 'pce' then
               case when x.pieces > 0 then round(x.pieces * x.unit_price, 2) end
           end as revenue
    from (
      select l.*, pl.unit as price_unit, pl.name as price_name,
             coalesce(z.zone, 'bangkok') as zone,
             case
               when pl.unit = 'pce' and l.ordered_unit = 'pcs' and l.ordered_qty > 0 then l.ordered_qty
               when pl.unit = 'pce' and l.actual_kg > 0 and pl.piece_kg > 0 then round(l.actual_kg / pl.piece_kg)
             end as pieces,
             -- quantity tier: pieces when known (ordered in pieces), else none
             case
               when pl.bulk_min is not null
                    and (case when l.ordered_unit = 'pcs' then l.ordered_qty end) >= pl.bulk_min
                 then case when z.zone = 'upcountry' then coalesce(pl.bulk_up, pl.bulk_bkk) else pl.bulk_bkk end
               else case when z.zone = 'upcountry' then coalesce(pl.price_up, pl.price_bkk) else pl.price_bkk end
             end as unit_price
      from lines l
      left join public.price_list pl on pl.id = l.price_id
      left join public.client_price_zones z on z.client_key = lower(l.client)
    ) x
    left join public.price_list pl on pl.id = x.price_id
  ),
  papers_day as (
    select work_date, count(distinct paper_id) as papers
    from lines group by work_date
  ),
  days as (
    select work_date, sum(actual_kg) as kg, sum(revenue) as revenue
    from priced group by work_date
  ),
  months as (
    select date_trunc('month', d.work_date)::date as month,
           count(*) as days,
           sum(pd.papers) as papers,
           coalesce(sum(d.kg), 0) as kg,
           coalesce(sum(d.revenue), 0) as revenue
    from days d join papers_day pd using (work_date)
    group by 1
  ),
  month_priced as (
    select date_trunc('month', work_date)::date as month,
           coalesce(sum(actual_kg) filter (where revenue is not null), 0) as kg_priced
    from priced group by 1
  ),
  postp as (
    select coalesce(w.from_delivery_date, w.from_work_date) as original_date,
           w.reason, w.kg_ordered as kg,
           w.to_delivery_date - coalesce(w.from_delivery_date, w.from_work_date) as delay_days
    from public.weighing_postponements w
    where (v_co is null or w.company = v_co)
    union all
    select r.original_date, r.reason, r.quantity_kg, r.new_date - r.original_date
    from public.order_postponements r
    where (v_co is null or r.company = v_co)
  ),
  postp_period as (
    select * from postp where original_date between v_from and p_to
  ),
  postp_month as (
    select date_trunc('month', original_date)::date as month, count(*) as n,
           (array_agg(reason order by cnt desc, reason))[1] as top_reason
    from (select original_date, reason, count(*) over (partition by date_trunc('month', original_date), reason) as cnt
          from postp_period) s
    group by 1
  )
  select jsonb_build_object(
    'from', v_from, 'to', p_to, 'count_from', v_start,
    'totals', (select jsonb_build_object(
        'days',       (select count(*) from days),
        'papers',     (select coalesce(sum(papers), 0) from papers_day),
        'kg',         coalesce(sum(actual_kg), 0),
        'kg_priced',  coalesce(sum(actual_kg) filter (where revenue is not null), 0),
        'revenue',    coalesce(sum(revenue), 0),
        'lines',      count(*),
        'lines_priced', count(*) filter (where revenue is not null),
        'upcountry_revenue', coalesce(sum(revenue) filter (where zone = 'upcountry'), 0),
        'under_roof_revenue', coalesce(sum(revenue) filter (where price_id like 'ur\_%'), 0)
      ) from priced),
    'months', coalesce((select jsonb_agg(jsonb_build_object(
        'month', m.month, 'days', m.days, 'papers', m.papers, 'kg', m.kg,
        'kg_priced', coalesce(mp.kg_priced, 0), 'revenue', m.revenue,
        'postponed', coalesce(pm.n, 0), 'top_reason', pm.top_reason) order by m.month)
      from months m
      left join month_priced mp using (month)
      left join postp_month pm using (month)), '[]'::jsonb),
    'reasons', (select jsonb_build_object(
        'total', coalesce(sum(r.times), 0),
        'list', coalesce(jsonb_agg(r order by r.times desc, r.reason) filter (where r.reason is not null), '[]'::jsonb))
      from (select reason, count(*) as times, coalesce(sum(kg), 0) as kg, round(avg(delay_days), 1) as avg_delay
            from postp_period group by reason) r),
    'products', coalesce((select jsonb_agg(x order by x.revenue desc nulls last) from (
        select price_id as id, min(price_name) as name, min(price_unit) as unit,
               sum(actual_kg) as kg, sum(pieces) as pieces, count(*) as lines,
               sum(revenue) as revenue
        from priced where revenue is not null
        group by price_id order by sum(revenue) desc limit 20) x), '[]'::jsonb),
    'clients', coalesce((select jsonb_agg(x order by x.revenue desc nulls last) from (
        select min(client) as client, min(zone) as zone, sum(actual_kg) as kg,
               coalesce(sum(revenue), 0) as revenue,
               coalesce(sum(actual_kg) filter (where revenue is null), 0) as kg_unpriced
        from priced group by lower(client)
        order by coalesce(sum(revenue), 0) desc, sum(actual_kg) desc nulls last limit 25) x), '[]'::jsonb),
    'unpriced', coalesce((select jsonb_agg(x order by x.kg desc nulls last) from (
        select min(description) as description,
               min(price_name) as why,
               coalesce(sum(actual_kg), 0) as kg, count(*) as lines,
               min(ordered_unit) as unit
        from priced where revenue is null
        group by lower(trim(description)), price_id
        order by coalesce(sum(actual_kg), 0) desc limit 25) x), '[]'::jsonb),
    'zones', coalesce((select jsonb_agg(jsonb_build_object('client', client_name, 'zone', zone) order by client_name)
        from public.client_price_zones where zone = 'upcountry'), '[]'::jsonb),
    'price_list', (select jsonb_agg(jsonb_build_object(
        'name', name, 'code', code, 'unit', unit, 'bkk', price_bkk, 'up', price_up,
        'bulk_min', bulk_min, 'bulk_bkk', bulk_bkk, 'bulk_up', bulk_up, 'source', source) order by sort)
        from public.price_list where unit <> 'none' and id <> 'red_label_alt')
  ) into v_out;

  return v_out;
end;
$$;

comment on function public.management_summary(date, date, text) is
  'Management › Summary: kg per day and month, approximate gross revenue at list prices, '
  'postponement reasons. Admin only; read-only. Migration 031.';


-- ----------------------------------------------------------------------------
-- 5. Mark a client up-country or Bangkok
-- ----------------------------------------------------------------------------
create or replace function public.management_set_client_zone(p_client text, p_zone text)
returns text
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  k text := lower(trim(coalesce(p_client, '')));
begin
  if coalesce(public.current_role(), '') <> 'admin' then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if k = '' or p_zone not in ('bangkok', 'upcountry') then
    raise exception 'choose a client and a zone' using errcode = '22023';
  end if;
  if p_zone = 'bangkok' then
    delete from public.client_price_zones where client_key = k;
  else
    insert into public.client_price_zones (client_key, client_name, zone, updated_by, updated_at)
    values (k, trim(p_client), 'upcountry', auth.uid(), now())
    on conflict (client_key) do update
      set zone = excluded.zone, client_name = excluded.client_name,
          updated_by = excluded.updated_by, updated_at = excluded.updated_at;
  end if;
  return p_zone;
end;
$$;

comment on function public.management_set_client_zone(text, text) is
  'Prices a client at the up-country list (or back to Bangkok) in the Management summary. Admin only. Migration 031.';

revoke all on function public.management_summary(date, date, text)        from public, anon;
revoke all on function public.management_set_client_zone(text, text)      from public, anon;
grant execute on function public.management_summary(date, date, text)     to authenticated, service_role;
grant execute on function public.management_set_client_zone(text, text)   to authenticated, service_role;
