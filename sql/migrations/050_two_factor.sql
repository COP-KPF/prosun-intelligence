-- ============================================================================
-- Migration 050 — Two-factor authentication (authenticator app), enforced by
-- the database. 25 Nov 2026.
-- ============================================================================
-- Clément, 25 Nov 2026: 2FA for the sensitive roles, as proposed — admin
-- (Clément, Khun Jum), accounting (Payables, confirmed weights) and the
-- company director (Chef Julien, management figures).
--
-- Why in the database and not only on the login screen: Supabase accepts a
-- password-only session (aal1) even when the person has an authenticator app.
-- Someone with a stolen password could skip the code screen and call the API
-- directly. After this migration, a session of one of these roles that has not
-- passed the 6-digit code (aal2) reaches nothing except its own profile row.
--
-- Three layers, because each Supabase product checks access differently:
--   1. Data API (every table, view and RPC the app calls):
--      public.pace_pre_request(), run by PostgREST before every request.
--      This is the layer that covers the ~120 SECURITY DEFINER functions
--      (dashboards, payables actions …), which do not go through RLS.
--   2. Realtime and anything else reading tables with the user's token:
--      a RESTRICTIVE policy "mfa: code required" on every table in public.
--   3. Storage (working-paper photos, scanned bills): the same restrictive
--      policy on storage.objects.
--
-- Scope (Clément, 25 Nov): the code at login only. A second code before
-- approving bills in Payables was built, then left out as secondary; the
-- helper public.mfa_recent() stays for that if it comes back.
--
-- Who needs 2FA is a table, public.mfa_policy (one row per role). To add a role:
--   insert into public.mfa_policy (role) values ('sale_support');
-- Nobody is locked out by running this: on the next login the app shows the
-- QR code to set up the authenticator app, then asks for the code.
--
-- Lost phone (admin, in the SQL editor):
--   delete from auth.mfa_factors
--    where user_id = (select id from auth.users where lower(email) = lower('name@klongphaifarm.com'));
-- The person then sets up the app again at the next login.
--
-- Future migrations that create a table: end them with
--   select public.mfa_gate_tables();
-- (the Data API layer already covers new tables; this adds the Realtime layer.)
--
-- Undo (emergency — e.g. everybody blocked):
--   alter role authenticator reset pgrst.db_pre_request;
--   notify pgrst, 'reload config';
--   delete from public.mfa_policy;          -- policies then let everyone through
-- ============================================================================

begin;
set local client_min_messages = warning;

-- Stop rather than overwrite a pre-request function set by something else.
do $$
declare v text;
begin
  select split_part(c, '=', 2) into v
    from pg_roles r, unnest(coalesce(r.rolconfig, '{}'::text[])) c
   where r.rolname = 'authenticator' and c like 'pgrst.db_pre_request=%';
  if v is not null and v <> 'public.pace_pre_request' then
    raise exception 'authenticator already has pgrst.db_pre_request = %. Migration 050 stopped — tell Claude.', v;
  end if;
end $$;

-- ---------------------------------------------------------------- who needs it
create table if not exists public.mfa_policy (
  role       text primary key check (role in ('admin', 'director', 'sales', 'sale_support', 'purchasing',
               'production', 'factory_admin', 'accounting', 'delivery', 'company_director')),
  created_at timestamptz not null default now()
);
comment on table public.mfa_policy is
  'Roles that must pass the authenticator-app code (aal2) to reach any data. Migration 050. '
  'Change from the SQL editor only.';
insert into public.mfa_policy (role) values ('admin'), ('accounting'), ('company_director')
  on conflict do nothing;
alter table public.mfa_policy enable row level security;
drop policy if exists "mfa_policy: signed-in users read" on public.mfa_policy;
create policy "mfa_policy: signed-in users read" on public.mfa_policy for select to authenticated using (true);
revoke insert, update, delete, truncate on public.mfa_policy from anon, authenticated;

-- ---------------------------------------------------------------- helpers
-- True when the signed-in person's role is in mfa_policy.
create or replace function public.mfa_required()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.profiles p join public.mfa_policy m on m.role = p.role
     where p.id = auth.uid());
$$;

-- True when the request may reach data: no signed-in person (anon pages and
-- the service key have their own rules), a role without 2FA, or a session
-- that passed the code.
create or replace function public.mfa_ok()
returns boolean language sql stable security definer set search_path = public as $$
  select auth.uid() is null
      or coalesce(auth.jwt() ->> 'aal', 'aal1') = 'aal2'
      or not public.mfa_required();
$$;

-- True when the code was typed in the last p_minutes (payments), or the
-- person's role does not need 2FA.
create or replace function public.mfa_recent(p_minutes int default 10)
returns boolean language sql stable security definer set search_path = public as $$
  select not public.mfa_required()
      or (coalesce(auth.jwt() ->> 'aal', 'aal1') = 'aal2'
          and exists (
            select 1 from jsonb_array_elements(coalesce(auth.jwt() -> 'amr', '[]'::jsonb)) a
             where a ->> 'method' = 'totp'
               and (a ->> 'timestamp')::numeric >= extract(epoch from now()) - p_minutes * 60));
