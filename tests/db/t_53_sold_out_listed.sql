-- Sold out stays listed (sql/53): guests and staff see a sold-out dish,
-- nobody but a manager sees one taken off the menu, and it still can't be ordered.
create table if not exists public.t_ctx53 (k text primary key, v text);
grant all on public.t_ctx53 to anon, authenticated;

do $$ declare b uuid; s uuid; o uuid; begin
  insert into public.branches (code, name, is_active) values ('t53', 'T53', true) returning id into b;
  insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000053a1', 'cook53@x') on conflict do nothing;
  insert into public.staff (id, full_name, role, branch_id, employment_status) values
    ('00000000-0000-0000-0000-0000000053a1', 'Cook 53', 'kitchen', b, 'active')
  on conflict (id) do update set full_name = excluded.full_name, role = excluded.role, branch_id = excluded.branch_id, employment_status = 'active';
  insert into public.menu_items (name, price, is_available) values ('T53 Sinigang', 250, false) returning id into s;
  insert into public.menu_items (name, price, is_available, is_listed) values ('T53 Old dish', 99, true, false) returning id into o;
  insert into public.t_ctx53 values ('branch', b), ('soldout', s), ('retired', o);
end $$;

do $$ declare s uuid := (select v::uuid from public.t_ctx53 where k = 'soldout');
              o uuid := (select v::uuid from public.t_ctx53 where k = 'retired');
              b uuid := (select v::uuid from public.t_ctx53 where k = 'branch');
              n_s int; n_o int; ok_now boolean; begin
  set local role anon;
  select count(*) into n_s from public.menu_items where id = s;
  select count(*) into n_o from public.menu_items where id = o;
  reset role;
  insert into public.t_results values ('guests see a sold-out dish', n_s = 1, n_s::text);
  insert into public.t_results values ('guests do not see a dish taken off the menu', n_o = 0, n_o::text);
  set local role anon;
  begin perform public.submit_order(b, 'pickup', jsonb_build_array(jsonb_build_object('menu_item_id', s)), null, 'Guest', null);
    reset role; insert into public.t_results values ('a sold-out dish still cannot be ordered', false, 'order went in');
  exception when others then reset role; insert into public.t_results values ('a sold-out dish still cannot be ordered', sqlerrm like 'item_sold_out%', sqlerrm); end;
  insert into public.t_results values ('a dish off the menu is never orderable',
    not (select is_available from public.menu_items where id = o), '');
  -- The cook who 86'd it can see it and switch it back on.
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000053a1', true);
  set local role authenticated;
  select count(*) into n_s from public.menu_items where id = s;
  perform public.set_item_available(s, true, 'back in stock');
  reset role;
  select is_available into ok_now from public.menu_items where id = s;
  insert into public.t_results values ('cook sees the sold-out dish and restocks it', n_s = 1 and ok_now, n_s::text || ' / ' || ok_now::text);
end $$;
select name, ok, detail from public.t_results;
