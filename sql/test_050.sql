-- Migration 050 — two-factor authentication. Run on a replica that has
-- migrations 001–049 and some data (psql -f). Compares what every role reads
-- from every table, view and storage before and after 050, with and without
-- the code, and checks the Data API gate.
\set ON_ERROR_STOP 1
\pset tuples_only on

-- People for every role (ids as in test_043 / test_046; safe to re-run).
insert into auth.users (id, email) values
 ('00000000-0000-0000-0000-0000000000a1','admin@x'),('00000000-0000-0000-0000-0000000000a2','jum@x'),
 ('00000000-0000-0000-0000-0000000000b1','ss@x'),('00000000-0000-0000-0000-0000000000c1','acc@x'),
 ('00000000-0000-0000-0000-0000000000f1','prod@x'),('00000000-0000-0000-0000-0000000000d1','nick@x'),
 ('00000000-0000-0000-0000-000000000012','james@x'),('00000000-0000-0000-0000-000000000002','christophe@x'),
 ('00000000-0000-0000-0000-0000000049a1','orawan@x'),('00000000-0000-0000-0000-0000000049a2','fa@x'),
 ('00000000-0000-0000-0000-0000000049a3','julien@x')
on conflict do nothing;
insert into public.profiles (id, full_name, role, company_scope) values
 ('00000000-0000-0000-0000-0000000000a1','Clément','admin', null),
 ('00000000-0000-0000-0000-0000000000a2','Jum','admin', null),
 ('00000000-0000-0000-0000-0000000000b1','Ploy','sale_support', null),
 ('00000000-0000-0000-0000-0000000000c1','Ann','accounting', null),
 ('00000000-0000-0000-0000-0000000000f1','Muay','production', null),
 ('00000000-0000-0000-0000-0000000000d1','Nick','delivery', null),
 ('00000000-0000-0000-0000-000000000012','James','sales', null),
 ('00000000-0000-0000-0000-000000000002','Christophe','director', null),
 ('00000000-0000-0000-0000-0000000049a1','Orawan','purchasing', null),
 ('00000000-0000-0000-0000-0000000049a2','Muay FA','factory_admin', null),
 ('00000000-0000-0000-0000-0000000049a3','Chef Julien','company_director','Prosun Food')
on conflict (id) do update set full_name = excluded.full_name, role = excluded.role, company_scope = excluded.company_scope;

create or replace function pg_temp.ok(cond boolean, label text) returns void language plpgsql as $$
begin if coalesce(cond, false) then raise notice 'PASS %', label; else raise exception 'FAIL %', label; end if; end $$;

-- Claims as Supabase puts them in the token. p_totp_age: seconds since the
-- code was typed (null = no code in this session).
create or replace function pg_temp.claims(p_user uuid, p_aal text, p_totp_age int default null) returns void language plpgsql as $$
declare amr jsonb := jsonb_build_array(jsonb_build_object('method', 'password', 'timestamp', extract(epoch from now())::bigint - 3600));
begin
  if p_totp_age is not null then
    amr := amr || jsonb_build_array(jsonb_build_object('method', 'totp', 'timestamp', extract(epoch from now())::bigint - p_totp_age));
  end if;
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated',
    'aal', p_aal, 'amr', amr)::text, false);
end $$;

-- Rows each person can read in every table / view (RLS as 'authenticated').
-- -1 = permission error.
create or replace function pg_temp.snapshot(p_label text) returns void language plpgsql as $$
declare u record; t record; n bigint; aal text;
begin
  for u in select id, role from public.profiles loop
    foreach aal in array array['aal1', 'aal2'] loop
      perform pg_temp.claims(u.id, aal, case when aal = 'aal2' then 60 end);
      for t in
        select format('%I.%I', s.nspname, c.relname) as rel from pg_class c join pg_namespace s on s.oid = c.relnamespace
         where (s.nspname = 'public' and c.relkind in ('r', 'v', 'm')) or (s.nspname = 'storage' and c.relname = 'objects')
      loop
        begin
          execute 'set local role authenticated';
          execute format('select count(*) from %s', t.rel) into n;
          execute 'reset role';
        exception when others then
          execute 'reset role';
          n := -1;
        end;
        insert into snap values (p_label, u.role, u.id, aal, t.rel, n);
      end loop;
    end loop;
  end loop;
  perform set_config('request.jwt.claims', '', false);
end $$;

create temp table snap (label text, role text, uid uuid, aal text, rel text, n bigint);
grant all on snap to authenticated;

begin;
select pg_temp.snapshot('before');
commit;

\i sql/migrations/050_two_factor.sql

begin;
select pg_temp.snapshot('after');
commit;

