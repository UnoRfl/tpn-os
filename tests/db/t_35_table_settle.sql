-- Settle a table in one go (sql/35). Fixtures: a dining cashier, a kitchen cook.
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000d351','cash35@x'),
  ('00000000-0000-0000-0000-00000000d352','cook35@x') on conflict do nothing;
insert into public.staff (id, full_name, role, branch_id, employment_status)
select v.id::uuid, v.n, v.r::public.staff_role, (select id from public.branches limit 1), 'active'
  from (values ('00000000-0000-0000-0000-00000000d351','Cash35','dining'),
               ('00000000-0000-0000-0000-00000000d352','Cook35','kitchen')) v(id, n, r)
on conflict (id) do update set role = excluded.role, branch_id = excluded.branch_id, employment_status = 'active';
create table if not exists public.t_ctx35 (k text primary key, v text);
grant all on public.t_ctx35 to anon, authenticated;

-- Two rounds at the same table: ₱300 and ₱450.
do $$ declare b uuid; m uuid; r1 jsonb; r2 jsonb; begin
  select id into b from public.branches limit 1;
  insert into public.menu_items (name, price, is_available) values ('T35 Sisig', 150, true) returning id into m;
  r1 := public.submit_order(b, 'pickup', jsonb_build_array(jsonb_build_object('menu_item_id', m, 'quantity', 2)), null, 'Table guest', null);
  r2 := public.submit_order(b, 'pickup', jsonb_build_array(jsonb_build_object('menu_item_id', m, 'quantity', 3)), null, 'Table guest', null);
  insert into public.t_ctx35 values ('a', r1->>'id'), ('b', r2->>'id');
end $$;

do $$ declare a uuid := (select v::uuid from public.t_ctx35 where k = 'a'); b uuid := (select v::uuid from public.t_ctx35 where k = 'b'); r jsonb; begin
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000d351', true);
  set local role authenticated;
  r := public.orders_amount_due(array[a, b]);
  reset role;
  insert into public.t_results values ('table due lists both orders',
    jsonb_array_length(r) = 2 and (select sum((x->>'amount_due')::numeric) from jsonb_array_elements(r) x) = 750, r::text);
  -- Short cash refused, nothing written.
  set local role authenticated;
  begin perform public.settle_table_cash(array[a, b], 700); reset role; insert into public.t_results values ('table short cash refused', false, '');
  exception when others then reset role; insert into public.t_results values ('table short cash refused', sqlerrm like 'not_enough_cash%', sqlerrm); end;
  insert into public.t_results values ('refusal wrote nothing', (select count(*) from public.payments where order_id in (a, b)) = 0, '');
  -- ₱1,000 with a ₱50 tip → change ₱200; both orders paid, one row each.
  set local role authenticated;
  r := public.settle_table_cash(array[a, b], 1000, 50);
  reset role;
  insert into public.t_results values ('table settle change', (r->>'change_due')::numeric = 200 and (r->>'orders_paid')::int = 2, r::text);
  insert into public.t_results values ('table settle marks both paid',
    (select bool_and(payment_status = 'paid') from public.orders where id in (a, b)), '');
  insert into public.t_results values ('one payment row per order with exact amount',
    (select count(*) = 2 and sum(amount) = 750 and sum(tip) = 50 from public.payments where order_id in (a, b) and kind = 'payment'), '');
  -- Settling again: nothing due.
  set local role authenticated;
  begin perform public.settle_table_cash(array[a, b], 1000); reset role; insert into public.t_results values ('settled table cannot pay twice', false, '');
  exception when others then reset role; insert into public.t_results values ('settled table cannot pay twice', sqlerrm like 'nothing_due%', sqlerrm); end;
  -- A signed-in account with no staff record may not take money.
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000dead1', true);
  set local role authenticated;
  begin perform public.settle_table_cash(array[a], 1000); reset role; insert into public.t_results values ('non-staff cannot settle table', false, '');
  exception when others then reset role; insert into public.t_results values ('non-staff cannot settle table', sqlerrm like 'permission_denied%', sqlerrm); end;
  -- Anonymous callers have no access at all.
  set local role anon;
  begin perform public.orders_amount_due(array[a]); reset role; insert into public.t_results values ('anon cannot read table due', false, '');
  exception when others then reset role; insert into public.t_results values ('anon cannot read table due', sqlerrm like 'permission denied%' or sqlerrm like 'permission_denied%', sqlerrm); end;
end $$;

select name, ok, detail from public.t_results;
