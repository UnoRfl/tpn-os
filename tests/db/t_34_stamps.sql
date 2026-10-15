-- Stamp cards (sql/34).
insert into auth.users (id, email) values ('00000000-0000-0000-0000-00000000e001','sup@x'), ('00000000-0000-0000-0000-00000000e002','crew3@x') on conflict do nothing;
insert into public.staff (id, full_name, role, branch_id, employment_status)
select v.id::uuid, v.n, v.r::public.staff_role, (select id from public.branches limit 1), 'active'
  from (values ('00000000-0000-0000-0000-00000000e001','Sup','supervisor'), ('00000000-0000-0000-0000-00000000e002','Crew3','dining')) v(id, n, r)
on conflict (id) do update set role = excluded.role, branch_id = excluded.branch_id, employment_status = 'active';
create table if not exists public.t_ctx (k text primary key, v text);
grant all on public.t_ctx to anon, authenticated;
update public.site_settings set value = 'true' where key = 'rewards.enabled';
update public.site_settings set value = '2' where key = 'rewards.stamps_needed';
update public.site_settings set value = '300' where key = 'rewards.min_order';

-- Helper: an order paid in cash by the supervisor, as the real flow does it.
create or replace function public.t_paid_order(p_phone text, p_price numeric) returns jsonb language plpgsql as $$
declare b uuid; m uuid; r jsonb;
begin
  select id into b from public.branches limit 1;
  insert into public.menu_items (name, price, is_available) values ('Stamp Dish ' || p_price || ' ' || gen_random_uuid(), p_price, true) returning id into m;
  r := public.submit_order(b, 'pickup', jsonb_build_array(jsonb_build_object('menu_item_id', m)), null, 'Ana', p_phone);
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000e001', true);
  set local role authenticated;
  perform public.record_cash_payment((r->>'id')::uuid, p_price);
  reset role;
  perform set_config('request.jwt.claim.sub', '', true);
  return r || jsonb_build_object('token', (select track_token from public.orders where id = (r->>'id')::uuid));
end $$;

do $$ declare r1 jsonb; r2 jsonb; c jsonb; n int; b uuid; m uuid; u jsonb; begin
  r1 := public.t_paid_order('0917 555 1234', 350);
  r2 := public.t_paid_order('+639175551234', 400);            -- same phone, other spelling
  perform public.t_paid_order('09175551234', 120);             -- below minimum
  -- An unpaid order earns nothing.
  select id into b from public.branches limit 1;
  insert into public.menu_items (name, price, is_available) values ('Unpaid Dish', 500, true) returning id into m;
  u := public.submit_order(b, 'pickup', jsonb_build_array(jsonb_build_object('menu_item_id', m)), null, 'Ana', '09175551234');
  select count(*) into n from public.loyalty_ledger where kind = 'stamp';
  insert into public.t_results values ('only paid orders over minimum stamp', n = 2, n::text);
  insert into public.t_results values ('one card per phone', (select count(*) from public.loyalty_cards) = 1, '');
  -- Paying again / re-settling never doubles.
  perform set_config('tpn.settle', 'on', true);
  update public.orders set payment_status = 'pending' where id = (r1->>'id')::uuid;
  update public.orders set payment_status = 'paid' where id = (r1->>'id')::uuid;
  perform set_config('tpn.settle', 'off', true);
  select count(*) into n from public.loyalty_ledger where kind = 'stamp';
  insert into public.t_results values ('no double stamp per order', n = 2, n::text);
  -- Anonymous: cannot read or write the ledger.
  set local role anon;
  begin perform 1 from public.loyalty_ledger; reset role; insert into public.t_results values ('anon cannot read ledger', false, '');
  exception when insufficient_privilege then reset role; insert into public.t_results values ('anon cannot read ledger', true, ''); end;
  set local role anon;
  begin insert into public.loyalty_ledger (card_id, kind, delta) select id, 'stamp', 50 from public.loyalty_cards limit 1;
    reset role; insert into public.t_results values ('anon cannot add stamps', false, '');
  exception when insufficient_privilege then reset role; insert into public.t_results values ('anon cannot add stamps', true, ''); end;
  -- Claim needs proof: right order + token + matching phone.
  set local role anon;
  begin perform public.claim_stamp_card('09175551234', r1->>'order_number', gen_random_uuid());
    reset role; insert into public.t_results values ('claim without token refused', false, '');
  exception when others then reset role; insert into public.t_results values ('claim without token refused', sqlerrm = 'proof_not_found', sqlerrm); end;
  set local role anon;
  begin perform public.claim_stamp_card('09998887777', r1->>'order_number', (r1->>'token')::uuid);
    reset role; insert into public.t_results values ('claim with other phone refused', false, '');
  exception when others then reset role; insert into public.t_results values ('claim with other phone refused', sqlerrm = 'phone_does_not_match_order', sqlerrm); end;
  set local role anon;
  c := public.claim_stamp_card('09175551234', r1->>'order_number', (r1->>'token')::uuid);
  reset role;
  insert into public.t_ctx values ('card', c->>'card_id'), ('secret', c->>'device_secret'), ('r1', r1->>'id')
    on conflict (k) do update set v = excluded.v;
  set local role anon;
  c := public.my_stamp_card((select v::uuid from public.t_ctx where k = 'card'), (select v from public.t_ctx where k = 'secret'));
  reset role;
  insert into public.t_results values ('card shows 2 stamps', (c->>'stamps')::int = 2, c::text);
  set local role anon;
  begin perform public.my_stamp_card((select v::uuid from public.t_ctx where k = 'card'), 'guess');
    reset role; insert into public.t_results values ('wrong device secret refused', false, '');
  exception when others then reset role; insert into public.t_results values ('wrong device secret refused', sqlerrm = 'card_not_on_this_device', sqlerrm); end;
