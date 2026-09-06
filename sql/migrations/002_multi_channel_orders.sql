-- ============================================================================
-- Migration 002 — multi-channel order support
-- ============================================================================
-- Written 5 Sep 2026, after reading the four real September order workbooks
-- (Restaurant, Department Store, Individual, Retail). Migration 001 was built
-- from the August RESTAURANT file alone; the other three channels turned out
-- to differ structurally, so several things in 001 would have rejected real
-- rows on first use. This migration fixes that before any data is entered.
--
-- What the other channels revealed:
--   1. A 'Frozen' TYPE (prepared French dishes) used by all three non-
--      restaurant channels — not in 001's type constraint at all.
--   2. Each channel has its OWN product catalog. Restaurant shares ZERO
--      product names with the other three: "Aiguillettes (สันในเป็ด)" vs
--      "Duck aiguillettes สันในเป็ด แพคละ 360 - 400 กรัม". Same physical
--      product, different naming convention per channel. Dept Store and
--      Retail are near-identical (56/57 Raw shared); Individual differs by
--      ~12 pack-size variants.
--   3. Individual and Retail are B2C: they carry Total order / Delivery fee
--      / Total, an Order Number (KPF0000116, sometimes free text), a customer
--      Code (CM2303), a Note, and — Individual only — a payment status
--      ("PAID 29/08/26 Credit") distinct from the logistics STATUS.
--   4. 'Jar' is a real unit (32 lines) missing from 001's constraint, and
--      units are case-inconsistent in the source (kg/Kg, pcs/Pcs, pack/Pack).
--   5. Weight is TEXT, not numeric — including size bands like "1.6-1.7".
--      Per Clément (5 Sep 2026): the weight is often the bird's size band —
--      Red Label comes in 1.2-1.4, 1.4-1.6 and 1.6-1.8 — and the point of
--      capturing it is "to be able to purchase the right size poultry when
--      we calculate the number of birds". So the poultry calculator needs
--      demand broken down BY SIZE BAND, not just a single bird count.
--
-- Run order: after 001. Safe to re-run (idempotent throughout).
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. order_products — per-channel catalogs
-- ----------------------------------------------------------------------------
-- Per Clément's decision (5 Sep 2026): keep each channel's own product names
-- exactly as Jane's team already knows them, rather than forcing one master
-- catalog. The physical unification happens through cut_yield_id — every
-- channel's "breast" row points at the same cut_yield_reference row, so the
-- poultry calculator still sees one product even though the dropdowns differ.

alter table public.order_products add column if not exists channel text;

-- everything seeded by 001 came from the restaurant workbook
update public.order_products set channel = 'Restaurant' where channel is null;

alter table public.order_products alter column channel set not null;

alter table public.order_products drop constraint if exists order_products_channel_check;
alter table public.order_products add constraint order_products_channel_check
  check (channel in ('Restaurant', 'Department Store', 'Individual', 'Retail'));

-- 'Frozen' added
alter table public.order_products drop constraint if exists order_products_type_check;
alter table public.order_products add constraint order_products_type_check
  check (type in ('Raw', 'Cooked', 'Delica', 'UnderRoof', 'PaleoRobbie',
                  'EasyHealth', 'Eggs', 'Frozen'));

-- The PaleoRobbie catalog range in the source workbook contains the same
-- "Duck Eggs (ไข่เป็ด)" row twice (rows 172-173 of the Parameters sheet).
-- 001 carried it through as-is rather than silently deduping, and flagged it
-- for Clément. It now blocks the unique index below, so it is collapsed here:
-- the row carrying a cut_yield_id (if either does) is kept, otherwise the
-- first. The product itself remains available — only the duplicate entry goes.
delete from public.order_products a
using public.order_products b
where a.channel = b.channel
  and a.type    = b.type
  and a.name    = b.name
  and a.id <> b.id
  and (a.cut_yield_id is null and b.cut_yield_id is not null
       or (a.cut_yield_id is null) = (b.cut_yield_id is null) and a.ctid > b.ctid);

-- 'Jar' also has to be allowed as a product's default unit, not just on the
-- order line — caught by testing, where sale_support could add a Jar product
-- but not save it.
alter table public.order_products drop constraint if exists order_products_default_unit_check;
alter table public.order_products add constraint order_products_default_unit_check
  check (default_unit is null or default_unit in ('Kg', 'Pcs', 'Grams', 'Pack', 'Jar'));

-- makes the seed below re-runnable without creating duplicates
create unique index if not exists order_products_channel_type_name_key
  on public.order_products (channel, type, name);


-- ----------------------------------------------------------------------------
-- 2. Deactivate the 7 restaurant Raw items dropped between August and September
-- ----------------------------------------------------------------------------
-- 001 seeded the August catalog. September's restaurant list is a strict
-- subset — these 7 offal/wing items were removed, nothing was added. They are
-- deactivated rather than deleted: past orders may reference them, and if the
-- removal was accidental Clément can flip active back to true.

update public.order_products
set active = false
where channel = 'Restaurant'
  and type = 'Raw'
  and name in (
    'Middle Wing (ปีกไก่กลาง)',
    'Top Wing (ปีกไก่บน)',
    'Chicken Cartilage (กระดูกอ่อนไก่)',
    'Chicken Skirt (กระบังลมไก่)',
    'Chicken Butt (ตูดไก่)',
    'Chicken Tenderloin (สันในไก่)',
    'Duck Intestine (ไส้เป็ด)'
  );


-- ----------------------------------------------------------------------------
-- 3. Seed the three new channels' catalogs (350 products, September files)
-- ----------------------------------------------------------------------------
-- Pulled programmatically from the same named ranges the Excel dropdowns use,
-- so the names match the sheets exactly, Thai text included. Deduped within
-- each channel+type (the source lists contain a few repeated rows).

