-- Order idempotency (sql/41): a retry with the same key returns the first order.
create table if not exists public.t_ctx41 (k text primary key, v text);
grant all on public.t_ctx41 to anon, authenticated;

do $$ declare b uuid; b2 uuid; m uuid; m2 uuid; t uuid; begin
  insert into public.branches (code, name, is_active) values ('t41a', 'T41 A', true) returning id into b;
  insert into public.branches (code, name, is_active) values ('t41b', 'T41 B', true) returning id into b2;
  insert into public.menu_items (name, price, is_available) values ('T41 Sisig', 250, true) returning id into m;
  insert into public.menu_items (name, price, is_available) values ('T41 Halo-halo', 120, true) returning id into m2;
  insert into public.restaurant_tables (branch_id, table_number) values (b, 41) returning id into t;
  insert into public.t_ctx41 values ('b', b), ('b2', b2), ('m', m), ('m2', m2), ('t', t);
end $$;

-- Pickup: same key twice is one order with one set of lines.
do $$ declare b uuid := (select v::uuid from public.t_ctx41 where k = 'b'); m uuid := (select v::uuid from public.t_ctx41 where k = 'm');
  k text := 'aaaaaaaa-1111-4111-8111-000000000041'; r1 jsonb; r2 jsonb; r3 jsonb; begin
  r1 := public.submit_order(b, 'pickup', jsonb_build_array(jsonb_build_object('menu_item_id', m, 'quantity', 2)),
          null, 'Ana', '09170000041', null, 'cash', null, null, 'dev-t41', true, 'web', null, k);
  r2 := public.submit_order(b, 'pickup', jsonb_build_array(jsonb_build_object('menu_item_id', m, 'quantity', 2)),
          null, 'Ana', '09170000041', null, 'cash', null, null, 'dev-t41', true, 'web', null, k);
  insert into public.t_results values ('retry returns the same order', r1->>'id' = r2->>'id'
    and r1->>'order_number' = r2->>'order_number' and r1->>'track_token' = r2->>'track_token', r1::text || ' / ' || r2::text);
  insert into public.t_results values ('retry has the same reply shape',
    (select array_agg(x order by x) from jsonb_object_keys(r1) x) = (select array_agg(x order by x) from jsonb_object_keys(r2) x)
    and r2->>'total' = r1->>'total' and r2->>'joined_existing' = 'false', r2::text);
  insert into public.t_results values ('retry inserts nothing',
    (select count(*) from public.orders where branch_id = b) = 1
    and (select count(*) from public.order_items where order_id = (r1->>'id')::uuid) = 1
    and (select total from public.orders where id = (r1->>'id')::uuid) = 500, '');
  -- The dish sells out before the retry lands: still the original order, no error.
  update public.menu_items set is_available = false where id = m;
  r3 := public.submit_order(b, 'pickup', jsonb_build_array(jsonb_build_object('menu_item_id', m, 'quantity', 2)),
          null, 'Ana', '09170000041', null, 'cash', null, null, 'dev-t41', true, 'web', null, k);
  update public.menu_items set is_available = true where id = m;
  insert into public.t_results values ('retry after sell-out returns the order', r3->>'id' = r1->>'id', r3::text);
  insert into public.t_ctx41 values ('o1', r1->>'id');
end $$;

-- No key: unchanged, every call is a new order. A malformed key is refused.
do $$ declare b uuid := (select v::uuid from public.t_ctx41 where k = 'b'); m uuid := (select v::uuid from public.t_ctx41 where k = 'm');
  r1 jsonb; r2 jsonb; begin
  r1 := public.submit_order(b, 'pickup', jsonb_build_array(jsonb_build_object('menu_item_id', m, 'quantity', 1)), null, 'Ben', null);
  r2 := public.submit_order(b, 'pickup', jsonb_build_array(jsonb_build_object('menu_item_id', m, 'quantity', 1)), null, 'Ben', null);
  insert into public.t_results values ('no key still makes separate orders', r1->>'id' <> r2->>'id', '');
  begin
    perform public.submit_order(b, 'pickup', jsonb_build_array(jsonb_build_object('menu_item_id', m, 'quantity', 1)),
      null, 'Ben', null, null, null, null, null, null, true, null, null, 'short');
    insert into public.t_results values ('malformed key refused', false, '');
  exception when others then insert into public.t_results values ('malformed key refused', sqlerrm like 'bad_client_key%', sqlerrm); end;