end $$;

do $$ declare card uuid := (select v::uuid from public.t_ctx where k = 'card'); sec text := (select v from public.t_ctx where k = 'secret');
  code jsonb; r jsonb; begin
  set local role anon;
  code := public.stamp_card_code(card, sec);
  reset role;
  -- Crew (dining) cannot redeem.
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000e002', true);
  set local role authenticated;
  begin perform public.redeem_stamp_reward(card, code->>'code'); reset role; insert into public.t_results values ('crew cannot redeem', false, '');
  exception when others then reset role; insert into public.t_results values ('crew cannot redeem', sqlerrm like 'permission_denied%', sqlerrm); end;
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000e001', true);
  set local role authenticated;
  begin perform public.redeem_stamp_reward(card, '000000'); reset role; insert into public.t_results values ('wrong code refused', (code->>'code') = '000000', '');
  exception when others then reset role; insert into public.t_results values ('wrong code refused', sqlerrm = 'code_expired_or_wrong', sqlerrm); end;
  set local role authenticated;
  r := public.redeem_stamp_reward(card, code->>'code');
  reset role;
  insert into public.t_results values ('redeem spends stamps', (r->>'stamps_left')::int = 0, r::text);
  set local role authenticated;
  begin perform public.redeem_stamp_reward(card, code->>'code'); reset role; insert into public.t_results values ('code works once', false, '');
  exception when others then reset role; insert into public.t_results values ('code works once', sqlerrm in ('code_already_used', 'not_enough_stamps: 0 of 2'), sqlerrm); end;
end $$;

do $$ declare o uuid := (select v::uuid from public.t_ctx where k = 'r1'); p uuid; card uuid := (select v::uuid from public.t_ctx where k = 'card'); bal int; begin
  -- A refund takes the stamp back.
  select id into p from public.payments where order_id = o and kind = 'payment' limit 1;
  insert into auth.users (id, email) values ('00000000-0000-0000-0000-00000000e003','mgr3@x') on conflict do nothing;
  insert into public.staff (id, full_name, role, branch_id, employment_status)
  values ('00000000-0000-0000-0000-00000000e003', 'Mgr3', 'manager', (select id from public.branches limit 1), 'active') on conflict (id) do update set role = 'manager', branch_id = excluded.branch_id, employment_status = 'active';
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000e003', true);
  set local role authenticated;
  perform public.refund_payment(p, 350, 'wrong order');
  reset role;
  select coalesce(sum(delta), 0) into bal from public.loyalty_ledger where card_id = card;
  insert into public.t_results values ('refund reverses the stamp', exists (select 1 from public.loyalty_ledger where order_id = o and kind = 'reversal') and bal = -1, bal::text);
end $$;

select name, ok, detail from public.t_results;