insert into public.order_products (channel, type, name) values
  ('Department Store', 'Delica', 'Terrine pigeon Armagnac (เทอร์รีนนกพิราบ) กระปุกละ 80 กรัม'),
  ('Department Store', 'Delica', 'Terrine poultry thyme (เทอร์รีนรวม) กระปุกละ 80 กรัม'),
  ('Department Store', 'Delica', 'Terrine duck with rosemary (เทอร์รีนเป็ด) กระปุกละ 80 กรัม'),
  ('Department Store', 'Delica', 'Foie gras salt and pepper (ฟัวกราส์เกลือ พริกไทย) กระปุกละ 80 กรัม'),
  ('Department Store', 'Delica', 'Foie gras Porto / Monbazillac (ฟัวร์กราส์ ปอร์โต้ มอนบาซิลยัค) กระปุกละ 80 กรัม'),
  ('Department Store', 'Delica', 'Foie gras Porto / Monbazillac (ฟัวร์กราส์ ปอ์โต้ มอนบาซิลยัค) กระปุกละ 80 กรัม'),
  ('Department Store', 'Delica', 'Liver mousse (มูสตับ) / Liver Mousse Four Spices - มูสตับผสมเครื่องเทศ4ชนิด กระปุกละ 80 กรัม'),
  ('Department Store', 'Delica', 'Liver mousse Porto/ Truffle (มูสตับปอ์โต้ เห็ดทรัฟเฟิล)กระปุกละ 80 กรัม'),
  ('Department Store', 'Delica', 'Chicken rillettes (ขาไก่บด) กระปุกละ 80 กรัม'),
  ('Department Store', 'Delica', 'Chicken rillettes (ขาไก่บด) กระปุกละ 150 กรัม'),
  ('Department Store', 'Delica', 'Duck rillettes (ขาเป็ดบด) กระปุกละ 80 กรัม'),
  ('Department Store', 'Delica', 'Duck rillettes (ขาเป็ดบด) กระปุกละ 150 กรัม'),
  ('Department Store', 'Delica', 'Discovery Box'),
  ('Department Store', 'Delica', 'Au torchon Foie gras salt and pepper (ฟัวกราส์เกลือ พริกไทย)'),
  ('Department Store', 'Delica', 'Au torchon Foie gras Armagac (ฟัวกราส์อาร์มาญัก)'),
  ('Department Store', 'Delica', 'Au torchon Foie gras Porto / Monbazillac (ฟัวร์กราส์ ปอ์โต้ มอนบาซิลยัค)'),
  ('Department Store', 'Delica', 'Duck legs confit ขาเป็ดกงฟี'),
  ('Department Store', 'Delica', 'Chicken gizzards confit กึ๋นไก่กงฟี'),
  ('Department Store', 'Delica', 'Smoked Duck Breast sliced อกเป็ดรมควันสไลด์ แพคละ 100 กรัม'),
  ('Department Store', 'Delica', 'Smoked Duck Breast Full อกเป็ดรมควันเต็มชิ้น แพคละ 1 ชิ้น ชิ้นละ 200 กรัม +'),
  ('Department Store', 'Delica', 'Smoked Chicken Breast sliced อกไก่รมควันสไลด์ แพคละ 160กรัม'),
  ('Department Store', 'Delica', 'Smoked Chicken Breast Full อกไก่รมควันเต็มชิ้น แพคละ 1 ชิ้น ชิ้นละ 180 กรัม +'),
  ('Department Store', 'Eggs', 'Chicken eggs ไข่ไก่'),
  ('Department Store', 'Eggs', 'Duck eggs ไข่เป็ด'),
  ('Department Store', 'Eggs', 'Prosun Chicken Eggs ไข่ไก่ฟาร์มคุณทอง'),
  ('Department Store', 'Frozen', 'Frozen COQ-AU-VIN (ไก่ซอสไวน์แดง) 300 gr'),
  ('Department Store', 'Frozen', 'Frozen POULET SAUCE FORESTIERE (ไก่ซอสเห็ด) 300 gr'),
  ('Department Store', 'Frozen', 'Frozen POULET BASQUAISE (ไก่ซอสบร๊าสเก๊ต) 300 gr'),
  ('Department Store', 'Frozen', 'Frozen POULET AU MASSAMAN (มัสมั่นไก่) 300 gr'),
  ('Department Store', 'Frozen', 'Frozen POULET À LA NOIX DE COCO (ต้มข่าไก่) 300 gr'),
  ('Department Store', 'Frozen', 'Frozen POULET AU CURRY VERT (แกงเขียวหวานไก่) 300 gr'),
  ('Department Store', 'Frozen', 'Frozen POULET AU PANANG (พะแนงไก่) 300 gr'),
  ('Department Store', 'Frozen', 'Frozen CANARD À L’ORANGE (เป็ดซอสส้ม) 300 g'),
  ('Department Store', 'Frozen', 'Frozen BLANQUETTE DE VEAU (เนื้อลูกวัวซอสครีม) 300 gr'),
  ('Department Store', 'Frozen', 'Frozen BLANQUETTE DE POULET (ไก่ซอสครีม) 300 gr'),
  ('Department Store', 'Frozen', 'Frozen ZAALOUK AU POULET (ไก่ซอสโมร๊อคกัน) 300 gr'),
  ('Department Store', 'Frozen', 'Frozen VEAU SAUCE FORESTIÈRE (เนื้อลูกวัวซอสเห็ด ) 300 gr'),
  ('Department Store', 'Frozen', 'Poultry souffle sauce financière (ซูเฟล่ไก่ในซอสฟินองเซีย)300 gr'),
  ('Department Store', 'Frozen', 'Poultry souffle confit shallot sauce (ซูเฟล่ไก่ กงฟี ซอสหอมแดง)300 gr'),
  ('Department Store', 'Frozen', 'Poultry souffle nature (ซูเฟล่ไก่ดั้งเดิม) 240 gr'),
  ('Department Store', 'Frozen', 'Sauteed Mushroom (เห็ดผัดเนย) 100 gr'),
  ('Department Store', 'Frozen', 'Mashed Potatoes (มันบด) 250 gr'),
  ('Department Store', 'Frozen', 'Frozen Shepherd’s Pie Duck, Chicken เชพเพิร์ดพายเป็ดผสมไก่ 320 gr'),
  ('Department Store', 'Frozen', 'Frozen Shepherd’s Pie Vegetarian เชพเพิร์ดพายมังสวิรัต 320 gr'),
  ('Department Store', 'Frozen', 'Frozen Shepherd’s Pie Vegan เชพเพิร์ดพายวีแกน 320 g'),
  ('Department Store', 'Frozen', 'Frozen Chicken Lasagna ลาซานญ่าไก่ 320 g'),
  ('Department Store', 'Frozen', 'Frozen Beef Lasagna ลาซานญ่าเนื้อ 320 g'),
  ('Department Store', 'Frozen', 'Frozen Vegan Lasagna ลาซานญ่าวีแกน 320 g'),
  ('Department Store', 'Frozen', 'Frozen Duck Cassoulet ขาเป็ดกงฟีในเมล็ดถั่วขาว 320 g'),
  ('Department Store', 'Frozen', 'Chicken Paupiettes ไก่โปปิแยต(ไก่ยัดไส้เป็ดและเห็ด) 380 g'),
  ('Department Store', 'Frozen', 'Chicken Cordon Bleu ไก่กอร์ดองเบลอ 100g'),
  ('Department Store', 'Frozen', 'Chicken Sous Vide อกไก่ซูวี 340 - 400 g'),
  ('Department Store', 'Frozen', 'Knack Smoked Sausage ไส้กรอกไก่รมควัน แพคละ 5 pcs'),
  ('Department Store', 'Frozen', 'Duck Sausage ไส้กรอกเป็ด แพคละ 3 pcs'),
  ('Department Store', 'Frozen', 'Chicken Sausage Basquaise ไส้กรอกไก่บร๊าสเกต แพคละ 3 pcs'),
  ('Department Store', 'Frozen', 'Veal Sausage with Rosemary (Chipolata) ไส้กรอกเนื้อลูกวัว แพคละ 5 pcs'),
  ('Department Store', 'Frozen', 'Chicken Sausage (Chipolata) ไส้กรอกไก่มันเนื้อ แพคละ 5 pcs'),
  ('Department Store', 'Frozen', 'Chicken Sausage (Chipolata) ไส้กรอกไก่มันเนื้อ แพคละ 3 pcs'),
  ('Department Store', 'Frozen', 'Chicken Bangers & Mashed Potatoes 320 - 500 g'),
  ('Department Store', 'Frozen', 'Veal Bangers & Mashed Potatoes 320 - 500 g'),
  ('Department Store', 'Frozen', 'Stuffed Whole turkey Chilled/Frozen (Stuffing Foie gras figs 1 Kg)'),
  ('Department Store', 'Frozen', 'Stuffed Whole turkey Chilled/Frozen (Stuffing Foie gras Truffles 1 Kg)'),
  ('Department Store', 'Frozen', 'Stuffed Whole Capon Chilled/Frozen (Stuffing Foie gras figs 1 Kg)'),
  ('Department Store', 'Frozen', 'Stuffed Whole Capon Chilled/Frozen (Stuffing Foie gras Truffles 1 Kg)'),
  ('Department Store', 'Frozen', 'Stuffed Red Label Chilled/Frozen (Stuffing Duck with mushroom 150-200 g)'),
  ('Department Store', 'Frozen', 'Stuffed Red Label Chilled/Frozen (Stuffing Duck with mushroom 150-200 g)+Side dish'),
  ('Department Store', 'Frozen', 'Stuffed Baby Chicken Chilled/Frozen (Stuffing Duck with mushroom 80-100 g)'),
  ('Department Store', 'Frozen', 'Stuffed Baby Chicken Chilled/Frozen (Stuffing Duck with mushroom 80-100 g)+Side dish'),
  ('Department Store', 'Frozen', 'Ballotine Capon 6 pax (Stuffing Foie gras figs)'),
  ('Department Store', 'Raw', 'Green Label Chicken ไก่โคราช'),
  ('Department Store', 'Raw', 'Red Label Chicken ไก่ตองหนึ่ง'),
  ('Department Store', 'Raw', 'Baby Chicken ไก่เบบี้'),
  ('Department Store', 'Raw', 'Spring Chicken ไก่สปริง'),
  ('Department Store', 'Raw', 'Chicken Breast อกไก่ แพคละ 2 ชิ้น'),
  ('Department Store', 'Raw', 'Chicken Breast อกไก่ติดหนัง'),
  ('Department Store', 'Raw', 'Chicken Breast อกไก่ลอกหนัง'),
  ('Department Store', 'Raw', 'Chicken Legs ขาไก่ แพคละ 2 ชิ้น'),
  ('Department Store', 'Raw', 'Chicken Legs ขาไก่'),
  ('Department Store', 'Raw', 'Chicken Wings ปีกไก่ แพคละ 8 ชิ้น'),
  ('Department Store', 'Raw', 'Chicken Wings ปีกไก่'),
  ('Department Store', 'Raw', 'Chicken Thighs สะโพกไก่ แพคละ 4 ชิ้น'),
  ('Department Store', 'Raw', 'Chicken Thighs สะโพกไก่'),
  ('Department Store', 'Raw', 'Whole Chicken with Offal ไก่ตองทั้งตัวพร้อมเครื่องใน'),
  ('Department Store', 'Raw', 'Duck Barbary Male เป็ดบาร์บารี่ ตัวผู้'),
  ('Department Store', 'Raw', 'Duck Barbary Female เป็ดบาร์บารี่ ตัวเมีย'),
  ('Department Store', 'Raw', 'Duck Fillet Male อกเป็ดตัวผู้'),
  ('Department Store', 'Raw', 'Duck Fillet Male อกเป็ดตัวผู้ แพคละ 1 ชิ้น'),
  ('Department Store', 'Raw', 'Duck Fillet Female อกเป็ดตัวเมีย แพคละ 1 ชิ้น'),
  ('Department Store', 'Raw', 'Duck Fillet Female อกเป็ดตัวเมีย'),
  ('Department Store', 'Raw', 'Duck aiguillettes สันในเป็ด แพคละ 360 - 400 กรัม'),
  ('Department Store', 'Raw', 'Duck aiguillettes สันในเป็ด'),
  ('Department Store', 'Raw', 'Duck Wings ปีกเป็ด แพคละ 5 ชิ้น'),
  ('Department Store', 'Raw', 'Duck Wings ปีกเป็ด'),
  ('Department Store', 'Raw', 'Duck Male Legs ขาเป็ดตัวผู้ แพคละ 2 ชิ้น'),
  ('Department Store', 'Raw', 'Duck Male Legs ขาเป็ดตัวผู้'),
  ('Department Store', 'Raw', 'Duck Female Legs ขาเป็ดตัวเมีย แพคละ 2 ชิ้น'),
  ('Department Store', 'Raw', 'Duck Female Legs ขาเป็ดตัวเมีย'),
  ('Department Store', 'Raw', 'Rabbit กระต่าย'),
  ('Department Store', 'Raw', 'Capon Frozen 2.8 – 3.2 ไก่คาปองแช่แข็ง'),
  ('Department Store', 'Raw', 'Capon Chilled 2.8-3.2 ไก่คาปอง'),
  ('Department Store', 'Raw', 'Capon Frozen 3.2+ ไก่คาปองใหญ่แช่แข็ง'),
  ('Department Store', 'Raw', 'Capon Chilled 3.2+ ไก่คาปองใหญ่'),
  ('Department Store', 'Raw', 'Quail นกกระทา (130-160 g)'),
  ('Department Store', 'Raw', 'Quail นกกระทา (161-250 g)'),
  ('Department Store', 'Raw', 'Turkey 4-6 ไก่งวง M'),
  ('Department Store', 'Raw', 'Turkey Chilled Brined 4-6 ไก่งวงแช่น้ำเกลือ'),
  ('Department Store', 'Raw', 'Turkey 6-7+ ไก่งวงL'),
  ('Department Store', 'Raw', 'Turkey Chilled Brined 6-7+ ไก่งวงแช่น้ำเกลือ'),
  ('Department Store', 'Raw', 'Guinea Fowl ไก่ตะเภา/ไก่ต๊อก'),
  ('Department Store', 'Raw', 'Pigeon นกพิราบ'),
  ('Department Store', 'Raw', 'Whole Chicken & Duck with Offal ไก่เป็ดเมียทั้งตัวพร้อมเครื่องใน'),
  ('Department Store', 'Raw', 'Chicken Carcass ซี่โครงไก่'),
  ('Department Store', 'Raw', 'Duck Carcass ซี่โครงเป็ด'),
  ('Department Store', 'Raw', 'Chicken Livers ตับไก่ แพคละ 250 กรัม'),
  ('Department Store', 'Raw', 'Chicken Livers ตับไก่ แพคละ 500 กรัม'),
  ('Department Store', 'Raw', 'Chicken Livers ตับไก่ แพคละ 1 กก'),
  ('Department Store', 'Raw', 'Chicken Gizzards กึ๋นไก่ แพคละ 250 กรัม'),
  ('Department Store', 'Raw', 'Chicken Gizzards กึ๋นไก่ แพคละ 500 กรัม'),
  ('Department Store', 'Raw', 'Chicken Gizzards กึ๋นไก่ แพคละ 1 กก'),
  ('Department Store', 'Raw', 'Chicken Hearts หัวใจไก่ แพคละ 250 กรัม'),
  ('Department Store', 'Raw', 'Chicken Hearts หัวใจไก่ แพคละ 500 กรัม'),
  ('Department Store', 'Raw', 'Chicken Hearts หัวใจไก่ แพคละ 1 กก'),
  ('Department Store', 'Raw', 'Chicken Feets ตีนไก่ แพคละ 250 กรัม'),
  ('Department Store', 'Raw', 'Chicken Feets ตีนไก่ แพคละ 500 กรัม'),
  ('Department Store', 'Raw', 'Chicken Feets ตีนไก่ แพคละ 1 กก'),
  ('Individual', 'Delica', 'Terrine pigeon Armagnac (เทอร์รีนนกพิราบ) กระปุกละ 80 กรัม'),
  ('Individual', 'Delica', 'Terrine poultry thyme (เทอร์รีนรวม) กระปุกละ 80 กรัม'),
  ('Individual', 'Delica', 'Terrine duck with rosemary (เทอร์รีนเป็ด) กระปุกละ 80 กรัม'),
  ('Individual', 'Delica', 'Foie gras salt and pepper (ฟัวกราส์เกลือ พริกไทย) กระปุกละ 80 กรัม'),
  ('Individual', 'Delica', 'Foie gras Porto / Monbazillac (ฟัวร์กราส์ ปอร์โต้ มอนบาซิลยัค) กระปุกละ 80 กรัม'),
  ('Individual', 'Delica', 'Foie gras Porto / Monbazillac (ฟัวร์กราส์ ปอ์โต้ มอนบาซิลยัค) กระปุกละ 80 กรัม'),
  ('Individual', 'Delica', 'Liver mousse (มูสตับ) / Liver Mousse Four Spices - มูสตับผสมเครื่องเทศ4ชนิด กระปุกละ 80 กรัม'),
  ('Individual', 'Delica', 'Liver mousse Porto/ Truffle (มูสตับปอ์โต้ เห็ดทรัฟเฟิล)กระปุกละ 80 กรัม'),
  ('Individual', 'Delica', 'Chicken rillettes (ขาไก่บด) กระปุกละ 80 กรัม'),
  ('Individual', 'Delica', 'Chicken rillettes (ขาไก่บด) กระปุกละ 150 กรัม'),
  ('Individual', 'Delica', 'Duck rillettes (ขาเป็ดบด) กระปุกละ 80 กรัม'),
  ('Individual', 'Delica', 'Duck rillettes (ขาเป็ดบด) กระปุกละ 150 กรัม'),
  ('Individual', 'Delica', 'Discovery Box'),
  ('Individual', 'Delica', 'Au torchon Foie gras salt and pepper (ฟัวกราส์เกลือ พริกไทย) แท่งละ 250 กรัม'),
  ('Individual', 'Delica', 'Au torchon Foie gras Armagac (ฟัวกราส์อาร์มาญัก) แท่งละ 250 กรัม'),
  ('Individual', 'Delica', 'Au torchon Foie gras Porto / Monbazillac (ฟัวร์กราส์ ปอ์โต้ มอนบาซิลยัค) แท่งละ 250 กรัม'),
  ('Individual', 'Delica', 'Duck legs confit ขาเป็ดกงฟี แพคละ 2 ชิ้น'),
  ('Individual', 'Delica', 'Duck legs confit ขาเป็ดกงฟี แพคละ 3 ชิ้น'),
  ('Individual', 'Delica', 'Chicken gizzards confit กึ๋นไก่กงฟี แพคละ 380 กรัม'),
  ('Individual', 'Delica', 'Smoked Duck Breast sliced อกเป็ดรมควันสไลด์ แพคละ 100 กรัม'),
  ('Individual', 'Delica', 'Smoked Duck Breast Full อกเป็ดรมควันเต็มชิ้น แพคละ 1 ชิ้น ชิ้นละ 200 กรัม +'),
  ('Individual', 'Delica', 'Smoked Chicken Breast sliced อกไก่รมควันสไลด์ แพคละ 160กรัม'),
  ('Individual', 'Delica', 'Smoked Chicken Breast Full อกไก่รมควันเต็มชิ้น แพคละ 1 ชิ้น ชิ้นละ 180 กรัม +'),
  ('Individual', 'Delica', 'Duck Fat - น้ำมันเป็ด 450 กรัม'),
  ('Individual', 'Eggs', 'Chicken eggs ไข่ไก่'),
  ('Individual', 'Eggs', 'Duck eggs ไข่เป็ด'),
  ('Individual', 'Eggs', 'Prosun Chicken Eggs ไข่ไก่ฟาร์มคุณทอง'),
  ('Individual', 'Frozen', 'Frozen COQ-AU-VIN (ไก่ซอสไวน์แดง) 300 gr'),
  ('Individual', 'Frozen', 'Frozen POULET SAUCE FORESTIERE (ไก่ซอสเห็ด) 300 gr'),
  ('Individual', 'Frozen', 'Frozen POULET BASQUAISE (ไก่ซอสบร๊าสเก๊ต) 300 gr'),
  ('Individual', 'Frozen', 'Frozen POULET AU MASSAMAN (มัสมั่นไก่) 300 gr'),
  ('Individual', 'Frozen', 'Frozen POULET À LA NOIX DE COCO (ต้มข่าไก่) 300 gr'),
  ('Individual', 'Frozen', 'Frozen POULET AU CURRY VERT (แกงเขียวหวานไก่) 300 gr'),
  ('Individual', 'Frozen', 'Frozen POULET AU PANANG (พะแนงไก่) 300 gr'),
  ('Individual', 'Frozen', 'Frozen CANARD À L’ORANGE (เป็ดซอสส้ม) 300 g'),
  ('Individual', 'Frozen', 'Frozen BLANQUETTE DE VEAU (เนื้อลูกวัวซอสครีม) 300 gr'),
  ('Individual', 'Frozen', 'Frozen BLANQUETTE DE POULET (ไก่ซอสครีม) 300 gr'),
  ('Individual', 'Frozen', 'Frozen ZAALOUK AU POULET (ไก่ซอสโมร๊อคกัน) 300 gr'),
  ('Individual', 'Frozen', 'Frozen VEAU SAUCE FORESTIÈRE (เนื้อลูกวัวซอสเห็ด ) 300 gr'),
  ('Individual', 'Frozen', 'Poultry souffle sauce financière (ซูเฟล่ไก่ในซอสฟินองเซีย)300 gr'),
  ('Individual', 'Frozen', 'Poultry souffle confit shallot sauce (ซูเฟล่ไก่ กงฟี ซอสหอมแดง)300 gr'),
  ('Individual', 'Frozen', 'Poultry souffle nature (ซูเฟล่ไก่ดั้งเดิม) 240 gr'),
  ('Individual', 'Frozen', 'Sauteed Mushroom (เห็ดผัดเนย) 100 gr'),
  ('Individual', 'Frozen', 'Mashed Potatoes (มันบด) 250 gr'),
  ('Individual', 'Frozen', 'Frozen Shepherd’s Pie Duck, Chicken เชพเพิร์ดพายเป็ดผสมไก่ 320 gr'),
  ('Individual', 'Frozen', 'Frozen Shepherd’s Pie Vegetarian เชพเพิร์ดพายมังสวิรัต 320 gr'),
  ('Individual', 'Frozen', 'Frozen Shepherd’s Pie Vegan เชพเพิร์ดพายวีแกน 320 g'),
  ('Individual', 'Frozen', 'Frozen Chicken Lasagna ลาซานญ่าไก่ 320 g'),
  ('Individual', 'Frozen', 'Frozen Beef Lasagna ลาซานญ่าเนื้อ 320 g'),
  ('Individual', 'Frozen', 'Frozen Vegan Lasagna ลาซานญ่าวีแกน 320 g'),
  ('Individual', 'Frozen', 'Frozen Duck Cassoulet ขาเป็ดกงฟีในเมล็ดถั่วขาว 320 g'),
  ('Individual', 'Frozen', 'Chicken Paupiettes ไก่โปปิแยต(ไก่ยัดไส้เป็ดและเห็ด) 380 g'),
  ('Individual', 'Frozen', 'Chicken Cordon Bleu ไก่กอร์ดองเบลอ 100g'),
  ('Individual', 'Frozen', 'Chicken Sous Vide อกไก่ซูวี 340 - 400 g'),
  ('Individual', 'Frozen', 'Knack Smoked Sausage ไส้กรอกไก่รมควัน แพคละ 5 pcs'),
  ('Individual', 'Frozen', 'Duck Sausage ไส้กรอกเป็ด แพคละ 3 pcs'),
  ('Individual', 'Frozen', 'Chicken Sausage Basquaise ไส้กรอกไก่บร๊าสเกต แพคละ 3 pcs'),
  ('Individual', 'Frozen', 'Veal Sausage with Rosemary (Chipolata) ไส้กรอกเนื้อลูกวัว แพคละ 5 pcs'),
  ('Individual', 'Frozen', 'Chicken Sausage (Chipolata) ไส้กรอกไก่มันเนื้อ แพคละ 5 pcs'),
  ('Individual', 'Frozen', 'Chicken Sausage (Chipolata) ไส้กรอกไก่มันเนื้อ แพคละ 3 pcs'),
  ('Individual', 'Frozen', 'Chicken Bangers & Mashed Potatoes 320 - 500 g'),
  ('Individual', 'Frozen', 'Veal Bangers & Mashed Potatoes 320 - 500 g'),
  ('Individual', 'Frozen', 'Stuffed Whole turkey Chilled/Frozen (Stuffing Foie gras figs 1 Kg)'),
  ('Individual', 'Frozen', 'Stuffed Whole turkey Chilled/Frozen (Stuffing Foie gras Truffles 1 Kg)'),
  ('Individual', 'Frozen', 'Stuffed Whole Capon Chilled/Frozen (Stuffing Foie gras figs 1 Kg)'),
  ('Individual', 'Frozen', 'Stuffed Whole Capon Chilled/Frozen (Stuffing Foie gras Truffles 1 Kg)'),
  ('Individual', 'Frozen', 'Stuffed Red Label Chilled/Frozen (Stuffing Duck with mushroom 150-200 g)'),
  ('Individual', 'Frozen', 'Stuffed Red Label Chilled/Frozen (Stuffing Duck with mushroom 150-200 g)+Side dish'),
  ('Individual', 'Frozen', 'Stuffed Baby Chicken Chilled/Frozen (Stuffing Duck with mushroom 80-100 g)'),
  ('Individual', 'Frozen', 'Stuffed Baby Chicken Chilled/Frozen (Stuffing Duck with mushroom 80-100 g)+Side dish'),
  ('Individual', 'Frozen', 'Ballotine Capon 6 pax (Stuffing Foie gras figs)'),
  ('Individual', 'Frozen', 'Ballotine Capon 6 pax (Stuffing Foie gras truffle)'),
  ('Individual', 'Raw', 'Green Label Chicken ไก่โคราช'),
  ('Individual', 'Raw', 'Red Label Chicken ไก่ตองหนึ่ง'),
  ('Individual', 'Raw', 'Baby Chicken ไก่เบบี้'),
  ('Individual', 'Raw', 'Spring Chicken ไก่สปริง'),
  ('Individual', 'Raw', 'Chicken Breast อกไก่ แพคละ 2 ชิ้น ( น้ำหนัก 360 - 400 g/pack )'),
  ('Individual', 'Raw', 'Chicken Breast อกไก่ติดหนัง'),
  ('Individual', 'Raw', 'Chicken Breast อกไก่ลอกหนัง'),
  ('Individual', 'Raw', 'Chicken Legs ขาไก่ แพคละ 2 ชิ้น ( น้ำหนัก 360 - 400 g/pack )'),
  ('Individual', 'Raw', 'Chicken Legs ขาไก่'),
  ('Individual', 'Raw', 'Chicken Wings ปีกไก่ แพคละ 8 ชิ้น ( น้ำหนัก 540 - 600 g/pack )'),
  ('Individual', 'Raw', 'Chicken Wings ปีกไก่'),
  ('Individual', 'Raw', 'Chicken Thighs สะโพกไก่ แพคละ 4 ชิ้น ( น้ำหนัก 540 - 600 g/pack )'),
  ('Individual', 'Raw', 'Chicken Thighs สะโพกไก่'),
  ('Individual', 'Raw', 'Whole Chicken with Offal ไก่ตองทั้งตัวพร้อมเครื่องใน'),
  ('Individual', 'Raw', 'Duck Barbary Male เป็ดบาร์บารี่ ตัวผู้'),
  ('Individual', 'Raw', 'Duck Barbary Female เป็ดบาร์บารี่ ตัวเมีย'),
  ('Individual', 'Raw', 'Duck Fillet Male อกเป็ดตัวผู้ แพคละ 1 ชิ้น ( น้ำหนัก 270 - 300 g/pack )'),
  ('Individual', 'Raw', 'Duck Fillet Male อกเป็ดตัวผู้'),
  ('Individual', 'Raw', 'Duck Fillet Female อกเป็ดตัวเมีย แพคละ 1 ชิ้น ( น้ำหนัก 130 - 150 g+ /pack )'),
  ('Individual', 'Raw', 'Duck Fillet Female อกเป็ดตัวเมีย'),
  ('Individual', 'Raw', 'Duck aiguillettes สันในเป็ด แพคละ 360 - 400 กรัม'),
  ('Individual', 'Raw', 'Duck aiguillettes สันในเป็ด'),
  ('Individual', 'Raw', 'Duck Wings ปีกเป็ด แพคละ 5 ชิ้น ( น้ำหนัก 500 - 530 g/pack )'),
  ('Individual', 'Raw', 'Duck Wings ปีกเป็ด'),
  ('Individual', 'Raw', 'Duck Male Legs ขาเป็ดตัวผู้ แพคละ 2 ชิ้น ( น้ำหนัก 500 - 600g/pack )'),
  ('Individual', 'Raw', 'Duck Male Legs ขาเป็ดตัวผู้'),
  ('Individual', 'Raw', 'Duck Female Legs ขาเป็ดตัวเมีย แพคละ 2 ชิ้น ( น้ำหนัก 500 - 600 g / pack )'),
  ('Individual', 'Raw', 'Duck Female Legs ขาเป็ดตัวเมีย'),
  ('Individual', 'Raw', 'Rabbit กระต่าย น้ำหนัก 1.2 - 1.6 kg'),
  ('Individual', 'Raw', 'Capon Frozen 2.8 – 3.2 ไก่คาปองแช่แข็ง'),
  ('Individual', 'Raw', 'Capon Chilled 2.8-3.2 ไก่คาปอง'),
  ('Individual', 'Raw', 'Capon Frozen 3.2+ ไก่คาปองใหญ่แช่แข็ง'),
  ('Individual', 'Raw', 'Capon Chilled 3.2+ ไก่คาปองใหญ่'),
  ('Individual', 'Raw', 'Quail นกกระทา (130-160 g)'),
  ('Individual', 'Raw', 'Quail นกกระทา (161-250 g)'),
  ('Individual', 'Raw', 'Turkey 4-6 ไก่งวง M'),
  ('Individual', 'Raw', 'Turkey Chilled Brined 4-6 ไก่งวงแช่น้ำเกลือ'),
  ('Individual', 'Raw', 'Turkey 6-7+ ไก่งวงL'),
  ('Individual', 'Raw', 'Turkey Chilled Brined 6-7+ ไก่งวงแช่น้ำเกลือ'),
  ('Individual', 'Raw', 'Guinea Fowl ไก่ตะเภา/ไก่ต๊อก'),
  ('Individual', 'Raw', 'Pigeon นกพิราบ น้ำหนัก 300 - 350 g'),
  ('Individual', 'Raw', 'Whole Chicken & Duck with Offal ไก่เป็ดเมียทั้งตัวพร้อมเครื่องใน'),
  ('Individual', 'Raw', 'Chicken Carcass ซี่โครงไก่'),
  ('Individual', 'Raw', 'Duck Carcass ซี่โครงเป็ด'),
  ('Individual', 'Raw', 'Chicken Livers ตับไก่ แพคละ 250 กรัม'),
  ('Individual', 'Raw', 'Chicken Livers ตับไก่ แพคละ 500 กรัม'),
  ('Individual', 'Raw', 'Chicken Livers ตับไก่ แพคละ 1 กก'),
  ('Individual', 'Raw', 'Duck Livers ตับเป็ด แพคละ 1 กก'),
  ('Individual', 'Raw', 'Chicken Gizzards กึ๋นไก่ แพคละ 250 กรัม'),
  ('Individual', 'Raw', 'Chicken Gizzards กึ๋นไก่ แพคละ 500 กรัม'),
  ('Individual', 'Raw', 'Chicken Gizzards กึ๋นไก่ แพคละ 1 กก'),
  ('Individual', 'Raw', 'Chicken Hearts หัวใจไก่ แพคละ 250 กรัม'),
  ('Individual', 'Raw', 'Chicken Hearts หัวใจไก่ แพคละ 500 กรัม'),
  ('Individual', 'Raw', 'Chicken Hearts หัวใจไก่ แพคละ 1 กก'),
  ('Individual', 'Raw', 'Chicken Feets ตีนไก่ แพคละ 250 กรัม'),
  ('Individual', 'Raw', 'Chicken Feets ตีนไก่ แพคละ 500 กรัม'),
  ('Individual', 'Raw', 'Chicken Feets ตีนไก่ แพคละ 1 กก'),
  ('Retail', 'Delica', 'Terrine pigeon Armagnac (เทอร์รีนนกพิราบ) กระปุกละ 80 กรัม'),
  ('Retail', 'Delica', 'Terrine poultry thyme (เทอร์รีนรวม) กระปุกละ 80 กรัม'),
  ('Retail', 'Delica', 'Terrine duck with rosemary (เทอร์รีนเป็ด) กระปุกละ 80 กรัม'),
  ('Retail', 'Delica', 'Foie gras salt and pepper (ฟัวกราส์เกลือ พริกไทย) กระปุกละ 80 กรัม'),
  ('Retail', 'Delica', 'Foie gras Porto / Monbazillac (ฟัวร์กราส์ ปอร์โต้ มอนบาซิลยัค) กระปุกละ 80 กรัม'),
  ('Retail', 'Delica', 'Foie gras Porto / Monbazillac (ฟัวร์กราส์ ปอ์โต้ มอนบาซิลยัค) กระปุกละ 80 กรัม'),
  ('Retail', 'Delica', 'Liver mousse (มูสตับ) / Liver Mousse Four Spices - มูสตับผสมเครื่องเทศ4ชนิด กระปุกละ 80 กรัม'),
  ('Retail', 'Delica', 'Liver mousse Porto/ Truffle (มูสตับปอ์โต้ เห็ดทรัฟเฟิล)กระปุกละ 80 กรัม'),
  ('Retail', 'Delica', 'Chicken rillettes (ขาไก่บด) กระปุกละ 80 กรัม'),
  ('Retail', 'Delica', 'Chicken rillettes (ขาไก่บด) กระปุกละ 150 กรัม'),
  ('Retail', 'Delica', 'Duck rillettes (ขาเป็ดบด) กระปุกละ 80 กรัม'),
  ('Retail', 'Delica', 'Duck rillettes (ขาเป็ดบด) กระปุกละ 150 กรัม'),
  ('Retail', 'Delica', 'Discovery Box'),
  ('Retail', 'Delica', 'Au torchon Foie gras salt and pepper (ฟัวกราส์เกลือ พริกไทย)'),
  ('Retail', 'Delica', 'Au torchon Foie gras Armagac (ฟัวกราส์อาร์มาญัก)'),
  ('Retail', 'Delica', 'Au torchon Foie gras Porto / Monbazillac (ฟัวร์กราส์ ปอ์โต้ มอนบาซิลยัค)'),
  ('Retail', 'Delica', 'Duck legs confit ขาเป็ดกงฟี'),
  ('Retail', 'Delica', 'Chicken gizzards confit กึ๋นไก่กงฟี'),
  ('Retail', 'Delica', 'Smoked Duck Breast sliced อกเป็ดรมควันสไลด์'),
  ('Retail', 'Delica', 'Smoked Duck Breast Full อกเป็ดรมควันเต็มชิ้น'),
  ('Retail', 'Delica', 'Smoked Chicken Breast sliced อกไก่รมควันสไลด์'),
  ('Retail', 'Eggs', 'Chicken eggs ไข่ไก่'),
  ('Retail', 'Eggs', 'Duck eggs ไข่เป็ด'),
  ('Retail', 'Eggs', 'Prosun Chicken Eggs ไข่ไก่ฟาร์มคุณทอง'),
  ('Retail', 'Frozen', 'Frozen COQ-AU-VIN (ไก่ซอสไวน์แดง )'),
  ('Retail', 'Frozen', 'Frozen POULET SAUCE FORESTIERE (ไก่ซอสเห็ด)'),
  ('Retail', 'Frozen', 'Frozen POULET BASQUAISE (ไก่ซอสบร๊าสเก๊ต )'),
  ('Retail', 'Frozen', 'Frozen POULET AU MASSAMAN (มัสมั่นไก่ )'),
  ('Retail', 'Frozen', 'Frozen POULET À LA NOIX DE COCO (ต้มข่าไก่ )'),
  ('Retail', 'Frozen', 'Frozen POULET AU CURRY VERT (แกงเขียวหวานไก่ )'),
  ('Retail', 'Frozen', 'Frozen POULET AU PANANG (พะแนงไก่ )'),
  ('Retail', 'Frozen', 'Frozen CANARD À L’ORANGE (เป็ดซอสส้ม)'),
  ('Retail', 'Frozen', 'Frozen BLANQUETTE DE VEAU (เนื้อลูกวัวซอสครีม)'),
  ('Retail', 'Frozen', 'Frozen BLANQUETTE DE POULET (ไก่ซอสครีม )'),
  ('Retail', 'Frozen', 'Frozen ZAALOUK AU POULET (ไก่ซอสโมร๊อคกัน )'),
  ('Retail', 'Frozen', 'Sauteed Mushroom (เห็ดผัดเนย)'),
  ('Retail', 'Frozen', 'Mashed Potatoes (มันบด)'),
  ('Retail', 'Frozen', 'Frozen Chicken Lasagna ลาซานญ่าไก่'),
  ('Retail', 'Frozen', 'Chicken Sous Vide อกไก่ซูวี'),
  ('Retail', 'Raw', 'Green Label Chicken ไก่โคราช'),
  ('Retail', 'Raw', 'Red Label Chicken ไก่ตองหนึ่ง'),
  ('Retail', 'Raw', 'Baby Chicken ไก่เบบี้'),
  ('Retail', 'Raw', 'Spring Chicken ไก่สปริง'),
  ('Retail', 'Raw', 'Chicken Breast อกไก่ แพคละ 2 ชิ้น'),
  ('Retail', 'Raw', 'Chicken Breast อกไก่ติดหนัง'),
  ('Retail', 'Raw', 'Chicken Breast อกไก่ลอกหนัง'),
  ('Retail', 'Raw', 'Chicken Legs ขาไก่ แพคละ 2 ชิ้น'),
  ('Retail', 'Raw', 'Chicken Legs ขาไก่'),
  ('Retail', 'Raw', 'Chicken Wings ปีกไก่ แพคละ 8 ชิ้น'),
  ('Retail', 'Raw', 'Chicken Wings ปีกไก่'),
  ('Retail', 'Raw', 'Chicken Thighs สะโพกไก่ แพคละ 4 ชิ้น'),
  ('Retail', 'Raw', 'Chicken Thighs สะโพกไก่'),
  ('Retail', 'Raw', 'Whole Chicken with Offal ไก่ตองทั้งตัวพร้อมเครื่องใน'),
  ('Retail', 'Raw', 'Duck Barbary Male เป็ดบาร์บารี่ ตัวผู้'),
  ('Retail', 'Raw', 'Duck Barbary Female เป็ดบาร์บารี่ ตัวเมีย'),
  ('Retail', 'Raw', 'Duck Fillet Male อกเป็ดตัวผู้ แพคละ 1 ชิ้น'),
  ('Retail', 'Raw', 'Duck Fillet Male อกเป็ดตัวผู้'),
  ('Retail', 'Raw', 'Duck Fillet Female อกเป็ดตัวเมีย แพคละ 1 ชิ้น'),
  ('Retail', 'Raw', 'Duck Fillet Female อกเป็ดตัวเมีย'),
  ('Retail', 'Raw', 'Duck aiguillettes สันในเป็ด แพคละ 360 - 400 กรัม'),
  ('Retail', 'Raw', 'Duck aiguillettes สันในเป็ด'),
  ('Retail', 'Raw', 'Duck Wings ปีกเป็ด แพคละ 5 ชิ้น'),
  ('Retail', 'Raw', 'Duck Wings ปีกเป็ด'),
  ('Retail', 'Raw', 'Duck Male Legs ขาเป็ดตัวผู้ แพคละ 2 ชิ้น'),
  ('Retail', 'Raw', 'Duck Male Legs ขาเป็ดตัวผู้'),
  ('Retail', 'Raw', 'Duck Female Legs ขาเป็ดตัวเมีย แพคละ 2 ชิ้น'),
  ('Retail', 'Raw', 'Duck Female Legs ขาเป็ดตัวเมีย'),
  ('Retail', 'Raw', 'Whole Duck with Offal เป็ดเมียทั้งตัวพร้อมเครื่องใน'),
  ('Retail', 'Raw', 'Rabbit กระต่าย'),
  ('Retail', 'Raw', 'Capon Frozen 2.8 – 3.2 ไก่คาปองแช่แข็ง'),
  ('Retail', 'Raw', 'Capon Chilled 2.8-3.2 ไก่คาปอง'),
  ('Retail', 'Raw', 'Capon Frozen 3.2+ ไก่คาปองใหญ่แช่แข็ง'),
  ('Retail', 'Raw', 'Capon Chilled 3.2+ ไก่คาปองใหญ่'),
  ('Retail', 'Raw', 'Quail นกกระทา (130-160 g)'),
  ('Retail', 'Raw', 'Quail นกกระทา (161-250 g)'),
  ('Retail', 'Raw', 'Turkey 4-6 ไก่งวง M'),
  ('Retail', 'Raw', 'Turkey Chilled Brined 4-6 ไก่งวงแช่น้ำเกลือ'),
  ('Retail', 'Raw', 'Turkey 6-7+ ไก่งวงL'),
  ('Retail', 'Raw', 'Turkey Chilled Brined 6-7+ ไก่งวงแช่น้ำเกลือ'),
  ('Retail', 'Raw', 'Guinea Fowl ไก่ตะเภา/ไก่ต๊อก'),
  ('Retail', 'Raw', 'Pigeon นกพิราบ'),
  ('Retail', 'Raw', 'Whole Chicken & Duck with Offal ไก่เป็ดเมียทั้งตัวพร้อมเครื่องใน'),
  ('Retail', 'Raw', 'Chicken Carcass ซี่โครงไก่'),
  ('Retail', 'Raw', 'Duck Carcass ซี่โครงเป็ด'),
  ('Retail', 'Raw', 'Chicken Livers ตับไก่ แพคละ 250 กรัม'),
  ('Retail', 'Raw', 'Chicken Livers ตับไก่ แพคละ 500 กรัม'),
  ('Retail', 'Raw', 'Chicken Livers ตับไก่ แพคละ 1 กก'),
  ('Retail', 'Raw', 'Chicken Gizzards กึ๋นไก่ แพคละ 250 กรัม'),
  ('Retail', 'Raw', 'Chicken Gizzards กึ๋นไก่ แพคละ 500 กรัม'),
  ('Retail', 'Raw', 'Chicken Gizzards กึ๋นไก่ แพคละ 1 กก'),
  ('Retail', 'Raw', 'Chicken Hearts หัวใจไก่ แพคละ 250 กรัม'),
  ('Retail', 'Raw', 'Chicken Hearts หัวใจไก่ แพคละ 500 กรัม'),
  ('Retail', 'Raw', 'Chicken Hearts หัวใจไก่ แพคละ 1 กก'),
  ('Retail', 'Raw', 'Chicken Feets ตีนไก่ แพคละ 250 กรัม'),
  ('Retail', 'Raw', 'Chicken Feets ตีนไก่ แพคละ 500 กรัม'),
  ('Retail', 'Raw', 'Chicken Feets ตีนไก่ แพคละ 1 กก')
