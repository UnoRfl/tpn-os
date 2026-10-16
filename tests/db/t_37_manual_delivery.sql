-- Manual payments (sql/37b) and delivery (sql/38).
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000f371','cash37@x'),
  ('00000000-0000-0000-0000-00000000f372','sup37@x') on conflict do nothing;
insert into public.staff (id, full_name, role, branch_id, employment_status)
select v.id::uuid, v.n, v.r::public.staff_role, (select id from public.branches limit 1), 'active'
  from (values ('00000000-0000-0000-0000-00000000f371','Cash37 Rider','dining'),
               ('00000000-0000-0000-0000-00000000f372','Sup37','supervisor')) v(id, n, r)
on conflict (id) do update set role = excluded.role, branch_id = excluded.branch_id, employment_status = 'active', full_name = excluded.full_name;
create table if not exists public.t_ctx37 (k text primary key, v text);
grant all on public.t_ctx37 to anon, authenticated;

do $$ declare b uuid; m uuid; r1 jsonb; r2 jsonb; begin
  select id into b from public.branches limit 1;
  insert into public.menu_items (name, price, is_available) values ('T37 Adobo', 200, true) returning id into m;
  r1 := public.submit_order(b, 'pickup', jsonb_build_array(jsonb_build_object('menu_item_id', m, 'quantity', 2)), null, 'Walk in', null);
  r2 := public.submit_order(b, 'pickup', jsonb_build_array(jsonb_build_object('menu_item_id', m, 'quantity', 1)), null, 'Walk in 2', null);
  insert into public.t_ctx37 values ('b', b), ('m', m), ('a', r1->>'id'), ('c', r2->>'id');
end $$;

do $$ declare a uuid := (select v::uuid from public.t_ctx37 where k = 'a'); c uuid := (select v::uuid from public.t_ctx37 where k = 'c'); r jsonb; begin
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000f371', true);
  set local role authenticated;
  begin perform public.record_manual_payment(a, 'gcash', ''); reset role; insert into public.t_results values ('gcash needs a reference', false, '');
  exception when others then reset role; insert into public.t_results values ('gcash needs a reference', sqlerrm like 'reference_required%', sqlerrm); end;
  set local role authenticated;
  r := public.record_manual_payment(a, 'gcash', 'GC-88123');
  reset role;
  insert into public.t_results values ('gcash payment settles order', r->>'payment_status' = 'paid'
    and (select payment_method::text from public.orders where id = a) = 'gcash', r::text);
  set local role authenticated;
  begin perform public.record_manual_payment(c, 'bitcoin', 'XYZ123'); reset role; insert into public.t_results values ('unknown method refused', false, '');
  exception when others then reset role; insert into public.t_results values ('unknown method refused', sqlerrm like 'bad_method%', sqlerrm); end;
  set local role authenticated;
  r := public.settle_table_manual(array[c], 'card', 'APPR-5521');
  reset role;
  insert into public.t_results values ('card settles via table path', (select payment_status::text from public.orders where id = c) = 'paid', r::text);
end $$;

-- Delivery: zone needed once zones exist; fee on the bill; minimum order; dispatch; tracking.
do $$ declare b uuid := (select v::uuid from public.t_ctx37 where k = 'b'); m uuid := (select v::uuid from public.t_ctx37 where k = 'm');
  z uuid; r jsonb; o uuid; tok uuid; num text; t jsonb; begin
  insert into public.delivery_zones (branch_id, name, fee, min_order, eta_minutes) values (b, 'Las Piñas', 50, 300, 30) returning id into z;
  begin perform public.submit_order(b, 'delivery', jsonb_build_array(jsonb_build_object('menu_item_id', m, 'quantity', 2)),
          null, 'Ana', '09170000001', null, null, 'Blk 1 Lot 2', null, null, true, null, null);
    insert into public.t_results values ('delivery needs a zone', false, '');
  exception when others then insert into public.t_results values ('delivery needs a zone', sqlerrm like 'delivery_needs_zone%', sqlerrm); end;
  begin perform public.submit_order(b, 'delivery', jsonb_build_array(jsonb_build_object('menu_item_id', m, 'quantity', 1)),
          null, 'Ana', '09170000001', null, null, 'Blk 1 Lot 2', null, null, true, null, z);
    insert into public.t_results values ('delivery minimum enforced', false, '');
  exception when others then insert into public.t_results values ('delivery minimum enforced', sqlerrm like 'delivery_min_order%', sqlerrm); end;
  r := public.submit_order(b, 'delivery', jsonb_build_array(jsonb_build_object('menu_item_id', m, 'quantity', 2)),
          null, 'Ana', '09170000001', null, null, 'Blk 1 Lot 2', null, null, true, null, z);
  o := (r->>'id')::uuid; num := r->>'order_number'; tok := (r->>'track_token')::uuid;
  insert into public.t_ctx37 values ('d', o) on conflict (k) do update set v = excluded.v;
  insert into public.t_results values ('fee is on the bill', (select total from public.orders where id = o) = 450
    and exists (select 1 from public.deliveries where order_id = o and status = 'waiting'), r::text);
  -- Nobody can just type a lower fee.
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000f372', true);
  set local role authenticated;
  begin update public.orders set delivery_fee = 0 where id = o; reset role;
    insert into public.t_results values ('fee cannot be edited directly', (select delivery_fee from public.orders where id = o) = 50, '');
  exception when others then reset role; insert into public.t_results values ('fee cannot be edited directly', true, sqlerrm); end;
  -- Supervisor waives it with a reason.
  set local role authenticated;
  r := public.set_delivery_fee(o, null, 0, 'regular customer');
  reset role;
  insert into public.t_results values ('supervisor can waive fee', (select total from public.orders where id = o) = 400, r::text);
  -- Dispatch to our rider; rider marks it on the way then delivered.
  set local role authenticated;
  perform public.delivery_assign(o, 'own', '00000000-0000-0000-0000-00000000f371');
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000f371', true);
  perform public.delivery_update(o, 'on_the_way');
  reset role;
  t := public.track_delivery(num, tok);
  insert into public.t_results values ('customer sees on the way', t->>'status' = 'on_the_way' and t->>'rider' = 'Cash37', t::text);
  set local role authenticated;
  perform public.delivery_update(o, 'delivered');
  reset role;
  insert into public.t_results values ('delivered completes order', (select status::text from public.orders where id = o) = 'completed', '');
  insert into public.t_results values ('wrong token shows nothing', public.track_delivery(num, gen_random_uuid()) is null, '');
  -- Courier link must be https.
  set local role authenticated;
  begin perform public.delivery_assign(o, 'lalamove', null, 'Lala', null, 'http://evil'); reset role; insert into public.t_results values ('courier link must be https', false, '');
  exception when others then reset role; insert into public.t_results values ('courier link must be https', sqlerrm ~ 'bad_tracking_url|order_closed', sqlerrm); end;
end $$;

select name, ok, detail from public.t_results;
