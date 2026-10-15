-- ═══════════════════════════════════════════════════════════════
-- 31 · Payments: HitPay, cash, bank transfer, refunds, service charge,
--      and the Senior Citizen / PWD VAT exemption
--
-- Requires 29 (hotfix), 29a (enum values), 29b (helpers).
--
-- THE RULE: an order is "paid" because confirmed money covers it, never
-- because somebody typed it. Every peso in or out is a row in
-- public.payments, written only by the functions below. orders.payment_*
-- is derived from those rows by private.settle_order(), the same way
-- orders.total is derived from order_items.
--
--   cash         recorded by staff at the counter/table (payments.take)
--   bank         recorded as PENDING, confirmed by a supervisor who saw
--                the money arrive (payments.confirm)
--   hitpay       created by the hitpay-create edge function, completed
--                ONLY by the hitpay-webhook edge function after the
--                HMAC signature checks out. The customer's browser coming
--                back from HitPay proves nothing and changes nothing.
--   refund       a negative-direction row (kind = 'refund'), manager+.
--
-- Senior Citizen (RA 9994) and PWD (RA 10754): the qualifying share is
-- VAT-EXEMPT and then gets 20% off the VAT-exclusive price. The old
-- computation took 20% of (price / 1.12) but left the 12% VAT in, so the
-- guest still paid VAT. For a ₱1,120 share: old discount ₱200; correct
-- deduction ₱120 VAT + ₱200 = ₱320. At a group table only the senior's
-- share qualifies, so apply_discount() now takes the covered amount.
-- ═══════════════════════════════════════════════════════════════

-- ── Permissions ──────────────────────────────────────────────
select private.add_permission('payments.take',    'Money', 'Take payments',           'Tumanggap ng bayad',
  'Record cash, start an online (HitPay) payment, record a bank transfer as pending.', 'dining', 300);
select private.add_permission('payments.confirm', 'Money', 'Confirm bank transfers',  'Kumpirmahin ang bank transfer',
  'Mark a pending bank transfer as received after checking the bank app.', 'supervisor', 310);
select private.add_permission('payments.refund',  'Money', 'Refund payments',         'Mag-refund',
  'Refund all or part of a paid order. Always audited with a reason.', 'manager', 320);
select private.add_permission('orders.service_charge', 'Money', 'Set service charge', 'Itakda ang service charge',
  'Add or remove a service charge on a bill.', 'supervisor', 330);

-- ── Payments ledger ──────────────────────────────────────────
create table if not exists public.payments (
  id                  uuid primary key default gen_random_uuid(),
  order_id            uuid not null references public.orders(id) on delete restrict,
  branch_id           uuid references public.branches(id),
  kind                text not null default 'payment' check (kind in ('payment', 'refund')),
  method              text not null check (method in ('cash', 'hitpay', 'bank', 'card_terminal', 'other')),
  status              text not null default 'pending'
                      check (status in ('pending', 'completed', 'failed', 'cancelled', 'expired')),
  amount              numeric(10,2) not null check (amount > 0),
  tip                 numeric(10,2) not null default 0 check (tip >= 0),
  tendered            numeric(10,2) check (tendered is null or tendered >= 0),
  change_due          numeric(10,2) check (change_due is null or change_due >= 0),
  provider_request_id text unique,           -- HitPay payment_request id
  provider_payment_id text,                  -- HitPay payment id (for refunds)
  provider_method     text,                  -- e.g. qrph, gcash, card (as HitPay reports it)
  checkout_url        text,
  reference           text check (length(reference) <= 120),   -- bank ref / OR no.
  note                text check (length(note) <= 500),
  refund_of           uuid references public.payments(id),
  cash_session_id     uuid,                  -- filled by the POS (sql/32)
  raw                 jsonb,                 -- provider payload, staff-only
  created_by          uuid references public.staff(id),
  created_at          timestamptz not null default now(),
  confirmed_by        uuid references public.staff(id),
  confirmed_at        timestamptz,
  constraint payments_refund_link check ((kind = 'refund') = (refund_of is not null))
);
create index if not exists idx_payments_order  on public.payments(order_id);
create index if not exists idx_payments_branch on public.payments(branch_id, created_at desc);
create index if not exists idx_payments_status on public.payments(status) where status = 'pending';

alter table public.payments enable row level security;
revoke all on public.payments from anon, authenticated;
grant select on public.payments to authenticated;
drop policy if exists payments_read on public.payments;
create policy payments_read on public.payments for select to authenticated
  using (
    (private.can('orders.view') or private.can('finance.view'))
    and (branch_id = private.my_branch() or private.has_role('admin'))
  );
-- No insert/update/delete policy on purpose: only the functions below write.

drop trigger if exists trg_audit_payments on public.payments;
create trigger trg_audit_payments after insert or update on public.payments
  for each row execute function private.audit_row();

