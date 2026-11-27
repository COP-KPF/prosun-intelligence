-- Migration 047 — the full view and the ratio-only view. Run on a replica
-- after test_046.sql (its accounts and data), then 047.
\set ON_ERROR_STOP 1
\i sql/migrations/047_purchase_ratio_views.sql

create or replace function pg_temp.ok(cond boolean, label text) returns void language plpgsql as $$
begin if coalesce(cond, false) then raise notice 'PASS %', label; else raise exception 'FAIL %', label; end if; end $$;
create or replace function pg_temp.as_user(uid text) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', uid, 'aal', 'aal2')::text, false) $$;

do $$
declare v_full jsonb; lim jsonb; me jsonb; g jsonb; v_pct numeric; v_rev numeric; v_cost numeric;
begin
  perform pg_temp.ok((select count(*) from public.purchase_access) = 3, 'Khun Jum added: three accounts');
  perform pg_temp.ok((select count(*) from public.purchase_access where sees_revenue) = 2, 'full view: Clément and Khun Jum');

  -- Clément: full
  perform pg_temp.as_user('00000000-0000-0000-0000-0000000046a1');
  me := public.purchase_me();
  perform pg_temp.ok((me->>'access')::boolean and (me->>'sees_revenue')::boolean, 'Clément: access + revenue');
  v_full := public.purchase_ratio('2026-11-01', '2026-11-30', 'Prosun Farm');
  perform pg_temp.ok((v_full->>'full')::boolean and v_full ? 'revenue' and v_full ? 'invoiced', 'Clément gets revenue and invoiced');
  select sum((x->>2)::numeric) into v_rev from jsonb_array_elements(v_full->'revenue') x;
  select sum((x->>2)::numeric + (x->>3)::numeric) into v_cost from jsonb_array_elements(v_full->'purchases') x;

  -- Khun Jum: full
  perform pg_temp.as_user('00000000-0000-0000-0000-0000000046a2');
  perform pg_temp.ok((public.purchase_ratio('2026-11-01', '2026-11-30', 'Prosun Farm')->>'full')::boolean, 'Khun Jum gets the full view');

  -- Orawan: ratio only
  perform pg_temp.as_user('00000000-0000-0000-0000-0000000046b1');
  me := public.purchase_me();
  perform pg_temp.ok((me->>'access')::boolean and not (me->>'sees_revenue')::boolean, 'Orawan: access, no revenue');
  lim := public.purchase_ratio('2026-11-01', '2026-11-30', 'Prosun Farm', 'month');
  perform pg_temp.ok(not (lim->>'full')::boolean, 'Orawan: ratio-only answer');
  perform pg_temp.ok(not (lim ? 'revenue') and not (lim ? 'purchases') and not (lim ? 'invoiced'), 'no revenue, purchases or invoiced in her answer');
  perform pg_temp.ok(lim::text !~ (round(v_rev)::text), 'the revenue amount appears nowhere in her answer');
  v_pct := round(v_cost / v_rev * 100, 1);
  perform pg_temp.ok((lim->>'complete_before')::date <= (now() at time zone 'Asia/Bangkok')::date
                     and ((lim->>'complete_before')::date > '2026-11-25' or (lim->'total'->>0) is null),
                     'total = completed cycles only');
  perform pg_temp.ok((lim->'groups'->0->>1)::numeric = v_pct, 'her November ratio = Clément''s cost ÷ revenue (' || v_pct || '%)');
  perform pg_temp.ok((lim->'groups'->0->>6)::boolean, 'November flagged in progress');
  perform pg_temp.ok(jsonb_array_length(lim->'groups') = 1 and lim->'groups'->0->>0 = '2026-11-01', 'by month: one row, November');
  lim := public.purchase_ratio('2026-11-01', '2026-11-30', 'Prosun Farm', 'cycle');
  perform pg_temp.ok(lim->'groups'->0->>0 = '2026-11-25', 'by cycle: Wednesday 25 Nov arrival');
  perform pg_temp.ok((lim->'groups'->0->>3)::numeric = 300 and (lim->'groups'->0->>4)::numeric = 270, 'birds ordered and received per cycle');
  lim := public.purchase_ratio('2026-11-01', '2026-11-30', 'Prosun Farm', 'week');
  perform pg_temp.ok(lim->'groups'->0->>0 = '2026-11-23', 'by week: Monday 23 Nov');
  begin
    perform public.purchase_ratio('2026-11-01', '2026-11-30', 'Prosun Farm', 'year');
    raise exception 'FAIL bad group';
  exception when sqlstate '22023' then perform pg_temp.ok(true, 'unknown grouping refused'); end;
  perform set_config('role', 'authenticated', true);
  begin
    perform public.purchase_ratio_days('2026-11-01', '2026-11-30', null);
    raise exception 'FAIL helper callable';
  exception when insufficient_privilege then perform pg_temp.ok(true, 'day-by-day helper not callable from the app'); end;
  perform pg_temp.ok(not (public.purchase_ratio('2026-11-01', '2026-11-30', 'Prosun Farm', 'cycle')->>'full')::boolean, 'ratio-only also as the app role');
  perform set_config('role', 'postgres', true);

  -- Jane: nothing
  perform pg_temp.as_user('00000000-0000-0000-0000-0000000046c1');
  perform pg_temp.ok(not (public.purchase_me()->>'access')::boolean, 'Jane: no access');
end $$;
