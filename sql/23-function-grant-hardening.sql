-- ═══════════════════════════════════════════════════════════════
-- TPN OS — Migration 23: close the new functions to anonymous callers
--
-- WHAT WAS WRONG
-- Migrations 19-22 each ended with `revoke all on function ... from anon`,
-- which looks right and does nothing. Two separate grants existed:
--
--   1. Postgres grants EXECUTE on every new function to PUBLIC by default.
--   2. Supabase additionally runs ALTER DEFAULT PRIVILEGES granting EXECUTE
--      on new functions in `public` to anon and authenticated DIRECTLY.
--
-- Revoking "from anon" removed (2) but left (1) in place, so every new RPC
-- stayed reachable at /rest/v1/rpc/<name> without signing in. The Supabase
-- security advisor flagged all eight.
--
-- No data was exposed: each of those functions checks private.can() first,
-- and an anonymous caller has no staff row, so can() returns false and they
-- got an empty set or a permission_denied exception. But an unauthenticated
-- request should not reach the function body at all. Both grants have to go.
--
-- TRIGGER FUNCTIONS
-- These were PUBLIC- and anon-executable too. Revoking EXECUTE from every
-- role does NOT stop them working: a trigger runs as the table owner, not as
-- the role that fired it. Verified after applying -- stock levels still move,
-- task status still rolls up, access changes are still audited.
--
-- Safe to re-run.
-- ═══════════════════════════════════════════════════════════════

-- ── The eight RPCs the browser calls: PUBLIC out, authenticated in ──
revoke execute on function public.my_permissions()                        from public, anon;
revoke execute on function public.access_matrix()                         from public, anon;
revoke execute on function public.staff_directory()                       from public, anon;
revoke execute on function public.task_board(boolean, uuid)               from public, anon;
revoke execute on function public.inventory_board(uuid)                   from public, anon;
revoke execute on function public.finance_summary(date, date, text, uuid)  from public, anon;
revoke execute on function public.expense_breakdown(date, date, uuid)      from public, anon;
revoke execute on function public.set_my_task_state(uuid, public.task_assignee_state, text) from public, anon;

grant execute on function public.my_permissions()                         to authenticated;
grant execute on function public.access_matrix()                          to authenticated;
grant execute on function public.staff_directory()                        to authenticated;
grant execute on function public.task_board(boolean, uuid)                to authenticated;
grant execute on function public.inventory_board(uuid)                    to authenticated;
grant execute on function public.finance_summary(date, date, text, uuid)   to authenticated;
grant execute on function public.expense_breakdown(date, date, uuid)       to authenticated;
grant execute on function public.set_my_task_state(uuid, public.task_assignee_state, text) to authenticated;

-- ── Trigger functions: callable by nobody ────────────────────
do $$
declare fn text;
begin
  foreach fn in array array[
    'trg_role_perm_floor()',
    'trg_protect_system_roles()',
    'trg_audit_access_role()',
    'trg_audit_role_permission()',
    'trg_audit_staff_override()',
    'trg_task_assignee_stamp()',
    'trg_task_assignee_rollup()',
    'trg_stock_level()',
    'trg_stock_apply()'
  ] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', fn);
  end loop;
end $$;

-- ── The one search_path left mutable in migration 20 ─────────
create or replace function public.trg_task_assignee_stamp()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.state is distinct from old.state then
    new.state_changed_at := now();
  end if;
  return new;
end $$;
revoke execute on function public.trg_task_assignee_stamp() from public, anon, authenticated;

-- ── Verify ───────────────────────────────────────────────────
-- Expect anon_can_call = false for all sixteen.
--
--   select p.proname,
--          has_function_privilege('anon', p.oid, 'EXECUTE') as anon_can_call
--     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--    where n.nspname = 'public'
--      and p.proname in ('my_permissions','access_matrix','staff_directory',
--                        'task_board','inventory_board','finance_summary',
--                        'expense_breakdown','set_my_task_state')
--    order by p.proname;
--
-- NOTE: signal_call_staff and signal_bill_request stay anon-callable on
-- purpose -- they are the customer "Call staff" and "Bill" buttons on the QR
-- menu. Two advisor warnings for those two are correct and must remain.