-- ── Order guard: one more authorised writer ─────────────────
-- private.settle_order() writes payment_status / payment_method and
-- set_service_charge() writes service_charge. Both raise a
-- transaction-local flag, exactly like tpn.recompute in sql/17; no client
-- can set it because set_config is not exposed through PostgREST.
create or replace function public.trg_guard_order_update()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  r public.staff_role;
  settling boolean := coalesce(current_setting('tpn.settle', true), 'off') = 'on';
begin
  r := private.my_role();

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

-- ── Settlement ───────────────────────────────────────────────
-- paid       completed payments (minus refunds) cover the total
-- refunded   money came in and all of it went back out
-- pending    anything else
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

  -- The method that brought in the most money names the order.
  select method into v_method from public.payments
   where order_id = p_order_id and status = 'completed' and kind = 'payment'
   group by method order by sum(amount) desc limit 1;

  perform set_config('tpn.settle', 'on', true);
  update public.orders
     set payment_status = v_status::public.payment_status,
         payment_method = coalesce(case v_method when 'cash' then 'cash' when 'hitpay' then 'hitpay'
                                                 when 'bank' then 'bank' when 'card_terminal' then 'card' end,
                                   payment_method::text)::public.payment_method
   where id = p_order_id;
  perform set_config('tpn.settle', 'off', true);
  return v_status;
end $$;
revoke all on function private.settle_order(uuid) from public, anon, authenticated;

create or replace function private.amount_due(p_order_id uuid)
returns numeric
language sql stable security definer set search_path = ''
as $$
  select greatest(0, o.total
         - coalesce((select sum(case when p.kind = 'payment' then p.amount else -p.amount end)
                       from public.payments p
                      where p.order_id = o.id and p.status = 'completed'), 0))
    from public.orders o where o.id = p_order_id
$$;
revoke all on function private.amount_due(uuid) from public, anon, authenticated;

create or replace function private.assert_order_access(o public.orders)
returns void
language plpgsql stable security definer set search_path = ''
as $$
begin
  if o.branch_id is distinct from private.my_branch() and not private.has_role('admin') then
    raise exception 'wrong_branch' using errcode = '42501';
  end if;
end $$;
revoke all on function private.assert_order_access(public.orders) from public, anon, authenticated;

