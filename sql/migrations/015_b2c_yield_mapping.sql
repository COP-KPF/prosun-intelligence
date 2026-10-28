-- ============================================================================
-- Migration 015 — poultry calculator: Department Store, Individual, Retail
-- ============================================================================
-- Written 7 Sep 2026, extending the poultry calculator (Restaurant-only
-- since it was first built) to the three B2C channels, for Clément's "next
-- step" pick after Migration 014. Two open questions were resolved with him
-- before writing this:
--
--   "Looking at the real catalogs, most B2C Raw items are whole animals
--   (Green Label, Baby/Spring Chicken, Rabbit, Capon, Quail, Turkey, Guinea
--   Fowl, Pigeon) with no yield weights on file for most of them — same
--   Green Label gap already flagged for Restaurant. Only a smaller set
--   (chicken/duck breast, leg, wing, thigh, carcass) are cuts sold by pack.
--   Which scope should v1 cover?" -> "Red Label chicken + Duck Moscovy/
--   Barbary cuts only" — the lines already linked to real yield weights
--   (Migration 001). Everything else (Green Label, Baby/Spring Chicken,
--   Rabbit, Capon, Quail, Turkey, Guinea Fowl, Pigeon, duck wings, duck
--   aiguillettes, all offal) stays unmapped, same as it already is for
--   Restaurant — surfaced by the calculator's existing "not yet mapped"
--   callout, not guessed at.
--
--   "A whole-bird order (e.g. Red Label Chicken sold whole, not by cut) —
--   does quantity ordered = birds needed, directly, no yield math?" ->
--   "It should, if its whole bird than yes."
--
-- What actually needed adding, once those were settled: B2C sells some of
-- these same cuts by the PACK rather than by weight — "Chicken Breast
-- อกไก่ แพคละ 2 ชิ้น" is 2 breast pieces per pack. The piece count is
-- printed right there in the product name, confirmed against the real
-- September import (parsed_orders.json): every "แพคละ N ชิ้น" product was
-- actually ordered in Pack units, every plain-named cut in Kg, and the
-- whole-bird "Red Label Chicken ไก่ตองหนึ่ง" in Pcs — exactly the three
-- unit families the calculator already has to handle, just one channel
-- wider. Storing the piece count as data (this migration) rather than
-- parsing the Thai product name at calculation time keeps that logic out
-- of app.js entirely.
--
-- Run order: after 001 (needs cut_yield_reference) and 002 (needs the B2C
-- catalog rows to exist). Independent of 012/013/014. Safe to re-run —
-- every update below is idempotent (sets the same value every time).
-- ============================================================================

alter table public.order_products
  add column if not exists pack_piece_count integer,
  add column if not exists is_whole_bird boolean not null default false;

comment on column public.order_products.pack_piece_count is
  'How many pieces of the linked cut_yield_reference cut are in one Pack '
  'unit of this product — e.g. 2 for "Chicken Breast แพคละ 2 ชิ้น". Only '
  'meaningful together with cut_yield_id and unit = ''Pack''. Read straight '
  'from the product name (แพคละ N ชิ้น), not guessed.';

comment on column public.order_products.is_whole_bird is
  'True when this product sells the whole animal, not a cut — e.g. "Red '
  'Label Chicken ไก่ตองหนึ่ง", "Duck Barbary Male". cut_yield_id is still '
  'set for these, purely to place them in the right species/variant card; '
  'the poultry calculator skips the piece-weight math entirely and counts '
  'the ordered quantity (Pcs only) as birds directly (Clément, 7 Sep 2026: '
  '"if its whole bird than yes"), added on top of whatever the group''s '
  'cuts need rather than competing with them for the bottleneck — a bird '
  'sold whole never reaches the cutting line.';

-- ----------------------------------------------------------------------------
-- Chicken Red Label cuts — Department Store, Individual, Retail.
-- Same cut_yield_reference rows Restaurant already uses (Migration 001);
-- B2C just sells some of them by the pack instead of by weight.
-- ----------------------------------------------------------------------------