end $$;

-- Server pricing holds on the keyed path: the browser's price is ignored.
do $$ declare b uuid := (select v::uuid from public.t_ctx41 where k = 'b'); m uuid := (select v::uuid from public.t_ctx41 where k = 'm');
  r jsonb; begin
  r := public.submit_order(b, 'pickup', jsonb_build_array(jsonb_build_object('menu_item_id', m, 'quantity', 1, 'unit_price', 1, 'name', 'Free')),
         null, 'Cy', null, null, null, null, null, null, true, null, null, 'bbbbbbbb-2222-4222-8222-000000000041');
  insert into public.t_results values ('keyed order priced by the server', (r->>'total')::numeric = 250
    and (select name_snapshot from public.order_items where order_id = (r->>'id')::uuid) = 'T41 Sisig', r::text);
end $$;

-- QR round appended to a table's open bill: the retry adds nothing.
do $$ declare b uuid := (select v::uuid from public.t_ctx41 where k = 'b'); m uuid := (select v::uuid from public.t_ctx41 where k = 'm');
  m2 uuid := (select v::uuid from public.t_ctx41 where k = 'm2'); t uuid := (select v::uuid from public.t_ctx41 where k = 't');
  k text := 'cccccccc-3333-4333-8333-000000000041'; r0 jsonb; r1 jsonb; r2 jsonb; begin
  r0 := public.submit_order(b, 'dine_in', jsonb_build_array(jsonb_build_object('menu_item_id', m, 'quantity', 1)),
          t, 'Dee', null, null, null, null, null, 'dev-t41q', true, 'qr', null, 'dddddddd-4444-4444-8444-000000000041');
  r1 := public.submit_order(b, 'dine_in', jsonb_build_array(jsonb_build_object('menu_item_id', m2, 'quantity', 2)),
          t, 'Eli', null, null, null, null, null, 'dev-t41r', true, 'qr', null, k);
  r2 := public.submit_order(b, 'dine_in', jsonb_build_array(jsonb_build_object('menu_item_id', m2, 'quantity', 2)),
          t, 'Eli', null, null, null, null, null, 'dev-t41r', true, 'qr', null, k);
  insert into public.t_results values ('round joins the table bill', r1->>'id' = r0->>'id' and r1->>'joined_existing' = 'true', r1::text);
  insert into public.t_results values ('retried round adds nothing', r2->>'id' = r0->>'id' and r2->>'joined_existing' = 'true'
    and (select count(*) from public.order_items where order_id = (r0->>'id')::uuid) = 2
    and (r2->>'total')::numeric = 490 and r2->>'delivery_fee' = '0', r2::text);
end $$;

-- A key from one branch can't fetch an order at another branch.
do $$ declare b2 uuid := (select v::uuid from public.t_ctx41 where k = 'b2'); m uuid := (select v::uuid from public.t_ctx41 where k = 'm'); begin
  begin
    perform public.submit_order(b2, 'pickup', jsonb_build_array(jsonb_build_object('menu_item_id', m, 'quantity', 1)),
      null, 'Fay', null, null, null, null, null, null, true, null, null, 'aaaaaaaa-1111-4111-8111-000000000041');
    insert into public.t_results values ('key is not shared across branches', false, '');
  exception when others then insert into public.t_results values ('key is not shared across branches', sqlerrm like 'client_key_in_use%', sqlerrm); end;
end $$;

-- Grants: customers can call the new signature, the old one is gone, the helper is private.
insert into public.t_results values
  ('anon can call submit_order with a key', has_function_privilege('anon',
     'public.submit_order(uuid, text, jsonb, uuid, text, text, text, text, text, timestamptz, text, boolean, text, uuid, text)', 'execute'), ''),
  ('old submit_order signature dropped', to_regprocedure(
     'public.submit_order(uuid, text, jsonb, uuid, text, text, text, text, text, timestamptz, text, boolean, text, uuid)') is null, ''),
  ('reply helper not callable by anon', not has_function_privilege('anon', 'private.submit_order_reply(uuid, boolean, text)', 'execute'), ''),
  ('one submit_order only', (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'submit_order') = 1, '');
select name, ok, detail from public.t_results;
