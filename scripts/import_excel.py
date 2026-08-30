#!/usr/bin/env python3
"""
One-time import: load your existing client list into the new CRM database.

This is meant to run ONCE, by you, from your own machine — not from GitHub
Actions — because it uses the Supabase "service_role" key, which bypasses
Row Level Security entirely. That key must never be committed to the repo or
put in a GitHub secret used by a workflow that anyone else can trigger.
Keep it only in your own terminal session:

    export SUPABASE_URL="https://YOUR-PROJECT-REF.supabase.co"
    export SUPABASE_SERVICE_ROLE_KEY="..."   # Project Settings > API > service_role
    pip install supabase pandas openpyxl
    python3 scripts/import_excel.py path/to/your_client_list.xlsx

Expected input columns (rename your sheet's headers to match, or edit the
COLUMN_MAP below instead of touching your source file):
    name, contact_name, phone, email, segment, delivery_area,
    assigned_to_email, stage, deal_value, next_action, next_action_date, notes

"segment" must be one of: Restaurant, Individual, Retail, Department Store
"stage" must be one of: lead, qualified, proposal, won, at_risk, dormant, lost
  (leave blank and it defaults to "lead")
"assigned_to_email" should be the email address of the sales rep's CRM login
  — the script looks up their user id from that. Leave blank for now and
  assign clients from inside the app later if you're not ready to map reps yet.
"""

import os
import sys

import pandas as pd
from supabase import create_client

# If your spreadsheet uses different header names, map them here:
# spreadsheet column -> database column
COLUMN_MAP = {
    "name": "name",
    "contact_name": "contact_name",
    "phone": "phone",
    "email": "email",
    "segment": "segment",
    "delivery_area": "delivery_area",
    "assigned_to_email": "assigned_to_email",  # resolved to a UUID below, not stored as-is
    "stage": "stage",
    "deal_value": "deal_value",
    "next_action": "next_action",
    "next_action_date": "next_action_date",
    "notes": "notes",
}


def main():
    if len(sys.argv) != 2:
        sys.exit("Usage: python3 scripts/import_excel.py path/to/file.xlsx")

    url = os.environ.get("SUPABASE_URL")
    key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
    if not url or not key:
        sys.exit("Set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY first.")

    client = create_client(url, key)

    df = pd.read_excel(sys.argv[1])
    df = df.rename(columns=COLUMN_MAP)

    # Build an email -> user id lookup so "assigned_to_email" in the sheet
    # becomes a real assigned_to uuid in the database.
    profiles = client.table("profiles").select("id, full_name").execute().data
    # profiles doesn't store email directly; pull it from auth via admin API instead.
    users = client.auth.admin.list_users()
    email_to_id = {u.email.lower(): u.id for u in users if u.email}

    rows = []
    skipped = 0
    for _, r in df.iterrows():
        if pd.isna(r.get("name")):
            skipped += 1
            continue

        assigned_email = str(r.get("assigned_to_email", "") or "").strip().lower()
        assigned_id = email_to_id.get(assigned_email) if assigned_email else None
        if assigned_email and not assigned_id:
            print(f"  ! No CRM user found for '{assigned_email}' (client: {r.get('name')}) — leaving unassigned")

        rows.append({
            "name": str(r.get("name")).strip(),
            "contact_name": clean(r.get("contact_name")),
            "phone": clean(r.get("phone")),
            "email": clean(r.get("email")),
            "segment": clean(r.get("segment")) or None,
            "delivery_area": clean(r.get("delivery_area")),
            "assigned_to": assigned_id,
            "stage": clean(r.get("stage")) or "lead",
            "deal_value": r.get("deal_value") if not pd.isna(r.get("deal_value", None)) else None,
            "next_action": clean(r.get("next_action")),
            "next_action_date": clean(r.get("next_action_date")),
            "notes": clean(r.get("notes")),
        })

    if not rows:
        sys.exit("Nothing to import — check the input file and COLUMN_MAP.")

    print(f"Importing {len(rows)} client(s) ({skipped} row(s) skipped for missing name) ...")
    client.table("clients").insert(rows).execute()
    print("Done.")


def clean(value):
    if value is None or (isinstance(value, float) and pd.isna(value)):
        return None
    text = str(value).strip()
    return text or None


if __name__ == "__main__":
    main()