update public.order_products set cut_yield_id = (
  select id from public.cut_yield_reference where species = 'Chicken' and variant = 'Red Label' and cut_name = 'Breast'
)
where channel in ('Department Store', 'Individual', 'Retail')
  and name in (
    'Chicken Breast อกไก่ แพคละ 2 ชิ้น',
    'Chicken Breast อกไก่ แพคละ 2 ชิ้น ( น้ำหนัก 360 - 400 g/pack )',
    'Chicken Breast อกไก่ติดหนัง',
    'Chicken Breast อกไก่ลอกหนัง'
  );
update public.order_products set pack_piece_count = 2
where channel in ('Department Store', 'Retail') and name = 'Chicken Breast อกไก่ แพคละ 2 ชิ้น';
update public.order_products set pack_piece_count = 2
where channel = 'Individual' and name = 'Chicken Breast อกไก่ แพคละ 2 ชิ้น ( น้ำหนัก 360 - 400 g/pack )';

-- "Chicken Legs ขาไก่" is the whole leg — pools with thigh/drumstick demand
-- exactly like Restaurant's own "Leg (whole)" line (leg_pool_group = 'leg'),
-- via the same shared cut_yield_reference row.
update public.order_products set cut_yield_id = (
  select id from public.cut_yield_reference where species = 'Chicken' and variant = 'Red Label' and cut_name = 'Leg (whole)'
)
where channel in ('Department Store', 'Individual', 'Retail')
  and name in (
    'Chicken Legs ขาไก่ แพคละ 2 ชิ้น',
    'Chicken Legs ขาไก่ แพคละ 2 ชิ้น ( น้ำหนัก 360 - 400 g/pack )',
    'Chicken Legs ขาไก่'
  );
update public.order_products set pack_piece_count = 2
where channel in ('Department Store', 'Retail') and name = 'Chicken Legs ขาไก่ แพคละ 2 ชิ้น';
update public.order_products set pack_piece_count = 2
where channel = 'Individual' and name = 'Chicken Legs ขาไก่ แพคละ 2 ชิ้น ( น้ำหนัก 360 - 400 g/pack )';

update public.order_products set cut_yield_id = (
  select id from public.cut_yield_reference where species = 'Chicken' and variant = 'Red Label' and cut_name = 'Thigh'
)
where channel in ('Department Store', 'Individual', 'Retail')
  and name in (
    'Chicken Thighs สะโพกไก่ แพคละ 4 ชิ้น',
    'Chicken Thighs สะโพกไก่ แพคละ 4 ชิ้น ( น้ำหนัก 540 - 600 g/pack )',
    'Chicken Thighs สะโพกไก่'
  );
update public.order_products set pack_piece_count = 4
where channel in ('Department Store', 'Retail') and name = 'Chicken Thighs สะโพกไก่ แพคละ 4 ชิ้น';
update public.order_products set pack_piece_count = 4
where channel = 'Individual' and name = 'Chicken Thighs สะโพกไก่ แพคละ 4 ชิ้น ( น้ำหนัก 540 - 600 g/pack )';

update public.order_products set cut_yield_id = (
  select id from public.cut_yield_reference where species = 'Chicken' and variant = 'Red Label' and cut_name = 'Wing'
)
where channel in ('Department Store', 'Individual', 'Retail')
  and name in (
    'Chicken Wings ปีกไก่ แพคละ 8 ชิ้น',
    'Chicken Wings ปีกไก่ แพคละ 8 ชิ้น ( น้ำหนัก 540 - 600 g/pack )',
    'Chicken Wings ปีกไก่'
  );
update public.order_products set pack_piece_count = 8
where channel in ('Department Store', 'Retail') and name = 'Chicken Wings ปีกไก่ แพคละ 8 ชิ้น';
update public.order_products set pack_piece_count = 8
where channel = 'Individual' and name = 'Chicken Wings ปีกไก่ แพคละ 8 ชิ้น ( น้ำหนัก 540 - 600 g/pack )';

