-- ============================================================================
-- Klong Phai Farm / Prosun CRM — database schema
-- Run this once in the Supabase SQL Editor (Project > SQL Editor > New query)
-- after creating a new Supabase project.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. PROFILES  (one row per login, extends Supabase's built-in auth.users)
-- ----------------------------------------------------------------------------
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  full_name   text not null,
  role        text not null check (role in ('admin', 'director', 'sales')),
  created_at  timestamptz not null default now()
);

comment on table public.profiles is
  'One row per user. role decides what they can see: admin = everything, '
  'director = leads only (no deal value / won-lost history), sales = only their own clients.';

-- Automatically create a profile row whenever someone is invited/signs up.
-- New users default to the lowest-privilege role ("sales"); an admin promotes
-- them afterwards with:  update public.profiles set role = 'admin' where id = '<uuid>';
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, role)
  values (new.id, coalesce(new.raw_user_meta_data->>'full_name', new.email), 'sales');
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Helper used inside RLS policies below. SECURITY DEFINER lets it read
-- profiles even though profiles itself has RLS enabled (avoids infinite
-- recursion: without this, checking a policy would trigger the policy).
create or replace function public.current_role()
returns text
language sql
security definer
set search_path = public
stable
as $$
  select role from public.profiles where id = auth.uid();
$$;

alter table public.profiles enable row level security;

create policy "profiles: read own row"
  on public.profiles for select
  using (id = auth.uid());

create policy "profiles: admin reads everyone"
  on public.profiles for select
  using (public.current_role() = 'admin');

create policy "profiles: admin updates roles"
  on public.profiles for update
  using (public.current_role() = 'admin');

-- ----------------------------------------------------------------------------
-- 2. CLIENTS  (the actual CRM records — clients / leads / deals in one table)
--    Field names mirror the existing Excel sales dashboard where possible.
-- ----------------------------------------------------------------------------
create table if not exists public.clients (
  id               uuid primary key default gen_random_uuid(),
  name             text not null,
  contact_name     text,
  phone            text,
  email            text,
  segment          text check (segment in ('Restaurant', 'Individual', 'Retail', 'Department Store')),
  delivery_area    text,                          -- e.g. Bangkok / Up-country, used by the pricing engine already
  source           text,                          -- how the lead came in
  assigned_to      uuid references public.profiles(id),
  stage            text not null default 'lead'
                     check (stage in ('lead', 'qualified', 'proposal', 'won', 'at_risk', 'dormant', 'lost')),
  deal_value       numeric,                       -- monthly run-rate or deal size, THB
  next_action      text,
  next_action_date date,
  notes            text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

create index if not exists clients_assigned_to_idx on public.clients (assigned_to);
create index if not exists clients_stage_idx        on public.clients (stage);

create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists clients_set_updated_at on public.clients;
create trigger clients_set_updated_at
  before update on public.clients
  for each row execute function public.set_updated_at();

alter table public.clients enable row level security;

-- Admin: full access to everything.
create policy "clients: admin full access"
  on public.clients for all
  using (public.current_role() = 'admin')
  with check (public.current_role() = 'admin');

-- Sales rep: only rows assigned to them — read, create, update. No delete
-- (deleting a client record is an admin-only action).
create policy "clients: sales read own"
  on public.clients for select
  using (public.current_role() = 'sales' and assigned_to = auth.uid());

create policy "clients: sales insert own"
  on public.clients for insert
  with check (public.current_role() = 'sales' and assigned_to = auth.uid());

create policy "clients: sales update own"
  on public.clients for update
  using (public.current_role() = 'sales' and assigned_to = auth.uid())
  with check (public.current_role() = 'sales' and assigned_to = auth.uid());

-- Director: read-only, lead-stage rows only. This stops a director from ever
-- reading a colleague's won/lost history or an at-risk client through the
-- database. It does NOT by itself hide the deal_value column on lead rows
-- (Postgres row-level security controls rows, not columns) — the director
-- front-end view (director.html) simply never requests that column. See the
-- README "known limitation" note for how to harden this further later.
create policy "clients: director reads leads only"
  on public.clients for select
  using (public.current_role() = 'director' and stage = 'lead');

-- ----------------------------------------------------------------------------
-- 3. ACTIVITY LOG  (who did what, when — admin-only to read)
-- ----------------------------------------------------------------------------
create table if not exists public.activity_log (
  id          bigint generated always as identity primary key,
  table_name  text not null,
  record_id   uuid,
  user_id     uuid references public.profiles(id),
  action      text not null,           -- INSERT / UPDATE / DELETE
  details     jsonb,
  changed_at  timestamptz not null default now()
);

alter table public.activity_log enable row level security;

create policy "activity_log: admin reads all"
  on public.activity_log for select
  using (public.current_role() = 'admin');

create or replace function public.log_client_activity()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.activity_log (table_name, record_id, user_id, action, details)
  values (
    'clients',
    coalesce(new.id, old.id),
    auth.uid(),
    tg_op,
    case tg_op
      when 'DELETE' then to_jsonb(old)
      else to_jsonb(new)
    end
  );
  return coalesce(new, old);
end;
$$;

drop trigger if exists clients_log_activity on public.clients;
create trigger clients_log_activity
  after insert or update or delete on public.clients
  for each row execute function public.log_client_activity();

-- ----------------------------------------------------------------------------
-- 4. DIRECTOR-SAFE VIEW  (convenience — same row filter as the RLS policy
--    above, but also drops the sensitive columns at the query level so the
--    front-end code for the director role can just "select * from
--    director_leads" and never even see deal_value/notes in the response)
-- ----------------------------------------------------------------------------
create or replace view public.director_leads
with (security_invoker = true) as
  select id, name, contact_name, phone, email, segment, delivery_area,
         source, assigned_to, stage, next_action, next_action_date, created_at
  from public.clients
  where stage = 'lead';

-- ============================================================================
-- Done. Next steps (see README.md):
--   1. Project Settings > API — copy the Project URL and anon public key into
--      web/config.js
--   2. Authentication > Users — invite your first users (yourself as admin,
--      the sales director, each sales rep)
--   3. Run:  update public.profiles set role = 'admin' where id = '<your uuid>';
--      to promote yourself — everyone else defaults to 'sales' until you
--      change their role the same way.
-- ============================================================================