-- Staff-facing summary of what is owed and what came in.
create or replace function public.order_payments(p_order_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare o public.orders%rowtype;
begin
  if not (private.can('orders.view') or private.can('payments.take')) then
    raise exception 'permission_denied' using errcode = '42501';
  end if;
  select * into o from public.orders where id = p_order_id;
  if not found then raise exception 'order_not_found'; end if;
  perform private.assert_order_access(o);
  return jsonb_build_object(
    'order_id', o.id, 'order_number', o.order_number, 'total', o.total,
    'subtotal', o.subtotal, 'discount', o.discount_amount, 'service_charge', o.service_charge,
    'payment_status', o.payment_status, 'amount_due', private.amount_due(o.id),
    'payments', coalesce((select jsonb_agg(jsonb_build_object(
        'id', p.id, 'kind', p.kind, 'method', p.method, 'status', p.status, 'amount', p.amount,
        'tip', p.tip, 'tendered', p.tendered, 'change_due', p.change_due,
        'provider_method', p.provider_method, 'reference', p.reference, 'note', p.note,
        'created_at', p.created_at, 'confirmed_at', p.confirmed_at,
        'refunded', coalesce((select sum(r.amount) from public.payments r
                               where r.refund_of = p.id and r.status = 'completed'), 0))
        order by p.created_at) from public.payments p where p.order_id = o.id), '[]'::jsonb));
end $$;
revoke all on function public.order_payments(uuid) from public, anon;
grant execute on function public.order_payments(uuid) to authenticated;

-- ── Cash ─────────────────────────────────────────────────────
-- p_amount: how much of the bill this cash covers (null = all that is due).
-- p_tendered: what the guest handed over; change is computed here.
create or replace function public.record_cash_payment(
  p_order_id uuid, p_tendered numeric, p_amount numeric default null,
  p_tip numeric default 0, p_cash_session uuid default null, p_note text default null)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  o       public.orders%rowtype;
  v_due   numeric(10,2);
  v_amt   numeric(10,2);
  v_tip   numeric(10,2) := round(coalesce(p_tip, 0), 2);
  v_id    uuid;
  v_state text;
begin
  if not private.can('payments.take') then
    raise exception 'permission_denied: payments.take' using errcode = '42501';
  end if;
  select * into o from public.orders where id = p_order_id for update;
  if not found then raise exception 'order_not_found'; end if;
  perform private.assert_order_access(o);
  if o.status = 'cancelled' then raise exception 'order_cancelled'; end if;

  v_due := private.amount_due(o.id);
  if v_due <= 0 then raise exception 'nothing_due'; end if;
  v_amt := round(coalesce(p_amount, v_due), 2);
  if v_amt <= 0 or v_amt > v_due then raise exception 'bad_amount: due is %', v_due; end if;
  if v_tip < 0 or v_tip > 100000 then raise exception 'bad_tip'; end if;
  if p_tendered is null or round(p_tendered, 2) < v_amt + v_tip then
    raise exception 'not_enough_cash: need %', v_amt + v_tip;
  end if;

  insert into public.payments (order_id, branch_id, method, status, amount, tip, tendered, change_due,
                               cash_session_id, note, created_by, confirmed_by, confirmed_at)
  values (o.id, o.branch_id, 'cash', 'completed', v_amt, v_tip, round(p_tendered, 2),
          round(p_tendered, 2) - v_amt - v_tip, p_cash_session,
          left(nullif(btrim(coalesce(p_note, '')), ''), 500), auth.uid(), auth.uid(), now())
  returning id into v_id;

  v_state := private.settle_order(o.id);
  return jsonb_build_object('payment_id', v_id, 'change_due', round(p_tendered, 2) - v_amt - v_tip,
                            'payment_status', v_state, 'amount_due', private.amount_due(o.id));
end $$;
revoke all on function public.record_cash_payment(uuid, numeric, numeric, numeric, uuid, text) from public, anon;
grant execute on function public.record_cash_payment(uuid, numeric, numeric, numeric, uuid, text) to authenticated;

-- ── Bank transfer (catering / corporate) ─────────────────────
create or replace function public.record_bank_transfer(
  p_order_id uuid, p_amount numeric, p_reference text, p_note text default null)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare o public.orders%rowtype; v_id uuid; v_due numeric;
begin
  if not private.can('payments.take') then
    raise exception 'permission_denied: payments.take' using errcode = '42501';
  end if;
  select * into o from public.orders where id = p_order_id;
  if not found then raise exception 'order_not_found'; end if;
  perform private.assert_order_access(o);
  v_due := private.amount_due(o.id);
  if p_amount is null or p_amount <= 0 or p_amount > v_due then raise exception 'bad_amount: due is %', v_due; end if;
  if coalesce(length(btrim(p_reference)), 0) < 4 then raise exception 'reference_required'; end if;
  insert into public.payments (order_id, branch_id, method, status, amount, reference, note, created_by)
  values (o.id, o.branch_id, 'bank', 'pending', round(p_amount, 2), left(btrim(p_reference), 120),
          left(nullif(btrim(coalesce(p_note, '')), ''), 500), auth.uid())
  returning id into v_id;
  return v_id;
end $$;
revoke all on function public.record_bank_transfer(uuid, numeric, text, text) from public, anon;
grant execute on function public.record_bank_transfer(uuid, numeric, text, text) to authenticated;

-- Confirming needs a second person when possible: the recorder may not
-- confirm their own transfer unless they are manager+.
create or replace function public.confirm_bank_transfer(p_payment_id uuid, p_received boolean, p_note text default null)
returns text
language plpgsql security definer set search_path = ''
as $$
declare p public.payments%rowtype; o public.orders%rowtype;
begin
  if not private.can('payments.confirm') then
    raise exception 'permission_denied: payments.confirm' using errcode = '42501';
  end if;
  select * into p from public.payments where id = p_payment_id for update;
  if not found or p.method <> 'bank' then raise exception 'payment_not_found'; end if;
  if p.status <> 'pending' then raise exception 'already_%', p.status; end if;
  select * into o from public.orders where id = p.order_id;
  perform private.assert_order_access(o);
  if p.created_by = auth.uid() and not private.has_role('manager') then
    raise exception 'needs_second_person: someone else must confirm a transfer you recorded';
  end if;
  update public.payments
     set status = case when p_received then 'completed' else 'failed' end,
         confirmed_by = auth.uid(), confirmed_at = now(),
         note = left(concat_ws(' · ', note, nullif(btrim(coalesce(p_note, '')), '')), 500)
   where id = p.id;
  return private.settle_order(p.order_id);
end $$;
revoke all on function public.confirm_bank_transfer(uuid, boolean, text) from public, anon;
grant execute on function public.confirm_bank_transfer(uuid, boolean, text) to authenticated;

-- ── HitPay (called only by the edge functions, as service_role) ──
-- 1. hitpay-create asks for the amount due. A customer proves the order
--    is theirs with the private tracking token (sql/29); staff with their
--    session. The amount is always computed here, never sent by a client.
create or replace function public.hitpay_begin(
  p_order_number text default null, p_token uuid default null,
  p_order_id uuid default null, p_actor uuid default null)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare o public.orders%rowtype; v_due numeric; v_id uuid; v_open public.payments%rowtype;
begin
  if p_order_id is not null then
    select * into o from public.orders where id = p_order_id for update;
  else
    select * into o from public.orders
     where upper(order_number) = upper(btrim(p_order_number)) and track_token = p_token
     for update;
  end if;
  if not found then raise exception 'order_not_found'; end if;
  if o.status = 'cancelled' then raise exception 'order_cancelled'; end if;
  v_due := private.amount_due(o.id);
  if v_due <= 0 then raise exception 'nothing_due'; end if;

  -- Reuse a still-open request for the same amount instead of stacking
  -- several live checkouts for one bill.
  select * into v_open from public.payments
   where order_id = o.id and method = 'hitpay' and status = 'pending' and amount = v_due
     and created_at > now() - interval '50 minutes' and checkout_url is not null
   order by created_at desc limit 1;
  if found then
    return jsonb_build_object('payment_id', v_open.id, 'checkout_url', v_open.checkout_url,
                              'amount', v_open.amount, 'reused', true);
  end if;

  -- Older open requests for this order are superseded.
  update public.payments set status = 'cancelled'
   where order_id = o.id and method = 'hitpay' and status = 'pending';

  insert into public.payments (order_id, branch_id, method, status, amount, created_by)
  values (o.id, o.branch_id, 'hitpay', 'pending', v_due, p_actor)
  returning id into v_id;
  return jsonb_build_object('payment_id', v_id, 'amount', v_due, 'currency', 'PHP',
    'order_number', o.order_number, 'customer_name', o.customer_name, 'reused', false);
end $$;

create or replace function public.hitpay_attach(p_payment_id uuid, p_request_id text, p_url text)
returns void
language sql security definer set search_path = ''
as $$
  update public.payments set provider_request_id = p_request_id, checkout_url = p_url
   where id = p_payment_id and method = 'hitpay' and status = 'pending';
$$;

-- 2. hitpay-webhook, after verifying the signature. Idempotent: HitPay
--    retries, and a retry must not double-count.
create or replace function public.hitpay_complete(
  p_request_id text, p_status text, p_amount numeric, p_currency text,
  p_provider_payment_id text, p_provider_method text, p_payload jsonb)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare p public.payments%rowtype; v_state text;
begin
  select * into p from public.payments where provider_request_id = p_request_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'unknown_request');
  end if;
  if p.status = 'completed' then
    return jsonb_build_object('ok', true, 'reason', 'already_completed');
  end if;
  if lower(coalesce(p_status, '')) not in ('completed', 'succeeded') then
    update public.payments set status = 'failed', raw = p_payload where id = p.id and status = 'pending';
    return jsonb_build_object('ok', true, 'reason', 'marked_failed');
  end if;
  -- The money HitPay says it took must be the money we asked for.
  if upper(coalesce(p_currency, '')) <> 'PHP' or round(coalesce(p_amount, -1), 2) <> p.amount then
    update public.payments set raw = p_payload,
           note = left(concat_ws(' · ', note, 'AMOUNT MISMATCH from HitPay: ' || p_amount || ' ' || p_currency), 500)
     where id = p.id;
    insert into public.audit_log (action, entity_type, entity_id, metadata)
    values ('payment.hitpay_mismatch', 'payment', p.id,
            jsonb_build_object('expected', p.amount, 'got', p_amount, 'currency', p_currency));
    return jsonb_build_object('ok', false, 'reason', 'amount_mismatch');
  end if;
  update public.payments
     set status = 'completed', confirmed_at = now(), raw = p_payload,
         provider_payment_id = p_provider_payment_id,
         provider_method = left(p_provider_method, 40)
   where id = p.id;
  v_state := private.settle_order(p.order_id);
  return jsonb_build_object('ok', true, 'order_id', p.order_id, 'payment_status', v_state);