on conflict (channel, type, name) do nothing;


-- ----------------------------------------------------------------------------
-- 4. RLS — sale support can maintain the catalog
-- ----------------------------------------------------------------------------
-- Per Clément (5 Sep 2026): "Tod and Nam and Jane would be able to change and
-- add product specificities if necessary", with admin and sale support
-- confirming any additions. 001 made order_products admin-write only; this
-- opens insert/update to sale_support. Delete stays admin-only — deactivating
-- (active = false) is the intended way to retire a product, so history holds.

drop policy if exists "order_products: sale_support maintains" on public.order_products;
create policy "order_products: sale_support maintains"
  on public.order_products for insert to authenticated
  with check (public.current_role() = 'sale_support');

drop policy if exists "order_products: sale_support updates" on public.order_products;
create policy "order_products: sale_support updates"
  on public.order_products for update to authenticated
  using (public.current_role() = 'sale_support')
  with check (public.current_role() = 'sale_support');


-- ----------------------------------------------------------------------------
-- 5. sale_orders — channel, and the B2C fields
-- ----------------------------------------------------------------------------

alter table public.sale_orders add column if not exists channel text;
update public.sale_orders set channel = 'Restaurant' where channel is null;
alter table public.sale_orders alter column channel set not null;
alter table public.sale_orders alter column channel set default 'Restaurant';

