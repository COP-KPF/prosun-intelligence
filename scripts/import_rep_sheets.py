#!/usr/bin/env python3
"""
Import/refresh the four sales reps' personal tracking sheets — the ones
Clément actually manages month to month — into the CRM.

These are DIFFERENT from the "Customer Data" master sheet handled by
import_odoo_customers.py. Each rep sheet ("Christophe - 02", "James - 12",
"Chovie - 13", "Pammy - 14") is a monthly pivot: one row per customer, with
13 months (Jun 2025 -> latest) of FARM/FOOD/Total revenue, ending in an
"OK" status column. This script reads only those four sheets — "Customer
Data" and "08-Not transferred yet..." are intentionally left alone; those
stay admin-only to review and assign (per Clément's instruction).

For each customer row in a rep's sheet:
  - name is set to the rep sheet's name (the short/trade name reps actually
    use day to day, e.g. "Sloane", "Finch") — replacing whatever name came
    from the original Odoo master-list import (often the full registered
    company name, sometimes in Thai). The previous name is kept in notes
    as "Registered name on file" so it isn't lost.
  - deal_value is set to that customer's LATEST month's Total (the most
    recent column of dates in the sheet — detected automatically, so this
    keeps working next month when a new column is added). Blank/zero
    latest month = 0. This is deliberately the "did they order this
    month" number, not a historical sum — Clément wants it to show which
    accounts have gone quiet as much as overall size.
  - stage is set to "won" if that latest-month value is > 0, or "at_risk"
    if it's 0/blank — flagging exactly the accounts that haven't ordered
    yet this month, per Clément's request.
  - assigned_to is set to that sheet's rep, even if the customer was
    previously assigned to someone else in the CRM (the annotations in
    these sheets, e.g. "Come from 12", already reflect a completed
    transfer — this file is the source of truth for current ownership).

Matching against existing CRM records is done by the same Odoo Reference
code stored in each client's notes field (e.g. "Odoo ref: CH018") during
the original import. A customer in a rep's sheet that has NO matching
record yet (rare — a handful of accounts aren't in the original Odoo
export) is inserted as a new client instead.

SAFE TO RE-RUN every month with a fresh export: matched customers are
UPDATED in place (no duplicates), and a customer inserted once will be
found and updated (not re-inserted) on every later run, because the match
is by Odoo reference code, not by name.

Optional --reset flag: each rep's "Your pipeline" can end up also holding
every OTHER customer that was ever bulk-imported under their name from the
Odoo master list ("Customer Data") — mostly Thai company names, stage
'dormant', no deal value — cluttering the view with accounts the rep
isn't actually tracking day to day. Passing --reset clears that out first:
for each of the four reps, every client currently assigned to them is
UN-assigned (assigned_to -> NULL) and reset to stage 'dormant' / deal_value
NULL — nothing is deleted, those customers simply go back into the shared
unassigned pool the admin account reviews under "All clients & deals" —
and then the normal import below re-adds only the customers that are
actually in that rep's own sheet. Net effect: a rep's pipeline shows
ONLY what's in their sheet, nothing else.

Usage (same pattern as the other one-time scripts — run from your own
machine, not GitHub Actions, using the service_role key):

    export SUPABASE_URL="https://YOUR-PROJECT-REF.supabase.co"
    export SUPABASE_SERVICE_ROLE_KEY="..."   # Project Settings > API > service_role
    pip install supabase pandas openpyxl
    python3 scripts/import_rep_sheets.py "path/to/Report Sales 06072026 - All v2.xlsx"

    # or, to first clear each rep's pipeline back to just their own sheet:
    python3 scripts/import_rep_sheets.py --reset "path/to/Report Sales 06072026 - All v2.xlsx"
"""

import datetime
import os
import re
import sys

import pandas as pd
from supabase import create_client

# Sheet name (exact, as it appears in the workbook) -> that rep's CRM login email.
REP_SHEETS = {
    "Christophe - 02": "christophe@klongphaifarm.com",
    "James - 12": "james@klongphaifarm.com",
    "Chovie - 13": "chovie@klongphaifarm.com",
    "Pammy - 14": "pammy@klongphaifarm.com",
}

NAME_COL = 2
REF_COL = 3
HEADER_DATE_ROW = 1
DATA_START_ROW = 3

REF_RE = re.compile(r"Odoo ref:\s*(\S+)")
# A parenthetical that is itself just another reference code, e.g. "(CR232)"
# — these show up inside some customer names and aren't part of the real
# name, so they're stripped out and kept as a note instead.
REF_IN_PARENS_RE = re.compile(r"\(([A-Z]{2}\d+)\)")


def clean_text(value):
    if value is None or (isinstance(value, float) and pd.isna(value)):
        return None
    text = " ".join(str(value).replace("\xa0", " ").split())
    return text or None


def split_name_and_annotation(raw_name):
    """'Sloane  *Come from 03' -> ('Sloane', 'Come from 03')."""
    text = clean_text(raw_name) or ""
    ref_in_parens = None
    m = REF_IN_PARENS_RE.search(text)
    if m:
        ref_in_parens = m.group(1)
        text = text.replace(m.group(0), " ")
    name, _, annotation = text.partition("*")
    name = clean_text(name) or clean_text(raw_name) or "Unknown"
    annotation = clean_text(annotation.lstrip("*"))
    return name, annotation, ref_in_parens


