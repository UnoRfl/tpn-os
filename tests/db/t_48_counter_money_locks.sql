-- Counter money locks (sql/48): a paid bill is frozen, hand-entered bank
-- waits for a second person, no cash without an open shift.
-- Own branch so the shifts here are the only ones that count.
create table if not exists public.t_ctx48 (k text primary key, v text);
grant all on public.t_ctx48 to anon, authenticated;

do $$ declare b uuid; m uuid; m2 uuid; t uuid; r jsonb; tb uuid; begin
  insert into public.branches (code, name, is_active) values ('t48', 'T48', true) returning id into b;
  insert into auth.users (id, email) values
    ('00000000-0000-0000-0000-0000000048c1', 'cash48@x'),
    ('00000000-0000-0000-0000-0000000048b1', 'sup48@x'),
    ('00000000-0000-0000-0000-0000000048d1', 'mgr48@x') on conflict do nothing;
  insert into public.staff (id, full_name, role, branch_id, employment_status) values
    ('00000000-0000-0000-0000-0000000048c1', 'Cashier 48', 'dining', b, 'active'),
    ('00000000-0000-0000-0000-0000000048b1', 'Super 48', 'supervisor', b, 'active'),
    ('00000000-0000-0000-0000-0000000048d1', 'Manager 48', 'manager', b, 'active')
  on conflict (id) do update set role = excluded.role, branch_id = excluded.branch_id, employment_status = 'active';
  insert into public.menu_items (name, price, is_available) values ('T48 Sisig', 200, true) returning id into m;
  insert into public.menu_items (name, price, is_available) values ('T48 Rice', 50, true) returning id into m2;
  insert into public.discount_templates (code, name, kind, value) values ('t48-promo', 'T48 Promo', 'percent', 10) returning id into t;
  insert into public.t_ctx48 values ('branch', b), ('tmpl', t);
  r := public.submit_order(b, 'pickup', jsonb_build_array(jsonb_build_object('menu_item_id', m)), null, 'Cash guest', null);
  insert into public.t_ctx48 values ('cash', r->>'id');
  r := public.submit_order(b, 'pickup', jsonb_build_array(jsonb_build_object('menu_item_id', m)), null, 'Bank guest', null);
  insert into public.t_ctx48 values ('bank', r->>'id');
  r := public.submit_order(b, 'pickup', jsonb_build_array(jsonb_build_object('menu_item_id', m2)), null, 'Table A', null);
  insert into public.t_ctx48 values ('tabA', r->>'id');
  r := public.submit_order(b, 'pickup', jsonb_build_array(jsonb_build_object('menu_item_id', m2, 'quantity', 2)), null, 'Table B', null);
  insert into public.t_ctx48 values ('tabB', r->>'id');
  -- The bill that gets paid and then frozen: 2 × Sisig + 1 Rice = ₱450.
  r := public.submit_order(b, 'pickup', jsonb_build_array(jsonb_build_object('menu_item_id', m, 'quantity', 2),
                                                          jsonb_build_object('menu_item_id', m2)), null, 'Paid guest', null);
  insert into public.t_ctx48 values ('paid', r->>'id');
  r := public.submit_order(b, 'pickup', jsonb_build_array(jsonb_build_object('menu_item_id', m2, 'quantity', 2)), null, 'Offline guest', null);
  insert into public.t_ctx48 values ('off', r->>'id');
  r := public.submit_order(b, 'pickup', jsonb_build_array(jsonb_build_object('menu_item_id', m2)), null, 'Stale guest', null);
  insert into public.t_ctx48 values ('stale', r->>'id');
end $$;

do $$ declare o uuid := (select v::uuid from public.t_ctx48 where k = 'cash');
              a uuid := (select v::uuid from public.t_ctx48 where k = 'tabA'); s uuid; begin
  -- No shift open in this branch: cash is refused on every path.
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000048c1', true);
  set local role authenticated;
  s := public.my_shift();
  reset role;
  insert into public.t_results values ('my_shift is empty with no shift', s is null, coalesce(s::text, 'null'));
  set local role authenticated;
  begin perform public.record_cash_payment(o, 500); reset role; insert into public.t_results values ('cash refused with no open shift', false, '');
  exception when others then reset role; insert into public.t_results values ('cash refused with no open shift', sqlerrm like 'no_open_shift%', sqlerrm); end;
  set local role authenticated;
  begin perform public.settle_table_cash(array[a], 100); reset role; insert into public.t_results values ('table cash refused with no open shift', false, '');
  exception when others then reset role; insert into public.t_results values ('table cash refused with no open shift', sqlerrm like 'no_open_shift%', sqlerrm); end;
  insert into public.t_results values ('nothing written, still unpaid',
    not exists (select 1 from public.payments where order_id in (o, a))
    and (select payment_status from public.orders where id = o) = 'pending', '');
