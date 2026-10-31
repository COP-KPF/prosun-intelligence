-- ============================================================================
-- Migration 023 — change notifications also cover product and ordered qty
-- ============================================================================
-- Written 31 Oct 2026. The weighing check screen now lets production correct
-- every part of a line (product name, ordered quantity, what was written,
-- actual kg), not only the actual kg. Migration 021 notifies management when
-- a CONFIRMED paper is reopened and confirmed again, listing the weights
-- before → after. This extends that comparison to the product name and the
-- ordered quantity, and writes only what actually changed, e.g.
--   "ขาไก่: ordered 15 กก → 16 กก; Wings 4.60 → 4.40 kg".
-- Nothing else changes. Run order: after 022. Safe to re-run.
-- ============================================================================

create or replace function public.weighing_lines_diff(p_before jsonb, p_paper uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with b as (
    select (e->>'line_no')::int as n, e->>'description' as d, e->>'ordered_text' as o,
           (e->>'actual_kg')::numeric as kg
    from jsonb_array_elements(coalesce(p_before->'lines', '[]'::jsonb)) e
  ), a as (
    select line_no as n, description as d, ordered_text as o, actual_kg as kg
    from public.weighing_lines where paper_id = p_paper
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'line_no', coalesce(a.n, b.n),
           'description', coalesce(a.d, b.d),
           'description_before', case when a.n is not null and b.n is not null and a.d is distinct from b.d then b.d end,
           'ordered_before', case when a.n is not null and b.n is not null and a.o is distinct from b.o then coalesce(b.o, '—') end,
           'ordered_after',  case when a.n is not null and b.n is not null and a.o is distinct from b.o then coalesce(a.o, '—') end,
           'before_kg', b.kg, 'after_kg', a.kg,
           'kg_changed', a.n is not null and b.n is not null and a.kg is distinct from b.kg,
           'change', case when b.n is null then 'added' when a.n is null then 'removed' else 'changed' end)
         order by coalesce(a.n, b.n)), '[]'::jsonb)
  from b full join a on a.n = b.n
  where b.n is null or a.n is null or a.kg is distinct from b.kg
     or a.d is distinct from b.d or a.o is distinct from b.o;
$$;

revoke all on function public.weighing_lines_diff(jsonb, uuid) from public, anon, authenticated;

create or replace function public.weighing_diff_text(p_lines jsonb, p_fields jsonb)
returns text
language sql
immutable
as $$
  select nullif(concat_ws('; ',
    (select string_agg(
       case e->>'change'
         when 'added'   then 'added: ' || coalesce(nullif(e->>'description', ''), 'line ' || (e->>'line_no')) || ' ' || public.weighing_fmt_kg((e->>'after_kg')::numeric) || ' kg'
         when 'removed' then 'removed: ' || coalesce(nullif(e->>'description', ''), 'line ' || (e->>'line_no')) || ' ' || public.weighing_fmt_kg((e->>'before_kg')::numeric) || ' kg'
         else coalesce(nullif(e->>'description', ''), 'line ' || (e->>'line_no')) || ': '
              || concat_ws(', ',
                   case when e->>'description_before' is not null then '(was “' || (e->>'description_before') || '”)' end,
                   case when e->>'ordered_before' is not null then 'ordered ' || (e->>'ordered_before') || ' → ' || (e->>'ordered_after') end,
                   case when (e->>'kg_changed')::boolean is distinct from false
                             and ((e->>'before_kg') is distinct from (e->>'after_kg'))
                        then public.weighing_fmt_kg((e->>'before_kg')::numeric) || ' → ' || public.weighing_fmt_kg((e->>'after_kg')::numeric) || ' kg' end)
       end, '; ' order by (e->>'line_no')::int)
     from jsonb_array_elements(p_lines) e),
    (select string_agg(
       case e->>'field' when 'po_number' then 'PO' when 'customer_name' then 'customer'
                        when 'delivery_date' then 'delivery date' else e->>'field' end
       || ' ' || coalesce(e->>'before', '—') || ' → ' || coalesce(e->>'after', '—'), '; ')
     from jsonb_array_elements(p_fields) e)
  ), '');
$$;
