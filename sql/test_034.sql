-- Migration 034 — delivery board: open the weighing paper. Run on a replica after 034.
\set ON_ERROR_STOP 1
\pset tuples_only on
grant select on storage.objects to authenticated;   -- as on Supabase
insert into auth.users (id, email) values
 ('00000000-0000-0000-0000-0000000000d1','deliv@x'),('00000000-0000-0000-0000-0000000000f1','muay@x'),
 ('00000000-0000-0000-0000-0000000000c1','acc@x'),('00000000-0000-0000-0000-0000000000a9','sales@x') on conflict do nothing;
insert into public.profiles (id, full_name, role) values
 ('00000000-0000-0000-0000-0000000000d1','Khun Driver','delivery'),('00000000-0000-0000-0000-0000000000f1','Khun Muay','factory_admin'),
 ('00000000-0000-0000-0000-0000000000c1','Ann','accounting'),('00000000-0000-0000-0000-0000000000a9','Rep','sales')
on conflict (id) do update set role = excluded.role, full_name = excluded.full_name;
insert into public.weighing_papers (id, work_date, photo_path, status, company, po_number, customer_name, delivery_date) values
 ('34000000-0000-0000-0000-00000000000a', '2026-11-17', '2026-11-17/a.jpg', 'read', 'Prosun Farm', 'PO-A', 'Ledu',   '2026-11-18'),
 ('34000000-0000-0000-0000-00000000000b', '2026-11-17', '2026-11-17/b.jpg', 'read', 'Prosun Food', 'PO-B', 'Sloane', '2026-11-18');
insert into storage.objects (bucket_id, name) values ('weighing-photos', '2026-11-17/a.jpg'), ('weighing-photos', '2026-11-17/b.jpg');
-- Muay confirms A (the stamp trigger records who)
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000f1"}', false);
update public.weighing_papers set status = 'confirmed' where id = '34000000-0000-0000-0000-00000000000a';
select set_config('request.jwt.claims', '', false);

create or replace function pg_temp.as_user(u text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', u)::text, false); end $$;
create or replace function pg_temp.ok(cond boolean, label text) returns void language plpgsql as $$
begin if cond then raise notice 'PASS %', label; else raise exception 'FAIL %', label; end if; end $$;

select pg_temp.as_user('00000000-0000-0000-0000-0000000000d1'); set role authenticated;
do $$ declare b jsonb := public.delivery_board('2026-11-18'); x jsonb; begin
  select e into x from jsonb_array_elements(b->'papers') e where e->>'po_number' = 'PO-A';
  perform pg_temp.ok(x->>'photo_path' = '2026-11-17/a.jpg', 'board carries the photo path');
  perform pg_temp.ok(x->>'confirmed_by_name' = 'Khun Muay', 'board carries who confirmed: ' || coalesce(x->>'confirmed_by_name', 'null'));
  perform pg_temp.ok(x ? 'photo_deleted_at', 'board carries photo_deleted_at');
  perform pg_temp.ok((select count(*) from storage.objects where name = '2026-11-17/a.jpg') = 1, 'delivery opens the photo of a confirmed paper');
  perform pg_temp.ok((select count(*) from storage.objects where name = '2026-11-17/b.jpg') = 0, 'delivery cannot open a paper still being checked');
end $$;
reset role;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000c1'); set role authenticated;
do $$ begin perform pg_temp.ok((select count(*) from storage.objects where bucket_id = 'weighing-photos') = 1, 'accounting unchanged: confirmed only'); end $$;
reset role;
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a9'); set role authenticated;
do $$ begin perform pg_temp.ok((select count(*) from storage.objects where bucket_id = 'weighing-photos') = 0, 'a CRM sales rep sees no photo'); end $$;
reset role;
set role anon;
do $$ begin
  begin perform count(*) from storage.objects; perform pg_temp.ok(false, 'anon read storage');
  exception when insufficient_privilege then perform pg_temp.ok(true, 'anon: no photo'); end;
end $$;
reset role;
