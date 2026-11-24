-- Migration 043 — Special care clients. Run on a replica after 043 (psql -f).
\set ON_ERROR_STOP 1
\pset tuples_only on
insert into auth.users (id, email) values
 ('00000000-0000-0000-0000-0000000000a1','admin@x'),('00000000-0000-0000-0000-0000000000a2','jum@x'),
 ('00000000-0000-0000-0000-0000000000b1','ss@x'),('00000000-0000-0000-0000-0000000000c1','acc@x'),
 ('00000000-0000-0000-0000-0000000000f1','prod@x'),('00000000-0000-0000-0000-0000000000d1','nick@x'),
 ('00000000-0000-0000-0000-000000000012','james@x'),('00000000-0000-0000-0000-000000000002','christophe@x')
on conflict do nothing;
insert into public.profiles (id, full_name, role) values
 ('00000000-0000-0000-0000-0000000000a1','Clément','admin'),
 ('00000000-0000-0000-0000-0000000000a2','Jum','admin'),
 ('00000000-0000-0000-0000-0000000000b1','Ploy','sale_support'),
 ('00000000-0000-0000-0000-0000000000c1','Ann','accounting'),
 ('00000000-0000-0000-0000-0000000000f1','Muay','production'),
 ('00000000-0000-0000-0000-0000000000d1','Nick','delivery'),
 ('00000000-0000-0000-0000-000000000012','James','sales'),
 ('00000000-0000-0000-0000-000000000002','Christophe','director')
on conflict (id) do update set role = excluded.role, full_name = excluded.full_name;
update public.sales_reps set profile_id = '00000000-0000-0000-0000-000000000012' where code = '12';
update public.sales_reps set profile_id = '00000000-0000-0000-0000-000000000002' where code = '02';

insert into public.sales_customers (code, name, portfolio, salesperson_code) values
 ('CR010', 'Ledu', 'rep', '12'), ('CH143', 'Yona Beach', 'house', null), ('CB005', 'Accidental Butcher', 'rep', '13')
on conflict (code) do update set name = excluded.name, portfolio = excluded.portfolio, salesperson_code = excluded.salesperson_code;
insert into public.sales_customer_names (code, name) values
 ('CR010', 'Ledu'), ('CH143', 'Yona Beach'), ('CB005', 'Accidental Butcher') on conflict do nothing;