alter table public.sale_orders drop constraint if exists sale_orders_channel_check;
alter table public.sale_orders add constraint sale_orders_channel_check
  check (channel in ('Restaurant', 'Department Store', 'Individual', 'Retail'));

-- The source column is called "Restaurant Name" only in the restaurant sheet;
-- the other three call it "Name". Renamed while the table is still empty.
-- Guarded so the migration stays safe to re-run: Postgres has no
-- "rename column if exists", and an accidental second run should be a no-op,
-- not an error.
do $$ begin
  if exists (select 1 from information_schema.columns
             where table_schema='public' and table_name='sale_orders'
               and column_name='restaurant_name') then
    alter table public.sale_orders rename column restaurant_name to customer_name;
  end if;
  if exists (select 1 from pg_constraint
             where conname='sale_orders_client_or_name'
               and conrelid='public.sale_orders'::regclass) then
    alter table public.sale_orders rename constraint sale_orders_client_or_name
      to sale_orders_client_or_customer_name;
  end if;
end $$;

-- Likewise "Address": a literal multi-line delivery address in Individual and
-- Retail, but delivery notes/area in Restaurant and Department Store. One
-- field, as in the source sheets — the UI labels it per channel.
do $$ begin
  if exists (select 1 from information_schema.columns
             where table_schema='public' and table_name='sale_orders'
               and column_name='delivery_notes') then
    alter table public.sale_orders rename column delivery_notes to delivery_address;
  end if;
