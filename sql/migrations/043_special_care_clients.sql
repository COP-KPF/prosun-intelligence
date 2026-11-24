-- ============================================================================
-- Migration 043 — Special care clients (ลูกค้าดูแลพิเศษ)
-- ============================================================================
-- Clément, 24 Nov 2026: a "Special care" flag on a client, set by admin only
-- (Clément, Khun Jum). It carries:
--   • No postpone (ห้ามเลื่อน) — postponing stays possible, but every screen
--     warns first and admins get a bell when it happens anyway;
--   • Exact quantity (ส่งครบจำนวน) — no short delivery: moving one product of
--     the order to another day warns first and rings the admins too;
--   • Priority delivery (ส่งก่อน) — first on the delivery board, with an
--     optional time window ("before 10:00");
--   • Special-care instructions — free text everyone handling the order reads.
-- Middle office, production, delivery and sales all see it. Production must
-- tick "special care checked" on the working paper before it can be
-- confirmed (enforced here, not only on screen).
--
-- What is in this migration
--   1. client_special_care      — one row per client code (sales_customers)
--   2. special_care_checks      — production's tick, one per working paper
--   3. special_care_code(name)  — working-paper name → special-care client code
--   4. special_care_list()      — the flagged clients the caller may see
--      special_care_match(ids, names) — which papers / names are flagged
--      special_care_search(q)   — admin: find a client to flag
--      special_care_set(…) / special_care_remove(code) — admin only
--      special_care_check(paper, on) — production / factory admin / admin
--   5. Guard: a flagged paper cannot become 'confirmed' without the tick;
--      a "part 2" created already confirmed inherits the tick of its paper.
--   6. Bells: 'special_care_postponed' to admins when a No postpone client's
--      order (or a product of an Exact quantity client) is postponed anyway.
--
-- Matching: a working paper carries the client's name as printed; it is tied
-- to a client code with sales_code_for_name() (Migration 037), the same match
-- Sales › Clients uses. A paper whose name is not linked to a code is not
-- flagged — link it in Sales › Clients › "names not linked" (admin).
--
-- Run order: after 042 (or 041 — it does not depend on 042). Safe to re-run.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. The flag
-- ----------------------------------------------------------------------------
create table if not exists public.client_special_care (
  code               text primary key references public.sales_customers(code) on delete cascade,
  active             boolean not null default true,
  no_postpone        boolean not null default false,
  exact_quantity     boolean not null default false,
  priority_delivery  boolean not null default false,
  delivery_window    text,                    -- "before 10:00", "8:00–11:00"
  instructions       text,                    -- special care, shown to every team
  created_by         uuid references public.profiles(id) default auth.uid(),
  created_at         timestamptz not null default now(),
  updated_by         uuid references public.profiles(id) default auth.uid(),
  updated_at         timestamptz not null default now(),
  removed_by         uuid references public.profiles(id),
  removed_at         timestamptz,
  constraint client_special_care_something check (
    not active or no_postpone or exact_quantity or priority_delivery
    or length(btrim(coalesce(instructions, ''))) > 0)
);
comment on table public.client_special_care is
  'Special care clients (Clément, 24 Nov 2026): No postpone, Exact quantity, Priority delivery + instructions. '
  'Admin sets it; every PACE team sees it. Read and written only through the special_care_* functions. Migration 043.';

-- ----------------------------------------------------------------------------
-- 2. Production's tick
-- ----------------------------------------------------------------------------
create table if not exists public.special_care_checks (
  paper_id    uuid primary key references public.weighing_papers(id) on delete cascade,
  code        text,
  checked_by  uuid references public.profiles(id) default auth.uid(),
  checked_at  timestamptz not null default now()
);
comment on table public.special_care_checks is
  'Production ticked "special care checked" on this working paper (required before confirming a special care client''s paper). Migration 043.';

