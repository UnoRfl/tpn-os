-- POS, modifiers, cash shifts, 86 (sql/32). Reuses the staff from t_31 if
-- present, otherwise creates them.
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000c001','cashier@x'),
  ('00000000-0000-0000-0000-00000000c004','cook@x') on conflict do nothing;
insert into public.staff (id, full_name, role, branch_id, employment_status)
select v.id::uuid, v.n, v.r::public.staff_role, (select id from public.branches limit 1), 'active'
  from (values ('00000000-0000-0000-0000-00000000c001','Cashier','dining'),
               ('00000000-0000-0000-0000-00000000c004','Cook','kitchen')) v(id, n, r)
on conflict (id) do update set role = excluded.role, branch_id = excluded.branch_id, employment_status = 'active';
create table if not exists public.t_ctx (k text primary key, v text);
grant all on public.t_ctx to anon, authenticated;

-- Fixture: a silog with a required "Egg" choice (1) and optional extras.
do $$ declare m uuid; g1 uuid; g2 uuid; begin
  insert into public.menu_items (name, price, is_available) values ('POS Silog', 150, true) returning id into m;
  insert into public.modifier_groups (name, min_select, max_select) values ('Egg', 1, 1) returning id into g1;
  insert into public.modifier_groups (name, min_select, max_select) values ('Extras', 0, 3) returning id into g2;
  insert into public.modifiers (group_id, name, price_delta) values (g1, 'Sunny side up', 0), (g1, 'Scrambled', 0),
         (g2, 'Extra rice', 25), (g2, 'Extra egg', 20);
  insert into public.menu_item_modifier_groups (menu_item_id, group_id) values (m, g1), (m, g2);
  insert into public.t_ctx values ('silog', m::text) on conflict (k) do update set v = excluded.v;
end $$;

do $$ declare b uuid; m uuid := (select v::uuid from public.t_ctx where k = 'silog'); egg uuid; rice uuid; r jsonb; begin
  select id into b from public.branches limit 1;
  select id into egg from public.modifiers where name = 'Scrambled';
  select id into rice from public.modifiers where name = 'Extra rice';
  -- Modifier priced by the server (150 + 25), quantity 2 → 350.
  r := public.submit_order(b, 'pickup', jsonb_build_array(jsonb_build_object('menu_item_id', m, 'quantity', 2,
         'modifiers', jsonb_build_array(egg, rice), 'unit_price', 1)));
  insert into public.t_results values ('modifier priced by server', (r->>'total')::numeric = 350, r::text);
  -- Required group missing → refused.
  begin perform public.submit_order(b, 'pickup', jsonb_build_array(jsonb_build_object('menu_item_id', m)));
    insert into public.t_results values ('required modifier enforced', false, '');
  exception when others then insert into public.t_results values ('required modifier enforced', sqlerrm like 'modifier_choice%', sqlerrm); end;
  -- A modifier that is not linked to the dish → refused.
  begin perform public.submit_order(b, 'pickup', jsonb_build_array(jsonb_build_object('menu_item_id', m,
          'modifiers', jsonb_build_array(egg, gen_random_uuid()))));
    insert into public.t_results values ('foreign modifier refused', false, '');
  exception when others then insert into public.t_results values ('foreign modifier refused', sqlerrm like 'unknown_modifier%', sqlerrm); end;
end $$;

do $$ declare b uuid; o uuid; begin
  -- Staff cannot insert order lines directly any more.
  select id into b from public.branches limit 1;
  select id into o from public.orders limit 1;
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000c001', true);
  set local role authenticated;
  begin insert into public.order_items (order_id, name_snapshot, quantity, unit_price, total_price, price_snapshot) values (o, 'x', 1, 0, 0, 0);
    reset role; insert into public.t_results values ('staff direct line insert blocked', false, '');
  exception when insufficient_privilege then reset role; insert into public.t_results values ('staff direct line insert blocked', true, ''); end;
end $$;

do $$ declare b uuid; m uuid := (select v::uuid from public.t_ctx where k = 'silog'); egg uuid; s uuid; r jsonb; rep jsonb; z jsonb; o uuid; begin
  select id into b from public.branches limit 1;
  select id into egg from public.modifiers where name = 'Sunny side up';
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000c001', true);
  set local role authenticated;
  s := public.open_cash_session(1000);
  begin perform public.open_cash_session(500); reset role; insert into public.t_results values ('one open drawer per register', false, '');
  exception when others then reset role; insert into public.t_results values ('one open drawer per register', sqlerrm = 'drawer_already_open', sqlerrm); end;
  set local role authenticated;
  -- Ring up at the counter (staff path, source = pos), take cash.
  r := public.submit_order(b, 'pickup', jsonb_build_array(jsonb_build_object('menu_item_id', m, 'modifiers', jsonb_build_array(egg))), null, 'Walk-in');
  o := (r->>'id')::uuid;
  perform public.record_cash_payment(o, 200);
  perform public.cash_move(s, 'cash_out', 50, 'Bought ice');
  perform public.cash_move(s, 'cash_in', 300, 'Change top-up from safe');
  rep := public.cash_session_report(s);
  reset role;
  insert into public.t_results values ('pos order source', (select source from public.orders where id = o) = 'pos', '');
  insert into public.t_results values ('cash attached to open drawer', (rep->>'cash_sales')::numeric = 150, rep::text);
  insert into public.t_results values ('X read expected cash', (rep->>'expected_cash')::numeric = 1000 + 150 - 50 + 300, rep->>'expected_cash');
  set local role authenticated;
  z := public.close_cash_session(s, 1390, '{"1000":1,"200":1,"100":1,"50":1,"20":2}', 'short 10');
  reset role;
  insert into public.t_results values ('Z read variance', (z->>'variance')::numeric = -10, z->>'variance');
  insert into public.t_results values ('drawer closed', (select status from public.cash_sessions where id = s) = 'closed', '');
end $$;

do $$ declare m uuid := (select v::uuid from public.t_ctx where k = 'silog'); begin
  -- Kitchen can 86 a dish; a guest then cannot order it.
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000c004', true);
  set local role authenticated;
  perform public.set_item_available(m, false, 'out of eggs');
  reset role;
  begin perform public.submit_order((select id from public.branches limit 1), 'pickup', jsonb_build_array(jsonb_build_object('menu_item_id', m)));
    insert into public.t_results values ('86 blocks ordering', false, '');
  exception when others then insert into public.t_results values ('86 blocks ordering', sqlerrm like 'item_sold_out%', sqlerrm); end;
  -- Cashier (dining) has no menu.86.
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000c001', true);
  set local role authenticated;
  begin perform public.set_item_available(m, true); reset role; insert into public.t_results values ('cashier cannot 86', false, '');
  exception when others then reset role; insert into public.t_results values ('cashier cannot 86', sqlerrm like 'permission_denied%', sqlerrm); end;
end $$;

select name, ok, detail from public.t_results;