do $$
declare v_n int; bad text;
begin
  -- 1. Roles without 2FA: identical everywhere, with or without a code.
  select count(*), string_agg(distinct a.role || ' ' || a.aal || ' ' || a.rel || ' ' || b.n || '→' || a.n, '; ')
    into v_n, bad
    from snap a join snap b on b.label = 'before' and b.uid = a.uid and b.aal = a.aal and b.rel = a.rel
   where a.label = 'after' and a.role not in ('admin', 'accounting', 'company_director') and a.n is distinct from b.n
     and a.rel <> 'public.mfa_policy';
  perform pg_temp.ok(v_n = 0, 'roles without 2FA read exactly the same as before (' ||
    (select count(*) from snap where label = 'after' and role not in ('admin','accounting','company_director')) || ' checks) ' || coalesce(bad, ''));

  -- 2. 2FA roles with the code: identical.
  select count(*), string_agg(distinct a.role || ' ' || a.rel || ' ' || b.n || '→' || a.n, '; ')
    into v_n, bad
    from snap a join snap b on b.label = 'before' and b.uid = a.uid and b.aal = a.aal and b.rel = a.rel
   where a.label = 'after' and a.aal = 'aal2' and a.role in ('admin', 'accounting', 'company_director')
     and a.n is distinct from b.n and a.rel <> 'public.mfa_policy';
  perform pg_temp.ok(v_n = 0, '2FA roles with the code read exactly the same as before (' ||
    (select count(*) from snap where label = 'after' and aal = 'aal2' and role in ('admin','accounting','company_director')) || ' checks) ' || coalesce(bad, ''));

  -- 3. 2FA roles without the code: nothing from any table, except their own profile.
  select count(*), string_agg(distinct a.role || ' ' || a.rel || '=' || a.n, '; ')
    into v_n, bad
    from snap a
   where a.label = 'after' and a.aal = 'aal1' and a.role in ('admin', 'accounting', 'company_director')
     and a.rel not in ('public.profiles', 'public.mfa_policy')
     and a.n > 0
     and exists (select 1 from pg_class c join pg_namespace s on s.oid = c.relnamespace
                  where format('%I.%I', s.nspname, c.relname) = a.rel and c.relkind = 'r');
  perform pg_temp.ok(v_n = 0, '2FA roles without the code read no table rows ' || coalesce(bad, ''));
  perform pg_temp.ok((select bool_and(n = 1) from snap where label = 'after' and aal = 'aal1'
                        and role in ('admin', 'accounting', 'company_director') and rel = 'public.profiles'),
    '2FA roles without the code read only their own profile row');
  perform pg_temp.ok((select bool_and(n = 0) from snap where label = 'after' and aal = 'aal1'
                        and role in ('admin', 'accounting', 'company_director') and rel = 'storage.objects'),
    '2FA roles without the code read no stored photo or bill');
  perform pg_temp.ok((select max(n) from snap where label = 'before' and rel = 'storage.objects' and role = 'admin') >= 0,
    'storage was checked');
  -- Something was actually readable before, so the comparison means something.
  perform pg_temp.ok((select count(distinct rel) from snap where label = 'before' and role = 'admin' and n > 0) >= 15,
    'admin read rows from ' || (select count(distinct rel) from snap where label = 'before' and role = 'admin' and n > 0) || ' tables/views before');
end $$;

-- Data API gate ---------------------------------------------------------------
create or replace function pg_temp.gate(p_user uuid, p_aal text, p_totp_age int, p_path text, p_method text default 'GET')
returns text language plpgsql as $$
begin
  perform pg_temp.claims(p_user, p_aal, p_totp_age);
  perform set_config('request.path', p_path, false);
  perform set_config('request.method', p_method, false);
  execute 'set local role authenticated';
  begin
    perform public.pace_pre_request();
    execute 'reset role';
    return 'ok';
  exception when others then
    execute 'reset role';
    return sqlerrm;
  end;
end $$;

begin;
do $$
declare
  clement uuid := '00000000-0000-0000-0000-0000000000a1';
  ann     uuid := '00000000-0000-0000-0000-0000000000c1';
  julien  uuid := '00000000-0000-0000-0000-0000000049a3';
  ploy    uuid := '00000000-0000-0000-0000-0000000000b1';
  muay    uuid := '00000000-0000-0000-0000-0000000000f1';
  nick    uuid := '00000000-0000-0000-0000-0000000000d1';
  orawan  uuid := '00000000-0000-0000-0000-0000000049a1';
  james   uuid := '00000000-0000-0000-0000-000000000012';