end $$;

-- Customer code (CS015, CM2303) — Dept Store / Individual / Retail. Free text
-- rather than an FK: these are the codes the team writes today, and they are
-- not yet reconciled against the CRM's Odoo reference codes.
alter table public.sale_orders add column if not exists customer_code text;

-- The "Note" column present in all three non-restaurant sheets.
alter table public.sale_orders add column if not exists note text;

-- Individual/Retail order number (KPF0000116, occasionally free text like
-- "whatapps" where the order arrived by chat). Kept as text deliberately —
-- it is not always a generated sequence today.
alter table public.sale_orders add column if not exists order_number text;

-- B2C money, header level (confirmed: these appear once per order, on the
-- first line, not per product line). Delivery fee is distance-based —
-- 40 THB in Bangkok up to 550 for Phuket/Samui.
alter table public.sale_orders add column if not exists total_order  numeric(12,2);
alter table public.sale_orders add column if not exists delivery_fee numeric(12,2);
alter table public.sale_orders add column if not exists total_amount numeric(12,2);

-- Payment status, Individual channel. Stored as entered ("PAID 29/08/26",
-- "PAID 01/09/26 Credit") plus parsed parts, so the raw text is never lost
-- while the app can still filter on paid/unpaid.
alter table public.sale_orders add column if not exists payment_status_text text;
alter table public.sale_orders add column if not exists paid boolean;
alter table public.sale_orders add column if not exists paid_date date;
alter table public.sale_orders add column if not exists payment_method text;


