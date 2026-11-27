-- Migration 054 — Odoo purchase upload. Run on a replica after test_046 / 047 / 048
-- (their accounts), then 054. Synthetic rows only: the real Odoo files are not
-- kept in the repository.
\set ON_ERROR_STOP 1
\i sql/migrations/054_purchase_odoo_upload.sql

create or replace function pg_temp.ok(cond boolean, label text) returns void language plpgsql as $$
begin if coalesce(cond, false) then raise notice 'PASS %', label; else raise exception 'FAIL %', label; end if; end $$;
create or replace function pg_temp.as_user(uid text) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'aal', 'aal2')::text, false) $$;

do $$
declare r jsonb; v_file jsonb; v_ratio jsonb; v_board jsonb; n int;
begin
  -- dates read from the text
  perform pg_temp.ok(public.purchase_odoo_text_date('Chicken on 18/11/26') = '2026-11-18', 'on 18/11/26');
  perform pg_temp.ok(public.purchase_odoo_text_date('Chicken On 9/11/26') = '2026-11-09', 'On 9/11/26');
  perform pg_temp.ok(public.purchase_odoo_text_date('Chicken Under Roof #ORNM691100885 on19/11/26') = '2026-11-19', 'on19/11/26');
  perform pg_temp.ok(public.purchase_odoo_text_date('Maintenance (QT202608030005) 05/08/26') = '2026-08-05', 'date after a reference number');
  perform pg_temp.ok(public.purchase_odoo_text_date('Plastic jar (2029652) 11/06/2026') = '2026-06-11', 'four-digit year');
  perform pg_temp.ok(public.purchase_odoo_text_date('Glass jar/ T20-2606-0338') is null, 'no date');
  perform pg_temp.ok(public.purchase_odoo_text_date('Chicken on 31/02/26') is null, 'impossible date → none');
  perform pg_temp.ok(public.purchase_odoo_po_month('PO26110048') = '2026-11-01', 'PO month');

  v_file := jsonb_build_object('company', 'Prosun Farm', 'file_name', 'Pivot_Purchase_Analysis_Prosun_Farm.xlsx',
    'file', jsonb_build_object('saleable', 120700, 'other', 18000),
    'rows', jsonb_build_array(
      jsonb_build_object('po', 'PO26110038', 'grp', 'saleable', 'description', 'Chicken on 18/11/26', 'lines', 2, 'untaxed', 42600, 'total', 42600),
      jsonb_build_object('po', 'PO26110038', 'grp', 'other',    'description', 'Chicken on 18/11/26', 'lines', 1, 'untaxed', 3500, 'total', 3500),
      jsonb_build_object('po', 'PO26110035', 'grp', 'saleable', 'description', 'Chicken on 16/11/26', 'lines', 3, 'untaxed', 70000, 'total', 70000),
      jsonb_build_object('po', 'PO26110024', 'grp', 'saleable', 'description', 'Turkey #0001 on 28/09/26', 'lines', 2, 'untaxed', 8100, 'total', 8100),
      jsonb_build_object('po', 'PO26110048', 'grp', 'other',    'description', 'foam box #69/141  on 23/11/26', 'lines', 5, 'untaxed', 14500, 'total', 14500)));

  -- Jane: refused
  perform pg_temp.as_user('00000000-0000-0000-0000-0000000046c1');
  begin
    perform public.purchase_odoo_import(v_file);
    raise exception 'FAIL Jane uploaded';
  exception when insufficient_privilege then perform pg_temp.ok(true, 'sale support cannot upload'); end;

  -- Orawan: dry run
  perform pg_temp.as_user('00000000-0000-0000-0000-0000000046b1');
  r := public.purchase_odoo_import(v_file || '{"dry_run": true}');
  perform pg_temp.ok((r->>'dry_run')::boolean and (r->>'new')::int = 5 and (select count(*) from public.purchase_odoo_lines) = 0, 'dry run: 5 new rows, nothing written');
  perform pg_temp.ok((r->>'complete')::boolean, 'rows add up to the file totals: complete');
  perform pg_temp.ok((select x->>'state' from jsonb_array_elements(r->'pos') x where x->>'po' = 'PO26110024') = 'far_date', 'Turkey: date far from the PO month → waits');
  perform pg_temp.ok((select x->>'state' from jsonb_array_elements(r->'pos') x where x->>'po' = 'PO26110048') = 'not_counted', 'foam boxes: not counted (packaging)');
  perform pg_temp.ok((select (x->>'arrival_day')::date from jsonb_array_elements(r->'pos') x where x->>'po' = 'PO26110038') = '2026-11-20'
                     and (select (x->>'freight')::numeric from jsonb_array_elements(r->'pos') x where x->>'po' = 'PO26110038') = 3500,
                     'chicken PO: ordered 18/11 → arrives 20/11, freight 3,500');

  -- real upload
  r := public.purchase_odoo_import(v_file);
  perform pg_temp.ok((select count(*) from public.purchase_odoo_lines) = 5 and (select count(*) from public.purchase_odoo_uploads) = 1, 'upload stored');
  perform pg_temp.ok((select goods from public.purchase_odoo_costs where po_number = 'PO26110038') = 42600
                     and (select counted from public.purchase_odoo_costs where po_number = 'PO26110038'), 'PO26110038 counted: goods 42,600');
  perform pg_temp.ok((select needs_date from public.purchase_odoo_costs where po_number = 'PO26110024'), 'Turkey waits for a date');

  -- next day: same POs (one amount changed) + one new, one missing
  r := public.purchase_odoo_import(jsonb_build_object('company', 'Prosun Farm', 'file', jsonb_build_object('saleable', 200000, 'other', 3500),
    'rows', jsonb_build_array(
      jsonb_build_object('po', 'PO26110038', 'grp', 'saleable', 'description', 'Chicken on 18/11/26', 'lines', 2, 'untaxed', 43000),
      jsonb_build_object('po', 'PO26110038', 'grp', 'other',    'description', 'Chicken on 18/11/26', 'lines', 1, 'untaxed', 3500),
      jsonb_build_object('po', 'PO26110035', 'grp', 'saleable', 'description', 'Chicken on 16/11/26', 'lines', 3, 'untaxed', 70000),
      jsonb_build_object('po', 'PO26110050', 'grp', 'saleable', 'description', 'Chicken on 21/11/26', 'lines', 1, 'untaxed', 20000))));
  perform pg_temp.ok((r->>'new')::int = 1 and (r->>'changed')::int = 1 and (r->>'unchanged')::int = 2, 'second upload: 1 new, 1 changed, 2 unchanged');
  perform pg_temp.ok(not (r->>'complete')::boolean, 'rows do not add up to the totals: incomplete');
  perform pg_temp.ok((select count(*) from public.purchase_odoo_lines where po_number = 'PO26110038') = 2
                     and (select goods from public.purchase_odoo_costs where po_number = 'PO26110038') = 43000, 'no double count, amount updated');
  perform pg_temp.ok((select missing_in_latest from public.purchase_odoo_costs where po_number = 'PO26110048'), 'foam boxes: not in the latest file');

  -- Turkey: the purchasing team sets its arrival
  perform public.purchase_odoo_set_dates('Prosun Farm', 'PO26110024', '2026-09-28', '2026-12-15', 'Christmas turkeys');
  perform pg_temp.ok((select counted from public.purchase_odoo_costs where po_number = 'PO26110024')
                     and (select arrival_day from public.purchase_odoo_costs where po_number = 'PO26110024') = '2026-12-15', 'Turkey counted on 15 Dec');
  begin
    perform public.purchase_odoo_set_dates('Prosun Farm', 'PO26110024', '2026-12-20', '2026-12-15');
    raise exception 'FAIL arrival before order';
  exception when sqlstate '22023' then perform pg_temp.ok(true, 'arrival before order refused'); end;
  begin
    perform public.purchase_odoo_set_dates('Prosun Farm', 'PO99999999', null, '2026-12-15');
    raise exception 'FAIL unknown PO';
  exception when sqlstate 'P0002' then perform pg_temp.ok(true, 'unknown PO refused'); end;

  -- the ratio takes its cost from Odoo
  perform pg_temp.as_user('00000000-0000-0000-0000-0000000046a1');
  v_ratio := public.purchase_ratio('2026-11-01', '2026-11-30', 'Prosun Farm');
  perform pg_temp.ok(v_ratio->>'first_purchase' = '2026-11-18', 'first purchase = first Odoo arrival (16 + 2)');
  perform pg_temp.ok((select sum((x->>2)::numeric) from jsonb_array_elements(v_ratio->'purchases') x) = 133000
                     and (select sum((x->>3)::numeric) from jsonb_array_elements(v_ratio->'purchases') x) = 3500,
                     'November cost = 43,000 + 70,000 + 20,000 goods, 3,500 freight (no turkey, no foam boxes)');
  perform pg_temp.ok((v_ratio->'odoo'->>'waiting_count')::int = 0 and jsonb_array_length(v_ratio->'odoo'->'uploads') = 1
                     and not (v_ratio->'odoo'->'uploads'->0->>'complete')::boolean, 'status: last upload incomplete, nothing waiting');

  v_board := public.purchase_odoo_board('2026-11-01', '2026-11-30', 'Prosun Farm');
  perform pg_temp.ok(jsonb_array_length(v_board->'uploads') = 2 and jsonb_array_length(v_board->'pos') = 4, 'board: 2 uploads, 4 POs in November (turkey now in December)');

  -- reading straight from the tables
  perform set_config('role', 'authenticated', true);
  perform pg_temp.as_user('00000000-0000-0000-0000-0000000046c1');
  perform pg_temp.ok((select count(*) from public.purchase_odoo_lines) = 0, 'sale support reads nothing');
  begin
    insert into public.purchase_odoo_lines (company, po_number, grp) values ('Prosun Farm', 'PO26119999', 'saleable');
    raise exception 'FAIL direct insert';
  exception when insufficient_privilege then perform pg_temp.ok(true, 'no direct insert'); end;
  -- 2FA: Clément without the code reads nothing
  perform set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-0000-0000-0000000046a1', 'aal', 'aal1')::text, false);
  perform pg_temp.ok((select count(*) from public.purchase_odoo_lines) = 0, 'admin without the 2FA code reads nothing');
  perform pg_temp.as_user('00000000-0000-0000-0000-0000000046a1');
  perform pg_temp.ok((select count(*) from public.purchase_odoo_lines) = 6, 'admin with the code reads the uploads');
  perform set_config('role', 'postgres', true);
  perform pg_temp.ok((select count(*) from public.activity_log where table_name = 'purchase_odoo_po') >= 1, 'date changes in activity_log');
end $$;