begin
  -- Without the code
  perform pg_temp.ok(pg_temp.gate(clement, 'aal1', null, '/rpc/management_dashboard', 'POST') = 'mfa_required', 'admin, no code: dashboard refused');
  perform pg_temp.ok(pg_temp.gate(clement, 'aal1', null, '/sale_orders') = 'mfa_required', 'admin, no code: orders refused');
  perform pg_temp.ok(pg_temp.gate(clement, 'aal1', null, '/payables') = 'mfa_required', 'admin, no code: payables refused');
  perform pg_temp.ok(pg_temp.gate(ann, 'aal1', null, '/rpc/payable_my_permissions', 'POST') = 'mfa_required', 'accounting, no code: payables refused');
  perform pg_temp.ok(pg_temp.gate(julien, 'aal1', null, '/rpc/management_summary', 'POST') = 'mfa_required', 'company director, no code: summary refused');
  perform pg_temp.ok(pg_temp.gate(clement, 'aal1', null, '/profiles', 'GET') = 'ok', 'admin, no code: own profile allowed (app reads the role)');
  perform pg_temp.ok(pg_temp.gate(clement, 'aal1', null, '/profiles', 'PATCH') = 'mfa_required', 'admin, no code: profile change refused');
  perform pg_temp.ok(pg_temp.gate(clement, 'aal1', null, '/rpc/my_mfa_required', 'POST') = 'ok', 'admin, no code: 2FA status allowed');
  -- With the code
  perform pg_temp.ok(pg_temp.gate(clement, 'aal2', 3600, '/rpc/management_dashboard', 'POST') = 'ok', 'admin with code: dashboard allowed');
  perform pg_temp.ok(pg_temp.gate(ann, 'aal2', 3600, '/payables') = 'ok', 'accounting with code: payables allowed');
  perform pg_temp.ok(pg_temp.gate(julien, 'aal2', 3600, '/rpc/management_summary', 'POST') = 'ok', 'company director with code: allowed');
  -- Payables: no second code (login code only, Clément 25 Nov)
  perform pg_temp.ok(pg_temp.gate(clement, 'aal2', 3600, '/rpc/payable_approve', 'POST') = 'ok', 'approve bills, code typed 1 h ago at login: no second code');
  perform pg_temp.ok(pg_temp.gate(clement, 'aal2', 3600, '/rpc/payable_mark_paid', 'POST') = 'ok', 'record bills as paid: no second code');
  -- Roles without 2FA: unchanged
  perform pg_temp.ok(pg_temp.gate(ploy, 'aal1', null, '/sale_orders') = 'ok', 'sale support, no code: works as before');
  perform pg_temp.ok(pg_temp.gate(muay, 'aal1', null, '/rpc/weighing_day', 'POST') = 'ok', 'production, no code: works as before');
  perform pg_temp.ok(pg_temp.gate(nick, 'aal1', null, '/rpc/delivery_board', 'POST') = 'ok', 'delivery, no code: works as before');
  perform pg_temp.ok(pg_temp.gate(orawan, 'aal1', null, '/purchase_orders') = 'ok', 'purchasing, no code: works as before');
  perform pg_temp.ok(pg_temp.gate(james, 'aal1', null, '/clients') = 'ok', 'sales (CRM), no code: works as before');
  -- Anonymous (capture pages) and service key
  perform set_config('request.jwt.claims', '{"role":"anon"}', false);
  perform set_config('request.path', '/rpc/anything', false);
  perform public.pace_pre_request();
  perform pg_temp.ok(true, 'anonymous request (capture pages) not affected');
  perform set_config('request.jwt.claims', '{"role":"service_role"}', false);
  perform public.pace_pre_request();
  perform pg_temp.ok(true, 'service key (Edge Functions, backups) not affected');
  perform set_config('request.jwt.claims', '', false);
end $$;
commit;

-- Writes without the code ------------------------------------------------------
begin;
do $$
declare n int; clement uuid := '00000000-0000-0000-0000-0000000000a1';
begin
  perform pg_temp.claims(clement, 'aal1', null);
  execute 'set local role authenticated';
  update public.profiles set full_name = full_name where id = clement;
  get diagnostics n = row_count;
  execute 'reset role';
  perform pg_temp.ok(n = 0, 'admin without code cannot change a profile (own row included)');
  perform pg_temp.claims(clement, 'aal1', null);
  execute 'set local role authenticated';
  begin
    insert into public.pace_customers (channel, name) values ('Restaurant', 'T049');
    execute 'reset role';
    raise exception 'FAIL insert without code';
  exception when insufficient_privilege or check_violation then
    execute 'reset role';
    perform pg_temp.ok(true, 'admin without code cannot add rows');
  end;
  perform pg_temp.claims(clement, 'aal2', 60);
  execute 'set local role authenticated';
  update public.profiles set full_name = full_name where id = clement;
  get diagnostics n = row_count;
  execute 'reset role';
  perform pg_temp.ok(n = 1, 'admin with code can change a profile as before');
end $$;
rollback;

-- Configuration ----------------------------------------------------------------
do $$
begin
  perform pg_temp.ok((select string_agg(role, ',' order by role) from public.mfa_policy) = 'accounting,admin,company_director',
    'roles needing 2FA: admin, accounting, company director');
  perform pg_temp.ok(exists (select 1 from pg_roles r, unnest(r.rolconfig) c where r.rolname = 'authenticator'
    and c = 'pgrst.db_pre_request=public.pace_pre_request'), 'Data API check switched on');
  perform pg_temp.ok((select count(*) from pg_class c join pg_namespace s on s.oid = c.relnamespace
      where s.nspname = 'public' and c.relkind = 'r' and c.relrowsecurity
        and not exists (select 1 from pg_policy p where p.polrelid = c.oid and p.polname like 'mfa: code required%')) = 0,
    'every table has the 2FA policy');
  perform pg_temp.ok(public.mfa_gate_tables() > 50, 'mfa_gate_tables() can be run again');
end $$;

-- Running 050 twice is harmless.
\i sql/migrations/050_two_factor.sql
select 'PASS 050 runs twice without error';