-- ----------------------------------------------------------------------------
-- 6. sale_order_lines — Frozen, Jar, and weight as a size band
-- ----------------------------------------------------------------------------

alter table public.sale_order_lines drop constraint if exists sale_order_lines_type_check;
alter table public.sale_order_lines add constraint sale_order_lines_type_check
  check (type in ('Raw', 'Cooked', 'Delica', 'UnderRoof', 'PaleoRobbie',
                  'EasyHealth', 'Eggs', 'Frozen'));

-- 'Jar' is genuinely used (rillettes/confit style products). Canonical
-- capitalisation is enforced here; the source sheets mix kg/Kg, pcs/Pcs and
-- pack/Pack, so the UI dropdown and any import script must normalise case.
alter table public.sale_order_lines drop constraint if exists sale_order_lines_unit_check;
alter table public.sale_order_lines add constraint sale_order_lines_unit_check
  check (unit in ('Kg', 'Pcs', 'Grams', 'Pack', 'Jar'));

-- Weight replaces 001's numeric weight_kg, which could not hold the real
-- values: every restaurant row and half the Dept Store rows store text, and
-- size bands like "1.6-1.7" are the norm for whole birds. The raw text is
-- kept exactly as entered; min/max are parsed alongside it so the poultry
-- calculator can group demand by size band (Red Label 1.2-1.4 / 1.4-1.6 /
-- 1.6-1.8) and tell purchasing which size of bird to buy, not just how many.
-- Safe to drop: sale_order_lines is empty in both projects at time of writing.
alter table public.sale_order_lines drop column if exists weight_kg;
alter table public.sale_order_lines add column if not exists weight_label  text;
alter table public.sale_order_lines add column if not exists weight_min_kg numeric;
alter table public.sale_order_lines add column if not exists weight_max_kg numeric;

-- Logistics status: Clément confirmed 5 Sep 2026 it is "not really used
-- anymore" — the column is empty across all four September workbooks. Kept
-- (it costs nothing and the workflow may come back), but the UI should not
-- push it, and it no longer defaults to a value implying it is tracked.
alter table public.sale_order_lines alter column status drop not null;
alter table public.sale_order_lines alter column status drop default;


-- ============================================================================
-- Done. Next steps:
--   1. Link the new channels' products to cut_yield_reference. Deliberately
--      NOT done here: the B2C names carry pack sizes ("แพคละ 2 ชิ้น",
--      "360 - 400 g/pack") that change what one unit means, so mapping them
--      to a per-piece yield weight needs Clément's confirmation rather than
--      a guess. Restaurant's 10 links from 001 are unaffected.
--   2. Model bird size bands properly on cut_yield_reference, so the
--      calculator can answer "how many 1.4-1.6 kg Red Label" rather than
--      "how many birds".
--   3. Reconcile customer_code (CS015 / CM2303) against the CRM clients
--      table's Odoo reference codes, so B2C orders can link to client_id.
-- ============================================================================
