#!/usr/bin/env python3
"""
One-time import: load the "Customer Data" sheet from your Odoo sales export
into the CRM database.

This is tailored to the exact shape of the export Clément shared (columns:
Activities, City, Company, Complete Name, Country, Email, Phone, Reference,
Salesperson, Salesperson Ref, Partner Contracts/Reference) — it is NOT the
generic import_excel.py script; use this one for that specific file.

What it does:
  - Reads only the "Customer Data" sheet (3,827 rows as of the 30 Aug 2026
    export). The separate "08 - not transferred yet" sheet is a subset of
    the same records (same Reference codes), not additional data, so it's
    intentionally not read separately here.
  - Maps each row's "Salesperson Ref" code to one of the four current CRM
    logins (S02 = Christophe, S12 = James, S13 = Chovie, S14 = Pammy). Any
    row under a different code, or with no salesperson at all, is imported
    with assigned_to left NULL — visible only to the admin account, who can
    view and reassign it from inside the app (the "Assigned to" dropdown on
    any record). This was a deliberate choice: import everything so nothing
    from the Odoo history is lost, but only the four active reps' own
    customers land directly in their personal pipeline.
  - Every imported row starts at stage = "dormant" — these are existing
    customers, not fresh leads, so this keeps them out of the director's
    org-wide "new leads" feed and out of anyone's "won this month" counts
    until a rep actually starts working the account again and moves it to
    an active stage.
  - segment, deal_value, next_action, and next_action_date are left blank —
    the source sheet has no data for these; reps/admin fill them in as they
    start working each account.
  - The original Odoo reference code (and, for unassigned rows, the name of
    whoever handled the account in Odoo) is kept in the notes field so nothing
    is lost and reassignment has context.

Usage (run once, from your own machine — NOT from GitHub Actions — because
it uses the Supabase "service_role" key, which bypasses Row Level Security
entirely. Never commit that key, never paste it anywhere public):

    export SUPABASE_URL="https://YOUR-PROJECT-REF.supabase.co"
    export SUPABASE_SERVICE_ROLE_KEY="..."   # Project Settings > API > service_role
    pip install supabase pandas openpyxl
    python3 scripts/import_odoo_customers.py "path/to/Report Sales 06072026 - All v2.xlsx"
"""

import os
import sys

import pandas as pd
from supabase import create_client

SHEET_NAME = "Customer Data"

# Odoo "Salesperson Ref" code -> the matching CRM login's email.
# Any code not listed here (or a blank salesperson) is imported unassigned.
REP_EMAIL_BY_CODE = {
    "S02": "christophe@klongphaifarm.com",
    "S12": "james@klongphaifarm.com",
    "S13": "chovie@klongphaifarm.com",
    "S14": "pammy@klongphaifarm.com",
}

BATCH_SIZE = 500


def clean(value):
    if value is None or (isinstance(value, float) and pd.isna(value)):
        return None
    # The Odoo export has stray non-breaking spaces (\xa0) inside some Thai
    # company names — normalize to regular spaces so they display cleanly.
    text = " ".join(str(value).replace("\xa0", " ").split())
    return text or None


def main():
    if len(sys.argv) != 2:
        sys.exit(f"Usage: python3 {sys.argv[0]} path/to/file.xlsx")

    url = os.environ.get("SUPABASE_URL")
    key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
    if not url or not key:
        sys.exit("Set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY first.")

    client = create_client(url, key)

    # Build an email -> user id lookup so a matched Salesperson Ref code
    # becomes a real assigned_to uuid.
    users = client.auth.admin.list_users()
    email_to_id = {u.email.lower(): u.id for u in users if u.email}
    for code, email in REP_EMAIL_BY_CODE.items():
        if email.lower() not in email_to_id:
            print(f"  ! Warning: no CRM user found for {email} (code {code}) — "
                  f"those rows will import unassigned instead.")

    df = pd.read_excel(sys.argv[1], sheet_name=SHEET_NAME, header=0)

    rows = []
    skipped = 0
    assigned_counts = {code: 0 for code in REP_EMAIL_BY_CODE}
    unassigned_count = 0

    for _, r in df.iterrows():
        company = clean(r.get("Company"))
        complete_name = clean(r.get("Complete Name"))

        if not company and not complete_name:
            skipped += 1
            continue

        name = company or complete_name
        contact_name = complete_name if (company and complete_name and complete_name != company) else None

        ref_code = clean(r.get("Reference"))
        salesperson_name = clean(r.get("Salesperson"))
        salesperson_ref = clean(r.get("Salesperson Ref"))

        assigned_email = REP_EMAIL_BY_CODE.get(salesperson_ref) if salesperson_ref else None
        assigned_id = email_to_id.get(assigned_email.lower()) if assigned_email else None

        if assigned_id:
            assigned_counts[salesperson_ref] += 1
        else:
            unassigned_count += 1

        note_parts = []
        if ref_code:
            note_parts.append(f"Odoo ref: {ref_code}")
        if not assigned_id and salesperson_name:
            note_parts.append(f"Previously handled by {salesperson_name} in Odoo (not a current CRM user)")

        rows.append({
            "name": name,
            "contact_name": contact_name,
            "phone": clean(r.get("Phone")),
            "email": clean(r.get("Email")),
            "segment": None,
            "delivery_area": clean(r.get("City")),
            "assigned_to": assigned_id,
            "stage": "dormant",
            "deal_value": None,
            "next_action": None,
            "next_action_date": None,
            "notes": " · ".join(note_parts) or None,
        })

    if not rows:
        sys.exit("Nothing to import — check the file and sheet name.")

    print(f"Importing {len(rows)} customer(s) ({skipped} blank row(s) skipped) ...")
    for code, count in assigned_counts.items():
        print(f"  {code} ({REP_EMAIL_BY_CODE[code]}): {count}")
    print(f"  unassigned (admin only, for now): {unassigned_count}")

    for i in range(0, len(rows), BATCH_SIZE):
        batch = rows[i:i + BATCH_SIZE]
        client.table("clients").insert(batch).execute()
        print(f"  inserted {min(i + BATCH_SIZE, len(rows))}/{len(rows)}")

    print("Done.")


if __name__ == "__main__":
    main()
