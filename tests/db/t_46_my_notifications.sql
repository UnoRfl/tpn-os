-- The bell (sql/46): an admin sees their own and the shared notifications, not someone else's,
-- and "mark all read" leaves nothing unread behind.
do $$ declare b uuid; begin
  select id into b from public.branches limit 1;
  insert into auth.users (id, email) values
    ('00000000-0000-0000-0000-0000000046a1', 'admin46@x'),
    ('00000000-0000-0000-0000-0000000046b1', 'ceo46@x') on conflict do nothing;
  insert into public.staff (id, full_name, role, branch_id, employment_status) values
    ('00000000-0000-0000-0000-0000000046a1', 'Admin 46', 'admin', b, 'active'),
    ('00000000-0000-0000-0000-0000000046b1', 'CEO 46', 'ceo', b, 'active')
  on conflict (id) do update set role = excluded.role, branch_id = excluded.branch_id, employment_status = 'active';
  insert into public.notifications (user_id, branch_id, kind, title) values
    ('00000000-0000-0000-0000-0000000046a1', b, 'system', 't46 mine'),
    ('00000000-0000-0000-0000-0000000046b1', b, 'void_request', 't46 for the ceo'),
    (null, b, 'order_new', 't46 shared');
end $$;

do $$ declare adm uuid := '00000000-0000-0000-0000-0000000046a1'; titles text[]; c jsonb; left_after int; begin
  perform set_config('request.jwt.claim.sub', adm::text, true);
  set local role authenticated;
  select array_agg(x->>'title') into titles from public.my_notifications(500, true) x where x->>'title' like 't46%';
  perform public.mark_read('notification', null);
  select count(*) into left_after from public.my_notifications(500, true) x where x->>'title' like 't46%';
  c := public.my_unread_counts();
  reset role;
  insert into public.t_results values ('admin bell has own + shared', 't46 mine' = any(titles) and 't46 shared' = any(titles), array_to_string(titles, ', '));
  insert into public.t_results values ('admin bell skips the ceo''s own', not ('t46 for the ceo' = any(titles)), array_to_string(titles, ', '));
  insert into public.t_results values ('mark all read leaves none unread', left_after = 0, left_after::text);
  insert into public.t_results values ('ceo''s notification still unread for the ceo',
    (select read_at is null from public.notifications where title = 't46 for the ceo'), '');
end $$;

select name, ok, detail from public.t_results;
