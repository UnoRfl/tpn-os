-- ═══════════════════════════════════════════════════════════════
-- TPN OS — Migration 17: Hardening + advisor cleanup
--
-- Run this AFTER sql/16-discounts.sql. Both are ordinary migrations —
-- no enum values are added, so they can be pasted together if you like,
-- but running them one at a time makes a failure easier to read.
--
-- Nothing here changes a feature or a screen. It closes holes and adds
-- audit trails. Every item was verified against the live database
-- (project xjlqfpnzobfqxetgkkai) before being written.
--
-- WHAT IT DOES
--   1. Removes the dead first-generation discount functions
--   2. Locks orders.total / orders.subtotal to the recompute path
--   3. Puts the missing role check on audit_log_archive_old()
--   4. Revokes TRUNCATE from anon and authenticated on every table
--   5. Stops trigger functions being callable as REST endpoints
--   6. Lets the dining-floor screen clear the signals it displays
--   7. Audits cancel_void_request
--   8. Stops un-voiding an item on a closed order
--   9. Audits every financially significant change to an order
-- ═══════════════════════════════════════════════════════════════


-- ═══════════════════════════════════════════════════════════════
-- 1. REMOVE THE DEAD FIRST-GENERATION DISCOUNT FUNCTIONS
--
-- Two generations of the discount system were live at the same time:
--
--   Gen 1  apply_discount(order, preset, reference, custom_value)
--          remove_discount(order)
--          → wrote orders.discount + orders.total DIRECTLY, off the
--            discount_presets table.
--
--   Gen 2  apply_discount(order, template, id_ref)
--          remove_discount(applied_id, reason)
--          → inserts into applied_discounts, which recomputes
--            orders.discount_amount → total. This is what the app calls.
--
-- Gen 1 is not merely unused, it is broken: its audit insert targets a
-- column called `details`, and audit_log has no such column — so any
-- call raises and rolls back. It also fought Gen 2 over the same order
-- totals, writing `discount` and `total` behind the recompute chain's
-- back.
--
-- Verified before dropping: applied_discounts has 0 rows, no order has
-- a non-zero discount or discount_amount, and nothing depends on these
-- two functions. Dropping them is safe.
--
-- The discount_presets table and the orders.discount* columns are left
-- in place — dropping columns is riskier than leaving them empty. They
-- are dead weight, not a hazard. See the note at the end of this file.
-- ═══════════════════════════════════════════════════════════════
drop function if exists public.apply_discount(uuid, uuid, text, numeric);
drop function if exists public.remove_discount(uuid);


