-- ═══════════════════════════════════════════════════════════════
-- 35 · Settle a whole table in one go (floor screen "Close table")
--
-- A dine-in table usually has several orders (each QR round is its own
-- order). Closing the table on the floor screen used to mark them
-- completed without recording any money, so they showed as unpaid in the
-- daily close and the cash never reached the drawer report.
--
--   orders_amount_due(ids)      what each order still owes (staff only)
--   settle_table_cash(ids, …)   one cash tender covers all of them, in one
--                               transaction: every order gets its own
--                               payments row for exactly what it owed, so
--                               refunds, receipts and stamps keep working
--                               per order. All or nothing.
--
-- Depends on sql/31 (payments, settle_order, amount_due) and sql/32
-- (cash sessions; the insert trigger attaches the open drawer).
-- Safe to re-run.
-- ═══════════════════════════════════════════════════════════════

create or replace function public.orders_amount_due(p_order_ids uuid[])
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  o     public.orders%rowtype;
  v_out jsonb := '[]'::jsonb;
begin
  if not (private.can('payments.take') or private.can('orders.view')) then
    raise exception 'permission_denied: payments.take' using errcode = '42501';
  end if;
  if p_order_ids is null or cardinality(p_order_ids) = 0 then return v_out; end if;
  if cardinality(p_order_ids) > 50 then raise exception 'too_many_orders'; end if;

  for o in select * from public.orders where id = any(p_order_ids) order by created_at loop
    perform private.assert_order_access(o);
    v_out := v_out || jsonb_build_object(
      'order_id', o.id, 'order_number', o.order_number, 'status', o.status,
      'total', o.total, 'payment_status', o.payment_status,
      'amount_due', case when o.status = 'cancelled' then 0 else private.amount_due(o.id) end);
  end loop;
  return v_out;
end $$;

create or replace function public.settle_table_cash(
  p_order_ids uuid[], p_tendered numeric, p_tip numeric default 0,
  p_cash_session uuid default null, p_note text default null)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  o        public.orders%rowtype;
  v_tip    numeric(10,2) := round(coalesce(p_tip, 0), 2);
  v_total  numeric(10,2) := 0;
  v_due    numeric(10,2);
  v_first  boolean := true;
  v_paid   int := 0;
  v_note   text := left(nullif(btrim(coalesce(p_note, '')), ''), 500);
begin
  if not private.can('payments.take') then
    raise exception 'permission_denied: payments.take' using errcode = '42501';
  end if;
  if p_order_ids is null or cardinality(p_order_ids) = 0 then raise exception 'nothing_due'; end if;
  if cardinality(p_order_ids) > 50 then raise exception 'too_many_orders'; end if;
  if v_tip < 0 or v_tip > 100000 then raise exception 'bad_tip'; end if;

  -- Lock every order first (fixed order, so two screens cannot deadlock),
  -- then add up what is owed.
  for o in select * from public.orders where id = any(p_order_ids) order by id for update loop
    perform private.assert_order_access(o);
    if o.status <> 'cancelled' then v_total := v_total + private.amount_due(o.id); end if;
  end loop;
  if v_total <= 0 then raise exception 'nothing_due'; end if;
  if p_tendered is null or round(p_tendered, 2) < v_total + v_tip then
    raise exception 'not_enough_cash: need %', v_total + v_tip;
  end if;

  for o in select * from public.orders where id = any(p_order_ids) and status <> 'cancelled' order by created_at loop
    v_due := private.amount_due(o.id);
    continue when v_due <= 0;
    -- The tip and the change ride on the first row; every row's amount is
    -- exactly what that order owed.
    insert into public.payments (order_id, branch_id, method, status, amount, tip, tendered, change_due,
                                 cash_session_id, note, created_by, confirmed_by, confirmed_at)
    values (o.id, o.branch_id, 'cash', 'completed', v_due,
            case when v_first then v_tip else 0 end,
            case when v_first then round(p_tendered, 2) - (v_total - v_due) else v_due end,
            case when v_first then round(p_tendered, 2) - v_total - v_tip else 0 end,
            p_cash_session, coalesce(v_note, 'Table settled together'), auth.uid(), auth.uid(), now());
    perform private.settle_order(o.id);
    v_first := false;
    v_paid := v_paid + 1;
  end loop;

  return jsonb_build_object('orders_paid', v_paid, 'amount', v_total, 'tip', v_tip,
                            'change_due', round(p_tendered, 2) - v_total - v_tip);
end $$;

revoke all on function public.orders_amount_due(uuid[]) from public, anon;
revoke all on function public.settle_table_cash(uuid[], numeric, numeric, uuid, text) from public, anon;
grant execute on function public.orders_amount_due(uuid[]) to authenticated;
grant execute on function public.settle_table_cash(uuid[], numeric, numeric, uuid, text) to authenticated;
