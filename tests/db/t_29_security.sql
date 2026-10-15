-- Hotfix behaviour tests. Run as postgres after migrations 01-29.
insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000a1','mgr@x'),('00000000-0000-0000-0000-0000000000a2','gone@x') on conflict do nothing;
insert into public.staff (id, full_name, role, branch_id, employment_status)
  select '00000000-0000-0000-0000-0000000000a1','Mgr','manager',(select id from public.branches limit 1),'active'
  where not exists (select 1 from public.staff where id='00000000-0000-0000-0000-0000000000a1');
insert into public.staff (id, full_name, role, branch_id, employment_status)
  select '00000000-0000-0000-0000-0000000000a2','Gone','manager',(select id from public.branches limit 1),'disabled'
  where not exists (select 1 from public.staff where id='00000000-0000-0000-0000-0000000000a2');
update public.staff set role='manager', branch_id=(select id from public.branches limit 1), employment_status='active' where id='00000000-0000-0000-0000-0000000000a1';
update public.staff set role='manager', branch_id=(select id from public.branches limit 1), employment_status='disabled' where id='00000000-0000-0000-0000-0000000000a2';

do $$ declare r jsonb; b uuid; m public.menu_items%rowtype; begin
  select id into b from public.branches limit 1;
  select * into m from public.menu_items where pax_options is null and price > 0 limit 1;
  perform set_config('request.headers', '{"cf-connecting-ip":"203.0.113.9"}', true);
  set local role anon;
  r := public.submit_order(b, 'pickup', jsonb_build_array(jsonb_build_object('menu_item_id', m.id, 'name','Free food','unit_price',0,'quantity',2)), null, '<img src=x onerror=alert(1)>', '0917-123', null, 'cash', null, null, 'dev-ABCDEFGH12', true);
  reset role;
  insert into public.t_results values ('server price', (r->>'total')::numeric = m.price*2, r::text);
  insert into public.t_results values ('name from menu', (select name_snapshot from public.order_items where order_id=(r->>'id')::uuid limit 1) = m.name, '');
  insert into public.t_results values ('token returned', r ? 'track_token', '');
end $$;

do $$ declare r jsonb; b uuid; m public.menu_items%rowtype; k text; begin
  select id into b from public.branches limit 1;
  select * into m from public.menu_items where pax_options is not null and jsonb_typeof(pax_options)='object' and pax_options <> '{}'::jsonb limit 1;
  if m.id is null then insert into public.t_results values ('pax price', true, 'no pax items in seed'); return; end if;
  select key into k from jsonb_each(m.pax_options) order by key desc limit 1;
  set local role anon;
  r := public.submit_order(b, 'pickup', jsonb_build_array(jsonb_build_object('menu_item_id', m.id, 'pax_size', k, 'quantity',1, 'unit_price', 1)));
  reset role;
  insert into public.t_results values ('pax price', (r->>'total')::numeric = (m.pax_options->>k)::numeric, r::text);
end $$;

do $$ declare b uuid; m uuid; begin
  select id into b from public.branches limit 1; select id into m from public.menu_items where pax_options is null limit 1;
  begin set local role anon; perform public.submit_order(b,'pickup','[{"menu_item_id":"00000000-0000-0000-0000-000000000000"}]'); reset role; insert into public.t_results values ('unknown item refused', false, '');
  exception when others then reset role; insert into public.t_results values ('unknown item refused', sqlerrm like 'unknown_item%', sqlerrm); end;
  begin set local role anon; perform public.submit_order(b,'pickup',jsonb_build_array(jsonb_build_object('menu_item_id',m,'quantity',500))); reset role; insert into public.t_results values ('qty cap', false, '');
  exception when others then reset role; insert into public.t_results values ('qty cap', sqlerrm like 'bad_quantity%', sqlerrm); end;
  update public.menu_items set is_available=false where id=m;
  begin set local role anon; perform public.submit_order(b,'pickup',jsonb_build_array(jsonb_build_object('menu_item_id',m))); reset role; insert into public.t_results values ('sold out refused', false, '');
  exception when others then reset role; insert into public.t_results values ('sold out refused', sqlerrm like 'item_sold_out%', sqlerrm); end;
  update public.menu_items set is_available=true where id=m;
end $$;

