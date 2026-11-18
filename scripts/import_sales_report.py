#!/usr/bin/env python3
"""
Sales report (.xlsx) -> SQL for PACE › Sales (Migration 037).

    python scripts/import_sales_report.py "Sales report (09-2026) - All.xlsx" sql/migrations/038_sales_report_09_2026

writes 038_sales_report_09_2026_01.sql, _02.sql … (each small enough for the
Supabase SQL editor). Run them in order in the SQL editor. It calls
public.sales_import(data, source): customers are updated (a client moved by
hand in PACE keeps its salesperson), the months the report covers are
replaced whole, invoices are added or updated by number.

What it reads
  * One sheet per salesperson, named by the code: "02", "12", "13", "14".
    Row 1: "Code Sale (12) James CUSTOMERS 09/2026". Row 2: month-end dates,
    one every 3 columns from E. Row 3: FARM / FOOD / Total. From row 4:
    A area (BKK / UPCOUNTRY), B zone, C name (with notes after "*"), D code.
    "Total amount … Zone" rows have no code and are skipped.
  * "Customer Data": the Odoo customer list (Reference, Complete Name,
    Salesperson Ref …).
  * The sheet starting with "08-Not transferred": K. Pom's clients not yet
    transferred -> portfolio not_transferred.
  * "FA-Odoo" (Prosun Farm) and "FO-Odoo" (Prosun Food): the month's invoices.
Everything else is a House client (admin and sales director only).
"""
import datetime as dt
import json
import re
import sys

import openpyxl

REP_SHEET = re.compile(r"^\d{2}$")
CODE = re.compile(r"^[A-Z]{2}\d{3,4}$")


def clean(v):
    if v is None:
        return None
    s = str(v).replace("\xa0", " ")
    s = re.sub(r"\s+", " ", s).strip()
    return s or None


def split_name(raw):
    """'Pullman G.    *09/25 Come from 12' -> ('Pullman G.', '*09/25 Come from 12')."""
    raw = clean(raw)
    if not raw:
        return None, None
    name, notes = raw, None
    star = raw.find("*")
    if star > 0:
        name, notes = raw[:star].strip(), raw[star:].strip()
    m = re.search(r"\s\d{1,2}/\d{1,2}(/\d{2,4})?\b.*$", name)   # "Le Cordon Bleu 30/1/26 14 to 12"
    if m:
        notes = (m.group(0).strip() + (" " + notes if notes else "")).strip()
        name = name[: m.start()].strip()
    return name or raw, notes


def zone_name(z):
    z = clean(z)
    if not z:
        return None
    return "Bangkok" if z.upper() == "BKK" else z.title()


def month_start(d):
    return dt.date(d.year, d.month, 1)


def rows_of(ws, start, stop_after_blank=2000):
    blank = 0
    for i, r in enumerate(ws.iter_rows(values_only=True)):
        if i < start:
            continue
        if not any(c not in (None, "") for c in r):
            blank += 1
            if blank > stop_after_blank:
                break
            continue
        blank = 0
        yield r


