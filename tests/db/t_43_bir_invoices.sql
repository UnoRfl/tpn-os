-- BIR booklet invoices (sql/43): recording numbers, what the day still needs, who may do it.
create table if not exists public.t_ctx43 (k text primary key, v text);
grant all on public.t_ctx43 to anon, authenticated;

do $$ declare b uuid; big uuid; small uuid; o1 jsonb; o2 jsonb; o3 jsonb; begin
  insert into public.branches (code, name, is_active) values ('t43', 'T43', true) returning id into b;
  insert into public.menu_items (name, price, is_available) values ('T43 Bilao', 600, true) returning id into big;
  insert into public.menu_items (name, price, is_available) values ('T43 Silog', 100, true) returning id into small;
  insert into auth.users (id, email) values
    ('00000000-0000-0000-0000-0000000043c1', 'cash43@x'),
    ('00000000-0000-0000-0000-0000000043d1', 'screen43@x') on conflict do nothing;
  insert into public.staff (id, full_name, role, branch_id, employment_status) values
    ('00000000-0000-0000-0000-0000000043c1', 'Cashier 43', 'dining', b, 'active'),
    ('00000000-0000-0000-0000-0000000043d1', 'Kitchen screen 43', 'kitchen_display', b, 'active')
  on conflict (id) do update set role = excluded.role, branch_id = excluded.branch_id, employment_status = 'active';
  -- sql/48: cash needs an open shift.
  insert into public.cash_sessions (branch_id, opened_by, opening_float) values (b, '00000000-0000-0000-0000-0000000043c1', 0);
  o1 := public.submit_order(b, 'pickup', jsonb_build_array(jsonb_build_object('menu_item_id', big, 'quantity', 1)), null, 'Big', null);
  o2 := public.submit_order(b, 'pickup', jsonb_build_array(jsonb_build_object('menu_item_id', small, 'quantity', 1)), null, 'Small A', null);
  o3 := public.submit_order(b, 'pickup', jsonb_build_array(jsonb_build_object('menu_item_id', small, 'quantity', 1)), null, 'Small B', null);
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000043c1', true);
  perform public.record_cash_payment((o1->>'id')::uuid, 600);
  perform public.record_cash_payment((o2->>'id')::uuid, 100);
  perform public.record_cash_payment((o3->>'id')::uuid, 100);
  update public.site_settings set value = null where key = 'bir.vat_registered';
  insert into public.t_ctx43 values ('b', b), ('o1', o1->>'id'), ('o2', o2->>'id'), ('o3', o3->>'id');
end $$;

-- Not VAT-registered (setting blank): only the sale over ₱500 needs its own invoice.
do $$ declare s jsonb; o1 uuid := (select v::uuid from public.t_ctx43 where k = 'o1'); begin
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000043c1', true);
  s := public.invoice_day_summary();
  insert into public.t_results values ('non-VAT: over ₱500 is missing',
    jsonb_array_length(s->'missing') = 1 and (s->'missing'->0->>'id')::uuid = o1, s::text);
  insert into public.t_results values ('non-VAT: small sales add up for the day invoice',
    (s->>'small_total')::numeric = 200 and (s->>'small_count')::int = 2, s::text);
  insert into public.t_results values ('blank VAT setting is flagged', (s->>'vat_status_set')::boolean = false, s::text);
end $$;

-- Recording: the cashier can; a direct UPDATE can't; a screen account can't.
do $$ declare o1 uuid := (select v::uuid from public.t_ctx43 where k = 'o1'); s jsonb; begin
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000043c1', true);
  begin
    update public.orders set invoice_no = 'FORGED' where id = o1;
    insert into public.t_results values ('direct update of invoice_no refused', false, '');
  exception when others then insert into public.t_results values ('direct update of invoice_no refused', sqlerrm like 'invoice_no_is_set_by_rpc%', sqlerrm); end;
  perform public.record_order_invoice(o1, '  0451 ');
  insert into public.t_results values ('cashier records the booklet number',
    (select invoice_no = '0451' and invoice_by = '00000000-0000-0000-0000-0000000043c1' from public.orders where id = o1), '');
  insert into public.t_results values ('recording is audited',
    exists (select 1 from public.audit_log where action = 'invoice.record' and entity_id = o1 and metadata->>'invoice_no' = '0451'), '');
  s := public.invoice_day_summary();
  insert into public.t_results values ('recorded sale no longer missing', jsonb_array_length(s->'missing') = 0, s::text);
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000043d1', true);
  begin
    perform public.record_order_invoice(o1, '9999');
    insert into public.t_results values ('screen account cannot record', false, '');
  exception when others then insert into public.t_results values ('screen account cannot record', sqlerrm like 'permission_denied%', sqlerrm); end;
end $$;

-- Day invoice for the small sales, then VAT-registered: every sale needs one.
do $$ declare s jsonb; begin
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000043c1', true);
  perform public.record_day_invoice((now() at time zone 'Asia/Manila')::date, '0452', 200);
  s := public.invoice_day_summary();
  insert into public.t_results values ('day invoice is listed',
    jsonb_array_length(s->'day_invoices') = 1 and s->'day_invoices'->0->>'invoice_no' = '0452', s::text);
  update public.site_settings set value = to_jsonb('yes'::text) where key = 'bir.vat_registered';
  s := public.invoice_day_summary();
  insert into public.t_results values ('VAT: every sale without its own number is missing',
    jsonb_array_length(s->'missing') = 2 and (s->>'small_total')::numeric = 0, s::text);
  update public.site_settings set value = null where key = 'bir.vat_registered';
end $$;

-- A blank number clears a mistake.
do $$ declare o1 uuid := (select v::uuid from public.t_ctx43 where k = 'o1'); begin
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000043c1', true);
  perform public.record_order_invoice(o1, '');
  insert into public.t_results values ('blank clears the number',
    (select invoice_no is null and invoice_at is null from public.orders where id = o1), '');
end $$;

insert into public.t_results values
  ('anon cannot record invoices', not has_function_privilege('anon', 'public.record_order_invoice(uuid, text)', 'execute'), ''),
  ('anon cannot record day invoices', not has_function_privilege('anon', 'public.record_day_invoice(date, text, numeric, uuid)', 'execute'), ''),
  ('anon cannot read the day summary', not has_function_privilege('anon', 'public.invoice_day_summary(date, uuid)', 'execute'), ''),
  ('anon cannot read day invoices', not has_table_privilege('anon', 'public.bir_day_invoices', 'select'), '');
select name, ok, detail from public.t_results;