end $$;

-- 3. Refund bookkeeping for HitPay (the edge function calls HitPay's
--    refund API first, then records the outcome here).
create or replace function public.hitpay_refund_recorded(
  p_payment_id uuid, p_amount numeric, p_reason text, p_actor uuid, p_provider_ref text, p_payload jsonb)
returns text
language plpgsql security definer set search_path = ''
as $$
declare p public.payments%rowtype;
begin
  select * into p from public.payments where id = p_payment_id;
  if not found then raise exception 'payment_not_found'; end if;
  insert into public.payments (order_id, branch_id, kind, method, status, amount, refund_of,
                               reference, note, raw, created_by, confirmed_by, confirmed_at)
  values (p.order_id, p.branch_id, 'refund', 'hitpay', 'completed', round(p_amount, 2), p.id,
          left(p_provider_ref, 120), left(p_reason, 500), p_payload, p_actor, p_actor, now());
  return private.settle_order(p.order_id);
end $$;

do $$
declare f text;
begin
  foreach f in array array[
    'public.hitpay_begin(text, uuid, uuid, uuid)',
    'public.hitpay_attach(uuid, text, text)',
    'public.hitpay_complete(text, text, numeric, text, text, text, jsonb)',
    'public.hitpay_refund_recorded(uuid, numeric, text, uuid, text, jsonb)'] loop
    execute 'revoke all on function ' || f || ' from public, anon, authenticated';
    execute 'grant execute on function ' || f || ' to service_role';
  end loop;
