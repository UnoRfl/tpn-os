-- ═══════════════════════════════════════════════════════════════
-- 48 — counter money locks (Oct 22, 2026)
--
-- Three gaps from the Oct 22 review, each checked on production in a
-- rolled-back transaction before this file was written:
--
-- 1. A PAID BILL COULD STILL CHANGE. A ₱495 bill paid in cash was voided
--    down to ₱0 by void_order_item and still read "paid". remove_discount,
--    unvoid_order_item, approve_void_request and a supervisor's direct
--    UPDATE of discount_amount / service_charge could move it too.
--    Now: once payment_status = 'paid', nothing may change the bill's
--    money. Every path raises order_already_paid (the token apply_discount
--    already used). The fix for a wrong paid bill is a refund (refund_check),
--    which reopens the bill; after that it can be edited again.
--      • trg_guard_order_update: total, subtotal, discount_amount,
--        service_charge, delivery_fee frozen on a paid bill, for every
--        caller (the SQL API too). This alone catches anything that
--        recomputes the total.
--      • trg_order_items_paid_lock: void / un-void / price change of a line
--        on a paid bill (void_order_item, unvoid_order_item,
--        approve_void_request) refused with the clear token, before the
--        recompute runs.
--      • trg_applied_discounts_paid_lock: a discount added or removed on a
--        paid bill (remove_discount) refused.
--      • trg_void_requests_paid_lock: no new void request on a paid bill
--        (it could never be approved; the manager would only see a dead
--        request). Requests filed before the bill was paid stay; approving
--        them is refused, denying works.
--
-- 2. HAND-ENTERED BANK SKIPPED THE SECOND PERSON. record_manual_payment
--    (and settle_table_manual) with method 'bank' wrote a completed
--    payment and marked the order paid. Now a bank row from either is
--    written 'pending', exactly like record_bank_transfer: it counts only
--    after confirm_bank_transfer, which a different person must do
--    (manager+ may confirm their own — unchanged rule). GCash, Maya,
--    QR Ph and card stay "received at once".
--
-- 3. CASH WITHOUT AN OPEN SHIFT. trg_payment_cash_session (sql/32) only
--    filled in an open drawer when there was one; with none, the cash was
--    recorded with no drawer and never appeared in any X/Z read. Checked on
--    production (rolled back): record_cash_payment with no open shift
--    succeeded, cash_session_id null, order paid.
--    Now a cash PAYMENT must belong to a shift of the order's branch:
--      • no shift given → the open one is used; none open → no_open_shift.
--      • a shift given that is still open → used.
--      • a shift given that has since closed → the open one is used instead,
--        EXCEPT an offline replay (note starts "offline OFF-", written by
--        modules/offline.js) of a shift closed in the last 3 days: that
--        cash was in the drawer when it was counted, so it stays with the
--        shift it was taken in and that shift's stored expected cash and
--        variance are corrected (audited as cash_session.late_offline_cash).
--      • a shift of another branch, or unknown → bad_cash_session.
--    This covers record_cash_payment, settle_table_cash and the offline
--    replay (which calls record_cash_payment). Cash REFUNDS are unchanged
--    (still attached to the open shift when there is one).
--
-- New: my_shift() — the open shift of the caller's branch, for any account
-- that takes payments, so the counter can show "Open shift" instead of the
-- cash keypad (my_open_cash_session needs cash.drawer).
--
-- Safe to re-run.
-- ═══════════════════════════════════════════════════════════════

-- ── 1. Paid bills are frozen ─────────────────────────────────
create or replace function public.trg_guard_order_update()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  r public.staff_role;
  settling boolean := coalesce(current_setting('tpn.settle', true), 'off') = 'on';