end $$;

do $$ declare o uuid := (select v::uuid from public.t_ctx48 where k = 'bank'); r jsonb; st text; begin
  -- Hand-entered bank: saved, but waiting; the bill is not paid.
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000048b1', true);
  set local role authenticated;
  r := public.record_manual_payment(o, 'bank', 'BPI-5551', null, 0, 'from Ana');
  reset role;
  insert into public.t_results values ('manual bank is pending',
    (r->>'pending')::boolean and (select status from public.payments where id = (r->>'payment_id')::uuid) = 'pending'
    and (select confirmed_by from public.payments where id = (r->>'payment_id')::uuid) is null, r::text);
  insert into public.t_results values ('manual bank does not pay the order',
    (select payment_status from public.orders where id = o) = 'pending' and (r->>'amount_due')::numeric = 200, r::text);
  -- The supervisor who typed it cannot confirm it.
  set local role authenticated;
  begin perform public.confirm_bank_transfer((r->>'payment_id')::uuid, true); reset role; insert into public.t_results values ('recorder cannot confirm own bank', false, '');
  exception when others then reset role; insert into public.t_results values ('recorder cannot confirm own bank', sqlerrm like 'needs_second_person%', sqlerrm); end;
  -- Someone else confirms: now it is paid.
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000048d1', true);
  set local role authenticated;
  st := public.confirm_bank_transfer((r->>'payment_id')::uuid, true, 'seen in BPI');
  reset role;
  insert into public.t_results values ('second person confirms, order paid', st = 'paid' and (select payment_status from public.orders where id = o) = 'paid', st);
end $$;

do $$ declare a uuid := (select v::uuid from public.t_ctx48 where k = 'tabA'); b uuid := (select v::uuid from public.t_ctx48 where k = 'tabB');
              r jsonb; pid uuid; st text; begin
  -- Close a table by bank: both rounds wait.
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000048c1', true);
  set local role authenticated;
  r := public.settle_table_manual(array[a, b], 'bank', 'BDO-9001');
  reset role;
  insert into public.t_results values ('table bank is pending for every round',
    (r->>'pending')::boolean and (r->>'orders_pending')::int = 2 and (r->>'orders_paid')::int = 0
    and (select count(*) from public.payments where order_id in (a, b) and status = 'pending') = 2
    and (select count(*) from public.orders where id in (a, b) and payment_status = 'pending') = 2, r::text);
  -- GCash is still received at once.
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000048d1', true);
  set local role authenticated;
  pid := (select id from public.payments where order_id = a and status = 'pending');
  st := public.confirm_bank_transfer(pid, true);
  reset role;
  insert into public.t_results values ('manager confirms the table round', st = 'paid', st);
end $$;

do $$ declare o uuid := (select v::uuid from public.t_ctx48 where k = 'cash'); s uuid; mine uuid; r jsonb; begin
  -- The manager opens a shift; the cashier (no cash.drawer needed) sees it and takes cash.
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000048d1', true);
  set local role authenticated;
  s := public.open_cash_session(1000);
  reset role;
  insert into public.t_ctx48 values ('s1', s);
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000048c1', true);
  set local role authenticated;
  mine := public.my_shift();
  r := public.record_cash_payment(o, 500);
  reset role;
  insert into public.t_results values ('my_shift shows the open shift', mine = s, coalesce(mine::text, 'null'));
  insert into public.t_results values ('cash goes into the open shift',
    (select cash_session_id from public.payments where id = (r->>'payment_id')::uuid) = s and r->>'payment_status' = 'paid', r::text);
end $$;

do $$ declare o uuid := (select v::uuid from public.t_ctx48 where k = 'paid'); t uuid := (select v::uuid from public.t_ctx48 where k = 'tmpl');
              rice uuid; sisig uuid; ad uuid; req uuid; tot numeric; begin
  select id into rice from public.order_items where order_id = o and name_snapshot = 'T48 Rice';
  select id into sisig from public.order_items where order_id = o and name_snapshot = 'T48 Sisig';
  -- Before paying: 10% promo, the rice voided, a void request for the sisig filed.
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000048d1', true);
  set local role authenticated;
  ad := (public.apply_discount(o, t, null, null)).id;
  perform public.void_order_item(rice, 'guest changed mind');
  reset role;
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000048c1', true);
  set local role authenticated;
  req := (public.request_void(o, sisig, 'too salty')).id;
  -- Paid in full.
  perform public.record_cash_payment(o, 1000);
  reset role;
  tot := (select total from public.orders where id = o);
  insert into public.t_ctx48 values ('ad', ad), ('req', req), ('rice', rice), ('sisig', sisig), ('tot', tot);
  insert into public.t_results values ('bill paid (₱450 − 10% − rice)', tot = 355 and (select payment_status from public.orders where id = o) = 'paid', tot::text);