end $$;

-- ── Refunds (cash, bank, card terminal) ──────────────────────
-- Checks a refund is possible; for HitPay the edge function does the rest.
create or replace function public.refund_check(p_payment_id uuid, p_amount numeric)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare p public.payments%rowtype; o public.orders%rowtype; v_left numeric;
begin
  if not private.can('payments.refund') then
    raise exception 'permission_denied: payments.refund' using errcode = '42501';
  end if;
  select * into p from public.payments where id = p_payment_id;
  if not found or p.kind <> 'payment' or p.status <> 'completed' then raise exception 'payment_not_refundable'; end if;
  select * into o from public.orders where id = p.order_id;
  perform private.assert_order_access(o);
  v_left := p.amount - coalesce((select sum(amount) from public.payments
                                  where refund_of = p.id and status in ('completed', 'pending')), 0);
  if p_amount is null or p_amount <= 0 or round(p_amount, 2) > v_left then
    raise exception 'bad_amount: refundable is %', v_left;
  end if;
  return jsonb_build_object('payment_id', p.id, 'method', p.method, 'refundable', v_left,
                            'provider_payment_id', p.provider_payment_id, 'order_id', p.order_id,
                            'actor', auth.uid());
end $$;
revoke all on function public.refund_check(uuid, numeric) from public, anon;
grant execute on function public.refund_check(uuid, numeric) to authenticated;

create or replace function public.refund_payment(p_payment_id uuid, p_amount numeric, p_reason text)
returns text
language plpgsql security definer set search_path = ''
as $$
declare chk jsonb; p public.payments%rowtype;
begin
  if coalesce(length(btrim(p_reason)), 0) < 3 then raise exception 'reason_required'; end if;
  chk := public.refund_check(p_payment_id, p_amount);
  select * into p from public.payments where id = p_payment_id;
  if p.method = 'hitpay' then
    raise exception 'use_hitpay_refund: online payments are refunded through HitPay (Refund button)';
  end if;
  insert into public.payments (order_id, branch_id, kind, method, status, amount, refund_of,
                               note, created_by, confirmed_by, confirmed_at)
  values (p.order_id, p.branch_id, 'refund', p.method, 'completed', round(p_amount, 2), p.id,
          left(btrim(p_reason), 500), auth.uid(), auth.uid(), now());
  return private.settle_order(p.order_id);
end $$;
revoke all on function public.refund_payment(uuid, numeric, text) from public, anon;
grant execute on function public.refund_payment(uuid, numeric, text) to authenticated;

-- ── Service charge ───────────────────────────────────────────
-- Percent of the subtotal after discounts, or a fixed amount. 0 removes it.
create or replace function public.set_service_charge(p_order_id uuid, p_percent numeric default null, p_amount numeric default null)
returns numeric
language plpgsql security definer set search_path = ''
as $$
declare o public.orders%rowtype; v numeric(10,2);
begin
  if not private.can('orders.service_charge') then
    raise exception 'permission_denied: orders.service_charge' using errcode = '42501';
  end if;
  select * into o from public.orders where id = p_order_id for update;
  if not found then raise exception 'order_not_found'; end if;
  perform private.assert_order_access(o);
  if o.payment_status = 'paid' then raise exception 'order_already_paid'; end if;
  if p_percent is not null then
    if p_percent < 0 or p_percent > 20 then raise exception 'bad_percent: 0 to 20'; end if;
    v := round(greatest(0, o.subtotal - coalesce(o.discount_amount, 0)) * p_percent / 100.0, 2);
  else
    v := round(coalesce(p_amount, 0), 2);
    if v < 0 or v > o.subtotal then raise exception 'bad_amount'; end if;
  end if;
  perform set_config('tpn.settle', 'on', true);
  update public.orders set service_charge = v where id = o.id;
  perform set_config('tpn.settle', 'off', true);
  perform private.recompute_order_totals(o.id);
  insert into public.audit_log (actor_id, actor_role, action, entity_type, entity_id, metadata)
  values (auth.uid(), private.my_role(), 'order.service_charge', 'order', o.id,
          jsonb_build_object('percent', p_percent, 'amount', v, 'before', o.service_charge));
  return v;
end $$;
revoke all on function public.set_service_charge(uuid, numeric, numeric) from public, anon;
grant execute on function public.set_service_charge(uuid, numeric, numeric) to authenticated;