begin
  r := private.my_role();

  -- sql/48: a paid bill's money does not move, for anyone. Refund first.
  if old.payment_status = 'paid' and not settling
     and (new.total is distinct from old.total
          or new.subtotal is distinct from old.subtotal
          or coalesce(new.discount_amount, 0) is distinct from coalesce(old.discount_amount, 0)
          or coalesce(new.service_charge, 0) is distinct from coalesce(old.service_charge, 0)
          or coalesce(new.delivery_fee, 0) is distinct from coalesce(old.delivery_fee, 0)) then
    raise exception 'order_already_paid: refund first, then change the bill' using errcode = '42501';
  end if;

  if (new.total    is distinct from old.total
      or new.subtotal is distinct from old.subtotal)
     and coalesce(current_setting('tpn.recompute', true), 'off') <> 'on' then
    raise exception
      'totals_are_derived: change the order items or the discount instead'
      using errcode = '42501';
  end if;

  if r is null then
    return new;
  end if;

  if new.status = 'cancelled'
     and old.status is distinct from 'cancelled'
     and not private.has_role('manager') then
    raise exception 'cancel_requires_manager' using errcode = '42501';
  end if;

  if not settling and not private.has_role('supervisor')
     and (coalesce(new.discount_amount, 0) is distinct from coalesce(old.discount_amount, 0)
          or coalesce(new.service_charge, 0) is distinct from coalesce(old.service_charge, 0)) then
    raise exception 'adjustments_require_supervisor' using errcode = '42501';
  end if;

  -- Payment state is derived from public.payments. Nobody types it in,
  -- not even a manager: record a payment instead.
  if not settling
     and (new.payment_status is distinct from old.payment_status
          or new.payment_reference is distinct from old.payment_reference
          or new.payment_method is distinct from old.payment_method and old.payment_status = 'paid') then
    raise exception 'payment_state_is_derived: record a payment instead' using errcode = '42501';
  end if;

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
revoke execute on function public.trg_guard_order_update() from public, anon, authenticated;

