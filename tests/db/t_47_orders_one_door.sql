-- Orders have one door (sql/47): no direct insert for staff or guests; submit_order still works.
do $$ declare b uuid; begin
  select id into b from public.branches limit 1;
  insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000047a1', 'crew47@x') on conflict do nothing;
  insert into public.staff (id, full_name, role, branch_id, employment_status)
  values ('00000000-0000-0000-0000-0000000047a1', 'Crew 47', 'dining', b, 'active')
  on conflict (id) do update set role = 'dining', branch_id = b, employment_status = 'active';
end $$;

do $$ declare b uuid; m uuid; r jsonb; ok boolean; err text; begin
  select id into b from public.branches limit 1;
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000047a1', true);
  set local role authenticated;
  begin
    insert into public.orders (branch_id, order_type, subtotal, total, payment_status, status) values (b, 'pickup', 1, 1, 'paid', 'completed');
    ok := true; err := null;
  exception when others then ok := false; err := sqlerrm; end;
  reset role;
  insert into public.t_results values ('crew cannot insert an order directly', not ok, coalesce(err, 'allowed'));
  set local role anon;
  begin
    insert into public.orders (branch_id, order_type, subtotal, total) values (b, 'pickup', 1, 1);
    ok := true; err := null;
  exception when others then ok := false; err := sqlerrm; end;
  reset role;
  insert into public.t_results values ('a guest cannot insert an order directly', not ok, coalesce(err, 'allowed'));
  insert into public.menu_items (name, price, is_available) values ('t47 dish', 120, true) returning id into m;
  set local role authenticated;
  r := public.submit_order(b, 'pickup', jsonb_build_array(jsonb_build_object('menu_item_id', m, 'quantity', 2)), null, 'Guest 47', '09170000047');
  reset role;
  insert into public.t_results values ('submit_order still works, priced by the server', (r->>'total')::numeric = 240, r::text);
end $$;

select name, ok, detail from public.t_results;
