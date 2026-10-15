-- Payments (sql/31). Fixtures: a dining cashier, a supervisor, a manager.
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000c001','cashier@x'),
  ('00000000-0000-0000-0000-00000000c002','super@x'),
  ('00000000-0000-0000-0000-00000000c003','boss@x') on conflict do nothing;
insert into public.staff (id, full_name, role, branch_id, employment_status)
select v.id::uuid, v.n, v.r::public.staff_role, (select id from public.branches limit 1), 'active'
  from (values ('00000000-0000-0000-0000-00000000c001','Cashier','dining'),
               ('00000000-0000-0000-0000-00000000c002','Super','supervisor'),
               ('00000000-0000-0000-0000-00000000c003','Boss','manager')) v(id, n, r)
on conflict (id) do update set role = excluded.role, branch_id = excluded.branch_id, employment_status = 'active';
create table if not exists public.t_ctx (k text primary key, v text);
grant all on public.t_ctx to anon, authenticated;

-- An order worth ₱1,000 placed through the normal customer path.
do $$ declare b uuid; m uuid; r jsonb; begin
  select id into b from public.branches limit 1;
  insert into public.menu_items (name, price, is_available) values ('Test Platter', 500, true) returning id into m;
  r := public.submit_order(b, 'pickup', jsonb_build_array(jsonb_build_object('menu_item_id', m, 'quantity', 2)),
                           null, 'Lola Nena', '09170000000');
  insert into public.t_ctx values ('order', r->>'id'), ('number', r->>'order_number'),
         ('token', (select track_token::text from public.orders where id = (r->>'id')::uuid));
end $$;

do $$ declare o uuid := (select v::uuid from public.t_ctx where k = 'order'); begin
  -- Nobody, not even a manager, can type "paid".
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000c003', true);
  set local role authenticated;
  begin
    update public.orders set payment_status = 'paid' where id = o;
    reset role; insert into public.t_results values ('manager cannot type paid', false, '');
  exception when others then
    reset role; insert into public.t_results values ('manager cannot type paid', sqlerrm like 'payment_state_is_derived%', sqlerrm);
  end;
end $$;

do $$ declare o uuid := (select v::uuid from public.t_ctx where k = 'order'); r jsonb; begin
  -- Cashier takes part cash: ₱400 of ₱1,000, tendered ₱500 → change ₱100.
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000c001', true);
  set local role authenticated;
  r := public.record_cash_payment(o, 500, 400);
  reset role;
  insert into public.t_results values ('partial cash change', (r->>'change_due')::numeric = 100, r::text);
  insert into public.t_results values ('partial cash still pending', r->>'payment_status' = 'pending' and (r->>'amount_due')::numeric = 600, r::text);
  -- Not enough cash refused.
  set local role authenticated;
  begin perform public.record_cash_payment(o, 100); reset role; insert into public.t_results values ('short cash refused', false, '');
  exception when others then reset role; insert into public.t_results values ('short cash refused', sqlerrm like 'not_enough_cash%', sqlerrm); end;
end $$;

do $$ declare o uuid := (select v::uuid from public.t_ctx where k = 'order'); pid uuid; st text; begin
  -- Bank transfer for the rest: pending until someone else confirms.
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000c001', true);
  set local role authenticated;
  pid := public.record_bank_transfer(o, 600, 'BDO-REF-7788');
  reset role;
  insert into public.t_results values ('bank pending not paid', (select payment_status from public.orders where id = o) = 'pending', '');
  -- Cashier cannot confirm (no permission).
  set local role authenticated;
  begin perform public.confirm_bank_transfer(pid, true); reset role; insert into public.t_results values ('cashier cannot confirm bank', false, '');
  exception when others then reset role; insert into public.t_results values ('cashier cannot confirm bank', sqlerrm like 'permission_denied%', sqlerrm); end;
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000c002', true);
  set local role authenticated;
  st := public.confirm_bank_transfer(pid, true, 'seen in BDO app');
  reset role;
  insert into public.t_results values ('confirmed bank settles order', st = 'paid' and (select payment_status from public.orders where id = o) = 'paid', st);
  insert into public.t_results values ('payment method named by largest', (select payment_method::text from public.orders where id = o) = 'bank', '');
end $$;

do $$ declare o uuid := (select v::uuid from public.t_ctx where k = 'order'); cash uuid; st text; begin
  select id into cash from public.payments where order_id = o and method = 'cash';
  -- Supervisor may not refund; manager may, with a reason.
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000c002', true);
  set local role authenticated;
  begin perform public.refund_payment(cash, 100, 'cold food'); reset role; insert into public.t_results values ('supervisor cannot refund', false, '');
  exception when others then reset role; insert into public.t_results values ('supervisor cannot refund', sqlerrm like 'permission_denied%', sqlerrm); end;
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000c003', true);
  set local role authenticated;
  begin perform public.refund_payment(cash, 500, 'too much'); reset role; insert into public.t_results values ('refund capped at payment', false, '');
  exception when others then reset role; insert into public.t_results values ('refund capped at payment', sqlerrm like 'bad_amount%', sqlerrm); end;
  st := public.refund_payment(cash, 100, 'cold food');
  reset role;
  insert into public.t_results values ('partial refund reopens balance', st = 'pending', st);
