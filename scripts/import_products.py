#!/usr/bin/env python3
"""
Load the Prosun Farm hotel/restaurant price list (valid 16.04.2026) into the
CRM's product catalog, so reps can pick these when building a quotation.

Source: two PDF price lists Clement provided — Bangkok and Up-country —
which use different prices for almost every item (Up-country is consistently
about +20 THB/kg higher on most whole-bird and cut items). Per Clement's
instruction, each product that differs by zone is entered TWICE, once for
each zone, so a rep picks whichever applies to that customer. Items with a
volume price break ("1-10 pcs" vs "11 and more") are also entered twice —
once per tier — per Clement's instruction.

Also includes the new item announced 31 Aug 2026: Klong Phai Chicken,
1-1.2kg birds, 200 THB/kg — entered once, no zone given.

3 Sep 2026: added the "Chicken Under Roof" hotel/restaurant price list
(source: Prosunfarm_Underroof_Chicken_price.xlsx, valid from 01.07.2025) —
a separate product line from the Red/Green Label and Yellow chicken above,
priced per kg, no Bangkok/Up-country zone split on this sheet. Named with
an "Under Roof" suffix so it's never confused with the similarly-named
existing "Chicken Red/Green Label" or "Leg/Thigh/Drum Stick Red Label"
items above, which are a different price list entirely.

PLEASE SPOT-CHECK THESE TWO BEFORE TRUSTING THEM FOR A REAL QUOTE — they
were the two ambiguous readings off the PDF tables:
  - QUAILS: the price list shows only ONE number per size (no visible
    "11 and more" figure), unlike Capon/Pigeon/Rabbit/Turkey which clearly
    show two. Imported as a single flat price per size, no volume break.
    If quails actually do have a bulk price, tell me the number and I'll
    add the second entry.
  - CAPON, Up-country: 1-10 pcs = 520 THB/kg (same as Bangkok), but
    11-and-more = 528 THB/kg — i.e. buying MORE costs more per kg, the
    only item in the whole list where that happens. Every other tiered
    item gets cheaper in bulk. This may be a typo in the original price
    list rather than an intentional rule — worth checking against the
    paper original before quoting a large up-country Capon order.

Eggs and duck eggs are priced the same in both zones on the source sheets,
so those are entered once (no "— Bangkok" / "— Up-country" split).

SAFE TO RE-RUN: matches existing catalog rows by exact product name and
skips them, so running this twice does not create duplicates. If you need
to reload updated prices later, easiest is to deactivate/delete the old
rows in the admin Products tab first, then re-run.

Usage (same pattern as the other one-time scripts):

    export SUPABASE_URL="https://YOUR-PROJECT-REF.supabase.co"
    export SUPABASE_SERVICE_ROLE_KEY="..."   # Project Settings > API > service_role
    pip install supabase
    python3 scripts/import_products.py
"""

import os
import sys

from supabase import create_client

