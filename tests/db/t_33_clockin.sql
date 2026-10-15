-- Verified clock-in (sql/33).
grant all on storage.objects to authenticated;
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000d001','crew@x'), ('00000000-0000-0000-0000-00000000d002','mgr2@x'),
  ('00000000-0000-0000-0000-00000000d003','gone2@x') on conflict do nothing;
insert into public.staff (id, full_name, role, branch_id, employment_status)
select v.id::uuid, v.n, v.r::public.staff_role, (select id from public.branches limit 1), v.st
  from (values ('00000000-0000-0000-0000-00000000d001','Crew','kitchen','active'),
               ('00000000-0000-0000-0000-00000000d002','Mgr Two','manager','active'),
               ('00000000-0000-0000-0000-00000000d003','Gone','kitchen','disabled')) v(id, n, r, st)
on conflict (id) do update set role = excluded.role, branch_id = excluded.branch_id, employment_status = excluded.employment_status;
create table if not exists public.t_ctx (k text primary key, v text);
grant all on public.t_ctx to anon, authenticated;

do $$ declare r jsonb; begin
  -- Manager at the restaurant trusts the network.
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000d002', true);
  perform set_config('request.headers', '{"cf-connecting-ip":"203.0.113.5"}', true);
  set local role authenticated;
  r := public.trust_current_network('Shop Wi-Fi');
  reset role;
  insert into public.t_results values ('manager trusts network', r->>'network' = '203.0.113.5', r::text);
end $$;

do $$ declare r jsonb; a jsonb; begin
  -- Crew on the shop Wi-Fi with a photo → verified once the photo is attached.
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000d001', true);
  perform set_config('request.headers', '{"cf-connecting-ip":"203.0.113.5"}', true);
  set local role authenticated;
  r := public.clock_in_verified(true);
  insert into storage.objects (bucket_id, name, owner) values ('attendance-photos', r->>'upload_path', auth.uid());
  a := public.attach_clockin_photo((r->>'attendance_id')::uuid);
  reset role;
  insert into public.t_ctx values ('att1', r->>'attendance_id') on conflict (k) do update set v = excluded.v;
  insert into public.t_results values ('trusted + photo = verified', a->>'status' = 'verified', a::text);
  insert into public.t_results values ('server records IP', (select host(clock_in_ip) from public.attendance where id = (r->>'attendance_id')::uuid) = '203.0.113.5', '');
end $$;

do $$ declare a uuid := (select v::uuid from public.t_ctx where k = 'att1'); n int; begin
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000d001', true);
  set local role authenticated;
  -- No back-dating: crew cannot write attendance directly.
  update public.attendance set clock_in_at = clock_in_at - interval '2 hours' where id = a;
  get diagnostics n = row_count;
  reset role;
  insert into public.t_results values ('crew cannot back-date', n = 0, n::text);
  set local role authenticated;
  select count(*) into n from storage.objects where bucket_id = 'attendance-photos';
  reset role;
  insert into public.t_results values ('crew cannot read photos', n = 0, n::text);
  set local role authenticated;
  begin perform public.clock_in_verified(true); reset role; insert into public.t_results values ('no double clock-in', false, '');
  exception when others then reset role; insert into public.t_results values ('no double clock-in', sqlerrm = 'already_clocked_in', sqlerrm); end;
  set local role authenticated;
  perform public.clock_out_verified();
  reset role;
  insert into public.t_results values ('clock out recorded', (select clock_out_at is not null from public.attendance where id = a), '');
end $$;

do $$ declare r jsonb; begin
  -- From home (other IP), camera denied → needs approval with both reasons.
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000d001', true);
  perform set_config('request.headers', '{"cf-connecting-ip":"198.51.100.20"}', true);
  set local role authenticated;
  r := public.clock_in_verified(false);
  -- And cannot upload into someone else's path.
  begin
    insert into storage.objects (bucket_id, name, owner) values ('attendance-photos', 'x/2026-01-01/00000000-0000-0000-0000-00000000d002/' || (r->>'attendance_id') || '.jpg', auth.uid());
    reset role; insert into public.t_results values ('cannot upload to another path', false, '');
  exception when others then reset role; insert into public.t_results values ('cannot upload to another path', true, sqlerrm); end;
  insert into public.t_ctx values ('att2', r->>'attendance_id') on conflict (k) do update set v = excluded.v;
  insert into public.t_results values ('untrusted, no photo → needs approval',
    (select verify_status from public.attendance where id = (r->>'attendance_id')::uuid) = 'needs_approval'
    and r->'reasons' @> '["untrusted_network","no_photo"]', r::text);
end $$;

do $$ declare a uuid := (select v::uuid from public.t_ctx where k = 'att2'); v text; q int; begin
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000d002', true);
  set local role authenticated;
  select count(*) into q from public.clockin_review_queue();
  begin perform public.review_clockin(a, false); reset role; insert into public.t_results values ('flag needs a note', false, '');
  exception when others then reset role; insert into public.t_results values ('flag needs a note', sqlerrm = 'note_required', sqlerrm); end;
  set local role authenticated;
  v := public.review_clockin(a, true, '{"Apron": true}', 'new PLDT IP', true);
  reset role;
  insert into public.t_results values ('queue shows it', q >= 1, q::text);
  insert into public.t_results values ('approve + trust new IP', v = 'approved'
    and exists (select 1 from public.trusted_networks where network = '198.51.100.20/32'), v);
end $$;

do $$ begin
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000d003', true);
  set local role authenticated;
  begin perform public.clock_in_verified(true); reset role; insert into public.t_results values ('disabled cannot clock in', false, '');
  exception when others then reset role; insert into public.t_results values ('disabled cannot clock in', sqlerrm = 'account_not_active', sqlerrm); end;
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000d001', true);
  set local role authenticated;
  begin perform public.clockin_review_queue(); reset role; insert into public.t_results values ('crew cannot see review queue', false, '');
  exception when others then reset role; insert into public.t_results values ('crew cannot see review queue', sqlerrm like 'permission_denied%', sqlerrm); end;
end $$;

select name, ok, detail from public.t_results;