def latest_month_total_col(raw_df):
    date_cols = [
        i for i, v in enumerate(raw_df.iloc[HEADER_DATE_ROW])
        if isinstance(v, (pd.Timestamp, datetime.datetime))
    ]
    if not date_cols:
        sys.exit("Could not find any month columns in this sheet — layout may have changed.")
    return max(date_cols) + 2  # FARM, FOOD, Total -> Total is +2 from the date/FARM column


def parse_rep_sheet(path, sheet_name):
    raw = pd.read_excel(path, sheet_name=sheet_name, header=None)
    total_col = latest_month_total_col(raw)
    rows = []
    for _, r in raw.iloc[DATA_START_ROW:].iterrows():
        ref = clean_text(r.get(REF_COL))
        if not ref:
            continue
        name, annotation, ref_in_parens = split_name_and_annotation(r.get(NAME_COL))
        latest = r.get(total_col)
        deal_value = 0.0 if (latest is None or (isinstance(latest, float) and pd.isna(latest))) else round(float(latest), 2)
        rows.append({
            "reference": ref,
            "name": name,
            "annotation": annotation,
            "ref_in_parens": ref_in_parens,
            "deal_value": deal_value,
            "stage": "won" if deal_value > 0 else "at_risk",
        })
    return rows


def main():
    args = sys.argv[1:]
    reset = "--reset" in args
    args = [a for a in args if a != "--reset"]
    if len(args) != 1:
        sys.exit(f"Usage: python3 {sys.argv[0]} [--reset] path/to/file.xlsx")
    file_path = args[0]

    url = os.environ.get("SUPABASE_URL")
    key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
    if not url or not key:
        sys.exit("Set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY first.")

    client = create_client(url, key)

    users = client.auth.admin.list_users()
    email_to_id = {u.email.lower(): u.id for u in users if u.email}
    for sheet, email in REP_SHEETS.items():
        if email.lower() not in email_to_id:
            sys.exit(f"No CRM user found for {email} (sheet '{sheet}') — check the account exists.")

    if reset:
        print("Resetting each rep's pipeline (un-assigning, back to dormant)...")
        for sheet, email in REP_SHEETS.items():
            rep_id = email_to_id[email.lower()]
            result = client.table("clients").update({
                "assigned_to": None,
                "stage": "dormant",
                "deal_value": None,
            }).eq("assigned_to", rep_id).execute().data
            print(f"  {sheet} ({email}): {len(result)} client(s) un-assigned")
        print()

    # Pull every existing client's id + notes so we can match by Odoo
    # reference code (there's no dedicated reference column in the schema —
    # it's embedded in notes as "Odoo ref: XXXX" from the original import).
    ref_to_id = {}
    ref_to_name = {}
    start = 0
    page = 1000
    while True:
        chunk = client.table("clients").select("id, name, notes").range(start, start + page - 1).execute().data
        if not chunk:
            break
        for row in chunk:
            m = REF_RE.search(row.get("notes") or "")
            if m:
                ref_to_id.setdefault(m.group(1), row["id"])
                ref_to_name.setdefault(m.group(1), row.get("name"))
        if len(chunk) < page:
            break
        start += page

    today = datetime.date.today().isoformat()
    updated = 0
    inserted = 0
    won = 0
    at_risk = 0

    for sheet_name, email in REP_SHEETS.items():
        rep_id = email_to_id[email.lower()]
        rows = parse_rep_sheet(file_path, sheet_name)
        print(f"\n{sheet_name}: {len(rows)} customer row(s)")

        for row in rows:
            if row["stage"] == "won":
                won += 1
            else:
                at_risk += 1

            note_bits = [f"Odoo ref: {row['reference']}"]
            if row["ref_in_parens"]:
                note_bits.append(f"Previously tracked as {row['ref_in_parens']}")
            if row["annotation"]:
                note_bits.append(f"Rep sheet note: {row['annotation']}")

            existing_id = ref_to_id.get(row["reference"])
            if existing_id:
                old_name = ref_to_name.get(row["reference"])
                # The rep sheet's name is the one the rep actually recognizes
                # day to day (short/trade name) — use it as the CRM name.
                # If that's replacing a different name (often the full legal
                # entity name from the Odoo master list), keep the old one on
                # record so it isn't lost for invoicing/paperwork purposes.
                if old_name and old_name.strip() != row["name"].strip():
                    note_bits.append(f"Registered name on file: {old_name}")
                note_bits.append(f"Deal value refreshed from rep sheet on {today}")
                notes = " · ".join(note_bits)

                client.table("clients").update({
                    "name": row["name"],
                    "assigned_to": rep_id,
                    "stage": row["stage"],
                    "deal_value": row["deal_value"],
                    "notes": notes,
                }).eq("id", existing_id).execute()
                updated += 1
            else:
                note_bits.append(f"Deal value refreshed from rep sheet on {today}")
                notes = " · ".join(note_bits)
                inserted_row = client.table("clients").insert({
                    "name": row["name"],
                    "assigned_to": rep_id,
                    "stage": row["stage"],
                    "deal_value": row["deal_value"],
                    "notes": notes,
                }).execute().data
                # so a second run of this script finds it too, instead of
                # inserting it again
                ref_to_id[row["reference"]] = inserted_row[0]["id"]
                inserted += 1

        print(f"  done: {sum(1 for r in rows if True)} processed")

    print(f"\nTotals: {updated} updated, {inserted} newly inserted "
          f"({won} won / {at_risk} at_risk based on latest month).")


if __name__ == "__main__":
    main()