# (name, unit, unit_price)
PRODUCTS = [
    # ---------------- CHICKEN ----------------
    ("Yellow chicken (1.8-2.0kg) — Bangkok", "kg", 558),
    ("Yellow chicken (1.8-2.0kg) — Up-country", "kg", 578),
    ("Poularde (1.8-2.2kg) — Bangkok", "kg", 376),
    ("Poularde (1.8-2.2kg) — Up-country", "kg", 396),
    ("Chicken Green Label (1.7-1.8kg) — Bangkok", "kg", 298),
    ("Chicken Green Label (1.7-1.8kg) — Up-country", "kg", 318),
    ("Chicken Red Label (1.4-1.5kg) — Bangkok", "kg", 222),
    ("Chicken Red Label (1.4-1.5kg) — Up-country", "kg", 242),
    ("Spring Chicken (400-600gr) — Bangkok", "pce", 228),
    ("Spring Chicken (400-600gr) — Up-country", "pce", 248),
    ("Baby Chicken (600-800gr) — Bangkok", "pce", 178),
    ("Baby Chicken (600-800gr) — Up-country", "pce", 198),
    ("Wing Red Label (90gr) — Bangkok", "kg", 162),
    ("Wing Red Label (90gr) — Up-country", "kg", 182),
    ("Leg Red Label (220-240gr) — Bangkok", "kg", 283),
    ("Leg Red Label (220-240gr) — Up-country", "kg", 303),
    ("Drum stick Red Label (100-120gr) — Bangkok", "kg", 294),
    ("Drum stick Red Label (100-120gr) — Up-country", "kg", 314),
    ("Leg tight Red Label (120-140gr) — Bangkok", "kg", 294),
    ("Leg tight Red Label (120-140gr) — Up-country", "kg", 314),
    ("Breasts Red Label (180-200gr) — Bangkok", "kg", 342),
    ("Breasts Red Label (180-200gr) — Up-country", "kg", 362),
    ("Supreme Red Label (200-220gr) — Bangkok", "kg", 354),
    ("Supreme Red Label (200-220gr) — Up-country", "kg", 374),
    ("Chicken carcass (600gr) — Bangkok", "kg", 46),
    ("Chicken carcass (600gr) — Up-country", "kg", 66),
    ("Chicken Liver Red Label (500gr/pack) — Bangkok", "pack", 167),
    ("Chicken Liver Red Label (500gr/pack) — Up-country", "pack", 187),
    ("Chicken gizzard Red Label (500gr/pack) — Bangkok", "pack", 167),
    ("Chicken gizzard Red Label (500gr/pack) — Up-country", "pack", 187),
    ("Chicken heart Red Label (500gr/pack) — Bangkok", "pack", 157),
    ("Chicken heart Red Label (500gr/pack) — Up-country", "pack", 177),
    ("Chicken feet Red Label (1kg/pack) — Bangkok", "pack", 183),
    ("Chicken feet Red Label (1kg/pack) — Up-country", "pack", 203),
    ("Chicken Neck Red Label (1kg/pack) — Bangkok", "pack", 46),
    ("Chicken Neck Red Label (1kg/pack) — Up-country", "pack", 66),
    ("Chicken Saut l'y laisse Oyster (500gr/pack) — Bangkok", "pack", 259),
    ("Chicken Saut l'y laisse Oyster (500gr/pack) — Up-country", "pack", 279),
    # ---------------- DUCK ----------------
    ("Golden Signature Duck female (2.3-2.9kg) — Bangkok", "kg", 400),
    ("Golden Signature Duck female (2.3-2.9kg) — Up-country", "kg", 420),
    ("Golden Signature Duck male (3.0-3.6kg) — Bangkok", "kg", 420),
    ("Golden Signature Duck male (3.0-3.6kg) — Up-country", "kg", 440),
    ("Moscovy/Barbary duck female (1.8-2.0kg) — Bangkok", "kg", 320),
    ("Moscovy/Barbary duck female (1.8-2.0kg) — Up-country", "kg", 340),
    ("Moscovy/Barbary duck male (3.5-3.8kg) — Bangkok", "kg", 340),
    ("Moscovy/Barbary duck male (3.5-3.8kg) — Up-country", "kg", 360),
    ("Moscovy/Barbary duck female filet (180-200gr/pce) — Bangkok", "kg", 746),
    ("Moscovy/Barbary duck female filet (180-200gr/pce) — Up-country", "kg", 766),
    ("Moscovy/Barbary duck male filet (300-350gr/pce) — Bangkok", "kg", 746),
    ("Moscovy/Barbary duck male filet (300-350gr/pce) — Up-country", "kg", 766),
    ("Moscovy/Barbary duck female leg (180-200gr/pce) — Bangkok", "kg", 533),
    ("Moscovy/Barbary duck female leg (180-200gr/pce) — Up-country", "kg", 553),
    ("Moscovy/Barbary duck male leg (300-320gr/pce) — Bangkok", "kg", 533),
    ("Moscovy/Barbary duck male leg (300-320gr/pce) — Up-country", "kg", 553),
    ("Golden Signature Duck (GSD) female filet (200-299gr/pce) — Bangkok", "kg", 820),
    ("Golden Signature Duck (GSD) female filet (200-299gr/pce) — Up-country", "kg", 840),
    ("Golden Signature Duck (GSD) male filet (+300gr/pce) — Bangkok", "kg", 900),
    ("Golden Signature Duck (GSD) male filet (+300gr/pce) — Up-country", "kg", 920),
    ("Golden Signature Duck (GSD) female leg (200-250gr/pce) — Bangkok", "kg", 586),
    ("Golden Signature Duck (GSD) female leg (200-250gr/pce) — Up-country", "kg", 606),
    ("Golden Signature Duck (GSD) male leg (260-300+gr/pce) — Bangkok", "kg", 643),
    ("Golden Signature Duck (GSD) male leg (260-300+gr/pce) — Up-country", "kg", 663),
    ("Duck carcass (600gr) — Bangkok", "kg", 76),
    ("Duck carcass (600gr) — Up-country", "kg", 96),
    ("Duck aiguillettes/filets (20-30gr/pce) — Bangkok", "kg", 350),
    ("Duck aiguillettes/filets (20-30gr/pce) — Up-country", "kg", 370),
    ("Duck wings + manchon (150gr environ) — Bangkok", "kg", 231),
    ("Duck wings + manchon (150gr environ) — Up-country", "kg", 251),
    ("Duck Liver (1kg/pack) — Bangkok", "pack", 259),
    ("Duck Liver (1kg/pack) — Up-country", "pack", 279),
    ("Duck gizzard (1kg/pack) — Bangkok", "pack", 259),
    ("Duck gizzard (1kg/pack) — Up-country", "pack", 279),
    # ---------------- SPECIAL POULTRY ----------------
    ("Capon (3-4kg, 1-10 pcs) — Bangkok", "kg", 520),
    ("Capon (3-4kg, 11+ pcs) — Bangkok", "kg", 508),
    ("Capon (3-4kg, 1-10 pcs) — Up-country", "kg", 520),
    ("Capon (3-4kg, 11+ pcs) — Up-country", "kg", 528),  # see caveat above
    ("Quails (130-160gr/pce, ~6 pces/kg) — Bangkok", "kg", 335),
    ("Quails (130-160gr/pce, ~6 pces/kg) — Up-country", "kg", 355),
    ("Quails (190-250gr/pce, ~4-5 pces/kg) — Bangkok", "kg", 426),
    ("Quails (190-250gr/pce, ~4-5 pces/kg) — Up-country", "kg", 446),
    ("Pigeon (300-350gr/pce, 1-10 pcs) — Bangkok", "pce", 550),
    ("Pigeon (300-350gr/pce, 11+ pcs) — Bangkok", "pce", 508),
    ("Pigeon (300-350gr/pce, 1-10 pcs) — Up-country", "pce", 550),
    ("Pigeon (300-350gr/pce, 11+ pcs) — Up-country", "pce", 528),
    ("Pigeon (350-400gr/pce, 1-10 pcs) — Bangkok", "pce", 630),
    ("Pigeon (350-400gr/pce, 11+ pcs) — Bangkok", "pce", 589),
    ("Pigeon (350-400gr/pce, 1-10 pcs) — Up-country", "pce", 630),
    ("Pigeon (350-400gr/pce, 11+ pcs) — Up-country", "pce", 609),
    ("Pigeon (400+gr/pce, 1-10 pcs) — Bangkok", "pce", 680),
    ("Pigeon (400+gr/pce, 11+ pcs) — Bangkok", "pce", 639),
    ("Pigeon (400+gr/pce, 1-10 pcs) — Up-country", "pce", 680),
    ("Pigeon (400+gr/pce, 11+ pcs) — Up-country", "pce", 659),
    # Turkey only appears on the Bangkok list
    ("Turkey (4.5kg+, 1-10 pcs) — Bangkok", "kg", 517),
    ("Turkey (4.5kg+, 11+ pcs) — Bangkok", "kg", 497),
    ("Rabbit (1.1-1.4kg/pce, 1-10 pcs) — Bangkok", "kg", 490),
    ("Rabbit (1.1-1.4kg/pce, 11+ pcs) — Bangkok", "kg", 467),
    ("Rabbit (1.1-1.4kg/pce, 1-10 pcs) — Up-country", "kg", 490),
    ("Rabbit (1.1-1.4kg/pce, 11+ pcs) — Up-country", "kg", 487),
    # ---------------- EGGS (same price both zones) ----------------
    ("Eggs (<90 cps)", "pce", 7.5),
    ("Eggs (>90 pcs)", "pce", 7.0),
    ("Duck Eggs size 0 (>30 pcs)", "pce", 14),
    # ---------------- DAIRY ----------------
    ("Greek Yogurt (450gr) — Bangkok", "pce", 233),
    ("Greek Yogurt (450gr) — Up-country", "pce", 253),
    ("Grass Fed Milk (1200ml) — Bangkok", "pce", 132),
    ("Grass Fed Milk (1200ml) — Up-country", "pce", 152),
    # ---------------- NEW PRODUCT (31 Aug 2026 launch) ----------------
    ("Klong Phai Chicken (1-1.2kg)", "kg", 200),
    # ---------------- CHICKEN UNDER ROOF (hotel/restaurant, valid 01.07.2025) ----------------
    ("Chicken Under Roof (1.4-1.6kg)", "kg", 167.64),
    ("Chicken Under Roof (1.0-1.1kg)", "kg", 184.15),
    ("Full Wing Under Roof (90gr)", "kg", 222.25),
    ("Middle Wing Under Roof", "kg", 304.80),
    ("Top Wing Under Roof", "kg", 198.12),
    ("Leg Under Roof (180-230gr)", "kg", 187.96),
    ("Thigh Under Roof", "kg", 154.94),
    ("Drum Stick Under Roof", "kg", 177.80),
    ("Chicken Feet Under Roof", "kg", 241.30),
    ("Breast with Skin Under Roof (180-270gr)", "kg", 170.00),
    ("Breast without Skin Under Roof (180-270gr)", "kg", 177.00),
]


def main():
    url = os.environ.get("SUPABASE_URL")
    key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
    if not url or not key:
        print("Set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY first.")
        sys.exit(1)

    client = create_client(url, key)

    existing = set()
    start = 0
    while True:
        chunk = (
            client.table("products")
            .select("name")
            .range(start, start + 999)
            .execute()
            .data
        )
        if not chunk:
            break
        existing.update(row["name"] for row in chunk)
        if len(chunk) < 1000:
            break
        start += 1000

    to_insert = [
        {"name": name, "unit": unit, "unit_price": price, "active": True}
        for name, unit, price in PRODUCTS
        if name not in existing
    ]

    if not to_insert:
        print("Nothing to insert — all product names already exist in the catalog.")
        return

    # Insert in batches to stay well under any request size limit.
    for i in range(0, len(to_insert), 200):
        client.table("products").insert(to_insert[i : i + 200]).execute()

    skipped = len(PRODUCTS) - len(to_insert)
    print(f"{len(to_insert)} products inserted, {skipped} already existed and were skipped.")


if __name__ == "__main__":
    main()