def main(path, out_prefix):
    wb = openpyxl.load_workbook(path, read_only=True, data_only=True)
    customers, monthly, months, invoices = {}, [], set(), []
    title = None

    # 1. Salesperson sheets
    for ws in wb.worksheets:
        if not REP_SHEET.match(ws.title.strip()):
            continue
        code = ws.title.strip()
        head = list(ws.iter_rows(min_row=1, max_row=3, values_only=True))
        title = title or clean(head[0][2])
        blocks = [(i, c) for i, c in enumerate(head[1]) if isinstance(c, (dt.datetime, dt.date))]
        for i, d in blocks:
            if [clean(x) for x in head[2][i:i + 2]] != ["FARM", "FOOD"]:
                raise SystemExit(f"sheet {code}: expected FARM / FOOD under {d:%Y-%m}")
            months.add(month_start(d))
        for r in rows_of(ws, 3, 50):
            c = clean(r[3])
            if not c or not CODE.match(c.upper()):
                continue
            c = c.upper()
            name, notes = split_name(r[2])
            customers[c] = {
                "code": c, "name": name, "report_name": clean(r[2]), "notes": notes,
                "area": clean(r[0]).upper() if clean(r[0]) else None, "zone": zone_name(r[1]),
                "portfolio": "rep", "salesperson": code,
            }
            for i, d in blocks:
                for off, company in ((0, "Prosun Farm"), (1, "Prosun Food")):
                    v = r[i + off] if i + off < len(r) else None
                    if isinstance(v, (int, float)) and abs(v) > 0.004:
                        monthly.append({"code": c, "month": month_start(d).isoformat(),
                                        "company": company, "amount": round(float(v), 2)})

    # 2. Odoo customer list
    for name in wb.sheetnames:
        if name.strip().lower() != "customer data":
            continue
        for r in rows_of(wb[name], 1):
            c = clean(r[7])
            if not c:
                continue
            c = c.upper()
            cur = customers.setdefault(c, {"code": c, "portfolio": "house"})
            cur.update({"odoo_name": clean(r[3]), "city": clean(r[1]), "phone": clean(r[6]),
                        "email": clean(r[5]), "odoo_salesperson": clean(r[9])})
            cur.setdefault("name", clean(r[3]))

    # 3. Not transferred yet (K. Pom)
    for name in wb.sheetnames:
        if not name.strip().startswith("08"):
            continue
        for r in rows_of(wb[name], 2, 200):
            c = clean(r[7]) if len(r) > 7 else None
            if not c or not CODE.match(c.upper()):
                continue
            c = c.upper()
            cur = customers.setdefault(c, {"code": c, "name": clean(r[3])})
            cur.setdefault("odoo_name", clean(r[3]))
            cur.setdefault("odoo_salesperson", clean(r[9]))
            if cur.get("portfolio") != "rep":
                cur["portfolio"] = "not_transferred"
                if len(r) > 10 and clean(r[10]):
                    cur["notes"] = clean(r[10])

    # 4. Invoices
    for name, company in (("FA-Odoo", "Prosun Farm"), ("FO-Odoo", "Prosun Food")):
        if name not in wb.sheetnames:
            continue
        for r in rows_of(wb[name], 1):
            number, d = clean(r[3]), r[2]
            if not number or not isinstance(d, (dt.datetime, dt.date)):
                continue
            c = (clean(r[11]) or "").upper() or None
            if c and c not in customers:
                customers[c] = {"code": c, "name": clean(r[1]), "odoo_name": clean(r[1]), "portfolio": "house"}
            invoices.append({
                "company": company, "number": number, "code": c, "partner_name": clean(r[1]),
                "date": d.date().isoformat() if isinstance(d, dt.datetime) else d.isoformat(),
                "untaxed": r[10], "total": r[9], "odoo_salesperson": clean(r[7]), "payment_status": clean(r[8]),
            })

    for c in customers.values():
        c.setdefault("portfolio", "house")
        if not c.get("name"):
            c["name"] = c.get("odoo_name") or c["code"]

    m = re.search(r"\d{2}/\d{4}", title or "")
    source = "Sales report " + m.group(0) if m else "Sales report"
    strip = lambda d: {k: v for k, v in d.items() if v not in (None, "")}
    custs = [strip(c) for c in sorted(customers.values(), key=lambda x: x["code"])]
    invs = [strip(i) for i in invoices]
    if any("$sales$" in json.dumps(x, ensure_ascii=False) for x in (custs, monthly, invs)):
        raise SystemExit("unexpected text in the workbook")

    # The Supabase SQL editor refuses large queries: one file per ~MAX bytes.
    # Customers first (invoices and months refer to them), then the months
    # (each file holds whole months, since a file replaces the months it lists),
    # then the invoices.
    MAX = 120_000   # bytes (UTF-8): Thai names take 3 bytes a letter
    parts = []
    def chunk(items, key):
        cur, size = [], 0
        for it in items:
            n = len(json.dumps(it, ensure_ascii=False).encode("utf-8")) + 1
            if cur and size + n > MAX:
                parts.append({key: cur}); cur, size = [], 0
            cur.append(it); size += n
        if cur:
            parts.append({key: cur})
    chunk(custs, "customers")
    by_month = {}
    for m in monthly:
        by_month.setdefault(m["month"], []).append(m)
    cur, size, cur_months = [], 0, []
    for month in sorted(by_month):
        rows = by_month[month]
        n = len(json.dumps(rows, ensure_ascii=False).encode("utf-8"))
        if cur and size + n > MAX:
            parts.append({"monthly": cur, "months": cur_months}); cur, size, cur_months = [], 0, []
        cur += rows; size += n; cur_months.append(month)
    # months with no figure at all still get replaced (cleared) with the last file
    empty = [m.isoformat() for m in sorted(months) if m.isoformat() not in by_month]
    if cur or empty:
        parts.append({"monthly": cur, "months": cur_months + empty})
    chunk(invs, "invoices")

    by = {}
    for c in customers.values():
        k = c["portfolio"] if c["portfolio"] != "rep" else "rep " + c["salesperson"]
        by[k] = by.get(k, 0) + 1
    source_sql = "'" + source.replace("'", "''") + "'"
    stamp = dt.datetime.now().strftime("%Y-%m-%d %H:%M")
    for i, part in enumerate(parts, 1):
        what = ", ".join(f"{k} {len(v)}" for k, v in part.items() if k != "months")
        payload = json.dumps(part, ensure_ascii=False, separators=(",", ":"), default=str)
        with open(f"{out_prefix}_{i:02d}.sql", "w", encoding="utf-8") as f:
            f.write(f"-- {source}, part {i} of {len(parts)} ({what}). Generated {stamp} by scripts/import_sales_report.py\n")
            if i == 1:
                f.write(f"-- Whole report: customers {len(customers)} ({', '.join(f'{k}: {v}' for k, v in sorted(by.items()))}); "
                        f"monthly rows {len(monthly)} over {len(months)} months; invoices {len(invoices)}\n")
            f.write(f"-- Run the parts in order, after Migration 037. Each part is safe to re-run.\n")
            f.write(f"select public.sales_import($sales${payload}$sales$::jsonb, {source_sql});\n")
        print(f"{out_prefix}_{i:02d}.sql  {what}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    main(sys.argv[1], sys.argv[2])