-- ── Senior Citizen / PWD: VAT exemption + 20% on the covered share ──
alter table public.discount_templates drop constraint if exists discount_templates_vat_treatment_check;
alter table public.discount_templates add constraint discount_templates_vat_treatment_check
  check (vat_treatment in ('gross', 'net_of_vat', 'vat_exempt'));
update public.discount_templates set vat_treatment = 'vat_exempt'
 where legal_law in ('RA 9994', 'RA 10754') and vat_treatment <> 'vat_exempt';

alter table public.applied_discounts
  add column if not exists covered_amount    numeric(10,2),
  add column if not exists vat_exempt_amount numeric(10,2) not null default 0;

drop function if exists public.apply_discount(uuid, uuid, text);
create or replace function public.apply_discount(
  p_order_id uuid, p_template_id uuid, p_id_ref text default null, p_covered_amount numeric default null)
returns public.applied_discounts
language plpgsql security definer set search_path = ''
as $$
declare
  t             public.discount_templates%rowtype;
  o             public.orders%rowtype;
  live_subtotal numeric(10,2);
  cur_discount  numeric(10,2);
  base          numeric(10,2);
  covered       numeric(10,2);
  vat_part      numeric(10,2) := 0;
  computed      numeric(10,2);
  result        public.applied_discounts%rowtype;
begin
  if not private.has_role('supervisor') then
    raise exception 'insufficient_privileges';
  end if;
  if p_order_id is null or p_template_id is null then
    raise exception 'invalid_input';
  end if;

  select * into t from public.discount_templates where id = p_template_id;
  if not found then raise exception 'template_not_found'; end if;
  if not t.is_active then raise exception 'template_inactive'; end if;
  if t.requires_id and (p_id_ref is null or length(trim(p_id_ref)) < 3) then
    raise exception 'id_ref_required';
  end if;

  select * into o from public.orders where id = p_order_id;
  if not found then raise exception 'order_not_found'; end if;
  if o.status in ('completed', 'cancelled') then raise exception 'order_terminal'; end if;
  if o.payment_status = 'paid' then raise exception 'order_already_paid'; end if;
  if not private.has_role('admin') and o.branch_id is distinct from private.my_branch() then
    raise exception 'wrong_branch' using errcode = '42501';
  end if;

  select coalesce(sum(total_price), 0) into live_subtotal
    from public.order_items where order_id = p_order_id and voided_at is null;
  if live_subtotal < coalesce(t.min_subtotal, 0) then
    raise exception 'below_min_subtotal';
  end if;
  if not t.stackable then
    if exists (select 1 from public.applied_discounts where order_id = p_order_id and removed_at is null) then
      raise exception 'not_stackable';
    end if;
  end if;

  select coalesce(sum(amount_applied), 0) into cur_discount
    from public.applied_discounts where order_id = p_order_id and removed_at is null;
  base := greatest(0, live_subtotal - cur_discount);

  -- What this discount applies to: the whole remaining bill, or just the
  -- qualifying guest's share (their own dishes, or their pro-rata share of
  -- shared dishes — BIR RR 7-2010).
  covered := least(base, round(coalesce(p_covered_amount, base), 2));
  if covered <= 0 then raise exception 'bad_covered_amount'; end if;

  if t.kind = 'percent' then
    if t.vat_treatment = 'vat_exempt' then
      -- VAT-exempt sale: remove the 12% VAT, then the discount on the
      -- VAT-exclusive price. Both parts are the guest's saving.
      vat_part := round(covered - covered / 1.12, 2);
      computed := vat_part + round((covered / 1.12) * (t.value / 100.0), 2);
    elsif t.vat_treatment = 'net_of_vat' then
      computed := round((covered / 1.12) * (t.value / 100.0), 2);
    else
      computed := round(covered * (t.value / 100.0), 2);
    end if;
  else
    computed := round(t.value, 2);
  end if;
  if t.max_discount is not null and t.vat_treatment <> 'vat_exempt' then
    computed := least(computed, t.max_discount);
  end if;
  computed := least(computed, base);

  insert into public.applied_discounts
    (order_id, template_id, name_snapshot, kind_snapshot, value_snapshot,
     amount_applied, id_ref, legal_law, applied_by, covered_amount, vat_exempt_amount)
  values
    (p_order_id, t.id, t.name, t.kind, t.value,
     computed, nullif(trim(coalesce(p_id_ref, '')), ''), t.legal_law, auth.uid(), covered, vat_part)
  returning * into result;

  insert into public.audit_log
    (actor_id, actor_role, action, entity_type, entity_id, after_state, metadata)
  values
    (auth.uid(), private.my_role(), 'discount.apply', 'order', p_order_id,
     jsonb_build_object('template', t.name, 'kind', t.kind, 'value', t.value,
                        'amount_applied', computed, 'vat_exempt_amount', vat_part,
                        'covered_amount', covered, 'legal_law', t.legal_law),
     jsonb_build_object('applied_discount_id', result.id, 'template_id', t.id,
                        'id_ref', result.id_ref, 'branch_id', o.branch_id,
                        'order_number', o.order_number, 'subtotal_at_apply', live_subtotal));
  return result;
