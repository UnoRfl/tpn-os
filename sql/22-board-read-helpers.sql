-- ═══════════════════════════════════════════════════════════════
-- TPN OS — Migration 22: read helpers for the new boards
--
-- WHY THIS EXISTS
-- staff RLS (sql/01) is deliberately tight: below manager you can read
-- exactly one staff row, your own.
--
--   staff_self_read    id = auth.uid()
--   staff_branch_read  manager+ and same branch
--   staff_admin_read   admin+
--
-- That is correct for the staff table and wrong for the task board,
-- which broke in testing in two ways:
--
--   1. A kitchen crew member on a shared task could see the other
--      assignee's row in task_assignees but could not resolve their
--      NAME -- the join to staff returned nothing. "Work on it
--      together" is meaningless if you cannot see who else is on it.
--   2. tasks.assign floors at supervisor, but a supervisor cannot read
--      the staff list at all, so the assignment picker was empty.
--
-- The fix is not to loosen staff RLS -- pay, email and role history
-- must stay manager+. It is to expose the minimum a board needs
-- (id, name, role, active) through SECURITY DEFINER functions whose
-- own permission check is explicit. Nothing here returns email,
-- phone, pay or branch history.
--
-- Safe to re-run.
-- ═══════════════════════════════════════════════════════════════

-- ── Who can I put on a task? ──────────────────────────────────
create or replace function public.staff_directory()
returns table (
  id        uuid,
  full_name text,
  role      public.staff_role,
  initials  text,
  employment_status text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not (private.can('staff.view') or private.can('tasks.assign')) then
    raise exception 'permission_denied: staff.view' using errcode = '42501';
  end if;

  return query
    select s.id,
           s.full_name,
           s.role,
           upper(left(split_part(s.full_name, ' ', 1), 1)
                 || coalesce(left(nullif(split_part(s.full_name, ' ', 2), ''), 1), '')),
           coalesce(s.employment_status, 'active')
      from public.staff s
     where s.branch_id = private.my_branch()
        or private.can('settings.manage')
     order by s.full_name;
end $$;

comment on function public.staff_directory is
  'Minimal roster for assignment pickers and name resolution. Name, role and
   employment status only -- never email, phone or pay. Deliberately readable by
   anyone who can assign a task, which staff RLS does not permit directly.';


-- ── The task board in one round trip ──────────────────────────
create or replace function public.task_board(
  p_include_done boolean default false,
  p_branch       uuid default null
)
returns table (
  id           uuid,
  title        text,
  description  text,
  category     text,
  status       public.task_status,
  priority     public.task_priority,
  due_at       timestamptz,
  checklist    jsonb,
  created_at   timestamptz,
  started_at   timestamptz,
  completed_at timestamptz,
  created_by_name text,
  assignees    jsonb,
  my_state     public.task_assignee_state
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v_branch uuid := coalesce(p_branch, private.my_branch());
begin
  if not private.can('tasks.view') then
    -- not a board reader, but they may still be ON tasks: return only those
    return query
      select t.id, t.title, t.description, t.category, t.status, t.priority,
             t.due_at, t.checklist, t.created_at, t.started_at, t.completed_at,
             cb.full_name,
             private.task_assignee_json(t.id),
             (select ta.state from public.task_assignees ta
               where ta.task_id = t.id and ta.staff_id = auth.uid())
        from public.tasks t
        left join public.staff cb on cb.id = t.created_by
       where private.am_i_on_task(t.id)
         and (p_include_done or t.status not in ('done','cancelled'))
       order by t.due_at nulls last, t.created_at desc;
    return;
  end if;

  return query
    select t.id, t.title, t.description, t.category, t.status, t.priority,
           t.due_at, t.checklist, t.created_at, t.started_at, t.completed_at,
           cb.full_name,
           private.task_assignee_json(t.id),
           (select ta.state from public.task_assignees ta
             where ta.task_id = t.id and ta.staff_id = auth.uid())
      from public.tasks t
      left join public.staff cb on cb.id = t.created_by
     where (t.branch_id = v_branch or private.can('settings.manage'))
       and (p_include_done or t.status not in ('done','cancelled'))
     order by
       case t.priority when 'urgent' then 0 when 'high' then 1
                       when 'normal' then 2 else 3 end,
       t.due_at nulls last,
       t.created_at desc;
end $$;

create or replace function private.task_assignee_json(p_task uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'staff_id', ta.staff_id,
        'name',     s.full_name,
        'role',     s.role,
        'state',    ta.state,
        'note',     ta.note,
        'changed',  ta.state_changed_at
      ) order by s.full_name
    ), '[]'::jsonb)
    from public.task_assignees ta
    join public.staff s on s.id = ta.staff_id
   where ta.task_id = p_task
$$;

comment on function private.task_assignee_json is
  'Co-assignee names for one task, read past staff RLS on purpose -- see the
   header of this migration. Name, role and progress only.';


-- ── Stock at a glance, with its supplier and last delivery ────
create or replace function public.inventory_board(p_branch uuid default null)
returns table (
  id             uuid,
  name           text,
  name_tagalog   text,
  category       text,
  unit           text,
  current_stock  numeric,
  reorder_level  numeric,
  needs_reorder  boolean,
  last_unit_cost numeric,
  avg_unit_cost  numeric,
  stock_value    numeric,
  supplier_name  text,
  last_delivery  timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v_branch uuid := coalesce(p_branch, private.my_branch());
begin
  if not private.can('inventory.view') then
    raise exception 'permission_denied: inventory.view' using errcode = '42501';
  end if;

  return query
    select i.id, i.name, i.name_tagalog, i.category, i.unit,
           i.current_stock, i.reorder_level,
           (i.current_stock <= i.reorder_level),
           i.last_unit_cost, i.avg_unit_cost,
           round(i.current_stock * coalesce(i.avg_unit_cost, i.last_unit_cost, 0), 2),
           sup.name,
           (select max(sm.occurred_at) from public.stock_movements sm
             where sm.ingredient_id = i.id and sm.movement_type = 'delivery_in')
      from public.ingredients i
      left join public.suppliers sup on sup.id = i.default_supplier_id
     where i.branch_id = v_branch
       and i.is_active
     order by (i.current_stock <= i.reorder_level) desc, i.category nulls last, i.name;
end $$;


-- ── Grants ────────────────────────────────────────────────────
grant execute on function public.staff_directory()                  to authenticated;
grant execute on function public.task_board(boolean, uuid)           to authenticated;
grant execute on function public.inventory_board(uuid)               to authenticated;
revoke all on function public.staff_directory()        from anon;
revoke all on function public.task_board(boolean, uuid) from anon;
revoke all on function public.inventory_board(uuid)     from anon;