alter table public.client_special_care enable row level security;
alter table public.special_care_checks enable row level security;
revoke all on public.client_special_care, public.special_care_checks from anon, authenticated;
grant all on public.client_special_care, public.special_care_checks to service_role;


-- ----------------------------------------------------------------------------
-- 3. Name → special-care code
-- ----------------------------------------------------------------------------
create or replace function public.special_care_code(p_name text)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select s.code from public.client_special_care s
   where s.active and s.code = public.sales_code_for_name(p_name);
$$;
revoke all on function public.special_care_code(text) from public, anon, authenticated;

-- One client as the screens use it.
create or replace function public.special_care_json(s public.client_special_care)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'code', s.code,
    'name', c.name,
    'no_postpone', s.no_postpone,
    'exact_quantity', s.exact_quantity,
    'priority_delivery', s.priority_delivery,
    'delivery_window', s.delivery_window,
    'instructions', s.instructions,
    'updated_at', s.updated_at,
    'updated_by_name', (select full_name from public.profiles where id = s.updated_by))
  from public.sales_customers c where c.code = s.code;
$$;
revoke all on function public.special_care_json(public.client_special_care) from public, anon, authenticated;

-- Who may read the flags: every PACE team; a salesperson only for clients
-- they can see in Sales.
create or replace function public.special_care_can_read(p_code text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select case
    when public.current_role() in ('admin', 'sale_support', 'production', 'factory_admin', 'delivery',
                                   'accounting', 'purchasing', 'company_director') then true
    when public.current_role() in ('sales', 'director') then public.sales_can_see(p_code)
    else false
  end;
$$;
revoke all on function public.special_care_can_read(text) from public, anon, authenticated;


-- ----------------------------------------------------------------------------
-- 4. Functions for the screens
-- ----------------------------------------------------------------------------
-- Every flagged client the caller may see. Admin also gets the working-paper
-- names linked to each code, to check the match.
create or replace function public.special_care_list()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_admin boolean := public.current_role() = 'admin';
begin
  if auth.uid() is null then raise exception 'not signed in' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(public.special_care_json(s)
             || case when v_admin then jsonb_build_object(
                  'paper_names', (select coalesce(jsonb_agg(n.name order by n.name), '[]'::jsonb)
                                    from public.sales_customer_names n where n.code = s.code),
                  'created_at', s.created_at,
                  'created_by_name', (select full_name from public.profiles where id = s.created_by))
                else '{}'::jsonb end
             order by c.name)
      from public.client_special_care s
      join public.sales_customers c on c.code = s.code
     where s.active and public.special_care_can_read(s.code)), '[]'::jsonb);
end;
$$;

-- Which of these working papers / client names belong to a flagged client.
-- {clients: {code: {...}}, papers: {paper id: code}, names: {name: code}, checks: {paper id: {by, at}}}
create or replace function public.special_care_match(p_papers uuid[] default '{}', p_names text[] default '{}')
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_papers jsonb := '{}';
  v_names  jsonb := '{}';
  v_checks jsonb := '{}';
  v_codes  text[] := '{}';
