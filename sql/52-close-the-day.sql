-- ═══════════════════════════════════════════════════════════════
-- 52 — close the day: one checklist of what is still open (Oct 25, 2026)
--
-- Ending the day was four separate jobs in three places: close every
-- table (floor), each cashier's Z read (counter), the manager's count
-- (Daily close) and the end-of-day booklet invoice (Daily close). Nothing
-- said what was still missing, and the Rev 36 live test left a drawer open.
--
-- close_day_checklist(date, branch) answers it in one call, for the
-- Daily close screen:
--   open_orders   every order not completed or cancelled, from that day
--                 or any day before it (a table left open yesterday counts)
--   unpaid        orders of that day that are finished but not fully paid
--   open_drawers  cash shifts still open, with what the drawer should hold
--   z_reads       shifts closed that day, with their variance
--   pending_bank  bank transfers waiting for a second person
--   clocked_in    people still clocked in (closing the app without
--                 Switch user leaves them on the clock)
--   invoices      invoice_day_summary for that day (missing booklet
--                 invoices, small sales for the end-of-day invoice)
--   daily_close   the recorded count, if any
--   blocking      how many of the above still need someone
--
-- Read-only. finance.view (same as the Daily close itself). Day = Manila.
-- ═══════════════════════════════════════════════════════════════

create or replace function public.close_day_checklist(p_date date default null, p_branch uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = '' set timezone to 'Asia/Manila'
as $$
declare
  v_branch uuid := coalesce(p_branch, private.my_branch());
  v_date   date := coalesce(p_date, current_date);
  v_lo     timestamptz := v_date::timestamptz;
  v_hi     timestamptz := (v_date + 1)::timestamptz;
  v_open   jsonb; v_unpaid jsonb; v_drawers jsonb; v_z jsonb; v_bank jsonb; v_clock jsonb;
  v_inv    jsonb; v_close jsonb; v_inv_left int;
begin
  if not private.can('finance.view') then
    raise exception 'permission_denied: finance.view' using errcode = '42501';
  end if;
  if v_branch is distinct from private.my_branch() and not private.has_role('admin') then
    raise exception 'wrong_branch' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', o.id, 'order_number', o.order_number, 'order_type', o.order_type,
           'status', o.status, 'table_number', t.table_number, 'customer_name', o.customer_name,
           'total', o.total, 'payment_status', o.payment_status,
           'amount_due', private.amount_due(o.id), 'placed_at', o.placed_at)
           order by t.table_number nulls last, o.placed_at), '[]'::jsonb)
    into v_open
    from public.orders o left join public.restaurant_tables t on t.id = o.table_id
   where o.branch_id = v_branch and o.status not in ('completed', 'cancelled')
     and o.placed_at < v_hi;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', o.id, 'order_number', o.order_number, 'order_type', o.order_type,
           'customer_name', o.customer_name, 'total', o.total,
           'amount_due', private.amount_due(o.id),
           'bank_waiting', exists (select 1 from public.payments p where p.order_id = o.id
                                    and p.method = 'bank' and p.status = 'pending'))
           order by o.placed_at), '[]'::jsonb)
    into v_unpaid
    from public.orders o
   where o.branch_id = v_branch and o.status = 'completed'
     and o.payment_status <> 'paid' and o.total > 0
     and o.placed_at >= v_lo and o.placed_at < v_hi;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', s.id, 'register', s.register_label, 'opened_at', s.opened_at,
           'opened_by', st.full_name, 'opening_float', s.opening_float,
           'expected_cash', (public.cash_session_report(s.id) ->> 'expected_cash')::numeric)
           order by s.opened_at), '[]'::jsonb)
    into v_drawers
    from public.cash_sessions s left join public.staff st on st.id = s.opened_by
   where s.branch_id = v_branch and s.status = 'open';

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', s.id, 'register', s.register_label, 'closed_at', s.closed_at,
           'closed_by', st.full_name, 'expected_cash', s.expected_cash,
           'counted_cash', s.counted_cash, 'variance', s.variance)
           order by s.closed_at), '[]'::jsonb)
    into v_z
    from public.cash_sessions s left join public.staff st on st.id = s.closed_by
   where s.branch_id = v_branch and s.status = 'closed'
     and s.closed_at >= v_lo and s.closed_at < v_hi;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', p.id, 'order_id', p.order_id, 'order_number', o.order_number,
           'amount', p.amount, 'reference', p.reference, 'created_at', p.created_at,
           'recorded_by', st.full_name, 'recorded_by_me', p.created_by = auth.uid())
           order by p.created_at), '[]'::jsonb)
    into v_bank
    from public.payments p
    join public.orders o on o.id = p.order_id
    left join public.staff st on st.id = p.created_by
   where p.branch_id = v_branch and p.method = 'bank' and p.status = 'pending';

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', a.id, 'staff_id', a.staff_id, 'name', st.full_name, 'role', st.role,
           'clock_in_at', a.clock_in_at)
           order by a.clock_in_at), '[]'::jsonb)
    into v_clock
    from public.attendance a join public.staff st on st.id = a.staff_id
   where st.branch_id = v_branch and a.clock_out_at is null
     and a.clock_in_at < v_hi
     and st.role not in ('kitchen_display', 'dine_in_display');

  v_inv := public.invoice_day_summary(v_date, v_branch);
  v_inv_left := jsonb_array_length(coalesce(v_inv -> 'missing', '[]'::jsonb))
              + case when coalesce((v_inv ->> 'small_count')::int, 0) > 0
                      and jsonb_array_length(coalesce(v_inv -> 'day_invoices', '[]'::jsonb)) = 0
                     then 1 else 0 end;

  select jsonb_build_object('expected_cash', d.expected_cash, 'counted_cash', d.counted_cash,
                            'variance', d.variance, 'closed_at', d.closed_at, 'closed_by', st.full_name)
    into v_close
    from public.daily_closes d left join public.staff st on st.id = d.closed_by
   where d.branch_id = v_branch and d.close_date = v_date;

  return jsonb_build_object(
    'date', v_date,
    'is_today', v_date = current_date,
    'open_orders', v_open,
    'unpaid', v_unpaid,
    'open_drawers', v_drawers,
    'z_reads', v_z,
    'pending_bank', v_bank,
    'clocked_in', v_clock,
    'invoices', v_inv,
    'invoices_left', v_inv_left,
    'daily_close', v_close,
    'blocking', jsonb_array_length(v_open) + jsonb_array_length(v_unpaid)
              + jsonb_array_length(v_drawers) + jsonb_array_length(v_bank)
              + jsonb_array_length(v_clock) + v_inv_left
              + case when v_close is null then 1 else 0 end);
end $$;
revoke all on function public.close_day_checklist(date, uuid) from public, anon;
grant execute on function public.close_day_checklist(date, uuid) to authenticated;