end $$;
revoke execute on function public.apply_discount(uuid, uuid, text, numeric) from public, anon;
grant  execute on function public.apply_discount(uuid, uuid, text, numeric) to authenticated;

-- ── Daily close: count the cash that was actually collected ──
-- HANDOFF said: when payment confirmation lands, expected_cash must switch
-- from DECLARED cash to RECEIVED cash, and the "declared" warning goes
-- with it. That is now: cash payments minus cash refunds, by the day the
-- money moved. Declared cash stays in the report for comparison.
create or replace function public.daily_close_report(p_date date default current_date, p_branch uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_branch uuid := coalesce(p_branch, private.my_branch());
  v_lo timestamptz := (p_date::timestamp at time zone 'Asia/Manila');
  v_hi timestamptz := ((p_date + 1)::timestamp at time zone 'Asia/Manila');
  v jsonb;
begin
  if not private.can('finance.view') and not private.can('orders.view') then
    raise exception 'permission_denied: orders.view' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'date', p_date,
    'gross_sales', coalesce(sum(o.subtotal), 0),
    'discounts',   coalesce(sum(o.discount_amount), 0),
    'service_charge', coalesce(sum(o.service_charge), 0),
    'net_sales',   coalesce(sum(o.total), 0),
    'order_count', count(*),
    'avg_ticket',  case when count(*) > 0 then round(coalesce(sum(o.total), 0) / count(*), 2) else 0 end,
    'unpaid', coalesce((select jsonb_build_object('orders', count(*), 'value', coalesce(sum(u.total), 0))
                          from public.orders u
                         where u.branch_id = v_branch and u.status <> 'cancelled'
                           and u.payment_status <> 'paid'
                           and u.placed_at >= v_lo and u.placed_at < v_hi), '{}'::jsonb),
    'collected', coalesce((
      select jsonb_agg(jsonb_build_object('method', c.method, 'in', c.amt_in, 'out', c.amt_out,
                                          'tips', c.tips, 'count', c.n) order by c.amt_in desc)
        from (select p.method,
                     sum(p.amount) filter (where p.kind = 'payment') amt_in,
                     coalesce(sum(p.amount) filter (where p.kind = 'refund'), 0) amt_out,
                     coalesce(sum(p.tip), 0) tips, count(*) n
                from public.payments p
               where p.branch_id = v_branch and p.status = 'completed'
                 and coalesce(p.confirmed_at, p.created_at) >= v_lo
                 and coalesce(p.confirmed_at, p.created_at) <  v_hi
               group by p.method) c), '[]'::jsonb),
    'received_cash', coalesce((
      select sum(case when p.kind = 'payment' then p.amount + p.tip else -p.amount end)
        from public.payments p
       where p.branch_id = v_branch and p.status = 'completed' and p.method = 'cash'
         and coalesce(p.confirmed_at, p.created_at) >= v_lo
         and coalesce(p.confirmed_at, p.created_at) <  v_hi), 0),
    'pending_bank', coalesce((select jsonb_build_object('count', count(*), 'value', coalesce(sum(b.amount), 0))
                                from public.payments b
                               where b.branch_id = v_branch and b.method = 'bank' and b.status = 'pending'), '{}'::jsonb),
    'by_method', coalesce((
      select jsonb_agg(jsonb_build_object(
               'method', coalesce(x.payment_method::text, 'unspecified'),
               'orders', x.n, 'total', x.amt) order by x.amt desc)
        from (select o2.payment_method, count(*) n, sum(o2.total) amt
                from public.orders o2
               where o2.branch_id = v_branch and o2.status <> 'cancelled'
                 and o2.placed_at >= v_lo and o2.placed_at < v_hi
               group by o2.payment_method) x), '[]'::jsonb),
    'by_type', coalesce((
      select jsonb_agg(jsonb_build_object('type', y.order_type::text, 'orders', y.n, 'total', y.amt) order by y.amt desc)
        from (select o3.order_type, count(*) n, sum(o3.total) amt
                from public.orders o3
               where o3.branch_id = v_branch and o3.status <> 'cancelled'
                 and o3.placed_at >= v_lo and o3.placed_at < v_hi
               group by o3.order_type) y), '[]'::jsonb),
    'declared_cash', coalesce((
      select sum(o4.total) from public.orders o4
       where o4.branch_id = v_branch and o4.status <> 'cancelled'
         and o4.payment_method = 'cash'
         and o4.placed_at >= v_lo and o4.placed_at < v_hi), 0),
    'cancelled', coalesce((
      select jsonb_build_object('orders', count(*), 'value', coalesce(sum(o5.total), 0))
        from public.orders o5
       where o5.branch_id = v_branch and o5.status = 'cancelled'
         and o5.placed_at >= v_lo and o5.placed_at < v_hi), '{}'::jsonb),
    'voided_items', coalesce((
      select jsonb_build_object('lines', count(*), 'value', coalesce(sum(i.total_price), 0))
        from public.order_items i join public.orders o6 on o6.id = i.order_id
       where o6.branch_id = v_branch and i.voided_at is not null
         and i.voided_at >= v_lo and i.voided_at < v_hi), '{}'::jsonb),
    'vat_exempt_sales', coalesce((
      select sum(ad.covered_amount) from public.applied_discounts ad join public.orders o8 on o8.id = ad.order_id
       where o8.branch_id = v_branch and ad.removed_at is null and ad.vat_exempt_amount > 0
         and o8.placed_at >= v_lo and o8.placed_at < v_hi), 0),
    'top_items', coalesce((
      select jsonb_agg(jsonb_build_object('name', z.name_snapshot, 'qty', z.q, 'total', z.amt) order by z.q desc)
        from (select i2.name_snapshot, sum(i2.quantity) q, sum(i2.total_price) amt
                from public.order_items i2 join public.orders o7 on o7.id = i2.order_id
               where o7.branch_id = v_branch and o7.status <> 'cancelled'
                 and i2.voided_at is null
                 and o7.placed_at >= v_lo and o7.placed_at < v_hi
               group by i2.name_snapshot order by sum(i2.quantity) desc limit 5) z), '[]'::jsonb),
    'already_closed', exists (
      select 1 from public.daily_closes d where d.branch_id = v_branch and d.close_date = p_date)
  ) into v
  from public.orders o
  where o.branch_id = v_branch and o.status <> 'cancelled'
    and o.placed_at >= v_lo and o.placed_at < v_hi;

  return v;