$$;

-- For the app: does this person need the code, and has this session passed it?
create or replace function public.my_mfa_required()
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'required', public.mfa_required(),
    'aal', coalesce(auth.jwt() ->> 'aal', 'aal1'),
    'recent', public.mfa_recent(10));
$$;

revoke all on function public.mfa_required(), public.mfa_ok(), public.mfa_recent(int), public.my_mfa_required() from public;
grant execute on function public.mfa_required(), public.mfa_ok(), public.mfa_recent(int) to anon, authenticated, service_role;
grant execute on function public.my_mfa_required() to authenticated;

-- ---------------------------------------------------------------- layer 1: Data API
create or replace function public.pace_pre_request()
returns void language plpgsql stable security definer set search_path = public as $$
declare
  v_path   text := ltrim(coalesce(current_setting('request.path', true), ''), '/');
  v_method text := upper(coalesce(current_setting('request.method', true), ''));
begin
  if auth.uid() is null then
    return;                                        -- anon (capture pages) and service key
  end if;
  if not public.mfa_ok() then
    -- Before the code: only the person's own profile and the 2FA status.
    if (v_path = 'profiles' and v_method in ('GET', 'HEAD')) or v_path = 'rpc/my_mfa_required' then
      return;
    end if;
    raise exception 'mfa_required'
      using errcode = '42501', hint = 'Enter the 6-digit code from your authenticator app.';
  end if;
end $$;
revoke all on function public.pace_pre_request() from public;
grant execute on function public.pace_pre_request() to anon, authenticated, service_role;

-- ---------------------------------------------------------------- layers 2 + 3: RLS
-- (Re)creates the restrictive policy on every RLS table in public and on
-- storage.objects. Idempotent; run again after creating tables.
create or replace function public.mfa_gate_tables()
returns int language plpgsql security invoker set search_path = public set client_min_messages = warning as $$
declare r record; n int := 0;
begin
  for r in
    select c.relname from pg_class c join pg_namespace s on s.oid = c.relnamespace
     where s.nspname = 'public' and c.relkind in ('r', 'p') and c.relrowsecurity
  loop
    execute format('drop policy if exists "mfa: code required" on public.%I', r.relname);
    execute format('drop policy if exists "mfa: code required to read" on public.%I', r.relname);
    execute format('drop policy if exists "mfa: code required to add" on public.%I', r.relname);
    execute format('drop policy if exists "mfa: code required to change" on public.%I', r.relname);
    execute format('drop policy if exists "mfa: code required to remove" on public.%I', r.relname);
    if r.relname = 'profiles' then
      -- Own row stays readable before the code, so the app knows the role.
      create policy "mfa: code required to read" on public.profiles as restrictive for select to authenticated
        using ((select public.mfa_ok()) or id = auth.uid());
      create policy "mfa: code required to add" on public.profiles as restrictive for insert to authenticated
        with check ((select public.mfa_ok()));
      create policy "mfa: code required to change" on public.profiles as restrictive for update to authenticated
        using ((select public.mfa_ok())) with check ((select public.mfa_ok()));
      create policy "mfa: code required to remove" on public.profiles as restrictive for delete to authenticated
        using ((select public.mfa_ok()));
    else
      execute format('create policy "mfa: code required" on public.%I as restrictive for all to authenticated '
                     'using ((select public.mfa_ok())) with check ((select public.mfa_ok()))', r.relname);
    end if;
    n := n + 1;
  end loop;
  drop policy if exists "mfa: code required" on storage.objects;
  create policy "mfa: code required" on storage.objects as restrictive for all to authenticated
    using ((select public.mfa_ok())) with check ((select public.mfa_ok()));
  return n;
end $$;
revoke all on function public.mfa_gate_tables() from public, anon, authenticated;

select public.mfa_gate_tables();

-- Turn layer 1 on.
alter role authenticator set pgrst.db_pre_request = 'public.pace_pre_request';

commit;

notify pgrst, 'reload config';

-- What it did (shown in the SQL editor result).
select
  (select string_agg(role, ', ' order by role) from public.mfa_policy)                       as roles_needing_2fa,
  (select count(*) from pg_policy p join pg_class c on c.oid = p.polrelid
     join pg_namespace s on s.oid = c.relnamespace
    where s.nspname = 'public' and p.polname like 'mfa: code required%')                       as table_policies,
  (select count(*) from public.profiles p join public.mfa_policy m on m.role = p.role)         as people_needing_2fa,
  (select string_agg(c, '') from pg_roles r, unnest(r.rolconfig) c
    where r.rolname = 'authenticator' and c like 'pgrst.db_pre_request=%')                     as data_api_check;