end $$;

do $$ declare o uuid := (select v::uuid from public.t_ctx48 where k = 'paid');
              t uuid := (select v::uuid from public.t_ctx48 where k = 'tmpl');
              ad uuid := (select v::uuid from public.t_ctx48 where k = 'ad');
              req uuid := (select v::uuid from public.t_ctx48 where k = 'req');
              rice uuid := (select v::uuid from public.t_ctx48 where k = 'rice');
              sisig uuid := (select v::uuid from public.t_ctx48 where k = 'sisig'); begin
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000048d1', true);
  set local role authenticated;
  begin perform public.void_order_item(sisig, 'after paying'); reset role; insert into public.t_results values ('paid: void refused', false, '');
  exception when others then reset role; insert into public.t_results values ('paid: void refused', sqlerrm like 'order_already_paid%', sqlerrm); end;
  set local role authenticated;
  begin perform public.unvoid_order_item(rice); reset role; insert into public.t_results values ('paid: un-void refused', false, '');
  exception when others then reset role; insert into public.t_results values ('paid: un-void refused', sqlerrm like 'order_already_paid%', sqlerrm); end;
  set local role authenticated;
  begin perform public.approve_void_request(req, 'ok'); reset role; insert into public.t_results values ('paid: approving an old void request refused', false, '');
  exception when others then reset role; insert into public.t_results values ('paid: approving an old void request refused', sqlerrm like 'order_already_paid%', sqlerrm); end;
  set local role authenticated;
  begin perform public.remove_discount(ad, 'mistake'); reset role; insert into public.t_results values ('paid: remove_discount refused', false, '');
  exception when others then reset role; insert into public.t_results values ('paid: remove_discount refused', sqlerrm like 'order_already_paid%', sqlerrm); end;
  set local role authenticated;
  begin perform public.apply_discount(o, t, null, null); reset role; insert into public.t_results values ('paid: apply_discount refused', false, '');
  exception when others then reset role; insert into public.t_results values ('paid: apply_discount refused', sqlerrm like 'order_already_paid%', sqlerrm); end;
  set local role authenticated;
  begin update public.orders set discount_amount = 100 where id = o; reset role; insert into public.t_results values ('paid: direct discount change refused', false, '');
  exception when others then reset role; insert into public.t_results values ('paid: direct discount change refused', sqlerrm like 'order_already_paid%', sqlerrm); end;
  set local role authenticated;
  begin update public.orders set service_charge = 30 where id = o; reset role; insert into public.t_results values ('paid: direct service charge refused', false, '');
  exception when others then reset role; insert into public.t_results values ('paid: direct service charge refused', sqlerrm like 'order_already_paid%', sqlerrm); end;
  -- Even the SQL API (no staff identity) cannot move a paid total.
  begin update public.orders set service_charge = 30 where id = o; insert into public.t_results values ('paid: SQL API change refused', false, '');
  exception when others then insert into public.t_results values ('paid: SQL API change refused', sqlerrm like 'order_already_paid%', sqlerrm); end;
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000048c1', true);
  set local role authenticated;
  begin perform public.request_void(o, null, 'second thoughts'); reset role; insert into public.t_results values ('paid: new void request refused', false, '');
  exception when others then reset role; insert into public.t_results values ('paid: new void request refused', sqlerrm like 'order_already_paid%', sqlerrm); end;
  insert into public.t_results values ('paid: total and status unchanged',
    (select total from public.orders where id = o) = (select v::numeric from public.t_ctx48 where k = 'tot') and (select payment_status from public.orders where id = o) = 'paid'
    and (select voided_at from public.order_items where id = sisig) is null, '');
  -- A manager can still deny the old request.
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000048d1', true);
  set local role authenticated;
  perform public.deny_void_request(req, 'paid already');
  reset role;
  insert into public.t_results values ('paid: old request can be denied', (select status from public.void_requests where id = req) = 'denied', '');
end $$;

