-- Close the day (sql/52): one checklist of what is still open.
-- Own branch so nothing from other test files lands in it.
create table if not exists public.t_ctx52 (k text primary key, v text);
grant all on public.t_ctx52 to anon, authenticated;

do $$ declare b uuid; m uuid; r jsonb; begin
  insert into public.branches (code, name, is_active) values ('t52', 'T52', true) returning id into b;
  insert into auth.users (id, email) values
    ('00000000-0000-0000-0000-0000000052c1', 'cash52@x'),
    ('00000000-0000-0000-0000-0000000052d1', 'mgr52@x') on conflict do nothing;
  insert into public.staff (id, full_name, role, branch_id, employment_status) values
    ('00000000-0000-0000-0000-0000000052c1', 'Cashier 52', 'dining', b, 'active'),
    ('00000000-0000-0000-0000-0000000052d1', 'Manager 52', 'manager', b, 'active')
  on conflict (id) do update set full_name = excluded.full_name, role = excluded.role, branch_id = excluded.branch_id, employment_status = 'active';
  insert into public.menu_items (name, price, is_available) values ('T52 Kare-kare', 400, true) returning id into m;
  r := public.submit_order(b, 'pickup', jsonb_build_array(jsonb_build_object('menu_item_id', m)), null, 'Still cooking', null);
  insert into public.t_ctx52 values ('branch', b), ('open', r->>'id');
  r := public.submit_order(b, 'pickup', jsonb_build_array(jsonb_build_object('menu_item_id', m)), null, 'Left unpaid', null);
  update public.orders set status = 'completed' where id = (r->>'id')::uuid;
  insert into public.t_ctx52 values ('unpaid', r->>'id');
  r := public.submit_order(b, 'pickup', jsonb_build_array(jsonb_build_object('menu_item_id', m)), null, 'Paid by bank', null);
  insert into public.t_ctx52 values ('bank', r->>'id');
  insert into public.attendance (staff_id) values ('00000000-0000-0000-0000-0000000052c1');
end $$;

do $$ declare o uuid := (select v::uuid from public.t_ctx52 where k = 'bank'); s uuid; begin
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000052c1', true);
  set local role authenticated;
  s := public.open_cash_session(1000);
  perform public.record_manual_payment(o, 'bank', 'BPI-5252', null, 0, null);
  reset role;
  insert into public.t_ctx52 values ('shift', s);
end $$;

do $$ declare r jsonb; begin
  -- A cashier can't read the checklist.
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000052c1', true);
  set local role authenticated;
  begin perform public.close_day_checklist(); reset role; insert into public.t_results values ('cashier cannot read the checklist', false, '');
  exception when others then reset role; insert into public.t_results values ('cashier cannot read the checklist', sqlerrm like 'permission_denied%', sqlerrm); end;
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000052d1', true);
  set local role authenticated;
  r := public.close_day_checklist();
  reset role;
  insert into public.t_results values ('open orders listed (cooking + bank waiting)', jsonb_array_length(r->'open_orders') = 2, r->>'open_orders');
  insert into public.t_results values ('finished but unpaid listed', jsonb_array_length(r->'unpaid') = 1
    and (r->'unpaid'->0->>'amount_due')::numeric = 400, r->>'unpaid');
  insert into public.t_results values ('open drawer listed with its float', jsonb_array_length(r->'open_drawers') = 1
    and (r->'open_drawers'->0->>'expected_cash')::numeric = 1000, r->>'open_drawers');
  insert into public.t_results values ('bank transfer waiting listed', jsonb_array_length(r->'pending_bank') = 1
    and r->'pending_bank'->0->>'reference' = 'BPI-5252', r->>'pending_bank');
  insert into public.t_results values ('person still clocked in listed', jsonb_array_length(r->'clocked_in') = 1
    and r->'clocked_in'->0->>'name' = 'Cashier 52', r->>'clocked_in');
  insert into public.t_results values ('no count yet', r->'daily_close' = 'null'::jsonb, coalesce(r->>'daily_close', 'null'));
  insert into public.t_results values ('blocking adds it all up (2+1+1+1+1+count)', (r->>'blocking')::int = 7, r->>'blocking');
end $$;

do $$ declare r jsonb; s uuid := (select v::uuid from public.t_ctx52 where k = 'shift'); begin
  -- Z read on the drawer and the manager's count: both drop off the list.
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000052c1', true);
  set local role authenticated;
  perform public.close_cash_session(s, 990);
  reset role;
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000052d1', true);
  set local role authenticated;
  perform public.record_daily_close((now() at time zone 'Asia/Manila')::date, 0);
  r := public.close_day_checklist();
  reset role;
  insert into public.t_results values ('closed drawer moves to Z reads with its variance',
    jsonb_array_length(r->'open_drawers') = 0 and jsonb_array_length(r->'z_reads') = 1
    and (r->'z_reads'->0->>'variance')::numeric = -10, r->>'z_reads');
  insert into public.t_results values ('recorded count shows', r->'daily_close' <> 'null'::jsonb, r->>'daily_close');
  insert into public.t_results values ('blocking drops by two', (r->>'blocking')::int = 5, r->>'blocking');
end $$;
select name, ok, detail from public.t_results;