do $$ declare r jsonb; b uuid; m uuid; begin
  select id into b from public.branches limit 1; select id into m from public.menu_items where pax_options is null limit 1;
  set local role anon;
  r := public.submit_order(b,'pickup',jsonb_build_array(jsonb_build_object('menu_item_id',m)), null,'x',null,null,null,null,null, $x$');alert(1);//$x$);
  reset role;
  insert into public.t_results values ('bad device id dropped', (select device_id from public.order_items where order_id=(r->>'id')::uuid limit 1) is null, '');
end $$;

do $$ begin
  set local role anon;
  begin perform 1 from public.orders limit 1; reset role; insert into public.t_results values ('anon select orders denied', false, '');
  exception when insufficient_privilege then reset role; insert into public.t_results values ('anon select orders denied', true, ''); end;
end $$;
do $$ declare o uuid; begin
  select id into o from public.orders limit 1;
  set local role anon;
  begin insert into public.order_items (order_id, name_snapshot, quantity, unit_price, total_price, price_snapshot) values (o,'x',1,99999,99999,99999); reset role; insert into public.t_results values ('anon insert items denied', false, '');
  exception when insufficient_privilege then reset role; insert into public.t_results values ('anon insert items denied', true, ''); end;
end $$;

do $$ declare n text; t uuid; r1 jsonb; r2 jsonb; begin
  select order_number, track_token into n, t from public.orders where customer_name like '<img%' limit 1;
  set local role anon;
  r1 := public.track_order(n); r2 := public.track_order(n, t);
  reset role;
  insert into public.t_results values ('track no token hides name', r1->>'customer_name' is null and (r1->>'full')::boolean = false, left(r1::text,120));
  insert into public.t_results values ('track with token full', r2->>'customer_name' is not null and r2->>'total' is not null, '');
end $$;

do $$ begin
  perform set_config('request.jwt.claim.sub','00000000-0000-0000-0000-0000000000a2', true);
  set local role authenticated;
  insert into public.t_results values ('disabled: no permissions', (select count(*) from public.my_permissions()) = 0, '');
  insert into public.t_results values ('disabled: sees only own staff row', (select count(*) from public.staff where id <> auth.uid()) = 0, '');
  insert into public.t_results values ('disabled: sees no orders', (select count(*) from public.orders) = 0, '');
  reset role;
  perform set_config('request.jwt.claim.sub','00000000-0000-0000-0000-0000000000a1', true);
  set local role authenticated;
  insert into public.t_results values ('active manager sees orders', (select count(*) from public.orders) > 0, '');
  reset role;
  perform set_config('request.jwt.claim.sub','', true);
end $$;

do $$ begin
  set local role anon;
  insert into public.inquiries (inquiry_type, contact_name, message) values ('events','A','hello');
  begin insert into public.inquiries (inquiry_type, contact_name, message, status) values ('events','A','hello','resolved'); reset role; insert into public.t_results values ('anon cannot set status', false, '');
  exception when insufficient_privilege then reset role; insert into public.t_results values ('anon cannot set status', true, ''); end;
end $$;

do $$ declare b uuid; m uuid; i int; hit boolean := false; begin
  select id into b from public.branches limit 1; select id into m from public.menu_items where pax_options is null limit 1;
  perform set_config('request.headers', '{"cf-connecting-ip":"198.51.100.7"}', true);
  set local role anon;
  for i in 1..25 loop
    begin perform public.submit_order(b,'pickup',jsonb_build_array(jsonb_build_object('menu_item_id',m)));
    exception when others then if sqlerrm = 'too_many_requests' then hit := true; exit; end if; raise; end;
  end loop;
  reset role;
  insert into public.t_results values ('rate limit trips', hit, 'after '||i);
end $$;

select name, ok, left(detail,140) detail from public.t_results;

do $$ declare b uuid; m public.menu_items%rowtype; r jsonb; k text; begin
  -- What the pages really send: QR menu "2-3 pax", website with no size.
  select id into b from public.branches limit 1;
  insert into public.menu_items (name, price, is_available, pax_options) values ('Size Test', 300, true, '{"2-3": 300, "4-6": 520}') returning * into m;
  r := public.submit_order(b, 'pickup', jsonb_build_array(jsonb_build_object('menu_item_id', m.id, 'pax_size', '4-6 pax')));
  insert into public.t_results values ('size "4-6 pax" accepted', (r->>'total')::numeric = 520, r::text);
  r := public.submit_order(b, 'pickup', jsonb_build_array(jsonb_build_object('menu_item_id', m.id)));
  insert into public.t_results values ('no size = menu price', (r->>'total')::numeric = 300, r::text);
  begin perform public.submit_order(b, 'pickup', jsonb_build_array(jsonb_build_object('menu_item_id', m.id, 'pax_size', '9-99')));
    insert into public.t_results values ('made-up size refused', false, '');
  exception when others then insert into public.t_results values ('made-up size refused', sqlerrm like 'unknown_size%', sqlerrm); end;
end $$;

select name, ok, detail from public.t_results;