do $$ declare o uuid := (select v::uuid from public.t_ctx48 where k = 'paid');
              sisig uuid := (select v::uuid from public.t_ctx48 where k = 'sisig'); cash uuid; st text; begin
  -- Refund is the way to correct: it reopens the bill, then it can change.
  select id into cash from public.payments where order_id = o and method = 'cash' and kind = 'payment';
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000048d1', true);
  set local role authenticated;
  st := public.refund_payment(cash, 180, 'one sisig was too salty');
  perform public.void_order_item(sisig, 'too salty, refunded');
  reset role;
  insert into public.t_results values ('refund reopens, then void works',
    st = 'pending' and (select voided_at from public.order_items where id = sisig) is not null
    and (select total from public.orders where id = o) < (select v::numeric from public.t_ctx48 where k = 'tot'), st || ' ' || (select total from public.orders where id = o)::text);
end $$;

do $$ declare o uuid := (select v::uuid from public.t_ctx48 where k = 'off');
              s1 uuid := (select v::uuid from public.t_ctx48 where k = 's1'); rep jsonb; z jsonb; pid uuid; v numeric; begin
  -- Cash for ₱100 taken offline during shift 1; the shift is closed before
  -- it syncs. The ₱100 is in the drawer, so the count is ₱100 over.
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000048d1', true);
  set local role authenticated;
  rep := public.cash_session_report(s1);
  z := public.close_cash_session(s1, (rep->>'expected_cash')::numeric + 100);
  reset role;
  insert into public.t_results values ('closed shift is ₱100 over', (z->>'variance')::numeric = 100, z->>'variance');
  -- Same shift, no offline tag, nothing open: refused.
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000048c1', true);
  set local role authenticated;
  begin perform public.record_cash_payment(o, 100, null, 0, s1, null); reset role; insert into public.t_results values ('closed shift without offline tag refused', false, '');
  exception when others then reset role; insert into public.t_results values ('closed shift without offline tag refused', sqlerrm like 'no_open_shift%', sqlerrm); end;
  -- The offline replay keeps its shift, and the Z read is put right.
  set local role authenticated;
  pid := (public.record_cash_payment(o, 100, null, 0, s1, 'offline OFF-001 1a2b3c4d')->>'payment_id')::uuid;
  reset role;
  select variance into v from public.cash_sessions where id = s1;
  insert into public.t_results values ('offline replay stays with its shift', (select cash_session_id from public.payments where id = pid) = s1, '');
  insert into public.t_results values ('stored Z variance corrected to 0', v = 0, v::text);
  insert into public.t_results values ('late offline cash is audited',
    exists (select 1 from public.audit_log where action = 'cash_session.late_offline_cash' and entity_id = s1), '');
end $$;

do $$ declare o uuid := (select v::uuid from public.t_ctx48 where k = 'stale');
              s1 uuid := (select v::uuid from public.t_ctx48 where k = 's1'); s2 uuid; other uuid; pid uuid; begin
  -- A screen still holding the closed shift's id: cash goes to the open one.
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000048d1', true);
  set local role authenticated;
  s2 := public.open_cash_session(500);
  reset role;
  -- A shift from another branch is refused.
  insert into public.branches (code, name, is_active) values ('t48x', 'T48 other', true) returning id into other;
  insert into public.cash_sessions (branch_id, opened_by, opening_float) values (other, '00000000-0000-0000-0000-0000000048d1', 0) returning id into other;
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000048c1', true);
  set local role authenticated;
  begin perform public.record_cash_payment(o, 50, null, 0, other, null); reset role; insert into public.t_results values ('other branch shift refused', false, coalesce(other::text, 'no other shift'));
  exception when others then reset role; insert into public.t_results values ('other branch shift refused', sqlerrm like 'bad_cash_session%', sqlerrm); end;
  set local role authenticated;
  pid := (public.record_cash_payment(o, 50, null, 0, s1, null)->>'payment_id')::uuid;
  reset role;
  insert into public.t_results values ('stale shift id lands in the open shift', (select cash_session_id from public.payments where id = pid) = s2, '');
end $$;

do $$ begin
  -- Grants: my_shift is staff-only; the helper and triggers are private.
  insert into public.t_results values ('anon cannot call my_shift', not has_function_privilege('anon', 'public.my_shift()', 'execute'), '');
  insert into public.t_results values ('authenticated can call my_shift', has_function_privilege('authenticated', 'public.my_shift()', 'execute'), '');
  insert into public.t_results values ('order_paid helper is private', not has_function_privilege('authenticated', 'private.order_paid(uuid)', 'execute'), '');
end $$;

select name, ok, detail from public.t_results;
