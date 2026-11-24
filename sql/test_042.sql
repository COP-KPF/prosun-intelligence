-- Migration 042 — delivery board: postponed orders first. Run on a replica
-- after 042 with the 042 seed (psql -f). Dates are relative to today.
\set ON_ERROR_STOP 1
\pset tuples_only on
create or replace function pg_temp.as_user(u text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', u)::text, false); end $$;
create or replace function pg_temp.ok(cond boolean, label text) returns void language plpgsql as $$
begin if coalesce(cond, false) then raise notice 'PASS %', label; else raise exception 'FAIL %', label; end if; end $$;

-- delivery team
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d1'); set role authenticated;
do $$ declare j jsonb; r jsonb; names text; begin
  j := public.delivery_postponed_open();
  perform pg_temp.ok((j->>'can_mark')::boolean and not (j->>'reasons')::boolean, 'delivery: can mark, no reasons');
  select string_agg(x->>'customer_name', ',' order by o) into names from jsonb_array_elements(j->'rows') with ordinality t(x, o);
  perform pg_temp.ok(names = 'Catering C,Bangkok Air Catering,Restaurant B,Gourmet Market,Villa Market,Easy Health,Hotel kitchen A,Restaurant D',
    'order: late (oldest first), today, coming, then waiting production — got ' || names);
  perform pg_temp.ok(not exists (select 1 from jsonb_array_elements(j->'rows') x where x->>'customer_name' in ('Paleo Robbie', 'Old order', 'Not postponed')),
    'delivered, untracked and never-postponed orders are not listed');
  select x into r from jsonb_array_elements(j->'rows') x where x->>'customer_name' = 'Catering C';
  perform pg_temp.ok(r->>'group' = 'late' and (r->>'days_late')::int = 3 and (r->>'can_mark')::boolean and r->>'state' = 'factory', 'late 3 days, at the factory, can be marked');
  select x into r from jsonb_array_elements(j->'rows') x where x->>'customer_name' = 'Restaurant B';
  perform pg_temp.ok(r->>'group' = 'late' and r->>'state' = 'problem' and r->>'mark_note' = 'Client closed', 'problem kept with its note');
  select x into r from jsonb_array_elements(j->'rows') x where x->>'customer_name' = 'Gourmet Market';
  perform pg_temp.ok(r->>'group' = 'today' and (r->>'part')::int = 2, 'part 2 due today');
  select x into r from jsonb_array_elements(j->'rows') x where x->>'customer_name' = 'Easy Health';
  perform pg_temp.ok(r->>'group' = 'coming' and r->>'source' = 'middle', 'coming, postponed by the middle office');
  select x into r from jsonb_array_elements(j->'rows') x where x->>'customer_name' = 'Hotel kitchen A';
  perform pg_temp.ok(r->>'group' = 'waiting' and not (r->>'can_mark')::boolean, 'waiting production: no buttons');
  select x into r from jsonb_array_elements(j->'rows') x where x->>'customer_name' = 'Restaurant D';
  perform pg_temp.ok(r->>'group' = 'waiting' and r->>'paper_id' is null and not (r->>'can_mark')::boolean, 'register entry without paper: waiting, no buttons');
  perform pg_temp.ok(not exists (select 1 from jsonb_array_elements(j->'rows') x where x->>'reason' is not null), 'no reason sent to the delivery team');
  perform pg_temp.ok((j->>'delivered_today')::int = 1, 'delivered today: 1');
  -- marking Delivered takes it off the list
  perform public.delivery_mark('42000000-0000-0000-0000-00000000000a', 'delivered', null);
  j := public.delivery_postponed_open();
  perform pg_temp.ok(not exists (select 1 from jsonb_array_elements(j->'rows') x where x->>'customer_name' = 'Catering C')
                     and (j->>'delivered_today')::int = 2, 'Delivered: off the list, delivered today 2');
  perform public.delivery_mark('42000000-0000-0000-0000-00000000000b', 'out', null);
  j := public.delivery_postponed_open();
  perform pg_temp.ok((select x->>'state' from jsonb_array_elements(j->'rows') x where x->>'customer_name' = 'Bangkok Air Catering') = 'out', 'On road: state follows');
end $$;
reset role;

-- middle office: read-only, with reasons
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b1'); set role authenticated;
do $$ declare j jsonb; begin
  j := public.delivery_postponed_open();
  perform pg_temp.ok(not (j->>'can_mark')::boolean and (j->>'reasons')::boolean, 'middle office: read-only, sees reasons');
  perform pg_temp.ok((select x->>'reason' from jsonb_array_elements(j->'rows') x where x->>'customer_name' = 'Easy Health') = 'client', 'reason shown to the middle office');
end $$;
reset role;

-- company director: his company only
select pg_temp.as_user('00000000-0000-0000-0000-0000000000e9'); set role authenticated;
do $$ declare j jsonb; begin
  j := public.delivery_postponed_open();
  perform pg_temp.ok(not (j->>'can_mark')::boolean
    and not exists (select 1 from jsonb_array_elements(j->'rows') x where x->>'company' <> 'Prosun Food')
    and jsonb_array_length(j->'rows') = 3, 'company director: Prosun Food only, read-only');
end $$;
reset role;

-- others: refused
select pg_temp.as_user('00000000-0000-0000-0000-0000000000c1'); set role authenticated;
do $$ begin
  begin perform public.delivery_postponed_open(); raise exception 'FAIL accounting';
  exception when insufficient_privilege then perform pg_temp.ok(true, 'accounting: not allowed'); end;
end $$;
reset role;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000f1'); set role authenticated;
do $$ begin
  begin perform public.delivery_postponed_open(); raise exception 'FAIL production';
  exception when insufficient_privilege then perform pg_temp.ok(true, 'production: not allowed'); end;
end $$;
reset role;
set role anon;
do $$ begin
  begin perform public.delivery_postponed_open(); raise exception 'FAIL anon';
  exception when insufficient_privilege then perform pg_temp.ok(true, 'not signed in: no access'); end;
end $$;
reset role;