create or replace function pg_temp.as_user(u text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', u)::text, false); end $$;
create or replace function pg_temp.ok(cond boolean, label text) returns void language plpgsql as $$
begin if coalesce(cond, false) then raise notice 'PASS %', label; else raise exception 'FAIL %', label; end if; end $$;
create or replace function pg_temp.fails(sql text, pattern text, label text) returns void language plpgsql as $$
begin
  begin execute sql; exception when others then
    if sqlerrm ~* pattern then raise notice 'PASS %', label; return; end if;
    raise exception 'FAIL % (wrong error: %)', label, sqlerrm;
  end;
  raise exception 'FAIL % (no error)', label;
end $$;

insert into public.weighing_papers (id, work_date, photo_path, status, company, po_number, customer_name, delivery_date) values
 ('42000000-0000-0000-0000-00000000000a', '2026-11-24', 'a.jpg', 'read', 'Prosun Farm', 'PO-L', 'Ledu (CR010)', '2026-11-24'),
 ('42000000-0000-0000-0000-00000000000b', '2026-11-24', 'b.jpg', 'read', 'Prosun Farm', 'PO-Y', 'Yona Beach', '2026-11-24'),
 ('42000000-0000-0000-0000-00000000000c', '2026-11-24', 'c.jpg', 'read', 'Prosun Food', 'PO-O', 'Other client', '2026-11-24'),
 ('42000000-0000-0000-0000-00000000000d', '2026-11-24', 'd.jpg', 'read', 'Prosun Farm', 'PO-A', 'Accidental Butcher', '2026-11-24');

-- who may set
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f1');
select pg_temp.fails($$select public.special_care_set('CR010', true, false, false, null, 'x')$$, 'admin only', 'production cannot flag a client');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b1');
select pg_temp.fails($$select public.special_care_set('CR010', true, false, false, null, 'x')$$, 'admin only', 'middle office cannot flag a client');
select pg_temp.fails($$select public.special_care_search('Led')$$, 'admin only', 'search is admin only');
select pg_temp.as_user('00000000-0000-0000-0000-000000000002');
select pg_temp.fails($$select public.special_care_remove('CR010')$$, 'admin only', 'sales director cannot remove a flag');

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
select pg_temp.fails($$select public.special_care_set('CR010', false, false, false, null, '  ')$$, 'at least one rule', 'a flag with no rule and no text is refused');
select pg_temp.fails($$select public.special_care_set('ZZ999', true, false, false, null, null)$$, 'unknown client', 'unknown code refused');
do $$ begin
  perform pg_temp.ok(jsonb_array_length(public.special_care_search('led')) >= 1, 'admin finds Ledu by name');
  perform pg_temp.ok((public.special_care_search('CR010')->0->>'code') = 'CR010', 'admin finds by code, exact code first');
  perform public.special_care_set('cr010', true, false, true, 'before 10:00', 'Check every breast for blood vessels. Chef Pop signs.');
  perform public.special_care_set('CH143', false, true, false, null, null);
  perform pg_temp.ok((public.special_care_search('CR010')->0->>'flagged')::boolean, 'search shows the client is already flagged');
  perform pg_temp.ok(jsonb_array_length(public.special_care_list()) = 2, 'admin lists 2 special care clients');
  perform pg_temp.ok((select (x->>'paper_names') like '%Ledu%' from jsonb_array_elements(public.special_care_list()) x where x->>'code' = 'CR010'),
                     'admin sees the paper names linked to the code');
  perform pg_temp.ok((select x->>'delivery_window' from jsonb_array_elements(public.special_care_list()) x where x->>'code' = 'CR010') = 'before 10:00',
                     'delivery window kept');
end $$;

-- who may read
do $$ begin
  perform pg_temp.as_user('00000000-0000-0000-0000-0000000000f1');
  perform pg_temp.ok(jsonb_array_length(public.special_care_list()) = 2, 'production sees both flags');
  perform pg_temp.ok(public.special_care_list()->0->'paper_names' is null, 'non-admin gets no paper names');
  perform pg_temp.as_user('00000000-0000-0000-0000-0000000000d1');
  perform pg_temp.ok(jsonb_array_length(public.special_care_list()) = 2, 'delivery sees both flags');
  perform pg_temp.as_user('00000000-0000-0000-0000-0000000000c1');
  perform pg_temp.ok(jsonb_array_length(public.special_care_list()) = 2, 'accounting sees both flags');
  perform pg_temp.as_user('00000000-0000-0000-0000-000000000012');
  perform pg_temp.ok(jsonb_array_length(public.special_care_list()) = 1 and public.special_care_list()->0->>'code' = 'CR010',
                     'salesperson sees only the flag of his own client (not the House one)');
  perform pg_temp.as_user('00000000-0000-0000-0000-000000000002');
  perform pg_temp.ok(jsonb_array_length(public.special_care_list()) = 2, 'sales director sees both flags');
end $$;

-- matching papers and names
do $$ declare m jsonb; begin
  perform pg_temp.as_user('00000000-0000-0000-0000-0000000000d1');
  m := public.special_care_match(array['42000000-0000-0000-0000-00000000000a','42000000-0000-0000-0000-00000000000b',
                                       '42000000-0000-0000-0000-00000000000c','42000000-0000-0000-0000-00000000000d']::uuid[],
                                 array['Yona Beach', 'Nobody', 'LEDU']);
  perform pg_temp.ok(m->'papers'->>'42000000-0000-0000-0000-00000000000a' = 'CR010', '"Ledu (CR010)" paper matched to CR010');
  perform pg_temp.ok(m->'papers'->>'42000000-0000-0000-0000-00000000000b' = 'CH143', 'Yona Beach paper matched');
  perform pg_temp.ok(not (m->'papers' ? '42000000-0000-0000-0000-00000000000c'), 'unflagged client not matched');
  perform pg_temp.ok(not (m->'papers' ? '42000000-0000-0000-0000-00000000000d'), 'known but unflagged client not matched');
  perform pg_temp.ok(m->'names'->>'Yona Beach' = 'CH143' and m->'names'->>'LEDU' = 'CR010' and not (m->'names' ? 'Nobody'), 'names matched');
  perform pg_temp.ok((m->'clients'->'CR010'->>'no_postpone')::boolean and (m->'clients'->'CR010'->>'priority_delivery')::boolean,
                     'client rules returned');
  perform pg_temp.as_user('00000000-0000-0000-0000-000000000012');
  m := public.special_care_match(array['42000000-0000-0000-0000-00000000000b']::uuid[], array['Yona Beach']);
  perform pg_temp.ok(m->'papers' = '{}'::jsonb and m->'names' = '{}'::jsonb, 'salesperson does not get a House client''s flag');
end $$;

-- the tick
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f1');
select pg_temp.fails($$update public.weighing_papers set status = 'confirmed' where id = '42000000-0000-0000-0000-00000000000a'$$,
                     'special_care_check_required', 'flagged paper cannot be confirmed without the tick');
select pg_temp.fails($$select public.special_care_check('42000000-0000-0000-0000-00000000000c', true)$$,
                     'not a special care', 'tick refused on a normal paper');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d1');
select pg_temp.fails($$select public.special_care_check('42000000-0000-0000-0000-00000000000a', true)$$, 'production only', 'delivery cannot tick');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f1');
do $$ declare r jsonb; begin
  r := public.special_care_check('42000000-0000-0000-0000-00000000000a', true);
  perform pg_temp.ok(r->>'by' = 'Muay', 'tick recorded with the name');
  perform public.special_care_check('42000000-0000-0000-0000-00000000000a', false);
  perform pg_temp.ok(not exists (select 1 from public.special_care_checks where paper_id = '42000000-0000-0000-0000-00000000000a'), 'tick can be removed before confirming');
  perform public.special_care_check('42000000-0000-0000-0000-00000000000a', true);
  update public.weighing_papers set status = 'confirmed' where id = '42000000-0000-0000-0000-00000000000a';
  perform pg_temp.ok((select status from public.weighing_papers where id = '42000000-0000-0000-0000-00000000000a') = 'confirmed', 'ticked paper confirms');
  update public.weighing_papers set status = 'confirmed' where id = '42000000-0000-0000-0000-00000000000c';
  perform pg_temp.ok((select status from public.weighing_papers where id = '42000000-0000-0000-0000-00000000000c') = 'confirmed', 'normal paper confirms without a tick');
  update public.weighing_papers set note = 'edit' where id = '42000000-0000-0000-0000-00000000000b';
  perform pg_temp.ok(true, 'other edits on an unticked flagged paper are not blocked');
end $$;
select pg_temp.fails($$select public.special_care_check('42000000-0000-0000-0000-00000000000a', false)$$, 'already confirmed', 'tick cannot be removed once confirmed');
do $$ declare m jsonb; begin
  m := public.special_care_match(array['42000000-0000-0000-0000-00000000000a']::uuid[], '{}');
  perform pg_temp.ok(m->'checks'->'42000000-0000-0000-0000-00000000000a'->>'by' = 'Muay', 'match returns who ticked');
  -- reopen + confirm again: the tick stays
  update public.weighing_papers set status = 'read' where id = '42000000-0000-0000-0000-00000000000a';
  update public.weighing_papers set status = 'confirmed' where id = '42000000-0000-0000-0000-00000000000a';
  perform pg_temp.ok(true, 'reopened paper confirms again with its tick');
end $$;

-- part 2 delivered later inherits the tick; part 2 back to production does not
insert into public.weighing_papers (id, work_date, photo_path, status, company, po_number, customer_name, delivery_date, split_from, split_part) values
 ('42000000-0000-0000-0000-0000000000a2', '2026-11-25', 'a.jpg', 'confirmed', 'Prosun Farm', 'PO-L', 'Ledu (CR010)', '2026-11-25', '42000000-0000-0000-0000-00000000000a', 2),
 ('42000000-0000-0000-0000-0000000000a3', '2026-11-26', 'a.jpg', 'postponed', 'Prosun Farm', 'PO-L', 'Ledu (CR010)', '2026-11-26', '42000000-0000-0000-0000-00000000000a', 3);
do $$ begin
  perform pg_temp.ok(exists (select 1 from public.special_care_checks where paper_id = '42000000-0000-0000-0000-0000000000a2'), 'part 2 delivered later carries the tick');
  perform pg_temp.ok(not exists (select 1 from public.special_care_checks where paper_id = '42000000-0000-0000-0000-0000000000a3'), 'part back to production needs a new tick');
end $$;
select pg_temp.fails($$update public.weighing_papers set status = 'confirmed' where id = '42000000-0000-0000-0000-0000000000a3'$$,
                     'special_care_check_required', 'part back to production cannot be confirmed without its own tick');

-- bells
do $$ declare n0 int; n1 int; begin
  perform pg_temp.as_user('00000000-0000-0000-0000-0000000000b1');
  select count(*) into n0 from public.notifications where kind = 'special_care_postponed';
  insert into public.order_postponements (created_by, customer_name, po_number, company, original_date, new_date, reason)
  values ('00000000-0000-0000-0000-0000000000b1', 'Ledu', 'PO-L9', 'Prosun Farm', '2026-11-24', '2026-11-25', 'client');
  select count(*) into n1 from public.notifications where kind = 'special_care_postponed';
  perform pg_temp.ok(n1 - n0 = 2, 'No postpone client postponed in the register → bell to both admins');
  perform pg_temp.ok((select title from public.notifications where kind = 'special_care_postponed' order by created_at desc limit 1) like '%Special care client postponed%PO-L9%',
                     'bell title names the order');
  perform pg_temp.ok((select body from public.notifications where kind = 'special_care_postponed' order by created_at desc limit 1) like '%No postpone%',
                     'bell body names the rules');
  insert into public.order_postponements (created_by, customer_name, po_number, company, original_date, new_date, reason)
  values ('00000000-0000-0000-0000-0000000000b1', 'Other client', 'PO-O9', 'Prosun Food', '2026-11-24', '2026-11-25', 'client');
  perform pg_temp.ok((select count(*) from public.notifications where kind = 'special_care_postponed') = n1, 'normal client → no special care bell');
  -- Exact quantity client (Yona): whole-order move → no bell; one product moved → bell
  insert into public.weighing_postponements (created_by, paper_id, customer_name, po_number, company, from_work_date, to_work_date,
      from_delivery_date, to_delivery_date, reason, stage)
  values ('00000000-0000-0000-0000-0000000000b1', '42000000-0000-0000-0000-00000000000b', 'Yona Beach', 'PO-Y', 'Prosun Farm',
          '2026-11-24', '2026-11-25', '2026-11-24', '2026-11-25', 'production', 'production');
  perform pg_temp.ok((select count(*) from public.notifications where kind = 'special_care_postponed') = n1, 'Exact quantity only: whole order postponed → no special care bell');
  insert into public.weighing_postponements (created_by, paper_id, customer_name, po_number, company, from_work_date, to_work_date,
      from_delivery_date, to_delivery_date, reason, stage, split_mode)
  values ('00000000-0000-0000-0000-0000000000b1', '42000000-0000-0000-0000-00000000000b', 'Yona Beach', 'PO-Y', 'Prosun Farm',
          '2026-11-24', '2026-11-26', '2026-11-24', '2026-11-26', 'raw_material', 'production', 'production');
  perform pg_temp.ok((select count(*) from public.notifications where kind = 'special_care_postponed') = n1 + 2, 'Exact quantity: one product moved → bell');
end $$;

-- remove
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1');
do $$ begin
  perform public.special_care_remove('CR010');
  perform pg_temp.ok(jsonb_array_length(public.special_care_list()) = 1, 'removed flag no longer listed');
  perform pg_temp.ok((select removed_by from public.client_special_care where code = 'CR010') = '00000000-0000-0000-0000-0000000000a1', 'removal recorded');
  update public.weighing_papers set status = 'confirmed' where id = '42000000-0000-0000-0000-0000000000a3';
  perform pg_temp.ok(true, 'after removal a paper confirms without a tick');
  perform public.special_care_set('CR010', true, false, false, null, null);
  perform pg_temp.ok((select active and removed_at is null from public.client_special_care where code = 'CR010'), 'flag can be set again');
end $$;

-- grants: nothing readable directly
set role authenticated;
select pg_temp.fails($$select * from public.client_special_care$$, 'permission denied', 'table not readable directly');
select pg_temp.fails($$insert into public.special_care_checks (paper_id) values ('42000000-0000-0000-0000-00000000000b')$$, 'permission denied', 'tick not writable directly');
reset role;
\echo done