begin
  if auth.uid() is null then raise exception 'not signed in' using errcode = '42501'; end if;
  if not exists (select 1 from public.client_special_care where active) then
    return jsonb_build_object('clients', '{}'::jsonb, 'papers', '{}'::jsonb, 'names', '{}'::jsonb, 'checks', '{}'::jsonb);
  end if;

  with m as (
    select p.id, public.special_care_code(p.customer_name) as code
      from public.weighing_papers p
     where p.id = any(coalesce(p_papers, '{}'))
  )
  select coalesce(jsonb_object_agg(m.id, m.code), '{}'), coalesce(array_agg(distinct m.code), '{}')
    into v_papers, v_codes
    from m where m.code is not null and public.special_care_can_read(m.code);

  with n as (
    select distinct x.name, public.special_care_code(x.name) as code
      from unnest(coalesce(p_names, '{}')) as x(name)
     where x.name is not null and btrim(x.name) <> ''
  )
  select coalesce(jsonb_object_agg(n.name, n.code), '{}'), v_codes || coalesce(array_agg(distinct n.code), '{}')
    into v_names, v_codes
    from n where n.code is not null and public.special_care_can_read(n.code);

  select coalesce(jsonb_object_agg(k.paper_id, jsonb_build_object(
           'by', (select full_name from public.profiles where id = k.checked_by), 'at', k.checked_at)), '{}')
    into v_checks
    from public.special_care_checks k
   where k.paper_id::text in (select jsonb_object_keys(v_papers));

  return jsonb_build_object(
    'clients', coalesce((select jsonb_object_agg(s.code, public.special_care_json(s))
                           from public.client_special_care s
                          where s.active and s.code = any(v_codes)), '{}'::jsonb),
    'papers', v_papers,
    'names', v_names,
    'checks', v_checks);
end;
$$;

-- Admin: find a client (code or name) to flag.
create or replace function public.special_care_search(p_q text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  q text := btrim(coalesce(p_q, ''));
begin
  if public.current_role() is distinct from 'admin' then raise exception 'admin only' using errcode = '42501'; end if;
  if length(q) < 2 then return '[]'::jsonb; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('code', c.code, 'name', c.name, 'zone', c.zone,
                       'salesperson', r.short_name, 'flagged', s.active is true)
             order by (upper(c.code) = upper(q)) desc, c.name)
      from (select * from public.sales_customers c
             where c.code ilike q || '%' or c.name ilike '%' || q || '%'
                or c.odoo_name ilike '%' || q || '%' or c.report_name ilike '%' || q || '%'
                or exists (select 1 from public.sales_customer_names n
                            where n.code = c.code and n.name ilike '%' || q || '%')
             order by (upper(c.code) = upper(q)) desc, c.name
             limit 20) c
      left join public.sales_reps r on r.code = c.salesperson_code
      left join public.client_special_care s on s.code = c.code), '[]'::jsonb);
end;
$$;