update public.order_products set cut_yield_id = (
  select id from public.cut_yield_reference where species = 'Chicken' and variant = 'Red Label' and cut_name = 'Carcass'
)
where channel in ('Department Store', 'Individual', 'Retail') and name = 'Chicken Carcass ซี่โครงไก่';

-- Whole Red Label chicken — sold by the piece, not cut at all.
update public.order_products set
  cut_yield_id = (select id from public.cut_yield_reference where species = 'Chicken' and variant = 'Red Label' and cut_name = 'Breast'),
  is_whole_bird = true
where channel in ('Department Store', 'Individual', 'Retail') and name = 'Red Label Chicken ไก่ตองหนึ่ง';

-- ----------------------------------------------------------------------------
-- Duck Moscovy/Barbary cuts — same three channels, same idea. Duck Wings
-- and Duck aiguillettes have NO cut_yield_reference row (Migration 001 only
-- seeded Filet, Leg and Carcass for this line) — left unmapped rather than
-- guessing a piece weight, exactly the Green Label pattern.
-- ----------------------------------------------------------------------------

update public.order_products set cut_yield_id = (
  select id from public.cut_yield_reference where species = 'Duck' and variant = 'Moscovy/Barbary male' and cut_name = 'Filet'
)
where channel in ('Department Store', 'Individual', 'Retail')
  and name in (
    'Duck Fillet Male อกเป็ดตัวผู้',
    'Duck Fillet Male อกเป็ดตัวผู้ แพคละ 1 ชิ้น',
    'Duck Fillet Male อกเป็ดตัวผู้ แพคละ 1 ชิ้น ( น้ำหนัก 270 - 300 g/pack )'
  );
update public.order_products set pack_piece_count = 1
where channel in ('Department Store', 'Retail') and name = 'Duck Fillet Male อกเป็ดตัวผู้ แพคละ 1 ชิ้น';
update public.order_products set pack_piece_count = 1
where channel = 'Individual' and name = 'Duck Fillet Male อกเป็ดตัวผู้ แพคละ 1 ชิ้น ( น้ำหนัก 270 - 300 g/pack )';

update public.order_products set cut_yield_id = (
  select id from public.cut_yield_reference where species = 'Duck' and variant = 'Moscovy/Barbary female' and cut_name = 'Filet'
)
where channel in ('Department Store', 'Individual', 'Retail')
  and name in (
    'Duck Fillet Female อกเป็ดตัวเมีย',
    'Duck Fillet Female อกเป็ดตัวเมีย แพคละ 1 ชิ้น',
    'Duck Fillet Female อกเป็ดตัวเมีย แพคละ 1 ชิ้น ( น้ำหนัก 130 - 150 g+ /pack )'
  );
update public.order_products set pack_piece_count = 1
where channel in ('Department Store', 'Retail') and name = 'Duck Fillet Female อกเป็ดตัวเมีย แพคละ 1 ชิ้น';
update public.order_products set pack_piece_count = 1
where channel = 'Individual' and name = 'Duck Fillet Female อกเป็ดตัวเมีย แพคละ 1 ชิ้น ( น้ำหนัก 130 - 150 g+ /pack )';

update public.order_products set cut_yield_id = (
  select id from public.cut_yield_reference where species = 'Duck' and variant = 'Moscovy/Barbary male' and cut_name = 'Leg'
)
where channel in ('Department Store', 'Individual', 'Retail')
  and name in (
    'Duck Male Legs ขาเป็ดตัวผู้',
    'Duck Male Legs ขาเป็ดตัวผู้ แพคละ 2 ชิ้น',
    'Duck Male Legs ขาเป็ดตัวผู้ แพคละ 2 ชิ้น ( น้ำหนัก 500 - 600g/pack )'
  );
update public.order_products set pack_piece_count = 2
where channel in ('Department Store', 'Retail') and name = 'Duck Male Legs ขาเป็ดตัวผู้ แพคละ 2 ชิ้น';
update public.order_products set pack_piece_count = 2
where channel = 'Individual' and name = 'Duck Male Legs ขาเป็ดตัวผู้ แพคละ 2 ชิ้น ( น้ำหนัก 500 - 600g/pack )';

