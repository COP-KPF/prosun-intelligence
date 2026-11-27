-- Migration 053 — Postponed orders: open the working paper. Run on a replica
-- after 053 with the 053 test seed (psql -f). Dates are relative to today.
\set ON_ERROR_STOP 1
\pset tuples_only on
create or replace function pg_temp.as_user(u text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', u, 'aal', 'aal2')::text, false); end $$;
create or replace function pg_temp.ok(cond boolean, label text) returns void language plpgsql as $$
begin if coalesce(cond, false) then raise notice 'PASS %', label; else raise exception 'FAIL %', label; end if; end $$;
create or replace function pg_temp.sees(n text) returns boolean language sql as $$
  select exists (select 1 from storage.objects where bucket_id = 'weighing-photos' and name = n) $$;
create or replace function pg_temp.refused(p uuid) returns boolean language plpgsql as $$
begin perform public.postponed_order_paper(p); return false;
exception when insufficient_privilege then return true; end $$;

-- middle office
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b1'); set role authenticated;
do $$ declare j jsonb; begin
  j := public.postponed_order_paper('42000000-0000-0000-0000-00000000000f');   -- waiting production
  perform pg_temp.ok(j->>'customer_name' = 'Hotel kitchen A' and j->>'status' = 'postponed'
                     and jsonb_array_length(j->'lines') = 1 and (j->>'photo_ok')::boolean
                     and j ? 'customer_po' and j->>'photo_path' = 'f.jpg', 'middle office: postponed paper waiting production, with lines and photo');
  perform pg_temp.ok(pg_temp.sees('f.jpg'), 'middle office: photo of the postponed paper can be opened');
  j := public.postponed_order_paper('42000000-0000-0000-0000-00000000000a');   -- confirmed, late
  perform pg_temp.ok((j->>'photo_ok')::boolean and j->>'confirmed_by_name' is null and (j->'lines'->0->>'actual_kg')::numeric = 10.2, 'middle office: confirmed postponed paper, actual kg');
  j := public.postponed_order_paper('42000000-0000-0000-0000-00000000000c');   -- part 2
  perform pg_temp.ok((j->>'part')::int = 2, 'part 2 paper: part number returned');
  j := public.postponed_order_paper('53000000-0000-0000-0000-000000000002');   -- register order matched by PO, not confirmed
  perform pg_temp.ok(j->>'po_number' = 'RD-3317' and (j->>'photo_ok')::boolean and pg_temp.sees('rd.jpg'), 'register order matched by PO: paper and photo open');
  perform pg_temp.ok(pg_temp.refused('53000000-0000-0000-0000-000000000001'), 'paper never postponed: not on the list, refused');
  perform pg_temp.ok(not pg_temp.sees('x.jpg'), 'photo of a paper never postponed and not confirmed: still hidden');
  perform pg_temp.ok(public.postponed_order_paper('00000000-0000-0000-0000-000000000000') is null, 'unknown paper: nothing');
end $$;
reset role;

-- company director (Prosun Food)
select pg_temp.as_user('00000000-0000-0000-0000-0000000000e9'); set role authenticated;
do $$ declare j jsonb; begin
  j := public.postponed_order_paper('42000000-0000-0000-0000-00000000000f');
  perform pg_temp.ok(j->>'company' = 'Prosun Food' and (j->>'photo_ok')::boolean, 'company director: his company''s postponed paper');
  perform pg_temp.ok(pg_temp.sees('f.jpg'), 'company director: photo of his company''s postponed paper can be opened');
  perform pg_temp.ok(pg_temp.refused('42000000-0000-0000-0000-00000000000a'), 'company director: Prosun Farm paper refused');
  perform pg_temp.ok(not pg_temp.sees('0a.jpg'), 'company director: Prosun Farm photo hidden');
end $$;
reset role;

-- admin: any paper
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1'); set role authenticated;
do $$ begin
  perform pg_temp.ok((public.postponed_order_paper('53000000-0000-0000-0000-000000000001')->>'photo_ok')::boolean, 'admin: any paper, photo ok');
end $$;
reset role;

-- others refused, and their photo rules unchanged
select pg_temp.as_user('00000000-0000-0000-0000-0000000000c1'); set role authenticated;
do $$ begin
  perform pg_temp.ok(pg_temp.refused('42000000-0000-0000-0000-00000000000f'), 'accounting: refused');
  perform pg_temp.ok(not pg_temp.sees('f.jpg'), 'accounting: postponed paper photo still hidden (not confirmed)');
end $$;
reset role;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d1'); set role authenticated;
do $$ begin
  perform pg_temp.ok(pg_temp.refused('42000000-0000-0000-0000-00000000000f'), 'delivery: refused');
  perform pg_temp.ok(not pg_temp.sees('f.jpg'), 'delivery: postponed paper photo still hidden (not confirmed)');
end $$;
reset role;
set role anon;
do $$ begin
  perform pg_temp.ok(pg_temp.refused('42000000-0000-0000-0000-00000000000f'), 'not signed in: refused');
end $$;
reset role;