end $$;

create or replace function public.record_daily_close(p_date date, p_counted_cash numeric, p_notes text default null, p_branch uuid default null)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_branch uuid := coalesce(p_branch, private.my_branch());
  v_rep jsonb; v_expected numeric; v_id uuid;
begin
  if not private.can('finance.view') then
    raise exception 'permission_denied: finance.view' using errcode = '42501';
  end if;
  v_rep := public.daily_close_report(p_date, v_branch);
  -- Received cash (from payments), not declared cash.
  v_expected := coalesce((v_rep->>'received_cash')::numeric, 0);

  insert into public.daily_closes (
    branch_id, close_date, expected_cash, counted_cash, variance,
    gross_sales, discounts, net_sales, order_count, void_count, voided_value, notes, closed_by)
  values (
    v_branch, p_date, v_expected, coalesce(p_counted_cash, 0), coalesce(p_counted_cash, 0) - v_expected,
    coalesce((v_rep->>'gross_sales')::numeric, 0), coalesce((v_rep->>'discounts')::numeric, 0),
    coalesce((v_rep->>'net_sales')::numeric, 0), coalesce((v_rep->>'order_count')::int, 0),
    coalesce((v_rep->'voided_items'->>'lines')::int, 0), coalesce((v_rep->'voided_items'->>'value')::numeric, 0),
    nullif(btrim(coalesce(p_notes, '')), ''), auth.uid())
  on conflict (branch_id, close_date) do update set
    expected_cash = excluded.expected_cash, counted_cash = excluded.counted_cash,
    variance = excluded.variance, gross_sales = excluded.gross_sales, discounts = excluded.discounts,
    net_sales = excluded.net_sales, order_count = excluded.order_count, void_count = excluded.void_count,
    voided_value = excluded.voided_value, notes = excluded.notes, closed_by = auth.uid(), closed_at = now()
  returning id into v_id;

  insert into public.audit_log (actor_id, actor_role, action, entity_type, entity_id, metadata)
  values (auth.uid(), private.my_role(), 'till.close', 'daily_close', v_id,
          jsonb_build_object('date', p_date, 'expected', v_expected, 'counted', p_counted_cash,
                             'variance', coalesce(p_counted_cash, 0) - v_expected, 'basis', 'received'));
  return jsonb_build_object('id', v_id, 'expected_cash', v_expected,
    'counted_cash', coalesce(p_counted_cash, 0), 'variance', coalesce(p_counted_cash, 0) - v_expected);
end $$;

-- Realtime: the floor panel and portal refresh when money moves.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime'
                      and schemaname = 'public' and tablename = 'payments') then
    alter publication supabase_realtime add table public.payments;
  end if;
end $$;
