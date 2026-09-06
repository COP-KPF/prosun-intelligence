-- ============================================================================
-- Prosun Intelligence — Migration 001: Sale support order module,
-- product/type catalog, and whole-bird yield reference.
--
-- Run this in the Supabase SQL Editor AFTER sql/schema.sql. This is the
-- first migration under the versioned-migrations discipline agreed with
-- Clément on 4 Sep 2026 — going forward, schema changes land as numbered
-- files in sql/migrations/ instead of ad hoc SQL Editor edits. (The
-- `products`, `quotations`, and `quotation_lines` tables already live on
-- the database from before this discipline started, added directly via
-- the SQL Editor — they are NOT touched by this migration and are not
-- redefined here. Worth eventually writing a "000_baseline" migration
-- that captures their current live definition for the record, but that
-- needs a `pg_dump`/SQL Editor "Definition" check against the actual
-- database rather than being reverse-engineered from app.js — flagged
-- as a follow-up, not done here.)
--
-- Full spec this implements: see "Sale support (middle office), production
-- planning, and purchasing COGS" in the Prosun Intelligence project.
--
-- Scope of this migration:
--   1. Expand profiles.role to add sale_support / purchasing / production.
--   2. cut_yield_reference — piece weights for whole-bird yield math.
--   3. order_products — the TYPE-scoped catalog sale support uses today.
--   4. sale_orders / sale_order_lines — header + line-items order entry,
--      replacing the monthly Excel table.
--
-- Deliberately NOT in this migration (comes next, once this is reviewed
-- and live with real data):
--   - Purchasing/COGS ratio tables and the two-named-account cost-data
--     restriction (bird input cost + travel/freight).
--   - The leftover-parts ledger and "system suggests, team confirms"
--     allocation tables.
--   - The end-of-day production sequencing report (a query/view over
--     sale_order_lines once there's real data to test it against).
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. ROLE EXPANSION
-- ----------------------------------------------------------------------------
-- Purely additive — no existing profile's role value changes. Promote
-- specific people the same way the README already documents:
--   update public.profiles set role = 'sale_support' where id = '<uuid>';
alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check
  check (role in ('admin', 'director', 'sales', 'sale_support', 'purchasing', 'production'));

comment on constraint profiles_role_check on public.profiles is
  'sale_support = order registration; purchasing = COGS ratio + poultry calculator (read) + buffer decision; production = read-only order/sequencing visibility. See sql/migrations/001 for scope.';


-- ----------------------------------------------------------------------------
-- 2. CUT YIELD REFERENCE  (piece weights for the poultry calculator's
--    kg-ordered -> birds-needed conversion, and for the leftover-parts
--    reconciliation once that's built. Source: Clément's real reference
--    file "Weight calculations formula.xlsx", read 5 Sep 2026 — sku codes,
--    species/variant, and piece weights are copied verbatim from it.
--
--    leg_pool_group: chicken Red Label Leg/Thigh/Drumstick share this
--    value ('leg') because they are the SAME physical leg, sold either
--    whole or split — confirmed by Clément 5 Sep 2026 ("it can be split,
--    i have client who orders thigh and other who orders full leg"). Any
--    future yield/leftover calculation must total demand across a
--    leg_pool_group in "leg units" rather than summing whole-leg and
--    thigh/drumstick bird-equivalents independently, or it will double-
--    count the same physical part. See the "Whole-bird yield" section of
--    the process doc for the full worked explanation.
-- ----------------------------------------------------------------------------
create table if not exists public.cut_yield_reference (
  id               uuid primary key default gen_random_uuid(),
  species          text not null check (species in ('Chicken', 'Duck')),
  variant          text not null,          -- e.g. 'Red Label', 'Golden Signature Duck male'
  cut_name         text not null,          -- e.g. 'Breast', 'Leg (whole)', 'Thigh', 'Carcass'
  sku              text,                   -- Clément's internal article code, where known
  piece_weight_g   numeric not null,
  paired           boolean not null,       -- true = 2 per bird (formula divides by 2), false = 1 per bird (carcass)
  leg_pool_group   text,                   -- shared-pool tag; see comment above
  created_at       timestamptz not null default now(),
  unique (species, variant, cut_name)
);

comment on table public.cut_yield_reference is
  'Reference piece weights driving `((kg_ordered * 1000) / piece_weight_g) / (paired ? 2 : 1)` = birds-equivalent needed for that cut.';

alter table public.cut_yield_reference enable row level security;

create policy "cut_yield_reference: all roles read"
  on public.cut_yield_reference for select
  using (public.current_role() in ('admin', 'director', 'sales', 'sale_support', 'purchasing', 'production'));

create policy "cut_yield_reference: admin manages"
  on public.cut_yield_reference for all
  using (public.current_role() = 'admin')
  with check (public.current_role() = 'admin');

insert into public.cut_yield_reference
  (species, variant, cut_name, sku, piece_weight_g, paired, leg_pool_group) values
  ('Chicken', 'Red Label', 'Wing', '01-1110-203KFR', 90, true, null),
  ('Chicken', 'Red Label', 'Leg (whole)', '01-1110-202PFR', 230, true, 'leg'),
  ('Chicken', 'Red Label', 'Drumstick', '01-1110-224KFR', 110, true, 'leg'),
  ('Chicken', 'Red Label', 'Thigh', '01-1110-223KFR', 130, true, 'leg'),
  ('Chicken', 'Red Label', 'Breast', '01-1110-201KFR', 190, true, null),
  ('Chicken', 'Red Label', 'Supreme', '01-1110-221KFR', 210, true, null),
  ('Chicken', 'Red Label', 'Carcass', '01-1110-212KFR', 600, false, null),
  ('Duck', 'Moscovy/Barbary female', 'Filet', '20-C180-202KFR', 190, true, null),
  ('Duck', 'Moscovy/Barbary male', 'Filet', '20-B250-202KFR', 325, true, null),
  ('Duck', 'Moscovy/Barbary female', 'Leg', '20-C180-203KFR', 190, true, null),
  ('Duck', 'Moscovy/Barbary male', 'Leg', '20-B250-203KFR', 310, true, null),
  ('Duck', 'Golden Signature Duck female', 'Filet', null, 250, true, null),
  ('Duck', 'Golden Signature Duck male', 'Filet', null, 300, true, null),
  ('Duck', 'Golden Signature Duck female', 'Leg', null, 225, true, null),
  ('Duck', 'Golden Signature Duck male', 'Leg', null, 280, true, null),
  ('Duck', 'Moscovy/Barbary', 'Carcass', '20-B250-207KFR', 600, false, null);
comment on column public.cut_yield_reference.variant is
  'Only Chicken Red Label and Duck Moscovy/Barbary + Golden Signature Duck are seeded — those are the only lines in the reference file with piece weights. Green Label, Under Roof, and other lines have no yield weights on file yet; add rows here the same way once Clément supplies them.';


-- ----------------------------------------------------------------------------
-- 3. ORDER PRODUCTS  (the sale-support TYPE-scoped catalog — separate from
--    the existing `products` table, which backs CRM quotations and is a
--    shorter, different list. Kept separate so this migration never
--    touches the quotation flow.)
-- ----------------------------------------------------------------------------
create table if not exists public.order_products (
  id            uuid primary key default gen_random_uuid(),
  type          text not null check (type in ('Raw', 'Cooked', 'Delica', 'UnderRoof', 'PaleoRobbie', 'EasyHealth', 'Eggs')),
  name          text not null,
  default_unit  text check (default_unit in ('Kg', 'Pcs', 'Grams', 'Pack')),
  cut_yield_id  uuid references public.cut_yield_reference(id),
  active        boolean not null default true,
  created_at    timestamptz not null default now()
);

comment on table public.order_products is
  'TYPE filters this list in the order-entry UI — matches the cascading Type -> Product dropdown in the source Excel workbook exactly (named ranges Raw/Cooked/Delica/UnderRoof/PaleoRobbie/EasyHealth/Eggs).';

create index if not exists order_products_type_idx on public.order_products (type);

alter table public.order_products enable row level security;

create policy "order_products: all roles read"
  on public.order_products for select
  using (public.current_role() in ('admin', 'director', 'sales', 'sale_support', 'purchasing', 'production'));

create policy "order_products: admin manages"
  on public.order_products for all
  using (public.current_role() = 'admin')
  with check (public.current_role() = 'admin');

-- ----------------------------------------------------------------------------
-- 169 real catalog rows, extracted 5 Sep 2026 from Clément's live workbook
-- ("NEW - Restaurant Order Delivery for August 2026", sheet 'Parameters',
-- named ranges Raw/Cooked/Delica/UnderRoof/PaleoRobbie/EasyHealth/Eggs).
-- Names are kept exactly as typed in the source file, Thai text included,
-- so this list matches what sale support already knows by eye. Two literal
-- duplicate 'Duck Eggs (ไข่เป็ด)' rows exist in the source PaleoRobbie range
-- (rows 172-173 of Parameters) — kept as-is rather than silently deduped;
-- flag to Clément whether that's a data entry slip in the source sheet.
-- ----------------------------------------------------------------------------
insert into public.order_products (type, name) values
  ('Raw', 'Aiguillettes (สันในเป็ด)'),
  ('Raw', 'Baby Chicken (เบบี้ชิคเก้น)'),
  ('Raw', 'Breasts Red Label (อกติดหนัง)'),
  ('Raw', 'Breasts Red Label without skin (อกลอกหนัง)'),
  ('Raw', 'Capon (ไก่ชะปอง)'),
  ('Raw', 'Chicken Skin (หนังไก่)'),
  ('Raw', 'Chicken Carcass (โครงไก่)'),
  ('Raw', 'Chicken Eggs (ไข่ไก่)'),
  ('Raw', 'Chicken Feet (ตีนไก่)'),
  ('Raw', 'Chicken Gizzard (กึ๋นไก่)'),
  ('Raw', 'Chicken heart (หัวใจไก่)'),
  ('Raw', 'Chicken Liver (ตับไก่)'),
  ('Raw', 'Chicken Neck (คอไก่)'),
  ('Raw', 'Chicken Oyster'),
  ('Raw', 'Chicken Red Label Supreme (อกพิเศษติดหนัง+ติดปีกบน)'),
  ('Raw', 'Drum Stick (น่องไก่)'),
  ('Raw', 'Duck Carcass(โครงเป็ด)'),
  ('Raw', 'Duck Fat (มันเป็ด)'),
  ('Raw', 'Duck Feet (ตีนเป็ด)'),
  ('Raw', 'Duck Gizzard (กึ๋นเป็ด)'),
  ('Raw', 'Duck heart (หัวใจเป็ด)'),
  ('Raw', 'Duck Liver (ตับเป็ด)'),
  ('Raw', 'Duck Neck (คอเป็ด)'),
  ('Raw', 'Duck Skin (หนังเป็ด)'),
  ('Raw', 'Female Duck Breast (อกเป็ดตัวเมีย)'),
  ('Raw', 'Female Duck Leg (ขาเป็ดตัวเมีย)'),
  ('Raw', 'Grass Fed Milk 1200 Ml'),
  ('Raw', 'Greek Yogurt (กรีกโยเกิร์ต) 450gr'),
  ('Raw', 'Green Label Chicken (ไก่โคราช)'),
  ('Raw', 'Guinea Fowl (ไก่ต๊อก)'),
  ('Raw', 'Jersey milks ( นมเจอร์ซี่) 300 ml'),
  ('Raw', 'Legs Red Label (ขาไก่ตองหนึ่ง)'),
  ('Raw', 'Male Duck Breast (อกเป็ดตัวผู้)'),
  ('Raw', 'Male Duck Leg (ขาเป็ดตัวผู้)'),
  ('Raw', 'Pigoen (นกพิราบ)'),
  ('Raw', 'Poularde Chicken (ไก่กินนม)'),
  ('Raw', 'Quail (นกกระทา)'),
  ('Raw', 'Rabbit (กระต่าย)'),
  ('Raw', 'Red Label Chicken (ไก่ตองหนึ่ง)'),
  ('Raw', 'Spring Baby (สปริงชิคเก้น)'),
  ('Raw', 'Thigh Red Label (สะโพกไก่ตองหนึ่ง)'),
  ('Raw', 'Turkey (ไก่งวง)'),
  ('Raw', 'Under Roof Chicken (ฟาร์มใต้หลังคา)'),
  ('Raw', 'Whole Female Duck (เป็ดตัวเมีย)'),
  ('Raw', 'Whole Male Duck (เป็ดตัวผู้)'),
  ('Raw', 'Wings Red Label (ปีกไก่ตองหนึ่ง)'),
  ('Raw', 'Yellow Chicken (ไก่ตะเภาทอง)'),
  ('Raw', 'Turkey Breast (อกไก่งวง)'),
  ('Raw', 'Turkey Leg (ขาไก่งวง)'),
  ('Raw', 'Duck Mouth (ปากเป็ด)'),
  ('Raw', 'Duck Wing (ปีกเป็ด)'),
  ('Raw', 'Whole Female Duck Etouffe (เป็ดกลมตัวเมีย)'),
  ('Raw', 'Whole Male Duck Etouffe (เป็ดกลมตัวผู้)'),
  ('Raw', 'Middle Wing (ปีกไก่กลาง)'),
  ('Raw', 'Top Wing (ปีกไก่บน)'),
  ('Raw', 'Chicken Cartilage (กระดูกอ่อนไก่)'),
  ('Raw', 'Chicken Skirt (กระบังลมไก่)'),
  ('Raw', 'Chicken Butt (ตูดไก่)'),
  ('Raw', 'Chicken Tenderloin (สันในไก่)'),
  ('Raw', 'Duck Intestine (ไส้เป็ด)'),
  ('Raw', 'Turkey (ไก่งวง) size 4.5-5 kg'),
  ('Raw', 'Turkey (ไก่งวง) size 5-6 kg'),
  ('Raw', 'Turkey (ไก่งวง) size 7-9 kg'),
  ('Raw', 'Turkey (ไก่งวง) size 9 kg+'),
  ('Cooked', 'Aloo Gobi Massala'),
  ('Cooked', 'Butter Chicken No Cashew Nuts'),
  ('Cooked', 'Chicken Basquaise (Pepper Sauce)'),
  ('Cooked', 'Chicken In Cream Sauce (Blanquette)'),
  ('Cooked', 'Chicken In Mushroom Sauce (Forestiere)'),
  ('Cooked', 'Chicken In Red Wine Sauce (Coq Au Vin)'),
  ('Cooked', 'Chicken Massaman'),
  ('Cooked', 'Chicken Morrocan Sauce (Zaalouck)'),
  ('Cooked', 'Dal Tadka'),
  ('Cooked', 'Duck In Orange Sauce (Canard A L''Orange)'),
  ('Cooked', 'Gan Leuang Kai'),
  ('Cooked', 'Garlic Sauce Stir Fried With Chicken'),
  ('Cooked', 'Green Curry Chicken'),
  ('Cooked', 'Green Curry Vegetarian'),
  ('Cooked', 'Kaprao Kai'),
  ('Cooked', 'Kaprao Moo'),
  ('Cooked', 'Lasagna Chicken'),
  ('Cooked', 'Palo Kai'),
  ('Cooked', 'Panang Kai'),
  ('Cooked', 'Panang Duck'),
  ('Cooked', 'Red Curry Chicken'),
  ('Cooked', 'Stir Fried Chicken In Black Pepper'),
  ('Cooked', 'Stir Fried Chicken With Ginger'),
  ('Cooked', 'Veal Bourguignon Replace By Beef Bourguignon'),
  ('Cooked', 'Veal In Cream Sauce (Blanquette)'),
  ('Delica', 'Ballotine Red label Leg stuffed with Foie Gras and Truffle'),
  ('Delica', 'Bangers sausage'),
  ('Delica', 'Chicken Gizzard Confit (กึ๋นไก่ฟี)'),
  ('Delica', 'Chicken Knack sausage frozen (ฟรีส) แพคละ 5 ชิ้น ชิ้นละ 50 กรัม (น้ำหนัก แพคละ 250 กรัม)'),
  ('Delica', 'Chicken Breakfast Sausage 25gr'),
  ('Delica', 'Chicken Breakfast Sausage 50gr'),
  ('Delica', 'Chicken Basquaise Sausage 100gr'),
  ('Delica', 'Chicken Chipolata Sausage 50gr'),
  ('Delica', 'Chicken Rillette (ขาไก่บด)'),
  ('Delica', 'Chicken Stock (สต็อกไก่)'),
  ('Delica', 'Duck Fat (มันเป็ด)'),
  ('Delica', 'Duck Gizzard Confit (กึ๋นเป็ดฟี)'),
  ('Delica', 'Duck Glaze (ซอสเป็ด)'),
  ('Delica', 'Duck Leg Confit Female (packed 3pcs/Vaccum Bag)'),
  ('Delica', 'Duck Legs Confit (ขาเป็ดกงฟี แพคละ 2 ชิ้น)'),
  ('Delica', 'Duck Rillette (ขาเป็ดบด)'),
  ('Delica', 'Duck Sausage 100gr'),
  ('Delica', 'Duck Sausage frozen (ฟรีส) แพคละ 3 ชิ้น ชิ้นละ 100 กรัม (น้ำหนัก แพคละ 300 กรัม)'),
  ('Delica', 'Duck Stock (สต๊อกเป็ด)'),
  ('Delica', 'Duck Terrine With Rosemary (เทอร์รีนเป็ดและโรสแมรี่)'),
  ('Delica', 'Foie Gras Armagnac (ฟัวกราส์อาร์มาญัก)'),
  ('Delica', 'Foie Gras Monbazillac / Porto (ฟัวกราส์ ปอร์โต้/มอนบาซิลยัค)'),
  ('Delica', 'Foie Gras Salt & Pepper (ฟัวกราส์เกลือพริกไทย)'),
  ('Delica', 'Knacked Smoked Chicken Sausage 25gr'),
  ('Delica', 'Knacked Smoked Chicken Sausage 50gr'),
  ('Delica', 'Liver Mousse 4 Spices (มูสตับเครื่องเทศ 4 ชนิด)'),
  ('Delica', 'Liver Mousse Porto And Truffles (มูสตับปอร์โต้และทรัฟเฟิล)'),
  ('Delica', 'Pigeon Terrine With Armagnac (เทอร์รีนนกพิราบ อาร์มาญัก )'),
  ('Delica', 'Poultry Sausage frozen (ฟรีส) แพคละ 3 ชิ้น ชิ้นละ 100 กรัม(น้ำหนัก แพคละ 300 กรัม)'),
  ('Delica', 'Poultry Terrine With Thym (เทอร์รีนรวมไทม์)'),
  ('Delica', 'Duck & Pistachio Terrine (เทอร์รีนเป็ดและพิสตาชิโอ)'),
  ('Delica', 'Smoked Bone-in Turkey leg'),
  ('Delica', 'Smoked boneless breast meat'),
  ('Delica', 'Smoked boneless turkey leg meat'),
  ('Delica', 'Smoked Chicken Filet Full (อกไก่รมควันแบบเต็มชิ้น)'),
  ('Delica', 'Smoked Chicken Filet Sliced (อกไก่รมควันแบบสไลด์)'),
  ('Delica', 'Smoked Duck Filet Full (อกเป็ดรมควันแบบเต็มชิ้น)'),
  ('Delica', 'Smoked Duck Filet Sliced (อกเป็ดรมควันแบบสไลด์)'),
  ('Delica', 'Sous vide Butterfly Baby chicken No Head (เบบี้ซูวี)'),
  ('Delica', 'Sous vide Butterfly Kai Tong (red label) No Head (ไก่ตองซูวี)'),
  ('Delica', 'Duck Wellington'),
  ('UnderRoof', 'Breasts With Skin Underroof (อกติดหนังใต้หลังคา)'),
  ('UnderRoof', 'Breasts Without Skin Underroof (อกลอกหนังใต้หลังคา)'),
  ('UnderRoof', 'Chicken Carcass Underroof (โครงไก่ใต้หลังคา)'),
  ('UnderRoof', 'Chicken Feet Underroof (ตีนไก่ใต้หลังคา)'),
  ('UnderRoof', 'Drum Stick Underroof (น่องไก่ใต้หลังคา)'),
  ('UnderRoof', 'Full Wing Underroof (ปีกไก่เต็มใต้หลังคา)'),
  ('UnderRoof', 'Leg Underroof (ขาไก่ใต้หลังคา)'),
  ('UnderRoof', 'Middle Wing Underroof (ปีกไก่กลางใต้หลังคา)'),
  ('UnderRoof', 'Thigh Underroof (สะโพกใต้หลังคา)'),
  ('UnderRoof', 'Top Wing Underroof (ปีกปลายไก่ใต้หลังคา)'),
  ('UnderRoof', 'Whole Chicken Underroof (ไก่ใต้หลังคายกตัว)'),
  ('PaleoRobbie', 'Baby Chicken (เบบี้ชิคเก้น)'),
  ('PaleoRobbie', 'Red Label Chicken (ไก่ตองหนึ่ง)'),
  ('PaleoRobbie', 'Yellow Chicken (ไก่ตะเภาทอง)'),
  ('PaleoRobbie', 'Capon (ไก่ชะปอง)'),
  ('PaleoRobbie', 'Breasts Red Label without skin (อกลอกติดหนัง)'),
  ('PaleoRobbie', 'Wings Red Label (ปีกไก่ตองหนึ่ง)'),
  ('PaleoRobbie', 'Legs Red Label (ขาไก่ตองหนึ่ง)'),
  ('PaleoRobbie', 'Male Duck Breast (อกเป็ดตัวผู้)'),
  ('PaleoRobbie', 'Female Duck Breast (อกเป็ดตัวเมีย)'),
  ('PaleoRobbie', 'Male Duck Leg (ขาเป็ดตัวผู้)'),
  ('PaleoRobbie', 'Female Duck Leg (ขาเป็ดตัวเมีย)'),
  ('PaleoRobbie', 'Chicken Eggs (ไข่ไก่)'),
  ('PaleoRobbie', 'Duck Eggs (ไข่เป็ด)'),
  ('PaleoRobbie', 'Duck Eggs (ไข่เป็ด)'),
  ('PaleoRobbie', 'Chicken Liver (ตับไก่)'),
  ('PaleoRobbie', 'Chicken heart (หัวใจไก่)'),
  ('PaleoRobbie', 'Chicken Gizzard (กึ๋นไก่)'),
  ('PaleoRobbie', 'Chicken Carcass (โครงไก่)'),
  ('PaleoRobbie', 'Chicken Feet (ตีนไก่)'),
  ('PaleoRobbie', 'Quail (นกกระทา)'),
  ('PaleoRobbie', 'Rabbit (กระต่าย)'),
  ('EasyHealth', 'Chicken Tradition breast Sousvide frozen'),
  ('EasyHealth', 'Chicken Tradition breast cutting Sousvide frozen'),
  ('EasyHealth', 'Chicken Sousvide garlic powder & Herbs'),
  ('EasyHealth', 'Diced Chicken breast Sousvide and Smoked'),
  ('Eggs', 'Duck Eggs (ไข่เป็ด)'),
  ('Eggs', 'Chicken Eggs (ไข่ไก่)'),
  ('Eggs', 'Chicken Eggs Prosun Farm (ไข่ไก่)');
-- Link the unambiguous Chicken Red Label cuts to their yield reference row
-- (exact 1:1 name matches only — see the open question below for the ones
-- deliberately left unmapped).
update public.order_products op
set cut_yield_id = cyr.id
from public.cut_yield_reference cyr
where cyr.species = 'Chicken' and cyr.variant = 'Red Label'
  and (
    (op.name = 'Breasts Red Label (อกติดหนัง)' and cyr.cut_name = 'Breast') or
    (op.name = 'Chicken Red Label Supreme (อกพิเศษติดหนัง+ติดปีกบน)' and cyr.cut_name = 'Supreme') or
    (op.name = 'Legs Red Label (ขาไก่ตองหนึ่ง)' and cyr.cut_name = 'Leg (whole)') or
    (op.name = 'Thigh Red Label (สะโพกไก่ตองหนึ่ง)' and cyr.cut_name = 'Thigh') or
    (op.name = 'Drum Stick (น่องไก่)' and cyr.cut_name = 'Drumstick') or
    (op.name = 'Wings Red Label (ปีกไก่ตองหนึ่ง)' and cyr.cut_name = 'Wing') or
    (op.name = 'Chicken Carcass (โครงไก่)' and cyr.cut_name = 'Carcass')
  );

-- Duck breast/leg mapping — resolved by Clément 5 Sep 2026: "the golden
-- signature duck is normally only sold in whole duck. the Barbary is the
-- one that most customers orders." So the generic 'Male/Female Duck
-- Breast/Leg' Raw-catalog entries are Moscovy/Barbary cuts, not Golden
-- Signature Duck (which has no per-cut demand to map here at all).
update public.order_products op
set cut_yield_id = cyr.id
from public.cut_yield_reference cyr
where cyr.species = 'Duck'
  and (
    (op.name = 'Male Duck Breast (อกเป็ดตัวผู้)' and cyr.variant = 'Moscovy/Barbary male' and cyr.cut_name = 'Filet') or
    (op.name = 'Female Duck Breast (อกเป็ดตัวเมีย)' and cyr.variant = 'Moscovy/Barbary female' and cyr.cut_name = 'Filet') or
    (op.name = 'Male Duck Leg (ขาเป็ดตัวผู้)' and cyr.variant = 'Moscovy/Barbary male' and cyr.cut_name = 'Leg') or
    (op.name = 'Female Duck Leg (ขาเป็ดตัวเมีย)' and cyr.variant = 'Moscovy/Barbary female' and cyr.cut_name = 'Leg')
  );

-- Remaining open gap (not guessed at here — left cut_yield_id = null):
-- 'Breasts Red Label without skin' has no skinless piece weight on file
-- (only the with-skin 190g figure exists), and the whole UnderRoof line
-- has no yield weights on file at all yet. Add rows to cut_yield_reference
-- and re-run an update like the ones above once those numbers exist.


-- ----------------------------------------------------------------------------
-- 4. SALE ORDERS  (header)  +  SALE ORDER LINES
--    Replaces the monthly "NEW - Restaurant Order Delivery" Excel table.
--    Header fields are entered once per client PO; product lines repeat
--    underneath — this is the explicit structure replacing the old
--    "blank cell means same client" convention.
-- ----------------------------------------------------------------------------
create table if not exists public.sale_orders (
  id               uuid primary key default gen_random_uuid(),
  entity           text not null check (entity in ('Prosun Farm', 'Prosun Food')),
  client_id        uuid references public.clients(id),
  restaurant_name  text,      -- fallback only — prefer client_id once the client exists in the CRM
  po_number        text,
  chef_name        text,
  phone            text,
  delivery_notes   text,      -- the source sheet's "Address" column — in practice delivery notes/area, confirmed 5 Sep 2026, not a literal street address
  order_date       date not null default current_date,   -- the "D day" the poultry calculator keys off (see process doc, section 4)
  delivery_date    date,
  delivery_time    time,
  created_by       uuid references public.profiles(id),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint sale_orders_client_or_name check (client_id is not null or restaurant_name is not null)
);

create index if not exists sale_orders_client_id_idx    on public.sale_orders (client_id);
create index if not exists sale_orders_order_date_idx   on public.sale_orders (order_date);
create index if not exists sale_orders_entity_idx       on public.sale_orders (entity);

drop trigger if exists sale_orders_set_updated_at on public.sale_orders;
create trigger sale_orders_set_updated_at
  before update on public.sale_orders
  for each row execute function public.set_updated_at();

create table if not exists public.sale_order_lines (
  id           uuid primary key default gen_random_uuid(),
  order_id     uuid not null references public.sale_orders(id) on delete cascade,
  type         text not null check (type in ('Raw', 'Cooked', 'Delica', 'UnderRoof', 'PaleoRobbie', 'EasyHealth', 'Eggs')),
  product_id   uuid references public.order_products(id),
  description  text,
  weight_kg    numeric,       -- kept as its own column, mirroring the source sheet's separate Weight/Quantity/Unit columns rather than collapsing them — see open question below
  quantity     numeric,
  unit         text check (unit in ('Kg', 'Pcs', 'Grams', 'Pack')),
  packaging    text,
  status       text not null default 'Pending' check (status in ('Pending', 'Out for delivery', 'Delivered')),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

comment on column public.sale_order_lines.weight_kg is
  'Open question for Clément: when a line is sold by Pcs/Pack rather than Kg, is weight_kg still populated (actual weighed kg) or left null with the poultry calculator expected to derive kg from quantity * cut_yield_reference.piece_weight_g instead? Confirm before wiring the poultry calculator to this table.';

create index if not exists sale_order_lines_order_id_idx   on public.sale_order_lines (order_id);
create index if not exists sale_order_lines_product_id_idx on public.sale_order_lines (product_id);
create index if not exists sale_order_lines_status_idx     on public.sale_order_lines (status);

drop trigger if exists sale_order_lines_set_updated_at on public.sale_order_lines;
create trigger sale_order_lines_set_updated_at
  before update on public.sale_order_lines
  for each row execute function public.set_updated_at();

alter table public.sale_orders enable row level security;
alter table public.sale_order_lines enable row level security;

-- Admin: full access.
create policy "sale_orders: admin full access"
  on public.sale_orders for all
  using (public.current_role() = 'admin')
  with check (public.current_role() = 'admin');

create policy "sale_order_lines: admin full access"
  on public.sale_order_lines for all
  using (public.current_role() = 'admin')
  with check (public.current_role() = 'admin');

-- Sale support: this is their screen — read, create, update. No delete
-- (matches the existing "no delete for reps" convention on clients;
-- deleting an order is an admin-only action).
create policy "sale_orders: sale_support reads"
  on public.sale_orders for select
  using (public.current_role() = 'sale_support');
create policy "sale_orders: sale_support inserts"
  on public.sale_orders for insert
  with check (public.current_role() = 'sale_support');
create policy "sale_orders: sale_support updates"
  on public.sale_orders for update
  using (public.current_role() = 'sale_support')
  with check (public.current_role() = 'sale_support');

create policy "sale_order_lines: sale_support reads"
  on public.sale_order_lines for select
  using (public.current_role() = 'sale_support');
create policy "sale_order_lines: sale_support inserts"
  on public.sale_order_lines for insert
  with check (public.current_role() = 'sale_support');
create policy "sale_order_lines: sale_support updates"
  on public.sale_order_lines for update
  using (public.current_role() = 'sale_support')
  with check (public.current_role() = 'sale_support');

-- Purchasing and production: read-only visibility across all orders (they
-- need the full picture, not just their own — matches "not broader CRM
-- access, but full read of this data" from the access-scope discussion).
create policy "sale_orders: purchasing reads"
  on public.sale_orders for select
  using (public.current_role() = 'purchasing');
create policy "sale_orders: production reads"
  on public.sale_orders for select
  using (public.current_role() = 'production');

create policy "sale_order_lines: purchasing reads"
  on public.sale_order_lines for select
  using (public.current_role() = 'purchasing');
create policy "sale_order_lines: production reads"
  on public.sale_order_lines for select
  using (public.current_role() = 'production');


-- ----------------------------------------------------------------------------
-- 5. ACTIVITY LOG for sale_orders (same pattern as clients — audit trail,
--    admin-only to read via the existing activity_log table/policy).
--    Line-level edits aren't separately audited yet; add a matching
--    trigger on sale_order_lines later if that granularity turns out to
--    matter.
-- ----------------------------------------------------------------------------
create or replace function public.log_sale_order_activity()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.activity_log (table_name, record_id, user_id, action, details)
  values (
    'sale_orders',
    coalesce(new.id, old.id),
    auth.uid(),
    tg_op,
    case tg_op
      when 'DELETE' then to_jsonb(old)
      else to_jsonb(new)
    end
  );
  return coalesce(new, old);
end;
$$;

drop trigger if exists sale_orders_log_activity on public.sale_orders;
create trigger sale_orders_log_activity
  after insert or update or delete on public.sale_orders
  for each row execute function public.log_sale_order_activity();

-- ============================================================================
-- Done. Next steps:
--   1. Run this after sql/schema.sql, in the Supabase SQL Editor, ideally
--      against a staging project first per the agreed process-rigor plan.
--   2. Promote the relevant accounts:
--        update public.profiles set role = 'sale_support' where id = '<uuid>';
--        update public.profiles set role = 'purchasing'   where id = '<uuid>';
--        update public.profiles set role = 'production'   where id = '<uuid>';
--   3. Resolve the remaining open question flagged above (weight_kg vs
--      quantity semantics for non-Kg lines) before the poultry calculator
--      is built on top of this — it affects its accuracy directly. (The
--      duck-line mapping is resolved — Barbary, not Golden Signature Duck.)
--   4. Decide whether to delete the duplicate 'Duck Eggs (ไข่เป็ด)' row in
--      the PaleoRobbie catalog seed (flagged in section 3 above) or keep
--      both.
-- ============================================================================