end $$;

-- HitPay: only service_role functions, amount computed server-side, webhook idempotent.
do $$ declare o uuid := (select v::uuid from public.t_ctx where k = 'order'); r jsonb; c jsonb; c2 jsonb; begin
  set local role anon;
  begin perform public.hitpay_begin((select v from public.t_ctx where k = 'number'), (select v::uuid from public.t_ctx where k = 'token'));
    reset role; insert into public.t_results values ('anon cannot call hitpay_begin', false, '');
  exception when insufficient_privilege then reset role; insert into public.t_results values ('anon cannot call hitpay_begin', true, ''); end;
  -- As the edge function (service_role): wrong token refused, right token works.
  begin perform public.hitpay_begin((select v from public.t_ctx where k = 'number'), gen_random_uuid());
    insert into public.t_results values ('wrong token refused', false, '');
  exception when others then insert into public.t_results values ('wrong token refused', sqlerrm = 'order_not_found', sqlerrm); end;
  r := public.hitpay_begin((select v from public.t_ctx where k = 'number'), (select v::uuid from public.t_ctx where k = 'token'));
  insert into public.t_results values ('hitpay amount is what is due', (r->>'amount')::numeric = 100, r::text);
  perform public.hitpay_attach((r->>'payment_id')::uuid, 'req_test_1', 'https://sandbox/checkout');
  c := public.hitpay_complete('req_test_1', 'completed', 99, 'PHP', 'pay_1', 'qrph', '{}');
  insert into public.t_results values ('wrong amount not accepted', c->>'reason' = 'amount_mismatch', c::text);
  c := public.hitpay_complete('req_test_1', 'completed', 100, 'PHP', 'pay_1', 'qrph', '{}');
  c2 := public.hitpay_complete('req_test_1', 'completed', 100, 'PHP', 'pay_1', 'qrph', '{}');
  insert into public.t_results values ('webhook settles order', c->>'payment_status' = 'paid', c::text);
  insert into public.t_results values ('webhook retry is harmless', c2->>'reason' = 'already_completed'
         and (select count(*) from public.payments where provider_request_id = 'req_test_1') = 1, c2::text);
end $$;

do $$ declare b uuid; m uuid; r jsonb; o uuid; t uuid; d public.applied_discounts; begin
  -- Senior at a table of 4 sharing ₱1,120: covered share ₱280 → VAT ₱30 + 20% of ₱250 = ₱50 → ₱80 off.
  select id into b from public.branches limit 1;
  insert into public.menu_items (name, price, is_available) values ('Family Tray', 1120, true) returning id into m;
  r := public.submit_order(b, 'dine_in', jsonb_build_array(jsonb_build_object('menu_item_id', m)));
  o := (r->>'id')::uuid;
  select id into t from public.discount_templates where legal_law = 'RA 9994' limit 1;
  if t is null then
    insert into public.discount_templates (code, name, kind, value, vat_treatment, legal_law, requires_id, is_active)
    values ('senior-test', 'Senior Citizen', 'percent', 20, 'vat_exempt', 'RA 9994', true, true) returning id into t;
  end if;
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000c002', true);
  set local role authenticated;
  d := public.apply_discount(o, t, 'OSCA-12345', 280);
  reset role;
  insert into public.t_results values ('senior share: VAT + 20%', d.amount_applied = 80 and d.vat_exempt_amount = 30, d.amount_applied || ' / ' || d.vat_exempt_amount);
  insert into public.t_results values ('order total after senior', (select total from public.orders where id = o) = 1040, (select total::text from public.orders where id = o));
end $$;

do $$ declare b uuid; m uuid; r jsonb; o uuid; v numeric; begin
  select id into b from public.branches limit 1;
  select id into m from public.menu_items where name = 'Test Platter';
  r := public.submit_order(b, 'dine_in', jsonb_build_array(jsonb_build_object('menu_item_id', m)));
  o := (r->>'id')::uuid;
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000c001', true);
  set local role authenticated;
  begin perform public.set_service_charge(o, 10); reset role; insert into public.t_results values ('cashier cannot set service charge', false, '');
  exception when others then reset role; insert into public.t_results values ('cashier cannot set service charge', sqlerrm like 'permission_denied%', sqlerrm); end;
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000c002', true);
  set local role authenticated;
  v := public.set_service_charge(o, 10);
  reset role;
  insert into public.t_results values ('10% service charge', v = 50 and (select total from public.orders where id = o) = 550, v::text);
end $$;

select name, ok, detail from public.t_results;