-- Admin: flag a client or change its flag.
create or replace function public.special_care_set(
  p_code text,
  p_no_postpone boolean,
  p_exact_quantity boolean,
  p_priority_delivery boolean,
  p_delivery_window text default null,
  p_instructions text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code text := upper(btrim(coalesce(p_code, '')));
  r public.client_special_care;
begin
  if public.current_role() is distinct from 'admin' then raise exception 'admin only' using errcode = '42501'; end if;
  if not exists (select 1 from public.sales_customers where code = v_code) then
    raise exception 'unknown client code %', v_code using errcode = '22023';
  end if;
  if not (coalesce(p_no_postpone, false) or coalesce(p_exact_quantity, false) or coalesce(p_priority_delivery, false)
          or length(btrim(coalesce(p_instructions, ''))) > 0) then
    raise exception 'choose at least one rule or write the special care' using errcode = '22023';
  end if;
  insert into public.client_special_care as s
    (code, active, no_postpone, exact_quantity, priority_delivery, delivery_window, instructions,
     created_by, created_at, updated_by, updated_at, removed_by, removed_at)
  values
    (v_code, true, coalesce(p_no_postpone, false), coalesce(p_exact_quantity, false), coalesce(p_priority_delivery, false),
     nullif(btrim(coalesce(p_delivery_window, '')), ''), nullif(btrim(coalesce(p_instructions, '')), ''),
     auth.uid(), now(), auth.uid(), now(), null, null)
  on conflict (code) do update set
    active = true,
    no_postpone = excluded.no_postpone,
    exact_quantity = excluded.exact_quantity,
    priority_delivery = excluded.priority_delivery,
    delivery_window = excluded.delivery_window,
    instructions = excluded.instructions,
    created_by = case when s.active then s.created_by else excluded.created_by end,
    created_at = case when s.active then s.created_at else excluded.created_at end,
    updated_by = excluded.updated_by,
    updated_at = now(),
    removed_by = null,
    removed_at = null
  returning * into r;
  return public.special_care_json(r);
end;
$$;

-- Admin: take the flag off (the row is kept, inactive, with who and when).
create or replace function public.special_care_remove(p_code text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.current_role() is distinct from 'admin' then raise exception 'admin only' using errcode = '42501'; end if;
  update public.client_special_care
     set active = false, removed_by = auth.uid(), removed_at = now(), updated_by = auth.uid(), updated_at = now()
   where code = upper(btrim(coalesce(p_code, ''))) and active;
end;
$$;

-- Production ticks (or un-ticks) "special care checked" on a paper that is
-- not confirmed yet.
create or replace function public.special_care_check(p_paper uuid, p_on boolean default true)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  p public.weighing_papers;
  v_code text;
begin
  if public.current_role() not in ('admin', 'production', 'factory_admin') then
    raise exception 'production only' using errcode = '42501';
  end if;
  select * into p from public.weighing_papers where id = p_paper for update;
  if not found then raise exception 'paper not found' using errcode = '22023'; end if;
  if p.status = 'confirmed' then
    raise exception 'this paper is already confirmed' using errcode = '22023';
  end if;
  v_code := public.special_care_code(p.customer_name);
  if coalesce(p_on, true) then
    if v_code is null then raise exception 'this paper is not a special care client' using errcode = '22023'; end if;
    insert into public.special_care_checks (paper_id, code, checked_by, checked_at)
    values (p.id, v_code, auth.uid(), now())
    on conflict (paper_id) do update set code = excluded.code, checked_by = excluded.checked_by, checked_at = now();
  else
    delete from public.special_care_checks where paper_id = p.id;
  end if;
  return coalesce((select jsonb_build_object('by', (select full_name from public.profiles where id = k.checked_by), 'at', k.checked_at)
                     from public.special_care_checks k where k.paper_id = p.id), 'null'::jsonb);
end;
$$;

revoke all on function public.special_care_list(), public.special_care_match(uuid[], text[]),
                       public.special_care_search(text),
                       public.special_care_set(text, boolean, boolean, boolean, text, text),
                       public.special_care_remove(text), public.special_care_check(uuid, boolean)
  from public, anon;
grant execute on function public.special_care_list(), public.special_care_match(uuid[], text[]),
                          public.special_care_search(text),
                          public.special_care_set(text, boolean, boolean, boolean, text, text),
                          public.special_care_remove(text), public.special_care_check(uuid, boolean)
  to authenticated, service_role;


-- ----------------------------------------------------------------------------
-- 5. No confirmation without the tick
-- ----------------------------------------------------------------------------
create or replace function public.special_care_confirm_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code text;
begin
  if new.status = 'confirmed' and old.status is distinct from 'confirmed' then
    v_code := public.special_care_code(new.customer_name);
    if v_code is not null and not exists (select 1 from public.special_care_checks where paper_id = new.id) then
      raise exception 'special_care_check_required'
        using errcode = 'P0001',
              detail = 'ลูกค้าดูแลพิเศษ: ติ๊ก "ตรวจการดูแลพิเศษแล้ว" ก่อนยืนยัน · Special care client: tick "special care checked" before confirming.',
              hint = v_code;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists weighing_papers_special_care_guard on public.weighing_papers;
create trigger weighing_papers_special_care_guard
  before update of status on public.weighing_papers
  for each row execute function public.special_care_confirm_guard();

-- A part 2 created already produced ("delivered later") carries its paper's tick.
create or replace function public.special_care_copy_check()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.split_from is not null and new.status = 'confirmed' then
    insert into public.special_care_checks (paper_id, code, checked_by, checked_at)
    select new.id, k.code, k.checked_by, k.checked_at
      from public.special_care_checks k
      join public.weighing_papers wp on wp.id = k.paper_id
     where wp.id <> new.id and (wp.id = new.split_from or wp.split_from = new.split_from)
     order by k.checked_at desc
     limit 1
    on conflict (paper_id) do nothing;
  end if;
  return new;
end;
$$;

drop trigger if exists weighing_papers_special_care_copy on public.weighing_papers;
create trigger weighing_papers_special_care_copy
  after insert on public.weighing_papers
  for each row execute function public.special_care_copy_check();


-- ----------------------------------------------------------------------------
-- 6. Bells when a protected client is postponed anyway
-- ----------------------------------------------------------------------------
create or replace function public.special_care_rule_text(s public.client_special_care)
returns text
language sql
immutable
as $$
  select concat_ws(' · ',
    case when s.no_postpone then 'No postpone' end,
    case when s.exact_quantity then 'Exact quantity' end,
    case when s.priority_delivery then 'Priority delivery' || coalesce(' (' || s.delivery_window || ')', '') end);
$$;

create or replace function public.special_care_postponed_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name   text;
  v_code   text;
  s        public.client_special_care;
  v_what   text;
  v_from   date;
  v_to     date;
  v_paper  uuid;
  v_hit    boolean;
  v_split  boolean := false;
begin
  if tg_table_name = 'weighing_postponements' then
    v_name  := coalesce(new.customer_name, (select customer_name from public.weighing_papers where id = new.paper_id));
    v_paper := new.paper_id;
    v_split := new.split_mode is not null;
    v_from  := coalesce(new.from_delivery_date, new.from_work_date);
    v_to    := new.to_delivery_date;
    v_what  := case when new.split_mode is not null then 'Product postponed'
                    when new.stage = 'delivery' then 'Delivery postponed'
                    else 'Production postponed' end;
  else
    v_name  := new.customer_name;
    v_paper := null;
    v_from  := new.original_date;
    v_to    := new.new_date;
    v_what  := 'Order postponed (register)';
  end if;

  v_code := public.special_care_code(v_name);
  if v_code is null then return new; end if;
  select * into s from public.client_special_care where code = v_code;

  v_hit := s.no_postpone
        or (s.exact_quantity and v_split);
  if not v_hit then return new; end if;

  perform public.notify_admins('special_care_postponed',
    '⚠ Special care client postponed — ' || public.weighing_paper_label(new.po_number, v_name),
    v_what || ' ' || coalesce(to_char(v_from, 'DD Mon'), '—') || ' → ' || coalesce(to_char(v_to, 'DD Mon'), 'no new date')
      || '. ' || public.postponement_reason_label(new.reason) || '.' || coalesce(' ' || new.note, '')
      || ' Rules: ' || public.special_care_rule_text(s) || '.',
    jsonb_build_object('code', v_code, 'source', tg_table_name, 'postponement', to_jsonb(new)),
    v_paper, v_from);
  return new;
end;
$$;

drop trigger if exists weighing_postponements_special_care on public.weighing_postponements;
create trigger weighing_postponements_special_care
  after insert on public.weighing_postponements
  for each row execute function public.special_care_postponed_notify();

drop trigger if exists order_postponements_special_care on public.order_postponements;
create trigger order_postponements_special_care
  after insert on public.order_postponements
  for each row execute function public.special_care_postponed_notify();

-- Screens refresh live when a flag or a tick changes (pace_live, Migration 041).
drop trigger if exists client_special_care_pace_live on public.client_special_care;
create trigger client_special_care_pace_live
  after insert or update or delete on public.client_special_care
  for each statement execute function public.pace_live_touch('orders');
drop trigger if exists special_care_checks_pace_live on public.special_care_checks;
create trigger special_care_checks_pace_live
  after insert or update or delete on public.special_care_checks
  for each statement execute function public.pace_live_touch('orders');

-- ============================================================================
-- Check (as admin, in the app or SQL editor with a signed-in session):
--   select public.special_care_list();
-- ============================================================================
