-- Manila days (sql/51): a 7:30 AM Manila order belongs to that Manila day
-- in finance_summary, even though the database runs on UTC.
create table if not exists public.t_ctx51 (k text primary key, v text);
grant all on public.t_ctx51 to anon, authenticated;

do $$ declare b uuid; m uuid; r jsonb; begin
  set local timezone to 'UTC';
  insert into public.branches (code, name, is_active) values ('t51', 'T51', true) returning id into b;
  insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000051d1', 'mgr51@x') on conflict do nothing;
  insert into public.staff (id, full_name, role, branch_id, employment_status) values
    ('00000000-0000-0000-0000-0000000051d1', 'Manager 51', 'manager', b, 'active')
  on conflict (id) do update set role = excluded.role, branch_id = excluded.branch_id, employment_status = 'active';
  insert into public.menu_items (name, price, is_available) values ('T51 Adobo', 300, true) returning id into m;
  r := public.submit_order(b, 'pickup', jsonb_build_array(jsonb_build_object('menu_item_id', m)), null, 'Early guest', null);
  -- 23:30 UTC on Oct 24 is 7:30 AM on Oct 25 in Manila.
  update public.orders set placed_at = '2026-10-24 23:30:00+00' where id = (r->>'id')::uuid;
  insert into public.t_ctx51 values ('branch', b), ('order', r->>'id');
end $$;

do $$ declare b uuid := (select v::uuid from public.t_ctx51 where k = 'branch'); n25 bigint; n24 bigint; begin
  set local timezone to 'UTC';
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000051d1', true);
  set local role authenticated;
  select coalesce(sum(order_count), 0) into n25 from public.finance_summary('2026-10-25', '2026-10-25', 'day', b);
  select coalesce(sum(order_count), 0) into n24 from public.finance_summary('2026-10-24', '2026-10-24', 'day', b);
  reset role;
  insert into public.t_results values ('7:30 AM Manila order counts on its Manila day', n25 = 1, n25::text);
  insert into public.t_results values ('and not on the UTC day before', n24 = 0, n24::text);
end $$;

do $$ declare f text; missing text := ''; begin
  foreach f in array array['finance_summary', 'inventory_variance', 'build_payroll_run', 'set_order_number',
                           'daily_close_report', 'record_daily_close', 'record_day_invoice', 'invoice_day_summary'] loop
    if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                    where n.nspname = 'public' and p.proname = f
                      and 'TimeZone=Asia/Manila' = any(p.proconfig)) then
      missing := missing || f || ' ';
    end if;
  end loop;
  -- (set_order_number uses now(), which a test can't move; the setting is
  -- what makes its YYYYMMDD the Manila date.)
  insert into public.t_results values ('every day-cutting function runs on Manila time', missing = '', missing);
end $$;
select name, ok, detail from public.t_results;
