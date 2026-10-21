-- ═══════════════════════════════════════════════════════════════
-- 44 — nobody climbs the ladder on their own
--
-- staff_admin_update checked who was calling (admin+), never what the
-- row became. An admin could PATCH their own row to role = 'ceo', or
-- demote the CEO and the director, straight through the REST API.
-- create-staff already refused "a role above yours"; this closes the
-- direct-update path, and the same hole in permission overrides
-- (roles.edit holders could grant themselves any key).
--
-- Rules, for a signed-in caller below CEO:
--   * your own role, custom access role and employment status are
--     changed by someone above you, never by you
--   * you can't edit or delete someone at or above your own tier
--   * you can't give anyone a tier above your own
--   * you can't set permission overrides for yourself or for someone
--     at or above your tier
-- The CEO keeps every key (same lockout rule as private.can). Calls
-- with no auth.uid() — the SQL editor, the service-role edge function,
-- sign-up — are not affected.
-- ═══════════════════════════════════════════════════════════════

create or replace function private.guard_staff_rank()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare me public.staff_role;
begin
  if auth.uid() is null then return coalesce(new, old); end if;
  select role into me from public.staff where id = auth.uid();
  if me = 'ceo' then return coalesce(new, old); end if;
  if me is null then
    raise exception 'permission_denied: not a staff account' using errcode = '42501';
  end if;

  if tg_op = 'DELETE' then
    if old.id = auth.uid() or old.role >= me then
      raise exception 'staff_outranks_you: % is at or above your level', old.role using errcode = '42501';
    end if;
    return old;
  end if;

  if tg_op = 'INSERT' then
    if new.role > me then
      raise exception 'role_above_yours: only someone at % or above can give that role', new.role using errcode = '42501';
    end if;
    return new;
  end if;

  if new.role is distinct from old.role
     or new.access_role_id is distinct from old.access_role_id
     or new.employment_status is distinct from old.employment_status then
    if old.id = auth.uid() then
      raise exception 'staff_self_change: your own role, access and status are changed by someone above you' using errcode = '42501';
    end if;
    if old.role >= me then
      raise exception 'staff_outranks_you: % is at or above your level', old.role using errcode = '42501';
    end if;
    if new.role > me then
      raise exception 'role_above_yours: only someone at % or above can give that role', new.role using errcode = '42501';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists trg_guard_staff_rank on public.staff;
create trigger trg_guard_staff_rank
  before insert or update or delete on public.staff
  for each row execute function private.guard_staff_rank();

create or replace function private.guard_override_rank()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare me public.staff_role; target public.staff_role; sid uuid;
begin
  if auth.uid() is null then return coalesce(new, old); end if;
  select role into me from public.staff where id = auth.uid();
  if me = 'ceo' then return coalesce(new, old); end if;
  sid := case when tg_op = 'DELETE' then old.staff_id else new.staff_id end;
  if sid = auth.uid() or (tg_op = 'UPDATE' and old.staff_id = auth.uid()) then
    raise exception 'override_self: someone above you sets your own permissions' using errcode = '42501';
  end if;
  select role into target from public.staff where id = sid;
  if me is null or target >= me then
    raise exception 'staff_outranks_you: % is at or above your level', target using errcode = '42501';
  end if;
  return coalesce(new, old);
end $$;

drop trigger if exists trg_guard_override_rank on public.staff_permission_overrides;
create trigger trg_guard_override_rank
  before insert or update or delete on public.staff_permission_overrides
  for each row execute function private.guard_override_rank();

revoke all on function private.guard_staff_rank()    from public, anon, authenticated;
revoke all on function private.guard_override_rank() from public, anon, authenticated;
