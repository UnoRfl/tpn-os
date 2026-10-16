-- ═══════════════════════════════════════════════════════════════
-- 37b · Manual payments: GCash, Maya, QR Ph, card terminal, bank
--
-- The restaurant takes every non-cash payment by hand: staff show the
-- shop's QR (or run the card terminal), check it went through, and type
-- the reference / approval code. No payment app talks to the system.
--
--   record_manual_payment(order, method, reference, amount?, tip?, note?)
--   settle_table_manual(order_ids, method, reference, tip?, note?)
--
-- Both count as paid at once (the staff member is vouching for it) and
-- keep who, when and the reference, so a disputed payment can be traced.
-- Cash keeps record_cash_payment / settle_table_cash.
-- Needs 37a (enum value 'qrph'). Safe to re-run.
-- ═══════════════════════════════════════════════════════════════

-- Allowed methods on the ledger.
alter table public.payments drop constraint if exists payments_method_check;
alter table public.payments add constraint payments_method_check
  check (method in ('cash', 'gcash', 'maya', 'qrph', 'card', 'bank', 'hitpay', 'card_terminal', 'other'));

-- The method that brought in the most money names the order.
create or replace function private.settle_order(p_order_id uuid)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  o        public.orders%rowtype;
  v_in     numeric(10,2);
  v_out    numeric(10,2);
  v_method text;
  v_status text;
begin
  select * into o from public.orders where id = p_order_id for update;
  if not found then raise exception 'order_not_found'; end if;

  select coalesce(sum(amount) filter (where kind = 'payment'), 0),
         coalesce(sum(amount) filter (where kind = 'refund'), 0)
    into v_in, v_out
    from public.payments where order_id = p_order_id and status = 'completed';

  v_status := case
    when v_in > 0 and v_out >= v_in               then 'refunded'
    when o.total > 0 and v_in - v_out >= o.total  then 'paid'
    when o.total = 0 and v_in > 0 and v_out = 0   then 'paid'
    else 'pending' end;

  select method into v_method from public.payments
   where order_id = p_order_id and status = 'completed' and kind = 'payment'
   group by method order by sum(amount) desc limit 1;

  perform set_config('tpn.settle', 'on', true);
  update public.orders
     set payment_status = v_status::public.payment_status,
         payment_method = coalesce(case v_method
                                     when 'cash' then 'cash' when 'hitpay' then 'hitpay' when 'bank' then 'bank'
                                     when 'card' then 'card' when 'card_terminal' then 'card'
                                     when 'gcash' then 'gcash' when 'maya' then 'paymaya' when 'qrph' then 'qrph' end,
                                   payment_method::text)::public.payment_method
   where id = p_order_id;
  perform set_config('tpn.settle', 'off', true);
  return v_status;
end $$;
revoke all on function private.settle_order(uuid) from public, anon, authenticated;

create or replace function private.manual_method(p_method text)
returns text language sql immutable set search_path = '' as $$
  select case lower(btrim(coalesce(p_method, '')))
    when 'gcash' then 'gcash' when 'maya' then 'maya' when 'paymaya' then 'maya'
    when 'qrph' then 'qrph' when 'qr ph' then 'qrph' when 'card' then 'card' when 'bank' then 'bank' end
$$;

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

  insert into public.payments (order_id, branch_id, method, status, amount, tip, reference, note,
                               created_by, confirmed_by, confirmed_at)
  values (o.id, o.branch_id, v_m, 'completed', v_amt, v_tip, v_ref,
          left(nullif(btrim(coalesce(p_note, '')), ''), 500), auth.uid(), auth.uid(), now())
  returning id into v_id;

  v_state := private.settle_order(o.id);
  return jsonb_build_object('payment_id', v_id, 'payment_status', v_state, 'amount_due', private.amount_due(o.id));
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
begin
  if not private.can('payments.take') then
    raise exception 'permission_denied: payments.take' using errcode = '42501';
  end if;
  if v_m is null then raise exception 'bad_method'; end if;
  if v_ref is null or length(v_ref) < 3 then raise exception 'reference_required'; end if;
  if p_order_ids is null or cardinality(p_order_ids) = 0 then raise exception 'nothing_due'; end if;
  if cardinality(p_order_ids) > 50 then raise exception 'too_many_orders'; end if;
  if v_tip < 0 or v_tip > 100000 then raise exception 'bad_tip'; end if;

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
    values (o.id, o.branch_id, v_m, 'completed', v_due, case when v_first then v_tip else 0 end, v_ref,
            coalesce(left(nullif(btrim(coalesce(p_note, '')), ''), 500), 'Table settled together'),
            auth.uid(), auth.uid(), now());
    perform private.settle_order(o.id);
    v_first := false;
    v_paid := v_paid + 1;
  end loop;
  return jsonb_build_object('orders_paid', v_paid, 'amount', v_total, 'tip', v_tip, 'method', v_m);
end $$;

revoke all on function private.manual_method(text) from public, anon, authenticated;
revoke all on function public.record_manual_payment(uuid, text, text, numeric, numeric, text) from public, anon;
revoke all on function public.settle_table_manual(uuid[], text, text, numeric, text) from public, anon;
grant execute on function public.record_manual_payment(uuid, text, text, numeric, numeric, text) to authenticated;
grant execute on function public.settle_table_manual(uuid[], text, text, numeric, text) to authenticated;