create or replace function private.order_paid(p_order_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce((select payment_status = 'paid' from public.orders where id = p_order_id), false)
$$;
revoke all on function private.order_paid(uuid) from public, anon, authenticated;

-- Lines: void, un-void or a price change on a paid bill.
create or replace function private.trg_order_items_paid_lock()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if (new.voided_at is distinct from old.voided_at
      or new.quantity is distinct from old.quantity
      or new.unit_price is distinct from old.unit_price
      or new.total_price is distinct from old.total_price)
     and private.order_paid(old.order_id) then
    raise exception 'order_already_paid: refund first, then void' using errcode = '42501';
  end if;
  return new;
end $$;
revoke all on function private.trg_order_items_paid_lock() from public, anon, authenticated;
drop trigger if exists trg_order_items_paid_lock on public.order_items;
create trigger trg_order_items_paid_lock before update on public.order_items
  for each row execute function private.trg_order_items_paid_lock();

-- Discounts: added or removed on a paid bill.
create or replace function private.trg_applied_discounts_paid_lock()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'UPDATE' and new is not distinct from old then return new; end if;
  if private.order_paid(case when tg_op = 'DELETE' then old.order_id else new.order_id end) then
    raise exception 'order_already_paid: refund first, then change the discount' using errcode = '42501';
  end if;
  return coalesce(new, old);
end $$;
revoke all on function private.trg_applied_discounts_paid_lock() from public, anon, authenticated;
drop trigger if exists trg_applied_discounts_paid_lock on public.applied_discounts;
create trigger trg_applied_discounts_paid_lock before insert or update or delete on public.applied_discounts
  for each row execute function private.trg_applied_discounts_paid_lock();

-- Void requests: none filed against a paid bill.
create or replace function private.trg_void_requests_paid_lock()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if private.order_paid(new.order_id) then
    raise exception 'order_already_paid: this bill is paid; refund instead' using errcode = '42501';
  end if;
  return new;
end $$;
revoke all on function private.trg_void_requests_paid_lock() from public, anon, authenticated;
drop trigger if exists trg_void_requests_paid_lock on public.void_requests;
create trigger trg_void_requests_paid_lock before insert on public.void_requests
  for each row execute function private.trg_void_requests_paid_lock();

-- ── 2. Hand-entered bank waits for a second person ───────────
create or replace function public.record_manual_payment(
  p_order_id uuid, p_method text, p_reference text,
  p_amount numeric default null, p_tip numeric default 0, p_note text default null)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  o       public.orders%rowtype;
  v_m     text := private.manual_method(p_method);
  v_ref   text := left(nullif(btrim(coalesce(p_reference, '')), ''), 120);
  v_due   numeric(10,2);
  v_amt   numeric(10,2);
  v_tip   numeric(10,2) := round(coalesce(p_tip, 0), 2);
  v_bank  boolean;
  v_id    uuid;
  v_state text;
begin
  if not private.can('payments.take') then
    raise exception 'permission_denied: payments.take' using errcode = '42501';
  end if;
  if v_m is null then raise exception 'bad_method'; end if;
  if v_ref is null or length(v_ref) < 3 then raise exception 'reference_required'; end if;
  select * into o from public.orders where id = p_order_id for update;
  if not found then raise exception 'order_not_found'; end if;
  perform private.assert_order_access(o);
  if o.status = 'cancelled' then raise exception 'order_cancelled'; end if;
  v_due := private.amount_due(o.id);
  if v_due <= 0 then raise exception 'nothing_due'; end if;
  v_amt := round(coalesce(p_amount, v_due), 2);
  if v_amt <= 0 or v_amt > v_due then raise exception 'bad_amount: due is %', v_due; end if;
  if v_tip < 0 or v_tip > 100000 then raise exception 'bad_tip'; end if;

  -- sql/48: a bank transfer is money only once someone else has seen it
  -- in the bank app (confirm_bank_transfer), same as record_bank_transfer.
  v_bank := v_m = 'bank';
  insert into public.payments (order_id, branch_id, method, status, amount, tip, reference, note,
                               created_by, confirmed_by, confirmed_at)
  values (o.id, o.branch_id, v_m, case when v_bank then 'pending' else 'completed' end, v_amt, v_tip, v_ref,
          left(nullif(btrim(coalesce(p_note, '')), ''), 500), auth.uid(),
          case when v_bank then null else auth.uid() end, case when v_bank then null else now() end)
  returning id into v_id;

  v_state := private.settle_order(o.id);
  return jsonb_build_object('payment_id', v_id, 'payment_status', v_state, 'amount_due', private.amount_due(o.id),
                            'pending', v_bank);
end $$;

create or replace function public.settle_table_manual(
  p_order_ids uuid[], p_method text, p_reference text, p_tip numeric default 0, p_note text default null)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  o       public.orders%rowtype;
  v_m     text := private.manual_method(p_method);
  v_ref   text := left(nullif(btrim(coalesce(p_reference, '')), ''), 120);
  v_tip   numeric(10,2) := round(coalesce(p_tip, 0), 2);
  v_total numeric(10,2) := 0;
  v_due   numeric(10,2);
  v_first boolean := true;
  v_paid  int := 0;
  v_bank  boolean;
begin
  if not private.can('payments.take') then
    raise exception 'permission_denied: payments.take' using errcode = '42501';
  end if;
  if v_m is null then raise exception 'bad_method'; end if;
  if v_ref is null or length(v_ref) < 3 then raise exception 'reference_required'; end if;
  if p_order_ids is null or cardinality(p_order_ids) = 0 then raise exception 'nothing_due'; end if;
  if cardinality(p_order_ids) > 50 then raise exception 'too_many_orders'; end if;
  if v_tip < 0 or v_tip > 100000 then raise exception 'bad_tip'; end if;
  v_bank := v_m = 'bank';

  for o in select * from public.orders where id = any(p_order_ids) order by id for update loop
    perform private.assert_order_access(o);
    if o.status <> 'cancelled' then v_total := v_total + private.amount_due(o.id); end if;
  end loop;
  if v_total <= 0 then raise exception 'nothing_due'; end if;

  for o in select * from public.orders where id = any(p_order_ids) and status <> 'cancelled' order by created_at loop
    v_due := private.amount_due(o.id);
    continue when v_due <= 0;
    insert into public.payments (order_id, branch_id, method, status, amount, tip, reference, note,
                                 created_by, confirmed_by, confirmed_at)
    values (o.id, o.branch_id, v_m, case when v_bank then 'pending' else 'completed' end, v_due,
            case when v_first then v_tip else 0 end, v_ref,
            coalesce(left(nullif(btrim(coalesce(p_note, '')), ''), 500), 'Table settled together'),
            auth.uid(), case when v_bank then null else auth.uid() end, case when v_bank then null else now() end);
    perform private.settle_order(o.id);
    v_first := false;
    v_paid := v_paid + 1;
  end loop;
  return jsonb_build_object('orders_paid', case when v_bank then 0 else v_paid end, 'orders_pending', case when v_bank then v_paid else 0 end,
                            'amount', v_total, 'tip', v_tip, 'method', v_m, 'pending', v_bank);
end $$;

revoke all on function public.record_manual_payment(uuid, text, text, numeric, numeric, text) from public, anon;
revoke all on function public.settle_table_manual(uuid[], text, text, numeric, text) from public, anon;
grant execute on function public.record_manual_payment(uuid, text, text, numeric, numeric, text) to authenticated;
grant execute on function public.settle_table_manual(uuid[], text, text, numeric, text) to authenticated;

-- ── 3. No cash without an open shift ─────────────────────────
create or replace function private.trg_payment_cash_session()
returns trigger language plpgsql security definer set search_path = '' as $$
declare s public.cash_sessions%rowtype;
begin
  if new.method <> 'cash' then return new; end if;

  if new.kind = 'refund' then
    -- Unchanged: a cash refund goes against the open drawer when there is one.
    if new.cash_session_id is null then
      select id into new.cash_session_id from public.cash_sessions
       where branch_id = new.branch_id and status = 'open'
       order by opened_at desc limit 1;
    end if;
    return new;
  end if;

  if new.cash_session_id is not null then
    select * into s from public.cash_sessions where id = new.cash_session_id;
    if not found or s.branch_id is distinct from new.branch_id then
      raise exception 'bad_cash_session' using errcode = '42501';
    end if;
    if s.status = 'open' then return new; end if;
    -- Cash taken offline while this shift was open, replayed after it was
    -- closed: it was in the drawer when the drawer was counted, so it stays
    -- with that shift (the AFTER trigger corrects the shift's figures).
    if coalesce(new.note, '') like 'offline OFF-%' and s.closed_at > now() - interval '3 days' then
      return new;
    end if;
    new.cash_session_id := null;   -- a stale shift on a screen: use the open one
  end if;

  select id into new.cash_session_id from public.cash_sessions
   where branch_id = new.branch_id and status = 'open'
   order by (register_label = 'Counter') desc, opened_at desc limit 1;
  if new.cash_session_id is null then
    raise exception 'no_open_shift: open a shift before taking cash' using errcode = '42501';
  end if;
  return new;
end $$;
revoke all on function private.trg_payment_cash_session() from public, anon, authenticated;
drop trigger if exists trg_payment_cash_session on public.payments;
create trigger trg_payment_cash_session before insert on public.payments
  for each row execute function private.trg_payment_cash_session();

-- Late offline cash on a closed shift: the stored Z read is put right.
create or replace function private.trg_payment_late_offline_cash()
returns trigger language plpgsql security definer set search_path = '' as $$
declare s public.cash_sessions%rowtype; v_add numeric(10,2);
begin
  if new.method <> 'cash' or new.kind <> 'payment' or new.status <> 'completed' or new.cash_session_id is null then
    return null;
  end if;
  select * into s from public.cash_sessions where id = new.cash_session_id for update;
  if not found or s.status <> 'closed' then return null; end if;
  v_add := new.amount + new.tip;
  update public.cash_sessions
     set expected_cash = coalesce(expected_cash, 0) + v_add,
         variance = counted_cash - (coalesce(expected_cash, 0) + v_add)
   where id = s.id;
  insert into public.audit_log (actor_id, actor_role, action, entity_type, entity_id, before_state, after_state, metadata)
  values (auth.uid(), private.my_role(), 'cash_session.late_offline_cash', 'cash_session', s.id,
          jsonb_build_object('expected_cash', s.expected_cash, 'variance', s.variance),
          jsonb_build_object('expected_cash', coalesce(s.expected_cash, 0) + v_add, 'variance', s.counted_cash - (coalesce(s.expected_cash, 0) + v_add)),
          jsonb_build_object('payment_id', new.id, 'order_id', new.order_id, 'amount', v_add, 'note', new.note));
  return null;
end $$;
revoke all on function private.trg_payment_late_offline_cash() from public, anon, authenticated;
drop trigger if exists trg_payment_late_offline_cash on public.payments;
create trigger trg_payment_late_offline_cash after insert on public.payments
  for each row execute function private.trg_payment_late_offline_cash();

-- The open shift of my branch (the Counter register first), for anyone who
-- takes payments: the counter shows "Open shift" instead of the keypad.
create or replace function public.my_shift()
returns uuid
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not (private.can('payments.take') or private.can('cash.drawer')) then
    raise exception 'permission_denied: payments.take' using errcode = '42501';
  end if;
  return (select id from public.cash_sessions
           where branch_id = private.my_branch() and status = 'open'
           order by (register_label = 'Counter') desc, opened_at desc limit 1);
end $$;
revoke all on function public.my_shift() from public, anon;
grant execute on function public.my_shift() to authenticated;
