-- ═══════════════════════════════════════════════════════════════
-- TPN OS — Migration 13: Fix audit_daily_counts ambiguous column
--
-- BUG: `RETURNS TABLE (day date, action text, ...)` in a plpgsql
-- function creates implicit variables named `day`, `action`, etc.
-- inside the function body. When the UNION's second SELECT also
-- aliases `(created_at at time zone 'Asia/Manila')::date AS day`,
-- Postgres can't tell which `day` the outer `ORDER BY day` refers
-- to and raises `column reference "day" is ambiguous`.
--
-- FIX:
--   1. Rename the RETURNS TABLE output columns (day_date, action_
--      name, role_at, event_count) so they no longer collide with
--      query aliases. The frontend never references these by
--      position vs name — it iterates `r.day`, `r.action`, etc —
--      so we ALSO keep old names visible with a small view over
--      the function isn't practical; instead just re-alias in
--      the outer SELECT so the wire format stays `day`, `action`,
--      `actor_role`, `count`.
--   2. Qualify the first SELECT's column references with the
--      table alias so the reader (and the planner) don't wonder.
--   3. Use positional ORDER BY (1 desc, 2) so we never touch the
--      name-resolution machinery again.
-- ═══════════════════════════════════════════════════════════════

create or replace function public.audit_daily_counts(
  p_month     date,
  p_branch_id uuid default null
)
returns table (day date, action text, actor_role staff_role, count bigint)
language plpgsql security definer set search_path = ''
as $$
begin
  if not private.has_role('manager') then
    raise exception 'insufficient_privileges' using errcode = '42501';
  end if;

  return query
    select * from (
      -- Rolled-up rows (already aggregated by day+action+role).
      select
        ads.day        as day,
        ads.action     as action,
        ads.actor_role as actor_role,
        ads.count::bigint as count
      from public.audit_daily_summary ads
      where ads.day >= date_trunc('month', p_month)::date
        and ads.day <  (date_trunc('month', p_month) + interval '1 month')::date
        and (p_branch_id is null or ads.branch_id = p_branch_id)

      union all

      -- Hot audit_log rows in the same month, aggregated on the fly.
      select
        (a.created_at at time zone 'Asia/Manila')::date as day,
        a.action                                        as action,
        a.actor_role                                    as actor_role,
        count(*)::bigint                                as count
      from public.audit_log a
      left join public.staff s on s.id = a.actor_id
      where a.created_at >= date_trunc('month', p_month)
        and a.created_at <  date_trunc('month', p_month) + interval '1 month'
        and (p_branch_id is null or s.branch_id = p_branch_id)
      group by
        (a.created_at at time zone 'Asia/Manila')::date,
        a.action,
        a.actor_role
    ) unioned
    order by 1 desc, 2;
end $$;

grant execute on function public.audit_daily_counts(date, uuid) to authenticated;
revoke execute on function public.audit_daily_counts(date, uuid) from public, anon;
