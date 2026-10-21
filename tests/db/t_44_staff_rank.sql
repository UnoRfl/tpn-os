-- Staff rank guard (sql/44): nobody promotes themselves or touches someone above them.
do $$ declare b uuid; begin
  insert into public.branches (code, name, is_active) values ('t44', 'T44', true) returning id into b;
  insert into auth.users (id, email) values
    ('00000000-0000-0000-0000-0000000044a1', 'admin44@x'),
    ('00000000-0000-0000-0000-0000000044b1', 'dir44@x'),
    ('00000000-0000-0000-0000-0000000044c1', 'ceo44@x'),
    ('00000000-0000-0000-0000-0000000044d1', 'crew44@x') on conflict do nothing;
  insert into public.staff (id, full_name, role, branch_id, employment_status) values
    ('00000000-0000-0000-0000-0000000044a1', 'Admin 44', 'admin', b, 'active'),
    ('00000000-0000-0000-0000-0000000044b1', 'Director 44', 'director', b, 'active'),
    ('00000000-0000-0000-0000-0000000044c1', 'CEO 44', 'ceo', b, 'active'),
    ('00000000-0000-0000-0000-0000000044d1', 'Crew 44', 'dining', b, 'active')
  on conflict (id) do update set role = excluded.role, branch_id = excluded.branch_id, employment_status = 'active';
end $$;

do $$
declare ok boolean; err text;
  adm uuid := '00000000-0000-0000-0000-0000000044a1';
  dir uuid := '00000000-0000-0000-0000-0000000044b1';
  ceo uuid := '00000000-0000-0000-0000-0000000044c1';
  crew uuid := '00000000-0000-0000-0000-0000000044d1';
begin
  perform set_config('request.jwt.claim.sub', adm::text, true);
  begin update public.staff set role = 'ceo' where id = adm; ok := true; err := null;
  exception when others then ok := false; err := sqlerrm; end;
  insert into public.t_results values ('admin cannot make themselves CEO', not ok and err like 'staff_self_change%', coalesce(err, 'allowed'));
  begin update public.staff set role = 'dining' where id = ceo; ok := true; err := null;
  exception when others then ok := false; err := sqlerrm; end;
  insert into public.t_results values ('admin cannot demote the CEO', not ok and err like 'staff_outranks_you%', coalesce(err, 'allowed'));
  begin update public.staff set employment_status = 'terminated' where id = dir; ok := true; err := null;
  exception when others then ok := false; err := sqlerrm; end;
  insert into public.t_results values ('admin cannot disable the director', not ok, coalesce(err, 'allowed'));
  begin update public.staff set role = 'director' where id = crew; ok := true; err := null;
  exception when others then ok := false; err := sqlerrm; end;
  insert into public.t_results values ('admin cannot give a role above their own', not ok and err like 'role_above_yours%', coalesce(err, 'allowed'));
  begin update public.staff set role = 'supervisor' where id = crew; ok := true; err := null;
  exception when others then ok := false; err := sqlerrm; end;
  insert into public.t_results values ('admin can still promote crew to supervisor', ok, coalesce(err, 'ok'));
  begin update public.staff set full_name = 'Admin Forty-Four' where id = adm; ok := true; err := null;
  exception when others then ok := false; err := sqlerrm; end;
  insert into public.t_results values ('editing your own name still works', ok, coalesce(err, 'ok'));
  begin insert into public.staff_permission_overrides (staff_id, permission_key, allowed) values (adm, 'payroll.edit', true); ok := true; err := null;
  exception when others then ok := false; err := sqlerrm; end;
  insert into public.t_results values ('admin cannot grant themselves a permission', not ok and err like 'override_self%', coalesce(err, 'allowed'));
  begin insert into public.staff_permission_overrides (staff_id, permission_key, allowed) values (dir, 'payroll.edit', false); ok := true; err := null;
  exception when others then ok := false; err := sqlerrm; end;
  insert into public.t_results values ('admin cannot set overrides on the director', not ok, coalesce(err, 'allowed'));
  begin insert into public.staff_permission_overrides (staff_id, permission_key, allowed) values (crew, 'menu.86', true); ok := true; err := null;
  exception when others then ok := false; err := sqlerrm; end;
  insert into public.t_results values ('admin can still set overrides on crew', ok, coalesce(err, 'ok'));
  perform set_config('request.jwt.claim.sub', dir::text, true);
  begin delete from public.staff where id = ceo; ok := true; err := null;
  exception when others then ok := false; err := sqlerrm; end;
  insert into public.t_results values ('director cannot delete the CEO', not ok and err like 'staff_outranks_you%', coalesce(err, 'allowed'));
  perform set_config('request.jwt.claim.sub', ceo::text, true);
  begin update public.staff set role = 'manager' where id = adm; ok := true; err := null;
  exception when others then ok := false; err := sqlerrm; end;
  insert into public.t_results values ('the CEO can still change anyone', ok, coalesce(err, 'ok'));
  perform set_config('request.jwt.claim.sub', '', true);
  begin update public.staff set role = 'admin' where id = adm; ok := true; err := null;
  exception when others then ok := false; err := sqlerrm; end;
  insert into public.t_results values ('service role / SQL editor is not blocked', ok, coalesce(err, 'ok'));
end $$;
select name, ok, detail from public.t_results;
