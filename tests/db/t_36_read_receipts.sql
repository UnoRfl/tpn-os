-- Read receipts (sql/36). A manager, two crew in the same branch.
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000e361','boss36@x'),
  ('00000000-0000-0000-0000-00000000e362','crewa36@x'),
  ('00000000-0000-0000-0000-00000000e363','crewb36@x') on conflict do nothing;
insert into public.staff (id, full_name, role, branch_id, employment_status)
select v.id::uuid, v.n, v.r::public.staff_role, (select id from public.branches limit 1), 'active'
  from (values ('00000000-0000-0000-0000-00000000e361','Boss36','manager'),
               ('00000000-0000-0000-0000-00000000e362','CrewA36','dining'),
               ('00000000-0000-0000-0000-00000000e363','CrewB36','dining')) v(id, n, r)
on conflict (id) do update set role = excluded.role, branch_id = excluded.branch_id, employment_status = 'active';
create table if not exists public.t_ctx36 (k text primary key, v text);
grant all on public.t_ctx36 to anon, authenticated;

-- One branch-wide notification, one broadcast message from the manager.
do $$ declare b uuid := (select id from public.branches limit 1); nid uuid; mid uuid; begin
  insert into public.notifications (user_id, branch_id, kind, title) values (null, b, 'system', 'Branch notice') returning id into nid;
  insert into public.messages (from_staff_id, to_staff_id, branch_id, subject, body)
  values ('00000000-0000-0000-0000-00000000e361', null, b, 'Team', 'Meeting at 3') returning id into mid;
  insert into public.t_ctx36 values ('n', nid), ('m', mid);
end $$;

do $$ declare nid uuid := (select v::uuid from public.t_ctx36 where k = 'n'); mid uuid := (select v::uuid from public.t_ctx36 where k = 'm'); c jsonb; begin
  -- Crew A reads both.
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000e362', true);
  set local role authenticated;
  perform public.mark_read('notification', array[nid]);
  perform public.mark_read('message', array[mid]);
  c := public.my_unread_counts();
  insert into public.t_ctx36 values ('a_read', (select x->>'read_at' from public.my_notifications(100) x where (x->>'id')::uuid = nid));
  reset role;
  insert into public.t_results values ('crew can mark branch notice read',
    (select v from public.t_ctx36 where k = 'a_read') is not null, c::text);
  insert into public.t_results values ('reader sees zero unread of these',
    (select count(*) from public.read_receipts where user_id = '00000000-0000-0000-0000-00000000e362') = 2, c::text);
  -- Crew B still has both unread.
  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000e363', true);
  set local role authenticated;
  c := public.my_unread_counts();
  reset role;
  insert into public.t_results values ('other crew still unread', (c->>'notifications')::int >= 1 and (c->>'messages')::int >= 1, c::text);
  -- Crew B cannot rewrite the manager's broadcast.
  set local role authenticated;
  begin
    update public.messages set body = 'Meeting cancelled' where id = mid;
    reset role;
    insert into public.t_results values ('crew cannot edit broadcast', (select body from public.messages where id = mid) = 'Meeting at 3', '');
  exception when others then
    reset role; insert into public.t_results values ('crew cannot edit broadcast', true, sqlerrm);
  end;
  -- Dismiss hides it for B only.
  set local role authenticated;
  perform public.dismiss_notification(nid);
  reset role;
  insert into public.t_results values ('dismiss keeps the row for others', exists (select 1 from public.notifications where id = nid), '');
end $$;

select name, ok, detail from public.t_results;
