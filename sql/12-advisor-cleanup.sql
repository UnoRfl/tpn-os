-- ═══════════════════════════════════════════════════════════════
-- TPN OS — Migration 12: Supabase advisor cleanup
--
-- Fixes every finding from the Security Advisor:
--
--   ERROR (1):
--     - v_audit_log_all was SECURITY DEFINER → switched to
--       SECURITY INVOKER so RLS on the underlying tables is enforced
--       against the *querying* user, not the view creator.
--
--   WARN — trigger functions callable via RPC (9):
--     - Every trg_notify_* and trg_order_*_recompute is a trigger
--       function that should NEVER be reachable via /rest/v1/rpc/.
--       Revoke EXECUTE from public, anon, authenticated. Triggers
--       still fire because Postgres runs them as the table owner
--       independent of the EXECUTE grant.
--
--   WARN — staff-only SECURITY DEFINER exposed to anon (2):
--     - ack_bill_request / ack_call_staff acknowledge that STAFF
--       have responded — should never be callable by an unauth
--       user. Revoke from anon.
--
--   WARN — search_path mutable on public.force_delete_storage_objects:
--     - Lock the function's search_path to '' so it can't be hijacked
--       via a search-path-based privilege escalation. Body is not
--       touched (this is a Supabase-provided helper).
--
--   WARN — anon can call signal_call_staff / signal_bill_request:
--     - INTENTIONAL. These two RPCs are the "Call Staff" and
--       "Bill Please" buttons on the customer-facing QR menu — anon
--       *must* be able to call them. The functions defensively
--       validate the table_id and enforce the 90-second cooldown
--       introduced in migration 11. Warning left in place so the
--       decision stays audible in future reviews.
--
--   WARN — auth_leaked_password_protection is disabled:
--     - CANNOT be fixed in SQL. Uno needs to toggle it in the
--       Supabase dashboard:
--         Authentication → Providers → Email
--         → enable "Prevent use of leaked passwords"
--       (Supabase checks against HaveIBeenPwned on signup / password
--       change. Zero-cost, no PII sent — only a hash prefix.)
--
-- Safe to run repeatedly.
-- ═══════════════════════════════════════════════════════════════

-- ═══════════════════════════════════════════════════════════════
-- 1. FIX ERROR: v_audit_log_all SECURITY DEFINER → INVOKER
-- ═══════════════════════════════════════════════════════════════
-- Postgres 15+ (Supabase is 15+) supports the security_invoker
-- storage parameter on views. Setting it to true means queries
-- against the view run with the CALLER's privileges + RLS, which
-- is the safe default.
do $$ begin
  if to_regclass('public.v_audit_log_all') is not null then
    execute 'alter view public.v_audit_log_all set (security_invoker = true)';
  end if;
end $$;

-- ═══════════════════════════════════════════════════════════════
-- 2. LOCK DOWN trg_notify_* AND trg_order_*_recompute
-- These are trigger functions — they should never be RPC-callable.
-- Revoking EXECUTE does NOT stop them from firing on triggers;
-- Postgres executes triggers as the table owner regardless.
-- ═══════════════════════════════════════════════════════════════
do $$
declare
  fn_sig text;
  fns text[] := array[
    'trg_notify_attendance_correction()',
    'trg_notify_inquiry_new()',
    'trg_notify_message_new()',
    'trg_notify_order_new()',
    'trg_notify_order_status()',
    'trg_notify_staff_pending()',
    'trg_notify_table_signal()',
    'trg_order_adjustments_recompute()',
    'trg_order_items_recompute()'
  ];
begin
  foreach fn_sig in array fns loop
    -- Only revoke if the function actually exists in this DB.
    -- Splitting on '(' to get the bare name for the pg_proc lookup.
    if exists (
      select 1 from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public'
         and p.proname = split_part(fn_sig, '(', 1)
    ) then
      execute format('revoke execute on function public.%s from public, anon, authenticated', fn_sig);
    end if;
  end loop;
end $$;

-- ═══════════════════════════════════════════════════════════════
-- 3. STAFF-ONLY ACK FUNCTIONS
-- ack_call_staff / ack_bill_request are for STAFF acknowledging
-- a customer signal. Anon should not be able to silence its own
-- call. Revoke from anon; authenticated still has it (function
-- body should still gate on has_role('dining'|'kitchen'|'manager')
-- but this belt-and-suspenders is cheap).
-- ═══════════════════════════════════════════════════════════════
do $$ begin
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'ack_call_staff') then
    execute 'revoke execute on function public.ack_call_staff(uuid) from anon, public';
  end if;
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'ack_bill_request') then
    execute 'revoke execute on function public.ack_bill_request(uuid) from anon, public';
  end if;
end $$;

-- ═══════════════════════════════════════════════════════════════
-- 4. TIGHTEN MAINTENANCE FUNCTIONS
-- notifications_prune is a cron / manual job. Nobody should call
-- it from a public endpoint. Revoke from all except postgres/
-- service_role (which retain access implicitly).
-- ═══════════════════════════════════════════════════════════════
do $$ begin
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'notifications_prune') then
    execute 'revoke execute on function public.notifications_prune() from public, anon, authenticated';
  end if;
end $$;

-- ═══════════════════════════════════════════════════════════════
-- 5. force_delete_storage_objects — lock search_path
-- Body untouched (this is a Supabase-generated helper). We only
-- pin its search_path so a role-mutable search_path can't be used
-- to swap in a shadow function or table.
-- ═══════════════════════════════════════════════════════════════
do $$ begin
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'force_delete_storage_objects') then
    execute 'alter function public.force_delete_storage_objects(uuid) set search_path = ''''';
    -- Also revoke from anon so this admin-tier op can't be RPC'd.
    execute 'revoke execute on function public.force_delete_storage_objects(uuid) from public, anon, authenticated';
  end if;
end $$;

-- ═══════════════════════════════════════════════════════════════
-- 6. audit_log_archive_old — sanity re-revoke (in case migration
--    11 didn't fully take on some environments).
-- ═══════════════════════════════════════════════════════════════
do $$ begin
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'audit_log_archive_old') then
    -- Keep for authenticated (manager check is inside the function).
    execute 'revoke execute on function public.audit_log_archive_old(integer) from public, anon';
  end if;
end $$;

-- ═══════════════════════════════════════════════════════════════
-- 7. audit_daily_counts — manager+ only, but stays callable by
--    authenticated so the History tab can use it. The function
--    body already enforces has_role('manager').
-- ═══════════════════════════════════════════════════════════════
do $$ begin
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'audit_daily_counts') then
    execute 'revoke execute on function public.audit_daily_counts(date, uuid) from public, anon';
  end if;
end $$;

-- Done. Re-run the advisor after applying:
--   ERROR count → 0
--   WARN count  → 3 (leaked-password toggle + the two intentional
--                    anon-signal RPCs. All expected.)