update public.order_products set cut_yield_id = (
  select id from public.cut_yield_reference where species = 'Duck' and variant = 'Moscovy/Barbary female' and cut_name = 'Leg'
)
where channel in ('Department Store', 'Individual', 'Retail')
  and name in (
    'Duck Female Legs ขาเป็ดตัวเมีย',
    'Duck Female Legs ขาเป็ดตัวเมีย แพคละ 2 ชิ้น',
    'Duck Female Legs ขาเป็ดตัวเมีย แพคละ 2 ชิ้น ( น้ำหนัก 500 - 600 g / pack )'
  );
update public.order_products set pack_piece_count = 2
where channel in ('Department Store', 'Retail') and name = 'Duck Female Legs ขาเป็ดตัวเมีย แพคละ 2 ชิ้น';
update public.order_products set pack_piece_count = 2
where channel = 'Individual' and name = 'Duck Female Legs ขาเป็ดตัวเมีย แพคละ 2 ชิ้น ( น้ำหนัก 500 - 600 g / pack )';

update public.order_products set cut_yield_id = (
  select id from public.cut_yield_reference where species = 'Duck' and variant = 'Moscovy/Barbary' and cut_name = 'Carcass'
)
where channel in ('Department Store', 'Individual', 'Retail') and name = 'Duck Carcass ซี่โครงเป็ด';

-- Whole Duck Barbary, male and female — sold by the piece, not cut at all.
-- cut_yield_id points at that gender's Filet row purely for card grouping.
update public.order_products set
  cut_yield_id = (select id from public.cut_yield_reference where species = 'Duck' and variant = 'Moscovy/Barbary male' and cut_name = 'Filet'),
  is_whole_bird = true
where channel in ('Department Store', 'Individual', 'Retail') and name = 'Duck Barbary Male เป็ดบาร์บารี่ ตัวผู้';

update public.order_products set
  cut_yield_id = (select id from public.cut_yield_reference where species = 'Duck' and variant = 'Moscovy/Barbary female' and cut_name = 'Filet'),
  is_whole_bird = true
where channel in ('Department Store', 'Individual', 'Retail') and name = 'Duck Barbary Female เป็ดบาร์บารี่ ตัวเมีย';

-- ============================================================================
-- Deliberately left unmapped, same "surface it, don't guess" convention as
-- Green Label on the Restaurant side (Migration 001's own comment) — these
-- show up in the calculator's summary table as "no yield weight on file
-- yet" rather than silently vanishing or being counted with an invented
-- weight:
--   Green Label Chicken, Baby Chicken, Spring Chicken, Whole Chicken (&
--   Duck) with Offal, Rabbit, Capon, Quail, Turkey, Guinea Fowl, Pigeon —
--   whole-animal SKUs with no yield reference at all;
--   Duck Wings, Duck aiguillettes — cuts of the Duck Moscovy/Barbary line
--   Clément's own reference file never gave a piece weight for;
--   Chicken/Duck Livers, Gizzards, Hearts, Feet — offal with no
--   cut_yield_reference rows on file.
-- Add rows here the same way once Clément supplies real weights for any of
-- these, exactly as Migration 001 already documents for Green Label.
-- ============================================================================

-- ============================================================================
-- Check afterwards, in the SQL Editor:
--
--   select channel, count(*) from public.order_products
--   where cut_yield_id is not null and channel <> 'Restaurant'
--   group by channel;
--   -- Department Store / Individual / Retail should each show ~18-20 rows
--   -- now linked (the pack + plain variants of each of the 10 cuts, plus
--   -- the 3 whole-bird SKUs).
--
--   select channel, name, pack_piece_count from public.order_products
--   where pack_piece_count is not null order by channel, name;
--   -- one row per pack-named SKU, piece count matching what's printed in
--   -- the Thai name (แพคละ N ชิ้น).
--
--   select channel, name from public.order_products
--   where is_whole_bird order by channel, name;
--   -- exactly 3 rows per channel: Red Label Chicken, Duck Barbary Male,
--   -- Duck Barbary Female.
-- ============================================================================