-- ═══════════════════════════════════════════════════════════════
-- 2. LOCK orders.total AND orders.subtotal
--
-- This was the most serious finding in the review. orders_staff_update
-- gates on branch alone, and trg_guard_order_update covered status,
-- discount_amount and service_charge — but not total or subtotal. So:
--
--     update orders set total = 1 where id = '…'
--
-- persisted, for every human role from dining upward. That is the exact
-- "pay ₱1 for a ₱1500 order" attack sql/11 was written to close; it was
-- simply reachable by writing the total instead of adding a cheap line.
--
-- A role check is the wrong tool here, because the legitimate writer of
-- those two columns is private.recompute_order_totals(), which runs as
-- a side effect of a DINING staff member adding an item. Guarding by
-- role would break ordinary service.
--
-- So the recompute function announces itself with a transaction-local
-- flag, and the guard trusts only that. No client can set the flag:
-- set_config lives in pg_catalog and PostgREST only exposes functions
-- in the public schema.
-- ═══════════════════════════════════════════════════════════════
create or replace function private.recompute_order_totals(p_order_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  new_subtotal numeric(10,2);
  disc         numeric(10,2);
  svc          numeric(10,2);
begin
  select coalesce(sum(total_price), 0) into new_subtotal
    from public.order_items
   where order_id = p_order_id and voided_at is null;

  select coalesce(discount_amount, 0), coalesce(service_charge, 0)
    into disc, svc
    from public.orders where id = p_order_id;

  -- Announce that the write below is the authorised one, then take it
  -- straight back down so the permission cannot leak to a later
  -- statement in the same transaction.
  perform set_config('tpn.recompute', 'on', true);

  update public.orders
     set subtotal = new_subtotal,
         total    = greatest(0, new_subtotal - coalesce(disc,0) + coalesce(svc,0))
   where id = p_order_id;

  perform set_config('tpn.recompute', 'off', true);
end $$;

revoke execute on function private.recompute_order_totals(uuid) from public, anon, authenticated;

create or replace function public.trg_guard_order_update()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  r public.staff_role;
begin
  r := private.my_role();

  -- Money columns are derived, never typed in. The only legitimate
  -- writer is private.recompute_order_totals(), which flags itself.
  -- This check runs before the null-role bail-out below on purpose:
  -- it applies to the anonymous checkout path too.
  if (new.total    is distinct from old.total
      or new.subtotal is distinct from old.subtotal)
     and coalesce(current_setting('tpn.recompute', true), 'off') <> 'on' then
    raise exception
      'totals_are_derived: change the order items or the discount instead'
      using errcode = '42501';
  end if;

  -- No staff row = the anonymous customer checkout path. RLS has
  -- already scoped that; nothing further applies.
  if r is null then
    return new;
  end if;

  -- Nobody below manager cancels an order. That is exactly what a
  -- whole-order void request is for.
  if new.status = 'cancelled'
     and old.status is distinct from 'cancelled'
     and not private.has_role('manager') then
    raise exception 'cancel_requires_manager' using errcode = '42501';
  end if;

  -- Discounts are a supervisor+ decision.
  if not private.has_role('supervisor')
     and (coalesce(new.discount_amount, 0) is distinct from coalesce(old.discount_amount, 0)
          or coalesce(new.service_charge, 0) is distinct from coalesce(old.service_charge, 0)) then
    raise exception 'adjustments_require_supervisor' using errcode = '42501';
  end if;

  -- Payment fields are a supervisor+ decision too. Recording that a
  -- ₱1500 check was paid in cash is a cash-handling act.
  if not private.has_role('supervisor')
     and (new.payment_status is distinct from old.payment_status
          or new.payment_reference is distinct from old.payment_reference) then
    raise exception 'payment_requires_supervisor' using errcode = '42501';
  end if;

  -- Screens may advance the workflow status and nothing else.
  if r in ('kitchen_display', 'dine_in_display') then
    if (to_jsonb(new) - '{status,confirmed_at,ready_at,served_at,updated_at}'::text[])
       is distinct from
       (to_jsonb(old) - '{status,confirmed_at,ready_at,served_at,updated_at}'::text[])
    then
      raise exception 'display_may_only_advance_status' using errcode = '42501';
    end if;
    if new.status in ('completed', 'cancelled')
       and old.status is distinct from new.status then
      raise exception 'display_cannot_close_orders' using errcode = '42501';
    end if;
  end if;

  return new;
end $$;

-- Break-glass, for a DBA fixing corrupt data by hand and nothing else:
--   alter table public.orders disable trigger trg_guard_order_update;
--   <the one repair statement>
--   alter table public.orders enable  trigger trg_guard_order_update;


-- ═══════════════════════════════════════════════════════════════
-- 3. THE MISSING GUARD ON audit_log_archive_old()
--
-- Its two siblings (audit_daily_counts, sales_performance_month) both
-- check manager+. This one did not, and sql/12 re-granted EXECUTE to
-- `authenticated` with the comment "manager check is inside the
-- function" — the check did not exist. Because the retention window is
-- caller-supplied, ANY signed-in account, including a wall screen,
-- could flush the entire live audit log into the archive:
--
--     rpc('audit_log_archive_old', { p_days_to_keep: -1 })
--
-- The rows survive in audit_log_archive, but the portal's Audit Log tab
-- reads the hot table, so it would go blank. Concealment, not deletion,
-- which is bad enough for an audit trail.
--
-- Body is unchanged apart from the guard and a floor on the window.
-- ═══════════════════════════════════════════════════════════════
create or replace function public.audit_log_archive_old(p_days_to_keep int default 31)
returns table (rolled_up int, archived int, deleted int)
language plpgsql security definer set search_path = ''
as $$
declare
  cutoff timestamptz;
  n_roll int;
  n_arch int;
  n_del  int;
begin
  if not private.has_role('manager') then
    raise exception 'insufficient_privileges' using errcode = '42501';
  end if;
  -- A negative or tiny window would archive everything, including today.
  if p_days_to_keep is null or p_days_to_keep < 7 then
    raise exception 'retention_window_too_small' using errcode = '22023';
  end if;

  cutoff := now() - (p_days_to_keep::text || ' days')::interval;

  insert into public.audit_daily_summary (day, branch_id, action, actor_role, count, updated_at)
  select
    (a.created_at at time zone 'Asia/Manila')::date as day,
    s.branch_id, a.action, a.actor_role, count(*) as cnt, now()
  from public.audit_log a
  left join public.staff s on s.id = a.actor_id
  where a.created_at < cutoff
  group by 1, 2, 3, 4
  on conflict (day, branch_id, action, actor_role)
    do update set count = excluded.count, updated_at = excluded.updated_at;
  get diagnostics n_roll = row_count;

  insert into public.audit_log_archive
    (id, actor_id, actor_role, action, entity_type, entity_id,
     before_state, after_state, metadata, ip_address, user_agent, created_at)
  select
     id, actor_id, actor_role, action, entity_type, entity_id,
     before_state, after_state, metadata, ip_address, user_agent, created_at
  from public.audit_log
  where created_at < cutoff
  on conflict (id) do nothing;
  get diagnostics n_arch = row_count;

  delete from public.audit_log where created_at < cutoff;
  get diagnostics n_del = row_count;

  rolled_up := n_roll;
  archived  := n_arch;
  deleted   := n_del;
  return next;
end $$;

revoke execute on function public.audit_log_archive_old(int) from public, anon;
grant   execute on function public.audit_log_archive_old(int) to authenticated;

-- The month index sql/11 meant to create never existed: its expression used
-- date_trunc() on a timestamptz, which is STABLE and therefore cannot be
-- indexed, so that one statement failed. Pinning the zone makes it
-- IMMUTABLE. (sql/11 is fixed at source too, for rebuilds.)
create index if not exists idx_audit_arch_month
  on public.audit_log_archive ((date_trunc('month', created_at at time zone 'UTC')));


-- ═══════════════════════════════════════════════════════════════
-- 4. REVOKE TRUNCATE EVERYWHERE
--
-- Supabase's default `grant all on all tables in schema public` hands
-- TRUNCATE to both anon and authenticated, and TRUNCATE bypasses RLS
-- completely. On this database that grant was still in place on 15+
-- tables including staff, branches, menu_items, attendance, messages,
-- schedules and audit_log_archive.
--
-- Practical exposure is limited — PostgREST has no TRUNCATE verb, so
-- the anon key alone cannot reach it. But it is a grant that should
-- never have been there, it defeats the "no direct writes" design of
-- order_items and void_requests, and it costs nothing to remove.
-- ═══════════════════════════════════════════════════════════════
revoke truncate on all tables in schema public from anon, authenticated;

-- And stop the default from re-granting it to future tables.
-- `alter default privileges` without FOR ROLE only edits the CURRENT
-- role's defaults. The Supabase SQL Editor runs as `postgres`, which is
-- what creates tables here, so that covers it — but cover supabase_admin
-- too in case something else does the DDL. Wrapped because membership in
-- that role is not guaranteed.
alter default privileges in schema public revoke truncate on tables from anon, authenticated;
do $$ begin
  execute 'alter default privileges for role supabase_admin in schema public '
          'revoke truncate on tables from anon, authenticated';
exception when others then
  raise notice 'skipped supabase_admin default privileges: %', sqlerrm;
end $$;


-- ═══════════════════════════════════════════════════════════════
-- 5. TRIGGER FUNCTIONS ARE NOT REST ENDPOINTS
--
-- Every function returning `trigger` in the public schema is published
-- by PostgREST as /rest/v1/rpc/<name> unless EXECUTE is revoked. They
-- cannot do damage (Postgres refuses a trigger function called outside
-- a trigger) but they are noise in the API surface and each one raises
-- a Supabase advisor warning.
--
-- sql/12 did this from a hardcoded list, which then went stale twice.
-- This does it by shape, so it also covers anything added later.
-- ═══════════════════════════════════════════════════════════════
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure::text as sig
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.prorettype = 'pg_catalog.trigger'::regtype
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', r.sig);
  end loop;
end $$;

-- Accepted, deliberate exceptions — these two MUST stay anon-callable.
-- They are how a customer at a table taps "Call staff" and "Bill" with
-- no login. Both take only a table id and are rate-limited to one per
-- 90 seconds per table. The Supabase advisor will keep flagging them as
-- "Public Can Execute SECURITY DEFINER Function"; that is expected and
-- correct — do not "fix" it or the customer buttons stop working.
--
-- Note: both return boolean, not trigger, so the loop above never
-- touched them. These two grants are a no-op safety net, kept so the
-- intent is explicit in the file.
grant execute on function public.signal_call_staff(uuid)                to anon, authenticated;
grant execute on function public.signal_bill_request(uuid, text, numeric) to anon, authenticated;


-- ═══════════════════════════════════════════════════════════════
-- 6. LET THE FLOOR SCREEN CLEAR THE SIGNALS IT DISPLAYS
--
-- ack_call_staff and ack_bill_request required has_role('dining'), and
-- dine_in_display sits BELOW dining in the enum. So the one screen
-- mounted where customers press "Call staff" could show the alert but
-- not dismiss it — and the 90-second cooldown then keys off a timestamp
-- nobody on that surface could reset. Almost certainly unintended.
-- ═══════════════════════════════════════════════════════════════
create or replace function public.ack_call_staff(p_table_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  -- coalesce matters: my_role() is NULL for a JWT with no staff row, and
  -- `false or null` is NULL, which `if not ... then` does NOT act on. The
  -- sql/04 version was safe only because it had a single condition.
  if not (private.has_role('dining')
          or coalesce(private.my_role() = 'dine_in_display', false)) then
    raise exception 'insufficient_privileges' using errcode = '42501';
  end if;
  -- Branch scope: sql/04 never had one, so any dining account could clear
  -- another branch's table signal.
  if not private.has_role('admin') and not exists (
       select 1 from public.restaurant_tables t
        where t.id = p_table_id and t.branch_id = private.my_branch()) then
    raise exception 'wrong_branch' using errcode = '42501';
  end if;
  update public.restaurant_tables
     set call_staff_at = null
   where id = p_table_id;
end $$;

create or replace function public.ack_bill_request(p_table_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not (private.has_role('dining')
          or coalesce(private.my_role() = 'dine_in_display', false)) then
    raise exception 'insufficient_privileges' using errcode = '42501';
  end if;
  if not private.has_role('admin') and not exists (
       select 1 from public.restaurant_tables t
        where t.id = p_table_id and t.branch_id = private.my_branch()) then
    raise exception 'wrong_branch' using errcode = '42501';
  end if;
  update public.restaurant_tables
     set bill_requested_at   = null,
         bill_payment_method = null,
         bill_total          = null
   where id = p_table_id;
end $$;

revoke execute on function public.ack_call_staff(uuid)   from public, anon;
revoke execute on function public.ack_bill_request(uuid) from public, anon;
grant   execute on function public.ack_call_staff(uuid)   to authenticated;
grant   execute on function public.ack_bill_request(uuid) to authenticated;


-- ═══════════════════════════════════════════════════════════════
-- 7. AUDIT cancel_void_request
--
-- It was the only one of the four void-request mutators that logged
-- nothing and notified nobody. A manager could withdraw another staff
-- member's pending request with no trace but a mutable column.
-- ═══════════════════════════════════════════════════════════════
create or replace function public.cancel_void_request(p_request_id uuid)
returns public.void_requests
language plpgsql security definer set search_path = ''
as $$
declare
  req      public.void_requests%rowtype;
  by_other boolean;
begin
  select * into req from public.void_requests where id = p_request_id for update;
  if not found then
    raise exception 'request_not_found' using errcode = 'P0002';
  end if;

  by_other := req.requested_by is distinct from auth.uid();
  if by_other then
    if not private.has_role('manager') then
      raise exception 'insufficient_privileges' using errcode = '42501';
    end if;
    if not private.has_role('admin') and req.branch_id <> private.my_branch() then
      raise exception 'wrong_branch' using errcode = '42501';
    end if;
  end if;
  if req.status <> 'pending' then
    raise exception 'request_not_pending' using errcode = '23514';
  end if;

  update public.void_requests
     set status      = 'cancelled',
         reviewed_by = auth.uid(),
         reviewed_at = now()
   where id = p_request_id
  returning * into req;

  insert into public.audit_log
    (actor_id, actor_role, action, entity_type, entity_id, after_state, metadata)
  values
    (auth.uid(), private.my_role(), 'void_request.cancel', 'void_request', req.id,
     jsonb_build_object('status', 'cancelled', 'withdrawn_by_other', by_other),
     jsonb_build_object('order_id', req.order_id, 'requested_by', req.requested_by,
                        'item_name', req.item_name, 'scope', req.scope));

  -- If a manager withdrew someone else's request, tell them.
  if by_other and req.requested_by is not null then
    perform public.notify_push(
      req.requested_by, req.branch_id, 'void_request_cancelled',
      'Void request withdrawn',
      coalesce(req.item_name, 'Order ' || coalesce(req.order_number, ''))
        || ' — a manager withdrew your request.',
      null, 'void_request', req.id, 'normal'
    );
  end if;

  return req;
end $$;

revoke execute on function public.cancel_void_request(uuid) from public, anon;
grant   execute on function public.cancel_void_request(uuid) to authenticated;


-- ═══════════════════════════════════════════════════════════════
-- 8. DON'T UN-VOID ONTO A CLOSED ORDER
--
-- void_order_item refuses completed and cancelled orders. Its inverse
-- did not, so a manager could restore an item onto a closed check and
-- silently change its total after the fact.
-- ═══════════════════════════════════════════════════════════════
create or replace function public.unvoid_order_item(p_item_id uuid)
returns public.order_items
language plpgsql security definer set search_path = ''
as $$
declare
  item      public.order_items%rowtype;
  order_row public.orders%rowtype;
begin
  if not private.has_role('manager') then
    raise exception 'insufficient_privileges' using errcode = '42501';
  end if;

  select * into item from public.order_items where id = p_item_id;
  if not found then raise exception 'item_not_found'; end if;
  if item.voided_at is null then raise exception 'not_voided'; end if;

  select * into order_row from public.orders where id = item.order_id;
  if not private.has_role('admin') and order_row.branch_id <> private.my_branch() then
    raise exception 'wrong_branch';
  end if;
  -- ADDED: parity with void_order_item.
  if order_row.status in ('completed','cancelled') then
    raise exception 'order_terminal' using errcode = '23514';
  end if;

  update public.order_items
     set voided_at = null, voided_by = null, void_reason = null
   where id = p_item_id
  returning * into item;

  insert into public.audit_log
    (actor_id, actor_role, action, entity_type, entity_id, metadata)
  values
    (auth.uid(), private.my_role(),
     'order_item.unvoid', 'order_item', item.id,
     jsonb_build_object('order_id', item.order_id));

  return item;
end $$;

revoke execute on function public.unvoid_order_item(uuid) from public, anon;
grant   execute on function public.unvoid_order_item(uuid) to authenticated;


-- ═══════════════════════════════════════════════════════════════
-- 8b. MAKE THE FAILED-ORDER ROLLBACK ACTUALLY WORK
--
-- TPN.createOrder() inserts the order header, then the lines, and on a
-- line failure it deletes the header again. There is no DELETE policy
-- on orders, so that cleanup silently removed zero rows — leaving an
-- orphan order with no items, a ₱0 total and an order number burnt.
--
-- This policy is deliberately narrow: an order can only be deleted if
-- it has no order_items at all. Every genuine order has lines, so the
-- only thing this can reach is exactly the junk the rollback is trying
-- to clear.
-- ═══════════════════════════════════════════════════════════════
drop policy if exists orders_cleanup_empty on public.orders;
create policy orders_cleanup_empty on public.orders
  for delete to anon, authenticated
  using (
    not exists (select 1 from public.order_items oi where oi.order_id = orders.id)
  );

grant delete on public.orders to anon, authenticated;


-- ═══════════════════════════════════════════════════════════════
-- 9. AUDIT THE ORDER LIFECYCLE
--
-- Nothing recorded order creation, cancellation, completion or payment.
-- trg_guard_order_update BLOCKS unauthorised changes but said nothing
-- about authorised ones, so there was no way to answer "who closed this
-- check, and for how much?".
--
-- Deliberately narrow: only the financially significant transitions, so
-- this does not write four rows per order just for moving a ticket
-- along the kitchen lanes.
-- ═══════════════════════════════════════════════════════════════
create or replace function public.trg_audit_order_money()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  changed text[] := '{}';
begin
  if new.status is distinct from old.status
     and new.status in ('completed', 'cancelled') then
    changed := changed || 'status'::text;
  end if;
  if coalesce(new.total,0) is distinct from coalesce(old.total,0) then
    changed := changed || 'total'::text;
  end if;
  if coalesce(new.discount_amount,0) is distinct from coalesce(old.discount_amount,0) then
    changed := changed || 'discount_amount'::text;
  end if;
  if coalesce(new.service_charge,0) is distinct from coalesce(old.service_charge,0) then
    changed := changed || 'service_charge'::text;
  end if;
  if new.payment_status is distinct from old.payment_status
     or new.payment_method is distinct from old.payment_method then
    changed := changed || 'payment'::text;
  end if;

  if array_length(changed, 1) is null then
    return new;
  end if;

  insert into public.audit_log
    (actor_id, actor_role, action, entity_type, entity_id,
     before_state, after_state, metadata)
  values
    (auth.uid(), private.my_role(),
     case when new.status = 'cancelled' and old.status is distinct from 'cancelled'
            then 'order.cancel'
          when new.status = 'completed' and old.status is distinct from 'completed'
            then 'order.complete'
          else 'order.money_change' end,
     'order', new.id,
     jsonb_build_object('status', old.status, 'total', old.total,
                        'discount_amount', old.discount_amount,
                        'service_charge', old.service_charge,
                        'payment_status', old.payment_status,
                        'payment_method', old.payment_method),
     jsonb_build_object('status', new.status, 'total', new.total,
                        'discount_amount', new.discount_amount,
                        'service_charge', new.service_charge,
                        'payment_status', new.payment_status,
                        'payment_method', new.payment_method),
     jsonb_build_object('order_number', new.order_number,
                        'branch_id', new.branch_id,
                        'changed', changed,
                        'cancel_reason', new.cancel_reason));
  return new;
end $$;

drop trigger if exists trg_audit_order_money on public.orders;
create trigger trg_audit_order_money
  after update on public.orders
  for each row execute function public.trg_audit_order_money();

revoke execute on function public.trg_audit_order_money() from public, anon, authenticated;


-- ═══════════════════════════════════════════════════════════════
-- VERIFY
-- ═══════════════════════════════════════════════════════════════
-- Signed in as a dining account, all of these must FAIL:
--   update public.orders set total = 1 where id = '<any>';
--     → totals_are_derived
--   update public.orders set status = 'cancelled' where id = '<any>';
--     → cancel_requires_manager
--   update public.orders set discount_amount = 500 where id = '<any>';
--     → adjustments_require_supervisor
--
-- And these must still WORK for a dining account:
--   insert into public.order_items (...);            -- totals recompute
--   update public.orders set status = 'preparing' where id = '<any>';
--
-- As any account, this must fail:
--   select public.audit_log_archive_old(-1);         → retention_window_too_small
--   select public.audit_log_archive_old(31);         → insufficient_privileges below manager
--
-- Confirm the grants are gone:
--   select table_name from information_schema.role_table_grants
--    where table_schema='public' and grantee in ('anon','authenticated')
--      and privilege_type='TRUNCATE';                -- expect 0 rows
--
-- ── LEFT DELIBERATELY ALONE ───────────────────────────────────
-- public.discount_presets (7 rows) and orders.discount,
-- discount_label, discount_preset_id, discount_reference,
-- discount_applied_by, discount_applied_at are first-generation
-- leftovers. Nothing reads or writes them now that section 1 has
-- dropped the Gen 1 functions. Dropping columns from a live orders
-- table is riskier than leaving them empty, so they stay. Remove them
-- in their own migration once you are confident:
--   drop table public.discount_presets;
--   alter table public.orders
--     drop column discount, drop column discount_label,
--     drop column discount_preset_id, drop column discount_reference,
--     drop column discount_applied_by, drop column discount_applied_at;
